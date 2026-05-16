# nix-types Architecture — Phase 4.5.2

## 版本：4.5.2

---

## 核心设计原则

### 1. 序列化边界不变式（INV-SER-1）

> **`builtins.toJSON` 绝不直接碰触含 Type 对象、Constraint 对象、或任何持有函数引用的结构。**

所有序列化必须经由规范路径：

- `meta/serialize.nix → serializeRepr r`（TypeRepr 序列化）
- `meta/serialize.nix → serializeConstraint c`（Constraint 序列化）
- `meta/serialize.nix → serializePredExpr pe`（PredExpr 序列化）
- `meta/serialize.nix → serializeKind k`（Kind 序列化）
- `meta/hash.nix → _safeStr v`（最后保护层：isFunction guard）

### 2. Nix 语言安全规则

| 不变式        | 规则                                                                                |
| ------------- | ----------------------------------------------------------------------------------- |
| **INV-NIX-1** | `or` 不在 `${}` 字符串插值内；改用 `let val = expr; in "...${val}..."`              |
| **INV-NIX-2** | `rec {}` 中自引用函数用 `builtins.map`/`builtins.concatLists`，不用 `lib.concatMap` |
| **INV-LET-1** | `let` 绑定不 shadow 外层函数参数（避免 Nix 互递归 thunk 死循环）                    |

### 3. 不变量驱动设计

每个架构决策锚定到具名 INV。INV 是唯一真理来源：违反 = soundness bug，不接受"实现方便"例外。

---

## 模块层次（Layer 0–22）

```
Layer 0:  core/kind.nix          — Kind 系统（KStar/KArrow/KRow/KEffect/KVar）
                                    + inferKind/solveKindConstraints/fixpoint (INV-KIND-1~3)
Layer 1:  meta/serialize.nix     — 规范序列化（← kindLib）         ★ INV-SER-1 核心
Layer 2:  core/meta.nix          — MetaType 控制层
Layer 3:  core/type.nix          — TypeIR 宇宙（_mkId via serializeRepr）
Layer 4:  repr/all.nix           — TypeRepr 构造器（26+ 变体，含 rDynamic/rHole）
Layer 5:  normalize/substitute.nix — 同步 capture-safe 替换（INV-SUB2）
Layer 6:  normalize/rules.nix    — TRS 规则集（11 规则）
Layer 7:  normalize/rewrite.nix  — TRS 主引擎（fuel-based，INV-2）
Layer 8:  meta/hash.nix          — 规范 hash（_safeStr 保护，INV-4）
Layer 9:  meta/equality.nix      — 类型等价（NF-hash equality，INV-3）
Layer 10: constraint/ir.nix      — Constraint IR（← serialLib）
Layer 11: runtime/instance.nix   — Instance DB（_instanceKey 纯字符串，INV-I1-key）
Layer 12: refined/types.nix      — 精化类型 + SMT oracle
Layer 13: normalize/unified_subst.nix — UnifiedSubst（t:/r:/k: 三前缀，INV-US1~5）
Layer 14: constraint/unify_row.nix — Row unification（← serialLib）
          constraint/unify.nix   — Robinson unification + Mu bisim up-to congruence (INV-MU-1)
Layer 15: module/system.nix      — Module 系统（λM.f1(f2(M))，INV-MOD-1~8）
Layer 16: effect/handlers.nix    — Effect Handlers + continuations（INV-EFF-4~11）
Layer 17: constraint/solver.nix  — Worklist solver（INV-SOL1~5）
Layer 18: bidir/check.nix        — 双向类型推断（INV-BIDIR-1~3）
Layer 19: incremental/graph.nix  — 依赖图（BFS 失效，INV-G1~4，INV-TOPO）
Layer 20: incremental/memo.nix   — Memo 层（epoch-based）
          incremental/query.nix  — QueryDB（Salsa-style）
Layer 21: match/pattern.nix      — 模式匹配（INV-PAT-1~3，INV-NIX-2）
Layer 22: lib/default.nix        — 统一导出（280+ 名称，topological order）
```

---

## 不变量体系（完整）

| 不变量       | 描述                                                              | 引入  | 状态 |
| ------------ | ----------------------------------------------------------------- | ----- | ---- |
| INV-1        | 所有结构 ∈ TypeIR                                                 | 4.0   | ✅   |
| INV-2        | 所有计算 = Rewrite(TypeIR)，fuel 保证终止                         | 4.0   | ✅   |
| INV-3        | 结果 = NormalForm（无可归约子项）                                 | 4.0   | ✅   |
| INV-4        | typeEq(a,b) ⟹ typeHash(a) == typeHash(b)                          | 4.0   | ✅   |
| INV-5        | 所有依赖追踪 = Graph Edge                                         | 4.0   | ✅   |
| INV-6        | Constraint ∈ TypeRepr（非函数值）                                 | 4.0   | ✅   |
| INV-US1~5    | UnifiedSubst compose law                                          | 4.1   | ✅   |
| INV-SUB2     | 替换为同步（非顺序），INV-SUB2 guard                              | 4.1   | ✅   |
| INV-SOL1~5   | Solver worklist correctness                                       | 4.1   | ✅   |
| INV-G1~4     | BFS worklist 失效传播，visited-set 防无限递归                     | 4.1   | ✅   |
| INV-I1-key   | instanceKey 纯字符串拼接，不用 builtins.toJSON                    | 4.3   | ✅   |
| INV-SCHEME-1 | let-generalization respects Ctx free vars                         | 4.2   | ✅   |
| INV-BIDIR-1  | infer/check sound w.r.t. normalize                                | 4.2   | ✅   |
| INV-MOD-1~8  | Module system invariants                                          | 4.2   | ✅   |
| INV-MU-1     | Mu bisimulation up-to congruence sound (Pous 2016)                | 4.3   | ✅   |
| INV-EFF-4~10 | Effect handler invariants                                         | 4.3   | ✅   |
| INV-EFF-11   | contType.from == paramType; checkHandlerContWellFormed.inv_eff_11 | 4.4   | ✅   |
| INV-KIND-1   | Inferred kinds consistent with annotations                        | 4.3   | ✅   |
| INV-KIND-2   | Kind annotation propagation consistent with inference             | 4.4   | ✅   |
| INV-KIND-3   | Kind fixpoint convergence, bounded at maxIter=10                  | 4.5   | ✅   |
| INV-BIDIR-2  | infer(eLamA p ty b) = (ty → bodyTy)                               | 4.4   | ✅   |
| INV-BIDIR-3  | App result solved when fn type is concrete (peek codomain)        | 4.5   | ✅   |
| INV-PAT-1    | patternVars captures all Var bindings in any pattern              | 4.4   | ✅   |
| INV-PAT-2    | isLinear(p) ↔ no duplicate variable in patternVars(p)             | 4.4   | ✅   |
| INV-PAT-3    | patternVars(Record{fi=pi}) = ⋃ patternVars(pi)                    | 4.5   | ✅   |
| INV-SER-1    | builtins.toJSON never receives Type/function values               | 4.3   | ✅   |
| INV-NIX-1    | `or` never inside `${}` string interpolation                      | 4.3   | ✅   |
| INV-NIX-2    | rec-scope self-ref functions use builtins.map, not lib.concatMap  | 4.5.2 | ✅   |
| INV-TOPO     | topologicalSort always returns `{ ok; order; error }`             | 4.5.2 | ✅   |
| INV-LET-1    | let bindings never shadow function parameters                     | 4.3   | ✅   |
| INV-NRM2     | Memo keys use NF-hash, not raw t.id                               | 4.1   | ✅   |
| INV-NRM3     | Mu-unfold uses independent fuel                                   | 4.1   | ✅   |
| INV-TEST-1~5 | Test isolation, defensive checks per group/result                 | 4.3~  | ✅   |

---

## 序列化执行图（INV-SER-1）

```
Type 对象
  └──→ serializeType(t)           meta/serialize.nix
         └──→ serializeRepr(t.repr)
                └──→ _serializeWithEnv   alpha-eq canonical (de Bruijn)

Constraint 对象
  └──→ serializeConstraint(c)     meta/serialize.nix
         └──→ serializeRepr per field  (仅访问 .repr，不触 kind/meta)

Kind 对象
  └──→ serializeKind(k)           core/kind.nix (inline)

PredExpr 对象
  └──→ serializePredExpr(pe)      meta/serialize.nix

未知值（fallback）
  └──→ _safeStr(v)                meta/hash.nix
         if isFunction v → "<fn>"
         else → toString v        ← 永不崩溃
```

---

## 关键架构模式

### Pattern Matching（INV-PAT-1~3, INV-NIX-2）

```
patternVars : Pattern → [String]

Var  → [name]
Ctor → builtins.concatLists (builtins.map patternVars fields)   ← INV-NIX-2
And  → patternVars p1 ++ patternVars p2
Guard → patternVars pat
Record → builtins.concatLists (builtins.map
           (fn: patternVars subPats.${fn})
           (attrNames subPats))                                   ← INV-PAT-3
Wild/Lit → []
```

`lib.concatMap` 在 rec-scope 自引用函数上可能触发 lazy cycle（INV-NIX-2 根因），
必须用 `builtins.concatLists (builtins.map ...)` 替代。

### Bidirectional Type Inference（INV-BIDIR-3）

```
_inferApp ctx fn arg:
  fnR = infer ctx fn
  CASE1: fnR.type.repr.__variant == "Fn"
    → result = fnR.type.repr.to  (peek codomain, O(1), no unification needed)
    → constraint = Eq(argTy, fnR.type.repr.from)
    → resultSolved = true
  CASE2: other fn types
    → freshVar = mkTypeDefault (rVar "_r_N" "") KStar
    → constraint = Eq(fnTy, argTy → freshVar)
    → resultSolved = false
```

### Kind Fixpoint Solver（INV-KIND-3）

```
solveKindConstraintsFixpoint kcs:
  foldl' over [0..maxIter-1]:
    if converged: passthrough
    else: run solveKindConstraints, check if new bindings were added
  Termination: each iter binds ≥1 KVar OR is no-op (converged)
  Bound: maxIter=10 (realistic kind-inference ≤ |KVars|+1 steps)
```

### Incremental Computation（INV-G1~4）

```
Salsa-style pipeline:
  Input change → markStale(node) → BFS propagate stale(visited-set) → INV-G1
  Query → lookupNormalize | storeNormalize → memo cache
  Epoch bump → full cache invalidation
```

---

## 测试套件架构

```
tests/test_all.nix
  mkTestBool name cond   → builtins.tryEval cond → { pass; error }  (INV-TEST-1)
  mkTest name res exp    → builtins.tryEval × 2
  runGroup name tests    → { passed; total; failed; ok }             (INV-TEST-4)
  allGroups = [t1..t28]  ← 28 groups, 203 tests
  failedGroups = filter (isAttrs g && !g.ok) allGroups               (INV-TEST-5)
  failedList   = map safeGroup failedGroups                          (INV-TEST-5)
```

**28 Test Groups:**

| Groups | Coverage                          | Tests   |
| ------ | --------------------------------- | ------- |
| T1–T15 | TypeIR, Kind, Repr, Normalize,    | 105     |
|        | Hash, Constraint, Subst, Solver,  |         |
|        | Instance, Refined, Module,        |         |
|        | Effect, Query, Graph              |         |
| T16    | Pattern Matching (INV-PAT-1/2)    | 13      |
| T17    | Row Polymorphism                  | 2       |
| T18    | Bidir + TypeScheme                | 10      |
| T19    | Unification                       | 7       |
| T20    | Integration                       | 6       |
| T21    | Kind Inference (INV-KIND-1/2)     | 14      |
| T22    | Handler Continuations             | 6       |
| T23    | Mu Bisim Congruence               | 6       |
| T24    | Bidir Annotated Lambda            | 8       |
| T25    | Handler Cont Type Check           | 7       |
| T26    | Bidir App Result (INV-BIDIR-3)    | 8       |
| T27    | Kind Fixpoint (INV-KIND-3)        | 7       |
| T28    | Nested Record Pattern (INV-PAT-3) | 7       |
| **Σ**  |                                   | **203** |

---

## ADRs（Architecture Decision Records）

### ADR-001: TypeIR 统一宇宙（Phase 4.0）

`Type = { tag="Type"; id: String; kind: Kind; repr: TypeRepr; meta: MetaType }`
所有类型操作在 TypeIR 上进行，INV-1。

### ADR-002: INV-SER-1 序列化边界（Phase 4.3）

`builtins.toJSON` 仅用于纯 JSON 安全数据。所有 Type/Kind/Constraint 经专用序列化路径。
根因：Nix `builtins.toJSON` 对函数值报 uncatchable abort。

### ADR-003: INV-NIX-2（Phase 4.5.2）

在 `rec {}` 中定义的自引用函数传递给 `lib.concatMap` 时，在某些 Nix 版本触发
lazy evaluation cycle。改用 `builtins.concatLists (builtins.map f xs)` 语义等价且安全。

### ADR-018: INV-BIDIR-3 peek-and-resolve（Phase 4.5）

`_inferApp` 对 `fnR.type.repr` 模式匹配：fn 类型已知时 O(1) 直接用 codomain，
不引入额外 fresh unification variable。

### ADR-019: INV-KIND-3 bounded fixpoint（Phase 4.5）

`solveKindConstraintsFixpoint` 最多迭代 10 次（`genList + foldl'` 实现有界循环）。
每次迭代要么绑定 ≥1 KVar（严格单调减少），要么无新绑定（立即 converged）。

### ADR-020: INV-PAT-3 sub-pattern recursion（Phase 4.5）

`patternVars` Record 分支由"返回字段名"改为"递归到 attrValues"。
旧行为是语义错误（字段名不是 pattern 绑定）。

### ADR-021: INV-TOPO unified return type（Phase 4.5.2）

`topologicalSort` 统一返回 `{ ok; order; error }`，消除 list/attrset 二义性。
根因：`--strict` 模式下 `list.ok` 抛 uncatchable "expected a set but found a list"。

---

## 变更记录

| 版本  | 主要变更                                                                      |
| ----- | ----------------------------------------------------------------------------- |
| 4.5.2 | INV-NIX-2/TOPO；T16/T25 patternVars fix；T25 INV-EFF-11 complete impl         |
| 4.5.1 | INV-BIDIR-3 (peek codomain)；INV-KIND-3 (fixpoint)；INV-PAT-3 (nested Record) |
| 4.5.0 | Phase 4.5 baseline                                                            |
| 4.4.0 | INV-BIDIR-2 annotated lambda；INV-EFF-11；INV-KIND-2；INV-PAT-1/2             |
| 4.3.0 | Kind inference；Mu bisim up-to congruence；Handler cont；INV-SER-1            |
| 4.2.0 | TypeScheme/HM；Functor λM.f1(f2(M))；Global coherence                         |
| 4.1.0 | UnifiedSubst；RISK-A~F；de Bruijn serialize；INV-G1~4                         |
| 4.0.0 | Constraint IR 化；rowVar solver 注入；Phase separation                        |
