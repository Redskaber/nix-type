这份 `bidir/check.nix — Phase 3` 已经是一个**完整可运行骨架级 bidirectional type checker + inferencer**，结构上基本对齐 Pierce/Turner + dependent type 扩展的方向，但目前存在几类**语义不一致与实现断裂点**，如果不修，会在 Phase 3.1 直接爆掉。

下面按“问题等级”拆解。

---

# 1. 关键语义断裂（必须修）

## 1.1 TLam / Pi 分支混用 repr 结构

你这里：

```nix
if tag == "TLam" && nVar == "Fn" then
  ctxBind ctx term.param nTyp.repr.from
```

但你 IR 里：

- `Fn` = simple function type
- `Pi` = dependent function type

问题：

### ❌ Fn 分支没有处理 body substitution

你只做了：

```nix
check ctx' term.body nTyp.repr.to
```

但实际上：

- Fn：OK
- Pi：必须 capture-safe substitution
- 但你 Pi 分支写的是：

```nix
bodyTyp = _substTypeInType nTyp.repr.param ...
```

然而：

```nix
_substTypeInType = ... typ;  # stub
```

### 结论

👉 Pi 规则现在是**伪实现**

---

## 1.2 \_substTypeInType 未实现 → dependent type 失效

这是**核心断点**：

```nix
_substTypeInType = varName: term: typ: typ;
```

意味着：

- Π(x:A).B(x)
- 在 lambda check 时：

```nix
B[y ↦ x]
```

实际上没有发生

### 结果

- dependent function 完全退化成 non-dependent
- Pi ≈ Fn（语义被压扁）

---

## 1.3 infer TLam 是伪 HM-ish but broken

```nix
freshParam = _freshTypeVar ...
freshBody  = _freshTypeVar ...
check ctx' term.body freshBody
```

问题：

- 你没有约束 param 在 body 中的 usage
- 也没有 unification feedback loop
- 生成 Fn type 也不依赖 inference result

### 结果

👉 这是“假 HM”，不是 Hindley-Milner

---

## 1.4 \_inferApp Var 分支是 non-standard

```nix
expectedFn = mkTypeDefault (rFn argIr.typ retVar)
uc = mkEquality ir.typ expectedFn;
```

问题：

- 你在“函数不是 Fn/Pi 时”直接造 constraint
- 但没有 solver loop integration
- 也没有 constraint normalization pipeline guarantee

### 风险

👉 constraint graph 会漂移（Phase 3.2 很可能爆 incoherence）

---

# 2. 设计层问题（结构性）

## 2.1 check / infer / unify 三者耦合不稳定

当前结构：

```
check → infer → unify → constraints
```

但：

- unify 没有 shown
- constraints 没有 solver stage
- normalization 没进入 equality kernel

👉 这会导致：

> “类型正确 ≠ 约束可解”

---

## 2.2 subsume = unify（过强简化）

```nix
unify subst inferred expected
```

这是：

> subtype = equality

意味着：

- 没有 variance
- 没有 row polymorphism
- 没有 effect subtyping

### 结果

👉 Phase 3 的 subtype system 是“假子类型”

---

## 2.3 Pattern matching type propagation 太弱

```nix
first branch determines type
```

问题：

- 不是 join
- 不是 meet
- 没有 algebraic typing

### 结果

- match 不是 type-safe join lattice
- 只是 “first branch wins”

---

# 3. engineering 层问题

## 3.1 recursive import \_kindLib

```nix
_kindLib = import ../core/kind.nix { inherit lib; };
```

风险：

- circular dependency (ctx ↔ type ↔ kind)
- Phase 3 已经有 meta graph

👉 建议：lazy thunk injection

---

## 3.2 fresh type var 非 global unique

```nix
hashString "md5" hint
```

问题：

- collision risk（hint identical）
- no counter / epoch

👉 影响：

- memo system 会错配 constraint identity

---

# 4. 实际语义状态总结

现在这个 checker 的真实能力是：

| feature           | status        |
| ----------------- | ------------- |
| λ → Fn typing     | OK            |
| dependent λ → Pi  | ❌ fake       |
| HM inference      | partial       |
| constraint system | partial       |
| subtyping         | equality-only |
| pattern matching  | weak          |
| effect system     | stub          |
| coherence         | not enforced  |

---

# 5. 最关键的三条修复优先级（Phase 3.1 必做）

## P0 — 必修（否则系统不成立）

1. 实现 `_substTypeInType`
   - de Bruijn 或 named capture-safe
   - 支持 Pi / Sigma

2. 修复 Pi λ check 语义
   - param substitution must be real

---

## P1 — inference consistency

3. TLam infer 改为：

- generate constraint
- unify result
- NOT dual fresh variables

---

## P2 — constraint kernel接入

4. unify 必须接：

```
normalize → constraint → solve → subst update
```

否则 subsystem inconsistent

---

# 6. 一句话评价

这是一个：

> “结构完整但语义未闭合的 bidirectional dependent type checker prototype”

核心问题不是设计，而是：

> dependent substitution + constraint solver 没有闭环

---

下一步要做 Phase 3.1 把：

- `_substTypeInType`（capture-safe version）
- Pi + Sigma 完整 reduction semantics
- constraint solver integration layer

补成一个**真正闭合的 type system kernel**。
