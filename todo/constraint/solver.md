整体结构是可运行方向正确的 worklist solver，但这一版存在几处**会直接破坏 INV-SOL1 / SOL5 / SOL4 的实现一致性问题**，以及数个 Nix 层面的硬错误。下面按严重程度分解。

---

# 1. ❌ 立即会导致语义错误的问题（Critical）

## 1.1 `_processConstraint` 中 newSubst 作用丢失（INV-SOL5 实际未成立）

代码：

```nix
let result = unify subst c'.a c'.b; in
if result.ok then
  let
    newSubst = result.subst;
    (affected: unaffected: {
      newWorklist = affected ++ unaffected;
    }) (_partitionAffected newSubst worklist);
```

### 问题

- 这里 partition 结果**被计算但完全未使用**
- `newWorklist` 没有被绑定到后续 solver
- 实际执行仍然是：

```nix
_worklistSolve ... newSubst worklist ...
```

### 结果

👉 INV-SOL5 声明：

> worklist = 受 subst 影响的 constraints

❌ 实际未成立（worklist 没更新）

---

## 1.2 unify 成功后没有更新 worklist（关键 correctness bug）

正确逻辑应该是：

> newSubst → 重新过滤/重排 worklist

当前：

```nix
_worklistSolve ... newSubst worklist ...
```

❌ 没有任何 requeue / recheck

---

## 1.3 `_applySubstType` 访问语法错误

```nix
let v = t.repr.__variant or null; in
```

但下面：

```nix
if v == "Var" || v == "VarScoped" then
  let bound = subst.${t.repr.name} or null;
```

### 问题

- `t.repr` 可能不存在 → Nix evaluation crash
- `subst.${...}` 在 key 不存在时会 throw（不是 safe lookup）

---

## 1.4 `_canDischargePrimitive` 有语法错误

这一行：

```nix
v        = (firstArg.repr or {})..__variant or firstArg.repr.__variant or null;
```

❌ `..__variant` 是非法 Nix token

---

## 1.5 `_instanceKey` 使用 builtins.toJSON 非稳定来源

```nix
builtins.hashString "md5" (builtins.toJSON a)
```

问题：

- `toJSON` **顺序不保证稳定**
- 与你 Phase 2 的 NF-hash 体系冲突（INV-HASH 已被你自己强调）

👉 会破坏：

- instance resolution determinism
- coherence guarantee

---

# 2. ⚠️ 逻辑问题（不会 crash，但会错推导）

## 2.1 `_substEq` 不符合真实 substitution equality

```nix
lib.all (k: (s1.${k}.id or "?") == (s2.${k}.id or "?"))
```

问题：

- 用 `.id` 比较 ≠ α-equivalence / NF-equivalence
- 与 Phase 2 “NF-hash equality”设计冲突

👉 会导致：

- INV-SOL1 “stability” 假阳性
- solver 过早 terminate

---

## 2.2 `_partitionAffected` 过度保守 + O(n²)

```nix
lib.any (v: _constraintContainsVar v c) domainVars;
```

问题：

- 每个 constraint × 每个 var 扫描 type tree
- 没有 dependency graph caching

结果：

- worklist solver 退化为 O(n³) 在复杂 constraint set

---

## 2.3 `_tryDischargeAll` ignores residual structure

```nix
{ ok = lib.all (r: r.ok) results; };
```

问题：

- 忽略 `residual = true` semantics
- Implies 语义丢失（premise unknown vs false 不区分）

---

## 2.4 `_dischargeClass` 的 super class entailment 是错误 model

```nix
lib.any (subClass:
  instanceDB ? ${_instanceKey subClass args}
  && isSuperclassOf classGraph c.name subClass)
```

问题：

- 逻辑反了（应该是 subClass ⊢ className）
- 当前写法是：

> 如果任意 subClass 是 className 的 super？

语义混乱

---

# 3. ⚠️ 架构问题（Phase 3 design tension）

## 3.1 Worklist 没有真正 incremental invalidation graph

你当前：

```text
subst → partition → （但未 requeue）
```

这不是 worklist solver，而是：

> “partial worklist evaluator”

缺少：

- dependency graph
- constraint-to-type-var index
- reactive invalidation

👉 INV-SOL5 目标其实没有实现

---

## 3.2 fuel 被当作 termination guard，而非 fairness control

```nix
fuel - 1
```

问题：

- 没有 per-constraint fairness
- large constraints starve small ones

---

# 4. 🧩 建议修正路径（最小改动版本）

## 4.1 修复 INV-SOL5（必须）

替换：

```nix
_worklistSolve ... newSubst worklist ...
```

为：

```nix
let
  p = _partitionAffected newSubst worklist;
  newWorklist = p.affected ++ p.unaffected;
in
_worklistSolve instanceDB classGraph newSubst newWorklist residual (fuel - 1)
```

---

## 4.2 修复 subst application safety

```nix
bound = subst.${t.repr.name} or null;
```

改：

```nix
bound = subst.${t.repr.name} or null;
```

→ 必须改为 safe attr lookup：

```nix
bound = builtins.getAttr t.repr.name subst or null;
```

---

## 4.3 修复 primitive bug

删除：

```nix
..__variant
```

改：

```nix
v = firstArg.repr.__variant or null;
```

---

## 4.4 替换 instanceKey（关键）

必须从：

```nix
toJSON + md5
```

改为：

```nix
NF-hash (Phase 2 meta/hash.nix)
```

否则 coherence 不成立。

---

## 4.5 修复 subst equality（INV-SOL1）

必须升级为：

- NF-hash comparison
- 或 structural normalize compare

---

# 5. 总体评价（实事求是）

这个 solver 的定位是：

> “incremental worklist constraint solver with class entailment + unification”

但当前状态是：

- ✔ worklist 架构成立（骨架正确）
- ✔ class/predicate/impl 结构清晰
- ✔ Phase 3 方向正确
- ❌ incremental invalidation 未实现（INV-SOL5失效）
- ❌ substitution propagation 不完整（INV-SOL4部分失效）
- ❌ instance coherence hash 不稳定
- ❌ primitive / syntax bug 会导致运行失败

---

# 如果你下一步要继续

建议优先顺序：

1. 修 INV-SOL5（worklist requeue）
2. 修 instanceKey（NF-hash统一）
3. 修 subst equality（INV-SOL1）
4. 再考虑 graph-based incrementalization（Phase 3.5）

---

直接重构成一个：

> **真正 incremental（dependency-indexed）constraint solver v2**

那一版会比当前 worklist 更接近 Hindley–Milner + typeclass resolution 的工业实现结构。
