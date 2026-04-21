整体来看，这一版 `substitute.nix` 已经从“结构递归替换”升级到“带 α-rename + de Bruijn + row spine 处理”的完整系统，属于 Phase 3 中比较关键的一块。下面按语义正确性、捕获安全性、实现一致性三个层面做审查。

---

# 1. 核心正确性（Substitution 语义）

## 1.1 substituteAll：顺序是正确的

```nix
lib.foldl' (acc: var: substitute var subst.${var} acc) t vars;
```

### 结论：❌ 有潜在问题（顺序不稳定）

你依赖：

```nix
builtins.attrNames subst
```

但：

- Nix attrNames **不是稳定排序**
- substitution composition 对顺序敏感

### 风险

σ(x := a, y := b) 可能在不同 eval 中表现不同。

### 建议（关键修复）

应显式排序或使用 deterministic key:

```nix
let vars = lib.sort (a: b: a < b) (builtins.attrNames subst);
```

否则 composition correctness 会被破坏。

---

## 1.2 composeSubst：语义是正确的，但实现偏“浅”

你写的是：

```nix
applied = lib.mapAttrs (_: t: substituteAll sigma2 t) sigma1;
extra = lib.filterAttrs (k: _: !(sigma1 ? ${k})) sigma2;
```

### 正确性判断：

✔ σ₂ ∘ σ₁ 的方向是对的
✔ extra merge 也合理

### 问题：

⚠ substitution 没有 closure guarantee

例如：

```text
σ1: x ↦ y
σ2: y ↦ z
```

compose 后：

```text
x ↦ z
y ↦ z   (extra)
```

这是“weak composition”，但不是 normalized substitution.

### 建议（语义强化）

如果目标是 canonical substitution，应加：

```nix
mapAttrs (_: t: substituteAll result t)
```

fixpoint closure。

---

# 2. 捕获安全（α + binder handling）

这是本文件的核心复杂部分。

---

## 2.1 Lambda / Pi / Sigma capture check

你写的是：

```nix
if fv ? ${t.repr.param}
```

### ❌ 严重问题：语法 + 语义双重风险

#### (1) Nix syntax问题

`${t.repr.param}` 在 attrset key context 是危险的：

- 如果 param 含特殊字符 → 解析错误
- 正确应是:

```nix
fv.${t.repr.param} or false
```

#### (2) 语义问题

你假设：

```text
freeVars replacement returns attrset
```

但没有保证 shape 是：

```nix
{ x = true; }
```

否则 membership check 不可靠。

---

## 2.2 Alpha-renaming correctness

### Lambda case：

```nix
_alphaRename t.repr.param (_fresh t.repr.param)
```

✔ 正确方向

但：

⚠ rename 仅作用于 Var / Lambda / Apply / Fn / Constrained / Mu

---

### ❗ 缺失：Pi/Sigma/Effect/Ascribe 不在 alphaRename 主函数中完整覆盖

你是分拆实现：

- `_alphaRenamePi`
- `_alphaRenameSigma`

但：

### ⚠ 问题

主 `_alphaRename` 没调用它们

=> 如果 Pi/Sigma 嵌套 Lambda，会出现 partial renaming inconsistency

---

## 建议（结构性修复）

统一：

```nix
_alphaRename → dispatch all binders (Lambda/Pi/Sigma/Mu)
```

否则：

- substitute safety ≠ alpha equivalence safety
- de Bruijn conversion correctness会被破坏

---

## 2.3 Mu binder handling

```nix
if t.repr.param == oldName then t
```

✔ safe (fixpoint binder stop)

但：

⚠ 不对称

Lambda/Pi/Sigma 在 rename 时会继续 descent，但 Mu 直接 stop

这在 equi-recursive type 下是可接受的，但：

- 依赖你 MU semantics 是否 iso-recursive

如果是 equi-recursive → ❌ 不一致

---

# 3. de Bruijnify（核心正确性审查）

这是 Phase 3 最关键部分之一。

---

## 3.1 env depth encoding

```nix
idx = env.${t.repr.name}
mkTypeWith (rVarDB (dep - idx - 1))
```

### ✔ 标准 encoding 正确

这是：

```text
de Bruijn index = distance to binder
```

---

## 3.2 Lambda/Pi/Sigma/Mu binding

### ✔ 基本正确

```nix
env // { name = dep; }
depth = dep + 1
```

---

## ❗ 关键问题：Var collision shadowing

你没有处理：

- 重名 binder shadowing（nested same name）

Nix attrset overwrite：

```nix
env // { x = dep }
```

会丢失 outer x binding

### ⚠ 这是 correctness bug

应使用：

```text
stack-based env (list), not attrset
```

---

## 3.3 Row / Effect correctness

✔ RowExtend / Record / VariantRow：

- 不进入 binder scope
- 设计合理

---

# 4. Row subsystem

## flattenRow

✔ 正确 fold spine

⚠ but:

- tail may be variable row → not normalized
- ordering sorted by label only (OK if row is unordered set semantics)

---

## buildRow

```nix
sorted = builtins.sort ...
```

✔ deterministic

⚠ but:

- does not preserve original extension order (which is fine only if row is set-semantics)

---

# 5. 关键设计问题总结

## ❌ 1. substitution order nondeterminism

- attrNames unordered

---

## ❌ 2. env representation broken for de Bruijn

- attrset used as stack
- shadowing bug exists

---

## ❌ 3. α-rename coverage incomplete

- Pi/Sigma/Effect/Ascribe inconsistent dispatch

---

## ❌ 4. substitution closure not enforced

- composeSubst not normalized

---

## ⚠ 5. freeVarsRepr contract assumed but not enforced

- membership check fragile

---

# 6. 总体评价

这个模块已经达到：

- ✔ capture-safe substitution（大体成立）
- ✔ de Bruijn conversion（理论正确）
- ✔ row spine canonicalization（稳定）

但在 Phase 3 语义一致性上仍存在三个“结构性风险点”：

### A. env model incorrect (critical)

→ 会影响 de Bruijn correctness

### B. substitution ordering nondeterministic

→ 会影响 canonical equality / hash stability

### C. α-rename dispatch incomplete

→ 会导致 Pi/Sigma 下 substitution 不封闭

---

# 如果要继续推进 Phase 3（建议）

优先级排序：

### P0（必须修）

- env 改 list/stack（替换 attrset）
- substituteAll deterministic ordering

### P1（语义一致性）

- unify α-rename dispatcher
- substitution closure normalization

### P2（优化）

- composeSubst fixpoint closure
- row normalization caching

---

如果你下一步是对接：

- `equality.nix`
- `hash.nix`
- `normalize.nix`

这个文件必须先修 P0，否则 INV-3 / INV-H2 会被系统性破坏。
