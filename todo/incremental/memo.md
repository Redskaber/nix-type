整体设计是“语义 key + epoch invalidation + 分桶缓存”，方向是正确的，但当前实现里有几处**一致性风险与隐性不变量冲突点**，主要集中在 key 生成、失效策略和 bucket 语义边界。

下面按模块拆解关键问题。

---

## 1. INV-M1（memoKey = typeHash）实际上被部分破坏

### 问题点

你在 normalize bucket：

```nix
_typeKey = memo: t: _vKey memo (hashLib.typeHash t);
```

但 substitute / solve 使用的是：

- `_vKey memo "${hashLib.typeHash t}:subst:${_substSig subst}"`
- `_constraintSetKey constraints`

也就是说：

> ❗ normalize 是 pure typeHash
> ❗ 其他 bucket 是 composite hash

这会导致一个结构性问题：

### 风险

同一个 `typeHash(t)`：

- normalize cache 命中
- substitute / solve cache 不命中

这本身不是 bug，但会破坏你文档里“INV-M1 单一来源”的叙述一致性。

### 结论

- INV-M1 **只对 normalize 成立**
- 对全 memo system 不成立

👉 建议修正 invariant 表述，否则设计语义是“假统一”。

---

## 2. epoch + prefix invalidation 存在“不可达 key 泄漏”

### 当前机制

```nix
_vKey = memo: rawKey: "${toString memo.epoch}:${rawKey}";
```

invalidate：

```nix
filterAttrs (k: _: !hasPrefix prefix k)
```

### 问题

你假设：

> 所有 key 都是 epoch:hash

但实际上：

#### ❗ substitute / solve key 是 double encoding

例如：

```
epoch:hash:t:subst:hash2
```

invalidateType 用的是：

```
prefix = "${epoch}:${h}"
```

### 风险

- prefix 只匹配 `epoch:typeHash`
- 但 key 是 `epoch:compound`

👉 所以 invalidateType **不会命中任何 substitute / solve key**

---

### 结论

❗ invalidateType 在当前实现是 **无效操作（no-op in most cases）**

---

## 3. \_constraintSetKey 的复杂度与非稳定性风险

### 当前实现

```nix
table = listToAttrs (map ...)
sorted = attrNames table
hash sha256 concat sorted
```

### 问题

#### (1) listToAttrs → key collision silent overwrite

如果 constraintKey 重复：

- 后一个覆盖前一个
- dedup 是“副作用式”的，不是显式 set

#### (2) constraintKey 非 canonical guarantee

```nix
builtins.toJSON c
```

fallback 分支：

- JSON field order 在 Nix 中**不稳定（取决于 attr order）**

👉 会导致：

> INV-M3 “canonical sorted+dedup” 在 fallback path 被破坏

---

### 结论

❗ INV-M3 只在 tag 分支成立
❗ fallback branch 是潜在 hash drift source

---

## 4. substitute sig 设计存在“结构泄漏”

```nix
"${k}:${(subst.${k}).id or "?"}"
```

### 问题

这里你把：

- type identity（k）
- runtime id（.id）

混入 hash

### 风险

如果 `.id`：

- 是 ephemeral
- 或 allocation-based

那么：

👉 substitute cache 命中率会异常低（近似失效）

---

## 5. bumpEpoch 的 eviction 统计是错误的

```nix
builtins.length (builtins.attrNames memo.normalize)
```

但你同时：

```nix
normalize = {};
substitute = {};
solve = {};
hash = {};
```

### 结果

- evictions 统计的是 **旧 memo.normalize**
- 但实际已清空

👉 统计语义变成：

> “理论 eviction”，不是“实际 eviction”

---

## 6. hit/miss double counting bug（轻微但真实）

### 问题

lookup：

```nix
found → stats.hits + 1
```

but withMemoNormalize：

```nix
bumpHit / bumpMiss 也会 +1
```

### 结果

normalize hit/miss 在某些路径会：

> ❗ 双重计数

---

## 7. 设计层级问题（最关键）

当前 memo system 实际是 3 层混合：

| 层          | 实际内容                  |
| ----------- | ------------------------- |
| structural  | typeHash                  |
| semantic    | constraints normalization |
| operational | substitution state        |

但：

👉 bucket 没有统一 key schema

---

## 总体评价

这个模块的核心问题不是实现错误，而是：

### ❗ key system 没有统一 algebra

导致：

- normalize / subst / solve 三种缓存语义不一致
- invalidate 策略只能覆盖 normalize
- constraint cache 存在 hash drift 风险
- epoch invalidation 语义被弱化

---

## 如果要修（最小改动方向）

建议三点收敛：

### 1. 统一 key algebra

```
Key = epoch
    + namespace
    + typeHash
    + stableFeatureHash
```

### 2. invalidateType 改为 prefix + namespace 双维

```
epoch:namespace:typeHash:*
```

### 3. constraint hash 改为 explicit set encoding（避免 JSON fallback）
