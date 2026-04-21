这份 `serialize.nix` 已经接近“语义级 canonical serializer”，但在 Phase 3 目标（INV-SER1~5 + α-canonical 强一致性）下，仍存在几个**结构性风险点**，不是实现细节问题，而是“规范与实现不一致”。

下面按不变量逐条审查。

---

# 1. INV-SER1（canonical deterministic）——基本达标，但有隐性非确定性点

## ✔ 已正确的部分

- `builtins.sort (a: b: a < b)` 用于：
  - ADT variants
  - Record fields
  - VariantRow labels
  - constraints
    → 这保证了 **attribute order independence**

## ⚠ 问题点

### ❌ Constraint 排序依赖 String representation（危险）

```nix
builtins.sort (a: b: a < b) (map (_serConstraint ctx) repr.constraints)
```

问题：

- 先 serialize，再 sort
- 但 `_serConstraint` 本身依赖 `_serType`
- `_serType` 可能递归结构不同导致 string 非局部稳定

👉 后果：

> sorting key 不是 structural key，而是 derived string key
> → 会导致“语义等价但字符串不同 → 排序不稳定”

### ✔ 正确方式应是：

- sort BEFORE serialization
- 或使用 structural hash key

---

# 2. INV-SER2（cycle-free）——部分违反风险

## ⚠ 风险点：Constructor / Mu / RowGraph

### Constructor

```nix
Ctor(...,[params...],bd)
```

问题：

- params 仅 encode kind string
- bd 递归 `_serType`

如果 `repr.body` 引用 `repr` 上层 structure（shared graph）
→ 可能重复 traversal

---

### Mu（递归类型）

```nix
"μ(${serTbind repr.param repr.body})"
```

✔ safe in alpha mode
❌ unsafe in structural mode (`_serRepr`）

因为：

- `_serRepr` 没有 cycle guard
- Mu-only protection在 alpha serializer

👉 结论：

> INV-SER2 只在 Alpha path 满足

---

# 3. INV-SER3（free variable policy）——目前是混合语义（不纯）

## 当前行为：

### Alpha mode：

```nix
FV(name,scope)
```

### Structural mode：

```nix
V(name,scope)
```

## 问题

### ❌ scope 被保留

这破坏了 INV-SER3 的目标：

> free variable normalization policy（global vs logical separation）

因为：

- scope 是 runtime artifact
- 会造成：
  - 环境敏感 serialization
  - cross-module instability

---

## 正确设计应该是：

两层 policy：

| 类别             | 行为                      |
| ---------------- | ------------------------- |
| global free var  | canonicalized symbol only |
| logical free var | de Bruijn + cutoff        |

现在是混合泄露 scope

---

# 4. INV-SER4（canonical order independence）——局部成立，但未全局保证

## 已正确：

- Record / ADT / VariantRow sorting

## 未覆盖：

### ❌ Lambda / Pi / Sigma binder name leak in structural serializer

```nix
"λ(${esc repr.param}.${_serType ctx repr.body})"
```

问题：

- param name encoded
- violates alpha invariance in structural mode

👉 structural serializer ≠ alpha invariant

---

# 5. INV-SER5（cycle-free recursion）——部分实现，但不系统

当前没有：

### ❌ visited set / memo guard

- `_serRepr`
- `_serType`
- `_serConstraint`

全部是 pure recursion

## 风险场景：

```
Mu
 └── body → Apply → Mu → ...
```

Alpha mode partially safe
Structural mode unsafe

---

# 6. Alpha-canonical serializer ——总体是正确方向，但有两个关键偏差

## ✔ 正确点

- de Bruijn index:

```nix
DB(depth - idx - 1)
```

- binder shadowing via env extension
- λ / Π / Σ / μ 全部 α-safe

---

## ❌ 关键问题 1：free variable 未 canonical 化

```nix
FV(name,scope)
```

这不是 α-canonical：

### α-canonical 要求：

> free variables must be normalized to a global namespace OR de Bruijn + cutoff

当前：

- name is preserved
- scope is preserved

→ ❌ 非 canonical

---

## ❌ 关键问题 2：RowVar leakage

```nix
|rv:${repr.rowVar}
```

问题：

- rowVar 是 logical variable
- 但没有 α-renaming policy

→ 两个等价 row system 会产生不同 string

---

# 7. 最核心设计问题（总结）

这份 serializer 实际上混合了三种语义层：

| 层              | 当前状态      | 问题                          |
| --------------- | ------------- | ----------------------------- |
| Structural      | ✔ 但不 stable | binder name leak              |
| Alpha-canonical | ✔ λ/Π/Σ/μ OK  | free var & rowVar broken      |
| Hash-canonical  | ❌ 不存在     | missing structural hash layer |

---

# 8. 建议的 Phase 3 修正（关键）

只给结构性修复点：

---

## 修复 A：Constraint sorting must be pre-serialization

```nix
let cs = builtins.sort constraintKey repr.constraints;
in map (_serConstraint ctx) cs;
```

---

## 修复 B：Remove scope from free variables

```nix
FV(name)   # NOT FV(name,scope)
```

---

## 修复 C：Structural serializer must not expose binder names

```nix
λ(${_serType ctx repr.body})
```

而不是：

```nix
λ(x.${body})
```

---

## 修复 D：Add cycle guard (mandatory for INV-SER5)

Introduce:

```
ctx.visited : set repr-id
```

---

## 修复 E：RowVar must be alpha-renamed

Replace:

```
|rv:${repr.rowVar}
```

with:

```
|rv:#${canonicalRowId repr.rowVar}
```

---

# 结论

当前实现状态：

- INV-SER1 ✔ mostly correct
- INV-SER2 ⚠ partial (Mu safe only in alpha mode)
- INV-SER3 ❌ not satisfied (free var leakage)
- INV-SER4 ⚠ partially violated (binder names leak)
- INV-SER5 ❌ not enforced (no cycle guard)

---

如果你下一步目标是“进入 Phase 3 收敛态”，关键不是继续扩展 serializer，而是：

> 先统一 **variable discipline（Var / RowVar / FreeVar）语义层**

否则 serialization 层会持续被语义污染。
