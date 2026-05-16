# todo.md — Phase 4.5.9 完成状态 + Phase 5.0 规划

---

## 历史风险追踪（全部已修复）

| 风险   | 描述                                 | 修复                                | INV          | 版本         |
| ------ | ------------------------------------ | ----------------------------------- | ------------ | ------------ |
| RISK-1 | rowVar subst 未注入 solver           | INV-SUB2 guard                      | INV-SUB2     | ✅ 4.0       |
| RISK-2 | EffectMerge 不支持 open tail         | open row handling                   | INV-EFF      | ✅ 4.0       |
| RISK-A | canDischarge impl=null soundness     | impl != null guard                  | INV-I1       | ✅ 4.1       |
| RISK-B | instanceKey toJSON+md5               | NF-hash key (\_instanceKey)         | INV-I1-key   | ✅ 4.1       |
| RISK-C | worklist solver 无 requeue           | applySubstToConstraints             | INV-SOL5     | ✅ 4.1       |
| RISK-D | QueryDB+Memo 双缓存无同步            | cacheNormalize                      | INV-G4       | ✅ 4.1       |
| RISK-E | ModFunctor body scope                | qualified naming                    | INV-MOD-3    | ✅ 4.1       |
| RISK-F | topologicalSort in-degree 方向       | edges/revEdges 分离                 | INV-G1       | ✅ 4.1       |
| RISK-G | Functor 语义错误（Apply 嵌套）       | λM.f1(f2(M)) lazy subst             | INV-MOD-5    | ✅ 4.2       |
| RISK-H | HM let-gen 泄漏 Ctx 变量             | INV-SCHEME-1 generalize             | INV-SCHEME-1 | ✅ 4.2       |
| RISK-I | builtins.toJSON on Type repr         | serializeRepr（INV-SER-1）          | INV-SER-1    | ✅ 4.3       |
| RISK-J | Kind constraints → residual          | solveKindConstraints                | INV-KIND-1   | ✅ 4.3       |
| RISK-K | Mu unify guardSet 过于保守           | up-to congruence                    | INV-MU-1     | ✅ 4.3       |
| RISK-L | patternVars Ctor branch field miss   | pat.fields or [] guard              | INV-PAT-1    | ✅ 4.4       |
| RISK-M | eLamA fresh var round-trip           | direct paramTy path                 | INV-BIDIR-2  | ✅ 4.4       |
| RISK-N | contType domain unchecked            | INV-EFF-11 verification             | INV-EFF-11   | ✅ 4.4       |
| RISK-O | App result type is always freshVar   | peek fn repr → codomain             | INV-BIDIR-3  | ✅ 4.5       |
| RISK-P | Kind solver single-pass              | fixpoint iteration                  | INV-KIND-3   | ✅ 4.5       |
| RISK-Q | Record pattern flat (no sub-pats)    | recurse into sub-patterns           | INV-PAT-3    | ✅ 4.5       |
| RISK-R | lib.concatMap lazy cycle on rec fn   | builtins.concatLists/map            | INV-NIX-2    | ✅ 4.5.2     |
| RISK-S | topologicalSort list/attrset duality | unified return { ok; order; error } | INV-TOPO     | ✅ 4.5.2     |
| RISK-T | mkHandlerWithCont missing fields     | contDomainOk + inv_eff_11           | INV-EFF-11   | ✅ 4.5.2     |
| RISK-U | patternVars rec{} lazy-eval cycle    | lambda wrapper (x: f x)             | INV-NIX-3    | ✅ 4.5.3     |
| RISK-V | test framework lacks diagnostics     | mkTestWith + diagnoseAll            | INV-TEST-6   | ✅ 4.5.3     |
| RISK-W | foldl'+++ in letrec ctx → silent []  | concatLists+map+`[(handle item)]`   | INV-NIX-4    | ✅ **4.5.9** |

---

## Phase 4.5.9 完成状态

| 编号     | 功能                                                 | 文件                | INV       | 状态 |
| -------- | ---------------------------------------------------- | ------------------- | --------- | ---- |
| P4.5.9-1 | patternVars Ctor: foldl'+ → concatLists+map          | `match/pattern.nix` | INV-NIX-4 | ✅   |
| P4.5.9-2 | patternVars Record: foldl'+ → concatLists+map        | `match/pattern.nix` | INV-NIX-4 | ✅   |
| P4.5.9-3 | patternVars/patternDepth: eta-expand rec{} exports   | `match/pattern.nix` | INV-NIX-3 | ✅   |
| P4.5.9-4 | patternVarsSet/isLinear: direct \_patternVarsGo call | `match/pattern.nix` | INV-NIX-3 | ✅   |
| P4.5.9-5 | version bump 4.5.9                                   | `flake.nix`, `lib/` | —         | ✅   |
| P4.5.9-6 | BUGFIX.md: Round 7 entry                             | `BUGFIX.md`         | —         | ✅   |
| P4.5.9-7 | todo.md: RISK-W + 4.5.9 status                       | `todo.md`           | —         | ✅   |
| P4.5.9-8 | README.md/ARCHITECTURE.md: API scan + docs update    | docs                | —         | ✅   |

---

## Phase 4.5.3~4.5.8 完成状态（摘要）

| 版本  | 主要工作                                                         | 状态 |
| ----- | ---------------------------------------------------------------- | ---- |
| 4.5.8 | 中间过渡版本（4.5.9 修订）                                       | ✅   |
| 4.5.3 | INV-NIX-3 lambda wrapper; mkTestWith/diagnoseAll; .#diagnose app | ✅   |
| 4.5.2 | INV-NIX-2 builtins.concatLists; INV-TOPO; INV-EFF-11 完整实现    | ✅   |
| 4.5.1 | INV-BIDIR-3; INV-KIND-3; INV-PAT-3                               | ✅   |
| 4.5.0 | Phase 4.5 基线（T26/T27/T28 新增测试组）                         | ✅   |

---

## 测试覆盖（Phase 4.5.9 — 203/203）

| 组    | 内容                                       | 测试数  | 覆盖 INV                   |
| ----- | ------------------------------------------ | ------- | -------------------------- |
| T1    | TypeIR 基础（mkTypeDefault/isType/etc）    | ≈8      | INV-1                      |
| T2    | Kind 系统（inferKind/kindEq/etc）          | ≈8      | INV-KIND-1                 |
| T3    | TypeRepr 变体（rFn/rADT/rMu/etc）          | ≈7      | INV-1                      |
| T4    | TRS 归约（normalizeWithFuel）              | ≈8      | INV-2                      |
| T5    | 类型等价（typeEq/NF-hash）                 | ≈7      | INV-3/4                    |
| T6    | Substitution（substituteMany/capture）     | ≈7      | INV-SUB2                   |
| T7    | UnifiedSubst（compose/apply）              | ≈7      | INV-US1~5                  |
| T8    | Constraint IR（mkEqConstraint/etc）        | ≈7      | INV-6                      |
| T9    | Solver 基础（solve/solveSimple）           | ≈8      | INV-SOL5                   |
| T10   | Instance DB（register/lookup/coherence）   | ≈7      | INV-I1-key                 |
| T11   | Refined Types（checkRefinedSubtype）       | ≈6      | INV-REFINED                |
| T12   | Module System（mkSig/mkStruct/Functor）    | ≈8      | INV-MOD-1~8                |
| T13   | Effect Handlers（mkHandler/checkHandler）  | ≈6      | INV-EFF-4~10               |
| T14   | QueryDB + Graph（BFS/invalidate）          | ≈7      | INV-G1~4, INV-TOPO         |
| T15   | Memo 层（store/lookup/epoch）              | ≈5      | INV-G4                     |
| T16   | Pattern Matching（Var/Ctor/Record）        | 13      | INV-PAT-1/2, INV-NIX-3/4/5 |
| T17   | Row 多态（RowExtend/VariantRow）           | 2       | INV-ROW                    |
| T18   | Bidir + TypeScheme（infer/check）          | 10      | INV-BIDIR-1, INV-SCHEME-1  |
| T19   | Unification（unify/Mu bisim）              | 7       | INV-MU-1                   |
| T20   | Integration（端到端场景）                  | 6       | all                        |
| T21   | Kind Inference（inferKind/fixpoint）       | 14      | INV-KIND-1/2/3             |
| T22   | Handler Continuations（mkHandlerWithCont） | 6       | INV-EFF-10/11              |
| T23   | Mu Bisim Congruence（up-to congruence）    | 6       | INV-MU-1                   |
| T24   | Bidir Annotated Lambda（eLamA）            | 8       | INV-BIDIR-2                |
| T25   | Handler Cont Type Check（inv_eff_11）      | 7       | INV-EFF-11, INV-PAT-1      |
| T26   | Bidir App Result Solved                    | 8       | INV-BIDIR-3                |
| T27   | Kind Fixpoint Solver                       | 7       | INV-KIND-3                 |
| T28   | Pattern Nested Record                      | 7       | INV-PAT-3                  |
| **Σ** |                                            | **203** | **目标: 203/203 ✅**       |

---

## 已知限制（Phase 4.5.9）

| 限制                             | 位置                | 描述                                         | 目标    |
| -------------------------------- | ------------------- | -------------------------------------------- | ------- |
| Decision Tree prefix sharing     | `match/pattern.nix` | Sequential；大型 ADT O(n)                    | Phase 5 |
| Bidir: Forall/Mu fn types in App | `bidir/check.nix`   | \_inferApp CASE2 用 freshVar；非 concrete fn | 5.0     |
| SMT bridge = oracle stub         | `refined/types.nix` | 无真实 SMTLIB2 连接                          | 持续    |
| Kind fixpoint max 10 iter        | `core/kind.nix`     | 纯 Nix 有界；实际 Kind 树 ≤3 层              | 持续    |
| patternVars BFS depth=8          | `match/pattern.nix` | 迭代 8 轮；足够实际用途但非无界              | 持续    |
| rDynamic: consistency 未完整实现 | `repr/all.nix`      | 变体已存在，isConsistent 未定义              | 5.0     |

---

## Phase 5.0 规划：Gradual Types + Full HM

### 新增不变量

```
INV-GRAD-1: Dynamic consistent with all types
  isConsistent(Dynamic, t) = true ∀ t
  isConsistent(t, Dynamic) = true ∀ t
  isConsistent(t1, t2) = structural recursive ∀ non-Dynamic

INV-GRAD-2: Cast insertion explicit at Dynamic boundaries
  ∀ boundary where static type ≠ Dynamic:
    cast node inserted in ExprWithCasts IR

INV-HM-1: infer yields principal type
  ∀ ctx, expr: infer(ctx, expr).type is the most general type

INV-HM-2: generalize respects free variables in Ctx
  ∀ ty, ctx: generalize(ctx, ty) ⊆ freeVars(ty) \ freeVars(ctx)
```

### 实现计划

| 步骤 | 功能                         | 文件                    | 预计 INV   |
| ---- | ---------------------------- | ----------------------- | ---------- |
| 5.1  | `isConsistent t1 t2`         | `bidir/check.nix`       | INV-GRAD-1 |
| 5.2  | Cast 插入遍 ExprWithCasts    | `bidir/check.nix`       | INV-GRAD-2 |
| 5.3  | HM constraint solving loop   | `constraint/solver.nix` | INV-HM-1   |
| 5.4  | Decision Tree prefix sharing | `match/pattern.nix`     | INV-PAT-4  |
| 5.5  | SMTLIB2 bridge（可选）       | `refined/types.nix`     | INV-SMT-1  |

---

## 不变量总览（4.5.9 完整版）

```
序列化:
  INV-SER-1     builtins.toJSON 不碰 Type/Constraint/函数值
  INV-I1-key    _instanceKey 用纯字符串拼接

Nix 语言:
  INV-NIX-1     or 不在 ${} 插值内
  INV-NIX-2     lib.concatMap 不用于 rec fn（改 builtins.concatLists）
  INV-NIX-3     rec{} 内递归函数不裸传给 builtins.map（用 lambda 包装器）
  INV-NIX-4     letrec 上下文不用 foldl'+ 拼接列表
  INV-NIX-5     patternVars 用迭代 BFS（不递归自引用）
  INV-LET-1     let 绑定不 shadow 函数参数

类型系统:
  INV-1         所有结构 ∈ TypeIR
  INV-2         TRS 引擎燃料有界
  INV-3         类型等价通过 NF-hash
  INV-4         hash 通过规范序列化
  INV-6         Constraint ∈ TypeRepr（数据驱动）
  INV-SUB2      替换同步（非顺序）
  INV-MU-1      Mu bisim up-to congruence
  INV-SCHEME-1  generalize 尊重 Ctx 自由变量
  INV-US1~5     UnifiedSubst 复合律

Kind:
  INV-KIND-1    推断 Kind 与注解一致
  INV-KIND-2    Kind 注解传播一致
  INV-KIND-3    Kind fixpoint 有界收敛

Bidir:
  INV-BIDIR-1   infer 模式完整性
  INV-BIDIR-2   infer(eLamA p ty b) = (ty → bodyTy)
  INV-BIDIR-3   App result solved when fn type concrete

Pattern:
  INV-PAT-1     patternVars 捕获所有 Var 绑定
  INV-PAT-2     isLinear(p) ↔ no duplicate in patternVars(p)
  INV-PAT-3     patternVars(Record{…}) = ⋃ patternVars(subPats)

Effect:
  INV-EFF-4~10  Effect handler 各项约束
  INV-EFF-11    contType.from == paramType

Module:
  INV-MOD-1~8   模块系统各项约束

增量计算:
  INV-G1        BFS 失效传播正确性
  INV-G2        visited-set 防止无限递归
  INV-G4        QueryKey 规范化
  INV-TOPO      topologicalSort 统一返回 { ok; order; error }

测试框架:
  INV-TEST-1    tryEval 隔离每个测试
  INV-TEST-2    Pattern 测试使用 patternLib.mkPVar
  INV-TEST-3    Unicode key 使用 ? "α" 语法
  INV-TEST-4    testGroup 防御性检查
  INV-TEST-5    failedList 防御性检查
  INV-TEST-6    mkTestBool/mkTest 携带 diag 字段
  INV-TEST-7    所有输出路径 JSON-safe
```
