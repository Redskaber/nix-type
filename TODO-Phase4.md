# TODO-Phase4.md — Phase 4.2 完成状态 + Phase 4.3/5.0 规划

---

## Phase 3.3 遗留风险（全部修复于 Phase 4.1）

| 风险   | 描述                            | 状态   |
| ------ | ------------------------------- | ------ |
| RISK-1 | rowVar subst 未注入 solver      | ✅ 4.0 |
| RISK-2 | EffectMerge 不支持 open tail    | ✅ 4.0 |
| RISK-3 | Decision Tree 无 prefix sharing | 🔵 4.x |

---

## Phase 4.0/4.1 遗留风险（全部修复）

| 风险   | 描述                             | 修复                         | 状态   |
| ------ | -------------------------------- | ---------------------------- | ------ |
| RISK-A | canDischarge impl=null soundness | instance.nix impl != null    | ✅ 4.1 |
| RISK-B | instanceKey toJSON+md5           | typeHash NF-hash key         | ✅ 4.1 |
| RISK-C | worklist solver 无 requeue       | applySubstToConstraints      | ✅ 4.1 |
| RISK-D | QueryDB+Memo 双缓存无同步        | cacheNormalize / bumpEpochDB | ✅ 4.1 |
| RISK-E | ModFunctor body scope            | qualified naming             | ✅ 4.1 |
| RISK-F | topologicalSort in-degree 方向   | edges/revEdges 分离          | ✅ 4.1 |

---

## Phase 4.2 完成状态

| 编号    | 功能                                    | 文件                    | INV          | 状态 |
| ------- | --------------------------------------- | ----------------------- | ------------ | ---- |
| P4.2-1  | Functor 真正 λM.f1(f2(M)) 语义          | `module/system.nix`     | INV-MOD-8    | ✅   |
| P4.2-2  | composeFunctorChain 传递性              | `module/system.nix`     | INV-MOD-8    | ✅   |
| P4.2-3  | TypeScheme (∀ quantification)           | `core/type.nix`         | INV-SCHEME-1 | ✅   |
| P4.2-4  | HM let-generalization (INV-SCHEME-1)    | `bidir/check.nix`       | INV-SCHEME-1 | ✅   |
| P4.2-5  | Bidir App via constraint generation     | `bidir/check.nix`       | INV-BIDIR-1  | ✅   |
| P4.2-6  | Global InstanceDB coherence (INV-COH-1) | `runtime/instance.nix`  | INV-COH-1    | ✅   |
| P4.2-7  | mergeLocalInstances + unify overlap     | `runtime/instance.nix`  | INV-COH-1    | ✅   |
| P4.2-8  | rForall / rHole / rDynamic repr         | `repr/all.nix`          | INV-1        | ✅   |
| P4.2-9  | KVar + unifyKind (kind-level unify)     | `core/kind.nix`         | INV-K1       | ✅   |
| P4.2-10 | mkSchemeConstraint / mkKindConstraint   | `constraint/ir.nix`     | INV-6        | ✅   |
| P4.2-11 | Solver: Scheme constraint dispatch      | `constraint/solver.nix` | INV-SOL      | ✅   |
| P4.2-12 | de Bruijn serialize (alpha-NF)          | `meta/serialize.nix`    | INV-4        | ✅   |
| P4.2-13 | schemeHash / substHash                  | `meta/hash.nix`         | INV-4        | ✅   |
| P4.2-14 | lib/default.nix 240 exports 无重复      | `lib/default.nix`       | 架构         | ✅   |
| P4.2-15 | tests/test_all.nix 136 tests 20 组      | `tests/test_all.nix`    | all          | ✅   |
| P4.2-16 | README + ARCHITECTURE + TODO 更新       | 文档                    | —            | ✅   |

---

## Phase 4.2 测试覆盖

| 组    | 内容                             | 测试数  | 覆盖 INV             |
| ----- | -------------------------------- | ------- | -------------------- |
| T1    | TypeIR 核心（INV-1）             | 7       | INV-1                |
| T2    | Kind 系统（INV-K1）              | 7       | INV-K1               |
| T3    | TypeRepr 全变体（25+）           | 14      | INV-1                |
| T4    | Serialize canonical（de Bruijn） | 4       | INV-4 前置           |
| T5    | Normalize（INV-2/3）             | 6       | INV-2/3              |
| T6    | Hash（INV-4）                    | 5       | INV-4                |
| T7    | Constraint IR（INV-6）           | 7       | INV-6                |
| T8    | UnifiedSubst（INV-US1~5）        | 6       | INV-US1~5            |
| T9    | Solver（INV-SOL1/4/5）           | 5       | INV-SOL1~5           |
| T10   | Instance DB（INV-I1/2）          | 6       | coherence            |
| T11   | Refined Types（INV-SMT-1~6）     | 8       | INV-SMT-1~6          |
| T12   | Module System（INV-MOD-1~8）     | 8       | INV-MOD-1~8          |
| T13   | Effect Handlers（INV-EFF-4~9）   | 7       | INV-EFF-4~9          |
| T14   | QueryDB（INV-QK1~5+schema）      | 6       | INV-QK1~5            |
| T15   | Incremental Graph（INV-G1~4）    | 6       | INV-G1~4             |
| T16   | Pattern Matching                 | 7       | DT                   |
| T17   | Row 多态                         | 2       | INV-ROW              |
| T18   | Bidir + TypeScheme               | 10      | INV-BIDIR-1,SCHEME-1 |
| T19   | Unification                      | 7       | unify                |
| T20   | 集成测试                         | 6       | all                  |
| **Σ** |                                  | **136** |                      |

---

## Phase 4.2 已知限制

| 限制                         | 位置                    | 描述                        | 目标 |
| ---------------------------- | ----------------------- | --------------------------- | ---- |
| Decision Tree prefix sharing | `match/pattern.nix`     | sequential；大型 ADT O(n)   | 4.x  |
| Kind inference 仅 defer      | `constraint/solver.nix` | Kind constraints → residual | 4.3  |
| Mu bisimulation 近似         | `constraint/unify.nix`  | guard set；up-to congruence | 4.3  |
| Effect Handler continuations | `effect/handlers.nix`   | type-level only             | 4.3  |
| SMT bridge = string stub     | `refined/types.nix`     | 用户需调用外部 z3/cvc5      | 持续 |
| Bidir Lam infer = fresh var  | `bidir/check.nix`       | 无注释 lam → fresh type var | 4.3  |

---

## Phase 4.3 规划：Continuation + Mu bisimulation + Kind Inference

```nix
# 1. Effect Handler continuations（delimited control）
# handle : Eff(E ++ R, A) → Handler(E, A, B) → Eff(R, B)
mkHandlerWithCont = effectTag: branches: returnType:
  Handler { effectTag; branches = branches ++ [resumeBranch]; ... };

# 2. Mu bisimulation up-to congruence
# 替换当前 guardSet 方法：congruence closure
# → 修改 constraint/unify.nix unifyMu
# → 使用 coinductive proof obligation

# 3. Kind inference complete
# 当前: KVar constraints → residual
# 4.3:  KVar constraints → unifyKind → solved
# → solver.nix 处理 Kind tag

# 新增 INV：
# INV-EFF-10: deep handler handles all occurrences（semantic）
# INV-MU-1:   bisimulation up-to congruence sound
# INV-KIND-1: inferred kinds consistent with annotations
```

---

## Phase 5.0 规划：Gradual Types + HM inference

```nix
# 1. Dynamic type（rDynamic 已添加到 repr/all.nix）
tDyn = mkTypeDefault rDynamic KStar;

# 2. Consistency relation（gradual subtype）
isConsistent = t1: t2:
  (t1.repr.__variant == "Dynamic") ||
  (t2.repr.__variant == "Dynamic") ||
  typeEq t1 t2;

# 3. HM type inference（全局）
# infer : Ctx → Expr → (Type, [Constraint])
# generalize★ 已在 Phase 4.2 实现
# Phase 5.0: 加入 constraint solving + unification loop

# 新增 INV：
# INV-GRAD-1: Dynamic consistent with all types
# INV-GRAD-2: cast insertion explicit at Dynamic boundaries
# INV-HM-1:   infer yields principal type
# INV-HM-2:   generalize respects free variables in Ctx（INV-SCHEME-1 已实现）
```

---

## 架构决策记录（ADR）

### ADR-001: Constraint ∈ TypeRepr（INV-6）

**决策**: Constraint 是结构化 IR，不是函数。

### ADR-002: UnifiedSubst（type+row+kind 统一）

**决策**: 单一 UnifiedSubst，INV-US1 compose law。

### ADR-003: QueryKey Schema Validation（Phase 4.1）

**决策**: `mkQueryKey` 构造所有 key，格式验证。

### ADR-004: 文件合并（Phase 4.1）

**决策**: 消灭所有 `_p33`/`_p40` 碎片文件，单文件合并版。

### ADR-005: topologicalSort in-degree 语义

**决策**: `edges[A]=[B]` = A 依赖 B；`in-degree(A) = |edges[A]|`。

### ADR-006: TypeScheme ∉ TypeIR（Phase 4.2）

**决策**: `mkScheme` 是 TypeIR 的包装层，`rForall` 是 TypeRepr 变体。  
**理由**: 泛化/实例化在 inference 层，TypeRepr 保持纯结构（INV-1）。

### ADR-007: Functor Composition = lazy substitution（Phase 4.2）

**决策**: `composeFunctors f1 f2` = `λM. f1_body[f1.param := f2_body[f2.param := M]]`  
**修复**: Phase 4.1 的 `Apply` 嵌套不是真正 functor application 语义。

### ADR-008: HM generalize respects Ctx（INV-SCHEME-1）

**决策**: `generalize(Γ, T) = ∀(fv(T) \ fv(Γ)).T`  
**理由**: 防止 let-polymorphism 泄漏外层 context 变量。

### ADR-009: emptyDB disambiguation

**决策**: `instanceLib.emptyDB` → `instanceEmptyDB`；`queryLib.emptyDB` → `emptyDB`（默认）。  
**理由**: 两个 lib 均有 `emptyDB`，flat export 需要消歧义。

### ADR-010: de Bruijn alpha-normalization in serialize（Phase 4.2）

**决策**: `meta/serialize.nix` 使用 de Bruijn index 对 Lambda/Mu/Forall 进行 alpha-NF。  
**理由**: 保证 `λx.x` 和 `λy.y` 的序列化相同（INV-4 前提）。
