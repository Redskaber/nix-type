该实现整体已经接近“单路径哈希语义闭包”，但仍存在几个**结构性风险点（不是局部 bug）**，主要集中在 INV-H2 / INV-H3 / cache 一致性三个层面。

下面按严重度拆解。

---

# 1. 🔴 INV-H2 在实现上“语义成立，但计算路径未收敛”

规范声明：

```
typeHash = nfHash ∘ normalize
nfHash   = H(serialize(NF))
```

但当前问题在于：

```nix
typeHash t =
  let nf = normalizeLib.normalize t; in
  nfHash nf;
```

以及：

```nix
nfHash t = serializeReprAlphaCanonical t.repr
```

## 问题点

### ❌ normalize 被执行在 memo / hashCons / verify 多个路径中重复触发

例如：

- `typeHash`
- `verifyHashConsistency`
- `typeHashCached`
- `hashCons`

都各自调用 normalize

👉 导致：

> normalize 不再是“唯一 canonical entry point”，而是“多入口副作用函数”

### 影响

- 性能退化（重复 NF computation）
- memo key 稳定性下降（尤其 normalize 非严格 pure cache 时）
- INV-H2 在“实现层”不再是 DAG 单路径，而是 fan-out

---

## 建议修复（关键）

引入**canonical NF materialization 层**

```nix
materializeNF = t: normalizeLib.normalize t;
```

然后强制：

- 所有路径必须使用 NF cache
- typeHash 不允许直接调用 normalize

---

# 2. 🔴 nfHash 命名与语义已经“误导性存在”

当前：

```nix
nfHash = t:
  serializeReprAlphaCanonical t.repr;
```

问题：

### ❌ nfHash 实际不是 NF hash

它是：

> repr-hash（assumes already normalized Type）

但没有 enforce：

```nix
assert isNF t;
```

---

## 风险

如果 upstream 传入非 NF：

- hash 仍会计算
- 但 INV-H2 被静默破坏
- collision 不会立即显现（延迟 bug）

---

## 建议

```nix
nfHash = t:
  assert normalizeLib.isNF t;
  builtins.hashString "sha256" ...
```

或至少：

```nix
debugAssertNF t;
```

---

# 3. 🔴 typeHashCached 破坏 INV-H2 的“单 key 收敛语义”

当前实现：

```nix
key = typeHash t;
cached = memo.cache.${key}
```

## 问题本质

你在做：

> cache key = normalized hash

但 value = same hash

```nix
cache = { ${key} = key; }
```

### ❌ 这实际上是 redundant identity cache

没有 memo value，只是 hash lookup table

---

## 更严重的问题

如果 future system 想 cache：

- NF object
- or serialized repr
- or substitution result

现在结构不支持扩展

---

## 建议结构

```nix
cache = {
  ${key} = {
    nf = nf;
    hash = key;
  };
};
```

否则 memo layer 是“空语义层”。

---

# 4. 🟡 hashCons 的 id injection 是副作用污染

```nix
let t' = t // { id = h; };
```

## 问题

这是：

> structural type → identity-augmented type

但：

- id 不参与 typeHash
- 但改变 structural equality semantics

### 风险

- typeEq vs structuralEq 分裂
- hash-consed object 不再 pure

---

## 建议

改为：

```nix
{ type = t; tag = h; }
```

避免污染 IR node

---

# 5. 🟡 verifyHashConsistency 逻辑冗余且“误判空间存在”

当前：

```nix
hashEq && nfEqual → consistent-equal
!hashEq && !nfEqual → consistent-different
```

问题：

### ❌ “双 false 判定 consistent”是不安全的

因为：

- hash collision 未发生 ≠ correctness
- nfEqual ≠ correctness guarantee（depends on normalize correctness）

---

## 更严格版本应该是：

```text
consistent ⇔ nfEqual
```

hash 只用于 performance probe，不用于 correctness classification

---

# 6. 🟢 结构上最大的优点（值得保留）

这个设计其实有一个非常好的点：

### ✔ 单入口 memoKey

```nix
memoKey = t: typeHash t;
```

这是 Phase 3 正确方向：

> 所有缓存统一进入 normalized hash space

---

# 7. 总体结论

## 当前系统状态

| 模块               | 状态                        |
| ------------------ | --------------------------- |
| INV-H2（语义）     | ✔ 成立                      |
| INV-H2（实现路径） | ⚠ 非单路径                  |
| memo consistency   | ⚠ 伪 cache                  |
| hash-consing       | ⚠ side-effect contamination |
| nfHash safety      | ❌ 不保证 NF precondition   |

---

# 8. 最关键修复优先级（建议顺序）

1. **引入 NF materialization cache（统一 normalize 入口）**
2. **nfHash 增加 NF invariant check**
3. **memo cache 改为结构化 value（不是 string identity）**
4. **移除 id injection 或隔离 IR metadata**
5. **verifyHashConsistency 改为 nf-only truth model**

---

如果你下一步是 Phase 3 收敛（尤其 INV-H2/H3 强化），建议下一步直接做：

> “NF Canonicalization Layer（single-pass, memoized, pure DAG rewrite）”

否则 hash 层会继续成为性能与语义双重不稳定源。
