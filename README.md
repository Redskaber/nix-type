# Nix Type System — Phase 3

> 纯 Nix 原生实现的强表达力类型系统  
> 类 Rust 编译器增量管道 · System Fω + Dependent Types · Bidirectional Checking · Equi-Recursive Bisimulation · Row Polymorphism · Effect System

---

## 核心不变量（Phase 3 精化，全部强制）

```
INV-1:  所有结构           ∈ TypeIR
INV-2:  所有计算           = Rewrite(TypeIR)，fuel-bounded 终止
INV-3:  所有比较           = NormalForm Equality（single canonical，Coherence Law 强制）
INV-4:  所有缓存 key       = NF-hash（typeHash = nfHash ∘ normalize，单一路径）
INV-5:  所有依赖追踪       = Graph Edge（BFS worklist，单源）
INV-6:  Constraint         ∈ TypeRepr（不是函数，不是 runtime）
INV-T1: t.kind ≠ null      → KUnbound（construction-safe + mutation-safe）
INV-T2: t.id = H(serializeAlpha(repr))（不依赖 toJSON 属性顺序）
INV-K4: kindUnify           纯函数，不 mutate（Phase 2→3 强化）
INV-I2: Instance DB coherence = 无 overlapping instances（register 强制检查）
INV-EQ1: typeEq(a,b) ⟹ typeHash(a) == typeHash(b)（强约束）
INV-EQ2: structuralEq ⊆ nominalEq ⊆ hashEq（Coherence Law，Phase 3 新增）
INV-EQ3: muEq = coinductive bisimulation（fuel-bounded + guard set）
INV-EQ4: rowVarEq = rigid name equality（不走 binder equality）
INV-H2:  typeHash = nfHash ∘ normalize（唯一收敛路径，Phase 3 统一）
INV-SOL1: Worklist Solver 终止条件含 subst 变化
INV-SOL4: subst 在每轮后应用到 constraints
INV-SER3: serializeReprAlphaCanonical(α-equivalent) = 相同 string
```

---

## Phase 3 新增能力

| 特性                           | 状态 | 说明                                                      |
| ------------------------------ | ---- | --------------------------------------------------------- |
| Pi-types（Dependent Function） | ✅   | `rPi`，`rulePiReduction`，bidirectional check 支持        |
| Sigma-types（Dependent Pair）  | ✅   | `rSigma`，capture-safe substitution                       |
| Effect types                   | ✅   | `rEffect`，`KEffect`，Row-encoded algebraic effects       |
| Opaque / Ascribe               | ✅   | `rOpaque`（phantom/newtype），`rAscribe`（bidirectional） |
| Bidirectional Type Checking    | ✅   | `bidir/check.nix`，check/infer，Pierce/Turner 风格        |
| Open ADT 扩展                  | ✅   | `extendADT`，ordinal 稳定追加                             |
| KRow / KEffect                 | ✅   | Row/Effect 专用 Kind，`kindUnify` 扩展                    |
| Equality Coherence Law         | ✅   | structural ⊆ nominal ⊆ hash（INV-EQ2）                    |
| muEq 真 bisimulation           | ✅   | coinductive guard set + fuel（INV-EQ3）                   |
| rowVarEq 修复                  | ✅   | rigid name equality（INV-EQ4，非 binder equality）        |
| typeHash/nfHash 收敛           | ✅   | 单一路径：typeHash = nfHash∘normalize（INV-H2）           |
| Worklist Solver                | ✅   | 精确增量 constraint propagation（INV-SOL1/4）             |
| α-canonical 序列化 v3          | ✅   | cycle-free，indexed Constructor binder（INV-SER）         |
| normalizeConstraint            | ✅   | 幂等统一入口（INV-C4）                                    |
| constraintsHash dedup          | ✅   | 集合语义（不是 multiset），O(n)（INV-C2）                 |
| Decision Tree（Pattern）       | ✅   | ordinal O(1) dispatch，exhaustiveness + redundancy check  |
| composeSubst 修复              | ✅   | σ₂∘σ₁ 正确顺序                                            |
| Constructor partial kind 修复  | ✅   | 保留真实参数 kind（INV-K1）                               |

---

## TypeRepr 完整变体集（Phase 3，20 个变体）

```
TypeRepr =
  Primitive  { name }                          # 原子类型
| Var        { name; scope }                   # 类型变量（有作用域）
| VarDB      { index }                         # de Bruijn index（α-canonical）
| VarScoped  { name; index }                   # 带 db 的命名变量
| Lambda     { param; body }                   # 类型级 λ
| Apply      { fn; args }                      # 类型级应用
| Fn         { from; to }                      # 函数类型（NF，不展开）
| Constructor{ name; kind; params; body }      # 泛型 ADT 构造器
| ADT        { variants; closed }              # 代数数据类型
| Constrained{ base; constraints }             # 约束内嵌（INV-6）
| Mu         { param; body }                   # 递归类型（equi-recursive）
| Record     { fields; rowVar }                # Row-polymorphic record
| VariantRow { variants; rowVar }              # Open variant sum type
| RowExtend  { label; fieldType; rowType }     # 行扩展 cons cell
| RowEmpty   {}                                # 封闭行终止符
| Pi         { param; paramType; body }        # Π(x:A).B(x) ★Phase3
| Sigma      { param; paramType; body }        # Σ(x:A).B(x) ★Phase3
| Effect     { tag; row }                      # Effect type ★Phase3
| Opaque     { name; id }                      # 不透明类型 ★Phase3
| Ascribe    { t; annotation }                 # 类型标注 ★Phase3
```

---

## Normalize 规则集（Phase 3，11 条规则）

| 优先级 | 规则                  | 归约                                                                    |
| ------ | --------------------- | ----------------------------------------------------------------------- |
| 1      | Constraint-float      | `Apply(Constrained(f,cs), args) → Constrained(Apply(f,args), cs)`       |
| 2      | Constraint-merge      | `Constrained(Constrained(t,c1),c2) → Constrained(t, dedup(c1∪c2))`      |
| 3      | Beta-reduction        | `Apply(Lambda(x,b), [a,...]) → b[x↦a]`                                  |
| 4      | Pi-reduction ★        | `Apply(Pi(x:A,b), [a]) → b[x↦a]`                                        |
| 5      | Constructor-unfold    | `Apply(Constructor(ps,b), args) → b[ps↦args]`（完整应用）               |
| 6      | Constructor-partial ★ | `Apply(Constructor(ps,b), args) → CurriedConstructor`（真实 kind 推断） |
| 7      | Mu-unfold             | `Apply(Mu(p,b), args) → Apply(b[p↦Mu(p,b)], args)`                      |
| 8      | Row-normalize         | Row spine 排序规范化（canonical field order）                           |
| 9      | Effect-normalize ★    | Effect row 规范化                                                       |
| 10     | Fn-NF                 | Fn 保留为 NF（不展开）                                                  |
| 11     | Eta-reduction         | `Lambda(x,Apply(f,[x])) → f`（可选，默认禁用）                          |

★ = Phase 3 新增/修复

---

## 目录结构（Phase 3）

```
nix-types/
├── core/
│   ├── kind.nix          # Kind 系统（+KRow/KEffect，kindUnify 纯函数）
│   ├── meta.nix          # MetaType（Coherence Law，muPolicy，rowPolicy）
│   └── type.nix          # TypeIR 统一结构（stableId α-canonical）
├── repr/
│   └── all.nix           # TypeRepr 全 20 变体 + freeVarsRepr 完整 + Open ADT
├── normalize/
│   ├── rewrite.nix       # TRS 主引擎（统一 step，fuel-based）
│   ├── rules.nix         # 11 条规则（Pi-reduction，kind 修复）
│   └── substitute.nix    # capture-safe 替换（Pi/Sigma/Effect/composeSubst 修复）
├── constraint/
│   ├── ir.nix            # Constraint IR（normalizeConstraint，dedup，INV-C1-4）
│   ├── unify.nix         # Robinson 统一（alpha-canonical Lambda，Pi/Sigma，rigid rowVar）
│   └── solver.nix        # Worklist Solver（INV-SOL1/4/5）
├── bidir/
│   └── check.nix         # Bidirectional Type Checking（P3-0，check/infer）★Phase3
├── meta/
│   ├── equality.nix      # Equality（Coherence Law，muEq bisimulation，rowVarEq rigid）
│   ├── hash.nix          # typeHash = nfHash∘normalize（单一路径，INV-H2）
│   └── serialize.nix     # α-canonical v3（cycle-free，indexed binder）
├── match/
│   └── pattern.nix       # Pattern IR + Decision Tree + exhaustiveness + redundancy
├── runtime/
│   └── instance.nix      # Instance DB（coherence强化，superclass传递）
├── incremental/
│   ├── graph.nix         # 依赖图（BFS worklist，valid transitions，INV-G1-5）
│   └── memo.nix          # Memo（epoch + NF-hash key，INV-M1-4）
├── lib/
│   └── default.nix       # 统一入口（18 模块，正确依赖拓扑序）
├── examples/
│   ├── phase3_demo.nix   # Phase 3 综合演示
│   └── list_maybe_mu.nix # μ-types 示例（Phase 2）
└── tests/
    └── test_all.nix      # 系统测试
```

---

## Bidirectional Type Checking（P3-0）

```
check : Ctx -> Term -> Type -> CheckResult
infer : Ctx -> Term -> InferResult

-- 规则（Pierce/Turner 风格）
check(ctx, λx.e,  Π(y:A).B)   = check(ctx[x:A], e, B[y↦x])
check(ctx, λx.e,  A→B)        = check(ctx[x:A], e, B)
check(ctx, e,     B)          = infer(ctx, e) = A; subtype(A, B)
infer(ctx, x)                 = ctx.lookup(x)
infer(ctx, e : A)             = check(ctx, e, A); A   ← Ascribe 切换
infer(ctx, f a)               = infer(f) = A→B; check(a, A); B
infer(ctx, f a)               = infer(f) = Π(x:A).B; check(a, A); B[x↦a]
```

---

## Phase 3 修复总览（nix-todo 清单对应）

| 模块          | 问题                            | Phase 3 修复                                         | INV      |
| ------------- | ------------------------------- | ---------------------------------------------------- | -------- |
| equality #1   | INV-3 被 strategy override 破坏 | 单一 canonical NF-hash equality，strategy 仅影响深度 | INV-3    |
| equality #2   | alphaEq ≈ structuralEq 重复     | alphaEq = 真正 de Bruijn α-equality                  | INV-EQ2  |
| equality #3   | nominalEq 不是 nominal          | nominalEq = name + NF-hash                           | INV-EQ2  |
| equality #4   | rowVar 走错 equality domain     | rowVarEq = rigid name identity                       | INV-EQ4  |
| equality #5   | muEq 不是真 equi-recursive      | muEq = coinductive bisimulation + guard set          | INV-EQ3  |
| hash #1       | typeHash/nfHash 双路径歧义      | typeHash = nfHash∘normalize（强制）                  | INV-H2   |
| serialize #1  | \_serType 非 canonical          | serializeReprAlphaCanonical（完整实现）              | INV-SER3 |
| serialize #2  | Constructor binder 循环         | indexed env（不用名字）                              | INV-SER5 |
| constraint #1 | \_serType 非 canonical          | constraintKey 使用 canonical serializer              | INV-C1   |
| constraint #2 | applySubst 不递归               | mapTypesInConstraint（完整递归）                     | INV-C3   |
| constraint #3 | constraintsHash 未去重          | listToAttrs O(n) dedup                               | INV-C2   |
| constraint #4 | 缺 normalizeConstraint          | 实现 normalizeConstraint（幂等）                     | INV-C4   |
| rules #1      | Constructor-partial kind 错误   | 保留真实 param.kind（INV-K1）                        | INV-K1   |
| solver #1     | fixpoint 不含 subst 变化        | Worklist Solver（INV-SOL1）                          | INV-SOL1 |
| solver #2     | subst 未应用到 constraints      | \_applySubstToConstraint 每轮                        | INV-SOL4 |
| memo #1       | constraint key 非 canonical     | \_constraintSetKey sorted + dedup                    | INV-M3   |
| memo #3       | normalize key 非 NF-stable      | typeHash（NF-based）versioned key                    | INV-M4   |

---

## 演化路径（Phase 3 → 4）

| 特性                               | Phase | 优先级 | 依赖                   |
| ---------------------------------- | ----- | ------ | ---------------------- |
| Equi-recursive Mu Unification 完善 | 3.1   | P0     | bisimulation soundness |
| Bidirectional Dependent Types 完善 | 3.1   | P0     | Pi/Sigma bidir         |
| Liquid Types（SMT interface）      | 4     | P2     | Predicate constraint   |
| Effect Handlers                    | 4     | P1     | Effect + VariantRow    |
| Module System（Sig + Functor）     | 4     | P2     | solver + Instance      |
| Nix eval 双向集成                  | 5     | P3     | bidir check            |

---

## 版本历史

| 版本  | Phase | 关键里程碑                                                                   |
| ----- | ----- | ---------------------------------------------------------------------------- |
| 0.1.0 | 0     | TypeIR 原型，基础 normalize                                                  |
| 1.0.0 | 1     | KUnbound, validateMeta, solver fixpoint, Graph visited set                   |
| 2.0.0 | 2     | de Bruijn, Mu-types, HKT, Row Poly, Instance DB, memo fix                    |
| 3.0.0 | 3     | Pi/Sigma, Effect, Bidir Check, Open ADT, Equality Coherence, Worklist Solver |
