# ARCHITECTURE.md — Phase 4.1

# Nix Type System 架构文档

---

## 总体架构（Phase 4.1）

```
┌────────────────────────────────────────────────────────────────────────────────────┐
│                          Nix Type System（Phase 4.1）                              │
│                                                                                    │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │                           TypeIR（统一宇宙）                                 │  │
│  │  Type = { tag; id; kind; repr; meta; }                                       │  │
│  │  Kind = KStar|KArrow|KRow|KEffect|KVar|KUnbound                              │  │
│  │  Meta = { eqStrategy; muPolicy; rowPolicy; bidirPolicy; ... }                │  │
│  └──────────────────────────────────────────────────────────────────────────────┘  │
│         │                    │                    │                │               │
│  ┌──────▼──────┐   ┌─────────▼──────┐   ┌─────────▼───────┐ ┌────▼─────────────┐  │
│  │  TypeRepr   │   │   Normalize    │   │  Constraint     │ │  Meta Layer      │  │
│  │ (25+ 变体)  │   │ (TRS 11规则)  │   │  IR (INV-6)     │ │  serialize(α-v3) │  │
│  │ Pi/Sigma    │   │ 合并版rules✅  │   │  Worklist P4.1  │ │  hash(NF)        │  │
│  │ Effect/Hdlr │   │ ruleEffMerge✅ │   │  RowEquality    │ │  equality        │  │
│  │ Refined  ✅ │   │ ruleRefined ✅ │   │  SMT residual✅ │ │  muEq bisim      │  │
│  │ Sig/Struct✅│   │ ruleSig     ✅ │   │  UnifiedSubst✅ │ └──────────────────┘  │
│  │ ModFunctor✅│   └─────────┬──────┘   └─────────┬───────┘                       │
│  └──────┬──────┘             │                    │                               │
│         │            ┌───────▼──────────────────────────────┐                    │
│         │            │         UnifiedSubst（Phase 4.1）     │                    │
│         │            │  { typeBindings:"t:"; rowBindings:"r:"; kindBindings:"k:" }│
│         │            │  INV-US1: compose law                 │                    │
│         │            │  INV-US3: 键前缀 t:/r:/k:             │                    │
│         │            └──────────────────────────────────────┘                    │
│                                                                                    │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │                     Phase 4.x 新增/修复模块                                 │   │
│  │                                                                              │   │
│  │  ┌───────────────────┐  ┌──────────────────┐  ┌─────────────────────────┐   │   │
│  │  │  Refined Types    │  │  Module System   │  │  Effect Handlers        │   │   │
│  │  │  PredExpr IR      │  │  Sig/Struct      │  │  checkHandler           │   │   │
│  │  │  staticEval       │  │  ModFunctor      │  │  handleAll              │   │   │
│  │  │  smtOracle ★4.1   │  │  composeFunctor★ │  │  subtractEffect         │   │   │
│  │  │  INV-SMT-1~6 ✅   │  │  mergeInst ★4.1  │  │  deep/shallow ★4.1     │   │   │
│  │  └───────────────────┘  └──────────────────┘  └─────────────────────────┘   │   │
│  │                                                                              │   │
│  │  ┌───────────────────────────────────────────────────────────────────────┐   │   │
│  │  │          QueryKey DB（Salsa-style，Phase 4.1 双缓存统一）              │   │   │
│  │  │  QueryKey = tag:inputs（INV-QK1 确定性 + INV-QK-SCHEMA 验证 ★4.1）   │   │   │
│  │  │  BFS invalidation（INV-QK2 精确失效，revEdges 方向 ★4.1）            │   │   │
│  │  │  cacheNormalize = QueryDB + Memo 统一写（RISK-D 修复 ★4.1）          │   │   │
│  │  │  bumpEpochDB = 两层同步清空（RISK-D 修复 ★4.1）                      │   │   │
│  │  └───────────────────────────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                    │
│  ┌──────────────────┐  ┌────────────────┐  ┌────────────────┐  ┌──────────────┐  │
│  │  Instance DB     │  │  Bidirectional │  │  Pattern Match │  │  Incremental │  │
│  │  NF-hash key ★   │  │  substLib ✅   │  │  合并版 ★4.1   │  │  Graph/Memo  │  │
│  │  impl≠null ★     │  │  Pi/Sigma ✅   │  │  DT compiler   │  │  topo fix ★  │  │
│  │  INV-I1~2 ✅     │  │  freshVar ✅   │  │  exhaustive    │  │  clean-stale★│  │
│  └──────────────────┘  └────────────────┘  └────────────────┘  └──────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────┘

★ = Phase 4.1 新增/修复
```

---

## 依赖拓扑（Phase 4.1，严格分层）

```
Layer 0:  kindLib                                （无依赖）
Layer 1:  serialLib                              （仅 lib + kindLib）
Layer 2:  metaLib                                （仅 lib）
Layer 3:  typeLib          ← kindLib, metaLib, serialLib
Layer 4:  reprLib          ← kindLib
Layer 5:  substLib         ← typeLib, reprLib, kindLib
Layer 6:  rulesLib         ← substLib, kindLib, reprLib, typeLib
          (合并 rules+p33+p40 → 单文件 11 条规则)
Layer 7:  normalizeLib     ← rulesLib, typeLib, reprLib, kindLib
Layer 8:  hashLib          ← normalizeLib, serialLib, typeLib
Layer 9:  equalityLib      ← hashLib, normalizeLib, serialLib, typeLib
Layer 10: constraintLib    ← typeLib, reprLib, kindLib, serialLib
Layer 11: unifyRowLib      ← typeLib, reprLib, kindLib, substLib, normalizeLib
          unifyLib         ← typeLib, reprLib, kindLib, substLib, hashLib, normalizeLib
Layer 12: instanceLib      ← typeLib, reprLib, kindLib, hashLib, normalizeLib
Layer 13: unifiedSubstLib  ← typeLib, kindLib, reprLib, substLib
Layer 14: refinedLib       ← typeLib, reprLib, kindLib, hashLib, normalizeLib
Layer 15: moduleLib        ← typeLib, reprLib, kindLib, normalizeLib, hashLib, unifiedSubstLib
Layer 16: effectLib        ← typeLib, reprLib, kindLib, normalizeLib, hashLib
Layer 17: solverLib        ← constraintLib, substLib, unifiedSubstLib,
                             unifyLib, unifyRowLib, instanceLib, hashLib, normalizeLib
                             (合并 solver+solver_p40 → 单文件)
Layer 18: bidirLib         ← typeLib, reprLib, kindLib, normalizeLib, constraintLib, substLib, hashLib
Layer 19: graphLib         （无 type 依赖，纯图算法）
Layer 20: memoLib          ← hashLib
          queryLib         ← hashLib
Layer 21: patternLib       ← typeLib, reprLib, kindLib
          (合并 pattern+pattern_p33 → 单文件)
Layer 22: lib/default.nix  ← ALL layers（统一导出）
```

---

## TRS 规则集（Phase 4.1，合并后）

| 规则                      | 触发条件                 | 语义                                       | 优先级 |
| ------------------------- | ------------------------ | ------------------------------------------ | ------ |
| `ruleBetaReduce`          | Apply + Lambda           | β-归约（计算核心）                         | P1     |
| `ruleConstructorPartial`  | Apply + Constructor      | 部分应用 + kind（INV-K1）                  | P2     |
| `ruleConstraintMerge`     | Constrained(Constrained) | 约束嵌套合并                               | P3     |
| `ruleConstraintFloat`     | Apply + Constrained      | 约束上浮                                   | P4     |
| `ruleRowCanonical`        | RowExtend                | spine 字母序（INV-ROW）                    | P5     |
| `ruleVariantRowCanonical` | VariantRow               | flatten + sort + open tail                 | P6     |
| `ruleEffectMerge`         | EffectMerge              | flatten + dedup + RowVar tail（INV-EFF-6） | P7     |
| `ruleRefined`             | Refined                  | PTrue → 退化 base（INV-SMT-2）             | P8     |
| `ruleSig`                 | Sig                      | fields 字母序（INV-MOD-4）                 | P9     |
| `ruleRecordCanonical`     | Record                   | null field 清理                            | P10    |
| `ruleEffectNormalize`     | Effect                   | VariantRow 字母序（INV-EFF）               | P11    |

---

## Solver Pipeline（Phase 4.1）

```
[Constraint]
  → normalizeConstraint        # canonical form（对称性 + 去重）
  → deduplicateConstraints     # O(n) set dedup（constraintKey hash）
  → _solveLoop (worklist, fuel=2000)
      ↓ Equality   → unify → fromLegacyTypeSubst → composeSubst
                   → applySubstToConstraints(worklist)  ← INV-SOL5 requeue ★
      ↓ RowEquality → unifyRow → fromLegacyRowSubst → composeSubst
                    → applySubstToConstraints(worklist)  ← INV-SOL5 ★
      ↓ Class      → instanceLib.resolveWithFallback
                   → impl != null check（RISK-A 修复）★
                   → discharge / classResidual
      ↓ Refined    → staticEvalPred → discharge / smtResidual
      ↓ Implies    → check premises → enqueue conclusion
  → SolverResult {
      ok;
      subst:         UnifiedSubst;     ← Phase 4.0 unified
      solved;
      classResidual;
      smtResidual;                     ← Phase 4.0+ new
      rowSubst;                        ← 向后兼容（from subst.rowBindings）
    }
```

---

## Phase 4.1 修复总览

### RISK-A: canDischarge Soundness

```
Before: resolveWithFallback → { found=true; impl=null; } (superclass path)
        canDischarge = r.found  ← 错误：impl=null 也认为 discharged
After:  canDischarge = r.found && r.impl != null  ← soundness 保证
        superclass resolution 现在返回真实 impl（从 sub-instance 提取）
```

### RISK-B: Instance Key Coherence

```
Before: instanceKey = md5(toJSON(normArgs))  ← toJSON 顺序不稳定
After:  instanceKey = sha256({ c: className, a: sorted(typeHash(arg)) })
        ← NF-hash，α-等价类型 → 相同 key → INV-4 coherence 成立
```

### RISK-C: Worklist Requeue

```
Before: _partitionAffected → unaffected list not requeued
After:  after composeSubst → applySubstToConstraints(newSubst, state.worklist)
        → newWorklist 写回 state.worklist
        ← INV-SOL5: substitution propagation 完整
```

### RISK-D: Dual Cache Consistency

```
Before: memoLib.storeNormalize + queryLib.storeResult 独立调用，无同步
After:  cacheNormalize(db, memo, typeId, nf, deps)
          → queryDB: storeResult(db, "norm:typeId", nf, deps)
          → memo: memo // { typeId = nf }
        bumpEpochDB({ queryDB; memo })
          → queryDB: all entries invalid
          → memo: {}  ← 两层同步清空
```

### RISK-E: ModFunctor Qualified Naming

```
Before: applyFunctor substitutes param → argStruct directly
        body 中的 param+"_field" 变量无法正确解析
After:  subst = singleTypeBinding param argStruct
        + for each field n: singleTypeBinding (param+"_"+n) impl.n
        → compose all → applyUnifiedSubst fieldSubsts body
```

### RISK-F: TopologicalSort Direction

```
Semantics: edges[A]=[B] means "A depends on B" (B processed first)
Before: inDegrees = { n: len(revEdges[n]) }  ← WRONG
After:  inDegrees = { n: len(edges[n]) }     ← in-degree = dependency count
        degree decrement: use revEdges[next]  ← nodes depending on 'next'
```

---

## 架构风险矩阵（Phase 4.1 → 4.2）

| 风险                                       | 等级  | 缓解                                             | 目标 Phase |
| ------------------------------------------ | ----- | ------------------------------------------------ | ---------- |
| Decision Tree prefix sharing               | 🟡 低 | sequential-first；大型 ADT 可能 O(n)             | 4.x        |
| Functor transitive composition 非真正语义  | 🟠 中 | body 嵌套表示；Phase 4.2 引入 lazy subst         | 4.2        |
| Bidir infer App 返回 freshVar              | 🟠 中 | freshVar + constraint generation；Phase 4.2 完善 | 4.2        |
| Mu bisimulation 近似（guard set）          | 🟡 低 | guard set 覆盖 99% 用例；up-to 精化              | 4.3        |
| Effect Handler continuations 仅 type-level | 🟠 中 | 当前仅静态分析；Phase 4.3 引入 cont passing      | 4.3        |
| SMT bridge = string only                   | 🟡 低 | 用户提供 oracle；设计合理                        | 持续       |
| Nix evaluation depth limit（深 ADT）       | 🔴 高 | fuel 保护（3-layer）；注意 builtins.seq          | 持续       |
