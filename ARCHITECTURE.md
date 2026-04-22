# ARCHITECTURE.md — Phase 4.2

## 总体架构

```
┌───────────────────────────────────────────────────────────────────────┐
│                    Nix Type System（Phase 4.2）                        │
│                                                                        │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │                      TypeIR（统一宇宙）                          │  │
│  │  Type = { tag; id; kind; repr; meta }                           │  │
│  │  Kind = KStar|KArrow|KRow|KEffect|KVar★|KUnbound               │  │
│  │  Meta = { eqStrategy; muPolicy; rowPolicy; schemePolicy★; ... } │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│       │               │               │               │               │
│  TypeRepr         Normalize       Constraint       Meta Layer          │
│  25+ 变体         TRS 11规则      IR（INV-6）      serialize           │
│  rForall★         rules           solver           hash（NF）          │
│  rHole★           rewrite         unify            equality            │
│  rDynamic★        unified_subst   unify_row        de Bruijn★          │
│       │               │               │                               │
│  ┌────▼───────────────▼───────────────▼──────────────────────────┐   │
│  │              Phase 4.2 核心新增层                               │   │
│  │  TypeScheme★   { __schemeTag; forall; body; constraints }      │   │
│  │  mkScheme/monoScheme/generalize★ (HM INV-SCHEME-1)            │   │
│  │  instantiateScheme (fresh vars, INV-BIDIR-1)                  │   │
│  └────┬─────────────────┬───────────────┬──────────────────────┘    │
│       │                 │               │                             │
│  Module★           Bidir★          InstanceDB★                       │
│  composeFunctors   infer/check     checkGlobalCoherence              │
│  λM.f1(f2(M))     let-gen         mergeLocalInstances(unify)         │
│  INV-MOD-8         INV-BIDIR-1    INV-COH-1                          │
└───────────────────────────────────────────────────────────────────────┘
★ = Phase 4.2 新增/升级
```

---

## 依赖拓扑（Layer 0~22，严格无环）

```
Layer 0:  kindLib          ← （无依赖）            Kind 系统 + unifyKind★
Layer 1:  serialLib        ← lib, kindLib          de Bruijn alpha-NF
Layer 2:  metaLib          ← lib                   MetaType 语义控制
Layer 3:  typeLib          ← kindLib,metaLib        TypeIR + mkScheme★
Layer 4:  reprLib          ← kindLib               TypeRepr 25+ 变体
Layer 5:  substLib         ← typeLib,reprLib,kindLib capture-safe subst
Layer 6:  rulesLib         ← substLib,kindLib,reprLib,typeLib  TRS 11 规则
Layer 7:  normalizeLib     ← rulesLib,typeLib,reprLib,kindLib  fuel-based TRS
Layer 8:  hashLib          ← normalizeLib,serialLib  typeHash/schemeHash★
Layer 9:  equalityLib      ← hashLib,normalizeLib,serialLib   NF equality
Layer 10: constraintLib    ← typeLib,reprLib,kindLib,serialLib  Constraint IR
Layer 11: unifyRowLib      ← typeLib,reprLib,kindLib,substLib,normalizeLib
          unifyLib         ← typeLib,reprLib,kindLib,substLib,hashLib,normalizeLib
Layer 12: instanceLib      ← typeLib,reprLib,kindLib,hashLib,normalizeLib
          （checkGlobalCoherence★，mergeLocalInstances升级★）
Layer 13: unifiedSubstLib  ← typeLib,kindLib,reprLib,substLib
Layer 14: refinedLib       ← typeLib,reprLib,kindLib,hashLib,normalizeLib
Layer 15: moduleLib        ← typeLib,reprLib,kindLib,normalizeLib,hashLib,unifiedSubstLib
          （composeFunctors★ λM.f1(f2(M)) INV-MOD-8）
Layer 16: effectLib        ← typeLib,reprLib,kindLib,normalizeLib,hashLib
Layer 17: solverLib        ← constraintLib,substLib,unifiedSubstLib,
                             unifyLib,unifyRowLib,instanceLib,hashLib,normalizeLib
                             （_instantiateScheme★ for Scheme constraints）
Layer 18: bidirLib         ← typeLib,reprLib,kindLib,normalizeLib,constraintLib,
                             substLib,unifiedSubstLib★,hashLib
                             （HM let-generalization★ INV-BIDIR-1/SCHEME-1）
Layer 19: graphLib         （无 type 依赖，纯图算法）
Layer 20: memoLib          ← hashLib
          queryLib         ← hashLib
Layer 21: patternLib       ← typeLib,reprLib,kindLib
Layer 22: lib/default.nix  ← ALL layers（240 exports，无重复）
```

---

## TRS 规则集（Phase 4.2，11 规则合并）

| 规则                      | 触发条件            | 语义                         | 优先级 |
| ------------------------- | ------------------- | ---------------------------- | ------ |
| `ruleBetaReduce`          | Apply + Lambda      | β-归约                       | P1     |
| `ruleConstructorPartial`  | Apply + Constructor | 部分应用 + kind              | P2     |
| `ruleConstraintMerge`     | Constrained嵌套     | 约束合并                     | P3     |
| `ruleConstraintFloat`     | Apply + Constrained | 约束上浮                     | P4     |
| `ruleRowCanonical`        | RowExtend           | spine 字母序（INV-ROW）      | P5     |
| `ruleVariantRowCanonical` | VariantRow          | flatten + sort + open tail   | P6     |
| `ruleEffectMerge`         | EffectMerge         | flatten + dedup（INV-EFF-6） | P7     |
| `ruleRefined`             | Refined PTrue       | → base（INV-SMT-2）          | P8     |
| `ruleSig`                 | Sig                 | fields 字母序（INV-MOD-4）   | P9     |
| `ruleRecordCanonical`     | Record              | null field 清理              | P10    |
| `ruleEffectNormalize`     | Effect              | VariantRow 字母序            | P11    |

---

## Solver Pipeline（Phase 4.2）

```
[Constraint]
  → normalizeConstraint       # canonical form（对称性 + 去重）
  → deduplicateConstraints    # O(n) set dedup
  → _solveLoop (worklist, fuel=2000)
      ↓ Equality   → unify → composeSubst
                   → applySubstToConstraints(worklist) ← INV-SOL5 requeue
      ↓ RowEquality → unifyRow → composeSubst
                    → applySubstToConstraints(worklist)
      ↓ Class      → instanceLib.resolveWithFallback
                   → canDischarge = found && impl != null（RISK-A）
      ↓ Refined    → staticEvalPred → discharge / smtResidual
      ↓ Implies    → check premises → enqueue conclusion
      ↓ Scheme★    → _instantiateScheme → fresh vars → mkEqConstraint
      ↓ Kind★      → defer to classResidual（Phase 4.3 完整实现）
  → SolverResult { ok; subst: UnifiedSubst; solved;
                   classResidual; smtResidual; rowSubst }
```

---

## TypeScheme（Phase 4.2 新增）

```
TypeScheme = {
  __schemeTag = "Scheme";
  forall:      [String];       # sorted canonical
  body:        Type;           # scheme body
  constraints: [Constraint];   # class constraints on type vars
}

INV-SCHEME-1: generalize(Γ, T, cs) = ∀(fv(T) \ fv(Γ)).T
  → 只泛化 T 的自由变量中不在 Γ 中的变量
  → 保证 polymorphic let 不会泄漏外层变量
```

---

## Functor Composition（Phase 4.2 核心修复）

```
Phase 4.1 问题（ADR-006-old）：
  composeFunctors f1 f2 → body = Apply(f1, Apply(f2, param))
  语义错误：这是 type-level Apply，不是 functor application

Phase 4.2 修复（ADR-009）：
  composeFunctors f1 f2 = λM. f1_body[f1.param := f2_body[f2.param := M]]

  实现：
  1. 生成新鲜参数 M（hash-based unique name）
  2. freshM = Var(M, "mod")
  3. f2Applied = applySubst(f2.param → freshM, f2.body)
  4. f1Applied = applySubst(f1.param → f2Applied, f1.body)
  5. composedSig = f2.paramSig（输入类型 = f2 的输入）
  6. return mkModFunctor(M, composedSig, f1Applied)

INV-MOD-8: isModFunctor(composeFunctors f1 f2) = true
```

---

## Phase 4.2 修复总览

| 编号    | 修复项                              | 文件                    | INV           |
| ------- | ----------------------------------- | ----------------------- | ------------- |
| P4.2-1  | Functor 真正 λM.f1(f2(M)) 语义      | `module/system.nix`     | INV-MOD-8★    |
| P4.2-2  | composeFunctorChain 传递性          | `module/system.nix`     | INV-MOD-8★    |
| P4.2-3  | TypeScheme + mkScheme/monoScheme    | `core/type.nix`         | INV-SCHEME-1★ |
| P4.2-4  | HM let-generalization               | `bidir/check.nix`       | INV-SCHEME-1★ |
| P4.2-5  | infer App via constraint generation | `bidir/check.nix`       | INV-BIDIR-1★  |
| P4.2-6  | Global InstanceDB coherence check   | `runtime/instance.nix`  | INV-COH-1★    |
| P4.2-7  | mergeLocalInstances + unify overlap | `runtime/instance.nix`  | INV-COH-1★    |
| P4.2-8  | rForall / rHole / rDynamic variants | `repr/all.nix`          | INV-1★        |
| P4.2-9  | KVar + unifyKind                    | `core/kind.nix`         | INV-K1★       |
| P4.2-10 | mkSchemeConstraint/mkKindConstraint | `constraint/ir.nix`     | INV-6★        |
| P4.2-11 | Solver handles Scheme constraints   | `constraint/solver.nix` | INV-SOL★      |
| P4.2-12 | de Bruijn serialize (alpha-NF fix)  | `meta/serialize.nix`    | INV-4         |
| P4.2-13 | schemeHash / substHash              | `meta/hash.nix`         | INV-4★        |
| P4.2-14 | lib/default.nix 240 exports，无重复 | `lib/default.nix`       | 架构          |
| P4.2-15 | tests/test_all.nix 150+ tests 20组  | `tests/test_all.nix`    | all           |
| P4.2-16 | README + ARCHITECTURE + TODO 更新   | 文档                    | —             |

---

## 架构风险矩阵（Phase 4.2 → 4.3）

| 风险                              | 等级  | 缓解                                    | 目标 |
| --------------------------------- | ----- | --------------------------------------- | ---- |
| Decision Tree prefix sharing      | 🟡 低 | sequential-first；大型 ADT O(n)         | 4.x  |
| Bidir infer 完整性                | 🟠 中 | App 用约束生成★；let-gen 完整★          | 4.3  |
| Mu bisimulation 近似（guard set） | 🟡 低 | guard set 覆盖 99%；up-to 精化          | 4.3  |
| Effect Handler continuations      | 🟠 中 | type-level only；Phase 4.3 cont passing | 4.3  |
| SMT bridge = string only          | 🟡 低 | 用户提供 oracle；设计合理               | 持续 |
| Nix evaluation depth（深 ADT）    | 🔴 高 | fuel 3层保护；注意 builtins.seq         | 持续 |
| Kind inference 部分               | 🟠 中 | KVar + unifyKind★；solver 仅 defer      | 4.3  |

---

## 架构决策记录（ADR）

### ADR-001: Constraint ∈ TypeRepr（INV-6）

**决策**: Constraint 是结构化 attrset，不是函数。

### ADR-002: UnifiedSubst（type+row+kind 统一）

**决策**: 单一 UnifiedSubst 替代分散 subst，INV-US1 compose law。

### ADR-003: QueryKey Schema Validation

**决策**: 所有 key 通过 `mkQueryKey` 构造，格式验证。

### ADR-004: 文件合并（Phase 4.1）

**决策**: 消灭所有 `_p33`/`_p40` 碎片文件。

### ADR-005: topologicalSort in-degree 语义

**决策**: `edges[A]=[B]` = A 依赖 B；`in-degree(A) = |edges[A]|`。

### ADR-006: TypeScheme ∉ TypeIR（Phase 4.2）★

**决策**: `mkScheme` 是 TypeIR 的包装，`rForall` 才是 TypeRepr 变体。  
**理由**: 泛化/实例化在 type inference 层；TypeRepr 保持纯结构。

### ADR-007: Functor Composition = lazy substitution（Phase 4.2）★

**决策**: `composeFunctors f1 f2` = `λM. f1_body[f1.param := f2_body[f2.param := M]]`  
**理由**: Phase 4.1 的 `Apply` 嵌套不是真正的 functor application 语义。

### ADR-008: HM let-generalization respects Ctx FVs（INV-SCHEME-1）★

**决策**: `generalize(Γ, T) = ∀(fv(T) \ fv(Γ)).T`，不泛化 Γ 中出现的变量。  
**理由**: 防止 let-polymorphism 违反值限制（value restriction）。

### ADR-009: emptyDB disambiguation★

**决策**: `instanceLib.emptyDB` → `instanceEmptyDB`，`queryLib.emptyDB` → `emptyDB`（default）。  
**理由**: 两个 lib 均有 `emptyDB`，flat export 需要消歧义。
