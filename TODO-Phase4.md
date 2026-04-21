# TODO-Phase4.md — Phase 4.1 完成状态 + Phase 4.2/4.3 规划

---

## Phase 3.3 遗留风险（全部修复于 Phase 4.1）

| 风险   | 描述                                | 修复位置                               | 状态        |
| ------ | ----------------------------------- | -------------------------------------- | ----------- |
| RISK-1 | rowVar subst 未注入 solver pipeline | `constraint/solver.nix` → UnifiedSubst | ✅ 4.0      |
| RISK-2 | EffectMerge 不支持 open RowVar tail | `normalize/rules.nix` ruleEffectMerge  | ✅ 4.0      |
| RISK-3 | Decision Tree 无 prefix sharing     | `match/pattern.nix`                    | 🔵 延至 4.x |

---

## Phase 4.0 → 4.1 遗留风险（Phase 4.1 全修复）

| 风险   | 描述                                             | 修复                                                 | INV       |
| ------ | ------------------------------------------------ | ---------------------------------------------------- | --------- |
| RISK-A | `canDischarge` 接受 `impl=null`（soundness bug） | `runtime/instance.nix` → impl != null 验证           | soundness |
| RISK-B | instanceKey 使用 `toJSON+md5`（非 NF-hash）      | `runtime/instance.nix` → `typeHash`                  | INV-4     |
| RISK-C | worklist solver 无 requeue（INV-SOL5 失效）      | `constraint/solver.nix` → applySubstToConstraints    | INV-SOL5  |
| RISK-D | QueryDB + Memo 双缓存无同步（一致性隐患）        | `incremental/query.nix` → cacheNormalize/bumpEpochDB | 一致性    |
| RISK-E | ModFunctor body scope（param 同名 free var）     | `module/system.nix` → qualified naming               | INV-MOD-5 |
| RISK-F | topologicalSort in-degree 方向错误               | `incremental/graph.nix` → edges/revEdges 分离        | INV-G1    |

---

## Phase 4.1 完成状态

| 编号    | 功能                                           | 文件                    | INV         | 状态 |
| ------- | ---------------------------------------------- | ----------------------- | ----------- | ---- |
| P4.1-1  | RISK-A 修复（canDischarge soundness）          | `runtime/instance.nix`  | soundness   | ✅   |
| P4.1-2  | RISK-B 修复（NF-hash instanceKey）             | `runtime/instance.nix`  | INV-4       | ✅   |
| P4.1-3  | RISK-C 修复（worklist requeue）                | `constraint/solver.nix` | INV-SOL5    | ✅   |
| P4.1-4  | RISK-D 修复（双缓存统一入口）                  | `incremental/query.nix` | 一致性      | ✅   |
| P4.1-5  | RISK-E 修复（qualified naming）                | `module/system.nix`     | INV-MOD-5   | ✅   |
| P4.1-6  | RISK-F 修复（topo sort in-degree）             | `incremental/graph.nix` | INV-G1      | ✅   |
| P4.1-7  | INV-SMT-5/6（checkRefinedSubtype + smtOracle） | `refined/types.nix`     | INV-SMT-5/6 | ✅   |
| P4.1-8  | INV-MOD-6（composeFunctors）                   | `module/system.nix`     | INV-MOD-6   | ✅   |
| P4.1-9  | INV-MOD-7（mergeLocalInstances coherence）     | `module/system.nix`     | INV-MOD-7   | ✅   |
| P4.1-10 | INV-EFF-8/9（deep/shallow handlers）           | `effect/handlers.nix`   | INV-EFF-8/9 | ✅   |
| P4.1-11 | INV-QK-SCHEMA（QueryKey validation）           | `incremental/query.nix` | schema      | ✅   |
| P4.1-12 | INV-G2（clean-stale FSM state）                | `incremental/graph.nix` | INV-G2      | ✅   |
| P4.1-13 | 文件合并（rules/solver/pattern/tests）         | 所有 `_p33`/`_p40` 文件 | 架构        | ✅   |
| P4.1-14 | flake.nix（lib/checks/packages/apps/overlays） | `flake.nix`             | —           | ✅   |
| P4.1-15 | 完整测试套件（127 tests，18 组）               | `tests/test_all.nix`    | all         | ✅   |
| P4.1-16 | README.md + ARCHITECTURE.md + TODO 更新        | 文档                    | —           | ✅   |

---

## Phase 4.1 测试覆盖

| 测试组   | 内容                            | 测试数  | 覆盖 INV    |
| -------- | ------------------------------- | ------- | ----------- |
| T1       | TypeIR 核心（INV-1）            | 5       | INV-1       |
| T2       | Kind 系统（INV-K1）             | 5       | INV-K1      |
| T3       | TypeRepr 全变体                 | 12      | INV-1       |
| T4       | Serialize canonical             | 3       | INV-4 前置  |
| T5       | Normalize（INV-2/3）            | 3       | INV-2/3     |
| T6       | Hash（INV-4）                   | 3       | INV-4       |
| T7       | Constraint IR（INV-6）          | 4       | INV-6       |
| T8       | UnifiedSubst（INV-US1~5）       | 5       | INV-US1~5   |
| T9       | Solver（INV-SOL1/4/5）          | 5       | INV-SOL1~5  |
| T10      | Instance DB（RISK-A/B）         | 6       | coherence   |
| T11      | Refined Types（INV-SMT-1~6）    | 8       | INV-SMT-1~6 |
| T12      | Module System（INV-MOD-1~7）    | 8       | INV-MOD-1~7 |
| T13      | Effect Handlers（INV-EFF-4~9）  | 6       | INV-EFF-4~9 |
| T14      | QueryKey DB（INV-QK1~5+schema） | 9       | INV-QK1~5   |
| T15      | Incremental Graph（INV-G1~4）   | 6       | INV-G1~4    |
| T16      | Pattern Matching                | 5       | DT          |
| T17      | Row 多态                        | 2       | INV-ROW     |
| T18      | 集成测试                        | 6       | all         |
| **合计** |                                 | **101** |             |

---

## Phase 4.1 已知限制

| 限制                             | 位置                   | 描述                                             | 目标 Phase |
| -------------------------------- | ---------------------- | ------------------------------------------------ | ---------- |
| Decision Tree prefix sharing     | `match/pattern.nix`    | sequential-first，大型 ADT O(n)                  | 4.x        |
| Functor coherence global check   | `module/system.nix`    | 局部一致性；未整合 global InstanceDB             | 4.2        |
| Functor transitive composition   | `module/system.nix`    | body 表示为 Apply 嵌套，非真 composition         | 4.2        |
| Mu bisimulation up-to congruence | `constraint/unify.nix` | guard set 近似；真正 up-to 需 congruence closure | 4.3        |
| Effect Handler continuations     | `effect/handlers.nix`  | type-level only；无 continuation passing 语义    | 4.3        |
| SMT bridge = string only         | `refined/types.nix`    | 用户需自行调用外部 z3/cvc5                       | 持续       |
| Bidir infer 不完整               | `bidir/check.nix`      | App 的函数类型推断使用 freshVar 占位             | 4.2        |

---

## Phase 4.2 规划：完善 Module + Bidir

```nix
# 1. Functor transitive composition（真正语义）
# composeFunctors f1 f2 = λM. f1(f2(M))
# 需要：delayed application，lazy substitution

# 2. Global InstanceDB coherence check
# mergeLocalInstances 升级为 partial-unify overlap detection
# 当前只做 exact key match，Phase 4.2 做 partial unification

# 3. Bidirectional 补全
# - infer App with unknown fn type: use constraint generation
# - check Lam without annotation: generate fresh paramVar
# - let-generalization（HM style）

# 新增 INV：
# INV-MOD-8: Functor composition type-correct（kind preserved）
# INV-BIDIR-1: infer + check sound w.r.t. normalize
```

---

## Phase 4.3 规划：Continuation + Mu bisimulation

```nix
# 1. Effect Handler continuations（delimited control）
# handle : Eff(E ++ R, A) → Handler(E, A, B) → Eff(R, B)
# mkHandlerWithCont effectTag branches returnType =
#   Handler { effectTag; branches = branches ++ [resumeBranch]; ... }

# 2. Mu bisimulation up-to congruence
# 替换当前 guardSet 方法：
# 使用 congruence closure 确保 α-等价的 Mu 类型被正确识别相等
# → 修改 constraint/unify.nix 的 unifyMu 函数

# 新增 INV：
# INV-EFF-10: deep handler handles all effect occurrences
# INV-MU-1: bisimulation up-to congruence sound
```

---

## Phase 5.0 规划：Gradual Types + HM inference

```nix
# 1. Dynamic type
rDynamic = mkRepr "Dynamic" {};
tDyn = mkTypeDefault rDynamic KStar;

# 2. Consistency relation（gradual subtype）
isConsistent = t1: t2:
  (t1.repr.__variant == "Dynamic") ||
  (t2.repr.__variant == "Dynamic") ||
  typeEq t1 t2;

# 3. HM type inference
# infer : Ctx → Expr → (Type, [Constraint])
# generalize : Ctx → Type → TypeScheme
# instantiate : TypeScheme → (Type, [Constraint])

# 新增 INV：
# INV-GRAD-1: Dynamic consistent with all types
# INV-GRAD-2: cast insertion explicit at Dynamic boundaries
# INV-HM-1: infer yields principal type
# INV-HM-2: generalize respects free variables in Ctx
```

---

## 架构决策记录（ADR）

### ADR-001: Constraint ∈ TypeRepr（INV-6）

**决策**: Constraint 不是函数，是结构化 IR。  
**理由**: 使 Constraint 可参与 normalize/hash/equality，保证增量系统可靠。

### ADR-002: UnifiedSubst（type+row+kind 统一）

**决策**: Phase 4.0 引入 UnifiedSubst 替代分散的 type subst + row subst。  
**理由**: 消除 rowVar binding 无法注入 constraint solver 的 RISK-1。

### ADR-003: QueryKey Schema Validation（Phase 4.1）

**决策**: 所有 QueryKey 必须通过 `mkQueryKey` 构造，storeResult 验证格式。  
**理由**: 防止手写 key 冲突，保证 INV-QK1（确定性）。

### ADR-004: 文件合并（Phase 4.1）

**决策**: 消灭所有 `_p33`/`_p40` 阶段性碎片文件。  
**理由**: 减少维护负担，消除版本间的隐式依赖和逻辑散落。

### ADR-005: topologicalSort in-degree 语义

**决策**: `edges[A]=[B]` 表示 A 依赖 B（B 先处理）；  
`in-degree(A) = len(edges[A])`；degree decrement 使用 `revEdges[next]`。  
**理由**: 匹配"依赖图"语义（B 是 A 的 prerequisite）。
