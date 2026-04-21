# ARCHITECTURE.md — Phase 4.0

# Nix Type System 架构文档

---

## 总体架构（Phase 4.0）

```
┌────────────────────────────────────────────────────────────────────────────────────┐
│                          Nix Type System（Phase 4.0）                              │
│                                                                                    │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │                           TypeIR（统一宇宙）                                 │  │
│  │  Type = { tag; id; kind; repr; meta; phase }                                 │  │
│  │  Kind = KStar|KArrow|KRow|KEffect|KVar|KUnbound                              │  │
│  │  Meta = { eqStrategy; muPolicy; rowPolicy; bidirPolicy; ... }                │  │
│  └──────────────────────────────────────────────────────────────────────────────┘  │
│         │                    │                    │                │               │
│  ┌──────▼──────┐   ┌─────────▼──────┐   ┌─────────▼───────┐ ┌────▼─────────────┐  │
│  │  TypeRepr   │   │   Normalize    │   │  Constraint     │ │  Meta Layer      │  │
│  │ (25+ 变体)  │   │ (TRS, 3-fuel)  │   │  IR (INV-6)     │ │  serialize(α-v3) │  │
│  │ Pi/Sigma    │   │ rules_p40 ✅   │   │  Worklist P4.0  │ │  hash(NF)        │  │
│  │ Effect/Hdlr │   │ ruleEffMerge✅ │   │  RowEquality    │ │  equality        │  │
│  │ Refined  ✅ │   │ ruleRefined ✅ │   │  SMT residual✅ │ │  muEq bisim      │  │
│  │ Sig/Struct✅│   │ ruleSig     ✅ │   │  UnifiedSubst✅ │ └──────────────────┘  │
│  │ ModFunctor✅│   └─────────┬──────┘   └─────────┬───────┘                       │
│  └──────┬──────┘             │                    │                               │
│         │            ┌───────▼──────────────────────────────┐                    │
│         │            │         UnifiedSubst（Phase 4.0）     │                    │
│         │            │  { typeBindings; rowBindings; kindBindings }               │
│         │            │  INV-US1: compose law                 │                    │
│         │            │  INV-US3: 键前缀 t:/r:/k:             │                    │
│         │            └──────────────────────────────────────┘                    │
│         │                                                                         │
│  ┌──────▼──────────────────────────────────────────────────────────┐              │
│  │                     Phase 4.0 新增模块                          │              │
│  │                                                                  │              │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐  │              │
│  │  │  Refined Types   │  │  Module System   │  │Effect Handlers│  │              │
│  │  │  PredExpr IR     │  │  Sig/Struct      │  │checkHandler   │  │              │
│  │  │  staticEval      │  │  ModFunctor      │  │handleAll      │  │              │
│  │  │  smtBridge(str)  │  │  checkSig        │  │subtractEffect │  │              │
│  │  │  INV-SMT-1~4 ✅  │  │  INV-MOD-1~5 ✅  │  │INV-EFF-4~7 ✅ │  │              │
│  │  └──────────────────┘  └──────────────────┘  └───────────────┘  │              │
│  │                                                                  │              │
│  │  ┌──────────────────────────────────────────────────────────┐   │              │
│  │  │          QueryKey Incremental（Salsa-style）              │   │              │
│  │  │  QueryKey = tag:inputs（INV-QK1 确定性）                  │   │              │
│  │  │  BFS invalidation（INV-QK2 精确失效）                     │   │              │
│  │  │  revDeps 反向依赖图（链式失效）                           │   │              │
│  │  │  Cycle detection（INV-QK5 DFS）                          │   │              │
│  │  │  bumpEpoch（退化全量失效模式）                            │   │              │
│  │  └──────────────────────────────────────────────────────────┘   │              │
│  └──────────────────────────────────────────────────────────────────┘              │
│                                                                                    │
│  ┌──────────────────┐  ┌────────────────┐  ┌────────────────┐  ┌──────────────┐  │
│  │  Instance DB     │  │  Bidirectional │  │  Pattern Match │  │  Incremental │  │
│  │  specificity ✅  │  │  substLib ✅   │  │  full P3.3 ✅   │  │  Graph/Memo  │  │
│  │  partialUnify ✅ │  │  Pi/Sigma ✅   │  │  DT compiler   │  │  QueryDB ✅  │  │
│  └──────────────────┘  └────────────────┘  └────────────────┘  └──────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 依赖拓扑（Phase 4.0，严格分层）

```
Layer 0:  kindLib                            （无依赖）
Layer 1:  serialLib                          （仅 lib）
Layer 2:  metaLib                            （仅 lib）
Layer 3:  typeLib          ← kindLib, metaLib, serialLib
Layer 4:  reprLib          ← typeLib, kindLib
Layer 5:  substLib         ← reprLib, typeLib
Layer 6:  rulesBaseLib     ← substLib, kindLib, reprLib, typeLib
          rules_p33Lib     ← typeLib, kindLib
          rules_p40Lib     ← typeLib, kindLib              ← NEW 4.0
          rulesLib         = rulesBaseLib ∪ p33 ∪ p40
Layer 7:  normalizeLib     ← rulesLib
Layer 8:  hashLib          ← normalizeLib, serialLib
Layer 9:  equalityLib      ← hashLib, normalizeLib
Layer 10: constraintLib    ← typeLib, hashLib
Layer 11: unifyRowLib      ← typeLib, reprLib, kindLib
          unifyLib         ← constraintLib, substLib, unifyRowLib
Layer 12: instanceLib      ← constraintLib, hashLib, normalizeLib, unifyLib
Layer 13: unifiedSubstLib  ← typeLib, kindLib, reprLib     ← NEW 4.0
Layer 14: refinedLib       ← typeLib, kindLib, reprLib, hashLib  ← NEW 4.0
Layer 15: moduleLib        ← typeLib, kindLib, reprLib, normalizeLib, hashLib, unifiedSubstLib ← NEW 4.0
Layer 16: effectHandlerLib ← typeLib, kindLib, reprLib, normalizeLib, hashLib ← NEW 4.0
Layer 17: solverP33Lib     ← constraintLib, unifyLib, instanceLib
          solverP40Lib     ← constraintLib, unifyLib, instanceLib,
                             unifyRowLib, unifiedSubstLib, refinedLib  ← NEW 4.0
Layer 18: bidirLib         ← normalizeLib, constraintLib, unifyLib, reprLib, substLib
Layer 19: graphLib         （无 type 依赖）
Layer 20: memoLib          ← hashLib, constraintLib
          queryLib         ← hashLib                       ← NEW 4.0
Layer 21: patternLib       = patternBase ∪ patternP33
Layer 22: lib/default.nix  ← ALL layers（unified export）
```

---

## TypeRepr 变体全集（Phase 4.0，25+ 变体）

```
TypeRepr =
  Primitive    { name }                       # 原子类型 Int/Bool/String
| Var          { name; scope }                # 类型变量
| Lambda       { param; body }                # 类型级 λ
| Apply        { fn; args }                   # 类型级应用
| Constructor  { name; kind; params; body }   # 泛型 ADT 构造器
| Fn           { from; to }                   # 函数类型
| ADT          { variants; closed }           # 代数数据类型
| Constrained  { base; constraints }          # 约束内嵌（INV-6）
| Mu           { var; body }                  # 等递归类型
| Record       { fields }                     # 记录类型
| VariantRow   { variants; extension }        # 变体行（Effect handler 基础）
| RowExtend    { label; fieldType; rest }     # 行扩展
| RowEmpty     {}                             # 空行
| RowVar       { name }                       # 行变量
| Pi           { param; domain; body }        # 依赖函数类型
| Sigma        { param; domain; body }        # 依赖积类型
| Effect       { effectRow }                  # 效果类型
| EffectMerge  { left; right }               # 效果合并节点
| Opaque       { inner; tag }                 # 不透明类型（sealing）
| Ascribe      { expr; type }                # 类型标注（bidir 辅助）
# Phase 4.0 NEW ─────────────────────────────────────────────────────
| Refined      { base; predVar; predExpr }   # { n : T | φ(n) }
| Sig          { fields }                     # Module 接口签名
| Struct       { sig; impl }                  # Module 实现
| ModFunctor   { param; paramTy; body }       # Π(M : Sig). Body
| Handler      { effectTag; branches; returnType } # Effect Handler
```

---

## PredExpr IR（Refined Types 谓词语言）

```
PredExpr =
  PTrue   {}                          # 恒真
| PFalse  {}                          # 恒假
| PAnd    { left; right }             # 合取
| POr     { left; right }             # 析取
| PNot    { body }                    # 否定
| PCmp    { op; lhs; rhs }            # 比较（op ∈ {gt,lt,ge,le,eq,neq}）
| PVar    { name }                    # 自由变量（指向约束 context）
| PLit    { value }                   # 字面量
| PApp    { fn; args }                # 外部谓词（应用）

静态求值（Phase 4.0）：
  PTrue/PFalse → immediately discharged
  PAnd(PFalse, _) → short-circuit false
  PCmp(lit, lit)  → constant folding
  PVar/PApp      → SMT residual（交给外部求解器）

SMT 输出（SMTLIB2，纯 string）：
  smtBridge([refined_constraint]) → SMTLIB2 script
  → 用户传递给 z3/cvc5/solver
```

---

## Constraint IR 全集（Phase 4.0）

```
Constraint =
  Equality    { lhs; rhs }           # 类型等价（INV-6）
| Class       { className; args }    # typeclass 约束
| Predicate   { predName; subject }  # 谓词约束（P3.x）
| Implies     { premises; conclusion } # 蕴含约束
| RowEquality { lhsRow; rhsRow }     # 行等价约束 ← NEW 4.0
| Refined     { subject; predVar; predExpr } # Refined 约束 ← NEW 4.0
```

---

## UnifiedSubst 架构（Phase 4.0，解决遗留风险 1）

```
┌─────────────────────────────────────────────────────────────┐
│                    UnifiedSubst                              │
│  {                                                          │
│    typeBindings : AttrSet "t:${varName}" → Type             │
│    rowBindings  : AttrSet "r:${varName}" → RowType          │
│    kindBindings : AttrSet "k:${varName}" → Kind             │
│  }                                                          │
│                                                             │
│  INV-US3: 前缀不冲突（t: vs r: vs k:）                     │
│  INV-US1: compose law 成立（INV-US1 = 替换正确性核心）      │
│                                                             │
│  之前（Phase 3.3）：                                        │
│    type subst: AttrSet String Type  → solver 用             │
│    row subst:  AttrSet String Type  → unifyRow 单独返回     │
│    ❌ 两轨不统一 → rowVar binding 无法注入 constraint       │
│                                                             │
│  现在（Phase 4.0）：                                        │
│    solver_p40 统一使用 UnifiedSubst                         │
│    RowEquality constraint → unifyRow → fromLegacyRowSubst   │
│    → composeSubst → applySubstToConstraints                 │
│    ✅ 单一 pipeline，INV-SOL-P40-1 成立                     │
└─────────────────────────────────────────────────────────────┘
```

---

## QueryKey 增量管道（Phase 4.0，Salsa-style）

```
┌───────────────────────────────────────────────────────────────────────┐
│  Phase 3.3 Memo（epoch-based，粗粒度）：                              │
│    bumpEpoch → 全量失效（所有 cache 清空）                            │
│    invalidateType → hash前缀匹配（中粒度）                            │
│    ❌ 无 dep tracking → 无法精确传播失效                              │
│                                                                       │
│  Phase 4.0 QueryDB（Salsa-style，细粒度）：                           │
│    QueryKey = "tag:input1,input2,..."（INV-QK1）                      │
│    storeResult(db, key, value, deps) → 记录反向依赖                   │
│    invalidateKey(db, key) → BFS 传播（仅失效依赖此 key 的查询）        │
│    detectCycle(db, key) → DFS cycle detection（INV-QK5）              │
│                                                                       │
│  失效传播示例：                                                       │
│    normalize("Int") → hash("Int") → solve([Eq a Int])                 │
│    invalidate normalize("Int")                                        │
│    → hash("Int") invalid（deps 包含 normalize key）                   │
│    → solve result invalid（deps 包含 normalize key）                  │
│    ✅ INV-QK2：精确失效，无过度失效                                   │
│                                                                       │
│  与 Phase 3.3 memo 互补：                                             │
│    memo  = 对 normalize/subst/solve 的 epoch bucket cache             │
│    query = 对任意 QueryKey 的 dep-tracked 细粒度 cache                │
│    bumpEpochDB = 兼容退化（全量失效，等同 memo.bumpEpoch）            │
└───────────────────────────────────────────────────────────────────────┘
```

---

## TRS 规则集（Phase 4.0，完整）

| 规则                      | 触发条件         | 语义                                     | Phase   |
| ------------------------- | ---------------- | ---------------------------------------- | ------- |
| ruleBetaReduce            | Apply + Lambda   | β-归约                                   | 1.0     |
| ruleConstructorPartial    | Apply + Ctor     | 部分应用 + kind 推断（INV-K1）           | 3.1     |
| ruleConstrainedFloat      | Apply + Const    | 约束上浮                                 | 3.0     |
| ruleRowCanonical          | RowExtend        | spine sort → NF（INV-ROW）               | 3.2     |
| ruleRecordCanonical       | Record           | null field 清理                          | 3.2     |
| ruleEffectNormalize       | Effect           | VariantRow 字母序（INV-EFF）             | 3.2     |
| ruleFnDesugar             | Fn               | 默认关闭                                 | 3.0     |
| ruleMuUnfold              | Mu               | equi-recursive unfold                    | 2.0     |
| ruleVariantRowCanonical   | VariantRow       | flatten + sort，open tail（INV-ROW-2）   | **4.0** |
| ruleEffectMerge(P40)      | EffectMerge      | flatten + merge + RowVar tail（INV-EFF-6）| **4.0** |
| ruleRefined               | Refined          | base 归约 + PTrue 消除                   | **4.0** |
| ruleSig                   | Sig              | fields 字母序规范化（INV-MOD-4）         | **4.0** |

规则引擎策略：`innermost + fixpoint（closed under normSubterms → rule → normSubterms）`

---

## Solver Pipeline（Phase 4.0）

```
[Constraint]
  → normalizeConstraint        # canonical form
  → deduplicateConstraints     # O(n) set dedup
  → _solveLoop (worklist)
      ↓ Equality   → unify → fromLegacyTypeSubst → composeSubst → applyToWorklist
      ↓ RowEquality → unifyRow → fromLegacyRowSubst → composeSubst → applyToWorklist
      ↓ Class      → instanceDB → discharge / classResidual
      ↓ Refined    → staticEvalPred → discharge / smtResidual
      ↓ Implies    → check premises → enqueue conclusion / classResidual
  → SolverResult {
      ok;
      subst: UnifiedSubst;   ← Phase 4.0: unified（INV-SOL-P40-1）
      solved;
      classResidual;
      smtResidual;            ← Phase 4.0 新增（INV-SMT-3）
      rowSubst;               ← 向后兼容（extracted from subst.rowBindings）
    }
```

---

## 架构风险矩阵（Phase 4.0 → 5.0）

| 风险                                          | 等级  | 缓解策略                                                   | 目标 Phase |
| --------------------------------------------- | ----- | ---------------------------------------------------------- | ---------- |
| SMT bridge = string only（用户需自行调用 z3） | 🟡 低 | smtBridge 生成标准 SMTLIB2；用户侧集成                     | 4.1        |
| Refined subtype 非自动化                      | 🟠 中 | Phase 4.1 引入 implication oracle（SMT auto check）        | 4.1        |
| Functor transitive composition 未实现         | 🟠 中 | applyFunctor 单次；Phase 4.2 引入 functor composition      | 4.2        |
| Effect Handler continuations（delimited）     | 🟠 中 | 当前仅 type-level；Phase 4.3 引入 continuation passing     | 4.3        |
| Mu bisimulation up-to congruence              | 🟡 低 | guard set 已覆盖 99% 用例；Phase 4.0 预研                  | 4.3        |
| Decision Tree prefix sharing                  | 🟡 低 | sequential-first；Phase 4.x 引入 DTSplit                  | 4.x        |
| QueryKey + Memo 双层缓存一致性                | 🟠 中 | 两者 key space 不重叠；bumpEpoch 同步两者；需文档化约定    | —          |
| Nix evaluation depth limit（深 ADT）          | 🔴 高 | split fuel 保护；注意 Nix builtins.seq 强制求值范围        | 持续       |
