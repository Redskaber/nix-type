整体结构是可运行级别的，但这版 unify.nix 仍然有几类**语义风险 + 不变量潜在破坏点**，其中有些会直接影响 INV-U2（MGU）和 INV-U4（Lambda α一致性）。按优先级拆一下。

---

# 1. 🔴 Lambda 统一：当前实现“过强等价”而非 α-等价

```nix
sA == sB
```

问题：
你用的是 `serializeReprAlphaCanonical` 的字符串相等，这隐含两个风险：

### (1) 依赖序列化器“完备性”

INV-U4 要求的是：

> α-equivalence ⇒ unify succeed

但现在是：

> serialize equality ⇒ unify succeed

如果 serializer：

- 没覆盖 binder shadowing edge case
- 或 row / mu / nested lambda 混合结构不完全 canonical

会出现：

- α等价但 unify 失败（false negative）
- 或更危险：不同语义结构被压成同串（false positive）

### (2) 破坏 MGU（INV-U2）

Lambda 分支直接 return fail/success，没有产生 substitution：

```nix
_ok subst / _fail
```

这意味着：

- Lambda 不参与 unifier construction
- 实际是 “decision procedure”，不是 unification

👉 结论：
这一步已经从 Robinson unification 退化成 **α-check oracle**

---

# 2. 🟠 Pi / Sigma：binder substitution 是“伪实现”

关键问题：

```nix
fresh = mkTypeDefault ...
bodyA = import ../normalize/substitute.nix {}
```

### 问题 A：运行时 import 递归破坏 purity

Nix 语义下：

- 动态 import self-module 是 anti-pattern
- 会破坏 referential transparency（隐式 dependency graph）

### 问题 B：fresh 变量没有进入 body rewrite

你实际上写的是：

```nix
if a.repr.param == b.repr.param
then unify r1.subst a.repr.body b.repr.body
```

否则 fallback：

```nix
serializeReprAlphaCanonical
```

👉 这导致：

- 没有真正做 α-renaming
- 只是“名字相等优先，否则 stringify 比较”

### 结果：

Pi-unify 不满足：

> INV-U1: substitution-preserving equivalence

因为 substitution 没有进入 binder scope 结构。

---

# 3. 🔴 Mu-unification：存在结构性错误（严重）

这一段：

```nix
let a' = { repr = a.repr.body.repr // {}; kind = a.kind; meta = a.meta; id = ""; } // a.repr.body;
```

问题非常严重：

## (1) repr 被破坏性 merge

- `a.repr.body.repr // {}` 是无意义 overwrite
- type structure 可能被 flatten / lose constructor tag

## (2) identity reset (`id = ""`)

会直接破坏：

- memoization consistency（你 Phase 2 memo hash 依赖 NF-id）
- equality invariant（INV-3 / INV-4）

## (3) Mu展开不是 substitution

正确 equi-recursive unfolding 应该是：

```
μX.T  →  T[X := μX.T]
```

你现在是：

> “直接取 body repr”

👉 这是**语义错误，不是 approximation**

---

# 4. 🟠 Record / Row unify：rowVar 处理过于 rigid

```nix
if rvA == rvB then ok else fail
```

问题：

你现在实现的是：

> row variable = nominal identity

但 Phase 3 设计注释是：

> rigid variable（不走 binder equality）

这会导致：

### ❌ 不能支持 row polymorphism generalization

例如：

```
{a:Int | r1}  vs  {a:Int | r2}
```

即使：

- r1, r2 都是 unification variables

也会 fail，而不是 unify + substitution

👉 这会破坏：

- structural polymorphism
- extensible record inference

---

# 5. 🟡 \_applySubstType 是“只做 top-level substitution”

```nix
if v == "Var" then subst.${t.repr.name} or t
```

问题：

- 不递归
- 不处理 nested Fn / Apply / Row / Mu

影响：

### 直接后果

unify pipeline 是：

```
unify → applySubst → unify
```

但 substitution 不 closure-safe，会导致：

- MGU 不稳定（order-dependent results）
- constraint graph inconsistent state propagation（你 Phase 2 incremental graph 会受影响）

---

# 6. 🟡 occursIn 逻辑依赖 freeVarsRepr 结构不明

```nix
freeVarsRepr t.repr ? ${name}
```

如果 `freeVarsRepr` 返回的是：

- list → ❌ membership check wrong
- attrset → ✔ OK

但这里是 unsafe assumption。

👉 occur check correctness 是 INV-U3 的基础，如果错：

- 会允许 cyclic type
- unify becomes non-terminating TRS

---

# 7. ⚠️ unifyApply 是正确方向但有隐含 bug

```nix
unify acc.subst a' b'
```

问题：

你每一步：

- 都用 acc.subst
- 但没有 composition normalization

理论上应保证：

```
σ1 ∘ σ2 normalized to canonical substitution
```

否则：

- later lookup shadowing inconsistency
- memo key mismatch (Phase 2 graph invalidation bug source)

---

# 总结（结构性判断）

这一版 unify：

### ✔ 正确部分

- Apply unification框架 OK
- Row/Variant 基础结构 OK
- Occur check存在（但依赖风险）

### ⚠️ 半正确

- Pi / Sigma（缺 α-renaming真实实现）
- Lambda（变成 oracle，不是 unifier）
- Record rowVar rigid化（过强）

### ❌ 关键问题（破坏理论性质）

1. Mu unfolding 是结构错误
2. Lambda 不产生 substitution → 破坏 MGU
3. substitution 不 closure-safe
4. rowVar rigid policy 不支持 row polymorphism
5. serializer 被当作 equality oracle（风险极高）

---

# 如果按 Phase 3 目标对齐（建议修正优先级）

## P0（必须修，否则 INV 崩）

- 修 Mu unfolding（必须 substitution-based）
- unifyLambda 改为 structural unify + α-renaming

## P1（MGU correctness）

- substitution composition normalization
- \_applySubstType recursion closure

## P2（类型系统表达能力）

- rowVar 从 rigid → unification variable + constraints
- Pi/Sigma binder capture-safe rewrite

---

下一步做：

> **“INV-U1~U4 完全可证明版本 unify kernel（Phase 3 corrected core）”**

那一版会把：

- de Bruijn + α equivalence
- equi-recursive μ
- row polymorphism
  统一到一个一致的 unification algebra。
