# nix-types — Phase 4.3

**Pure Nix Native Type System** — System Fω-level expressiveness, implemented entirely in pure Nix with no external runtime dependencies.

[![Phase](https://img.shields.io/badge/phase-4.3-blue)]() [![Tests](https://img.shields.io/badge/tests-160%2B-green)]() [![INVs](https://img.shields.io/badge/invariants-30%2B-orange)]()

---

## Phase 4.3 Highlights

| 特性                           | 描述                                                              | INV        |
| ------------------------------ | ----------------------------------------------------------------- | ---------- |
| **Kind Inference**★            | `inferKind`/`solveKindConstraints`: Kind 约束真正在 solver 中求解 | INV-KIND-1 |
| **Mu bisim up-to congruence**★ | `_unifyMu` 使用 coinductive up-to congruence（Pous 2016）         | INV-MU-1   |
| **Handler Continuations**★     | `mkHandlerWithCont`: delimited control 的 continuation type       | INV-EFF-10 |
| **Bug fix: \_mkId**★           | `core/type.nix` 使用 `serializeRepr` 而非 `builtins.toJSON`       | INV-4      |

---

## 特性概览

| 特性                  | 状态 | 说明                                            |
| --------------------- | ---- | ----------------------------------------------- |
| TypeIR 统一宇宙       | ✅   | Type = { tag; id; kind; repr; meta }            |
| TRS 规则集（11 规则） | ✅   | β-reduction, row canonical, constraint merge... |
| Kind 系统             | ✅   | KStar/KArrow/KRow/KEffect/KVar + unifyKind      |
| Kind Inference        | ✅★  | inferKind + solveKindConstraints（INV-KIND-1）  |
| 约束 IR（INV-6）      | ✅   | Equality/Class/Row/Refined/Scheme/Kind          |
| Constraint Solver     | ✅   | Worklist + fuel-bounded + Kind 求解             |
| UnifiedSubst          | ✅   | type+row+kind 三前缀 compose law                |
| Robinson Unification  | ✅   | occurs check + Mu bisim up-to congruence★       |
| Row Polymorphism      | ✅   | RowExtend + VariantRow + open tail              |
| ADT + Pattern         | ✅   | Decision Tree O(1) ordinal dispatch             |
| Mu equi-recursive     | ✅   | coinductive bisimulation（INV-MU-1）★           |
| TypeScheme（∀）       | ✅   | HM let-generalization（INV-SCHEME-1）           |
| Bidirectional check   | ✅   | infer/check + let-gen（INV-BIDIR-1）            |
| Refined Types         | ✅   | { x: T \| φ(x) } + SMT oracle interface         |
| Module Functors       | ✅   | λM.f1(f2(M)) semantics（INV-MOD-8）             |
| Effect Handlers       | ✅   | deep/shallow + continuations★（INV-EFF-10）     |
| Incremental Engine    | ✅   | Salsa-style Memo + BFS invalidation             |
| Gradual Types prep    | ✅   | rDynamic repr（Phase 5.0 planned）              |

---

## 快速开始

```bash
# 运行测试套件
nix run .#test

# 检查不变量
nix run .#check-inv

# 运行综合示例
nix run .#demo
```

### 基本用法

```nix
let
  ts = import ./lib/default.nix { lib = pkgs.lib; };

  # 基础类型
  tInt  = ts.tInt;
  tBool = ts.tBool;

  # 函数类型: Int → Bool
  tFn = ts.mkTypeDefault (ts.rFn tInt tBool) ts.KStar;

  # ADT: Maybe Int
  maybeVariants = [
    (ts.mkVariant "Nothing" [] 0)
    (ts.mkVariant "Just" [tInt] 1)
  ];
  tMaybeInt = ts.mkTypeDefault (ts.rADT maybeVariants true) ts.KStar;

  # Kind inference（Phase 4.3）
  kindR = ts.inferKind {} tFn.repr;
  # kindR.kind = KStar

  # Normalize + hash（INV-2/3/4）
  nf   = ts.normalize' tFn;
  hash = ts.typeHash nf;

  # Constraint solving with Kind（Phase 4.3）
  alpha = ts.mkTypeDefault (ts.rVar "α" "") ts.KStar;
  result = ts.solveSimple [
    (ts.mkEqConstraint alpha tInt)
    (ts.mkKindConstraint "α" ts.KStar)  # Kind constraint now solved!
  ];
  # result.ok = true
  # result.subst.typeBindings.α = tInt

  # Mu bisimulation up-to congruence（Phase 4.3）
  muX = ts.mkTypeDefault (ts.rMu "X" (ts.mkTypeDefault (ts.rFn tInt (ts.mkTypeDefault (ts.rVar "X" "") ts.KStar)) ts.KStar)) ts.KStar;
  muY = ts.mkTypeDefault (ts.rMu "Y" (ts.mkTypeDefault (ts.rFn tInt (ts.mkTypeDefault (ts.rVar "Y" "") ts.KStar)) ts.KStar)) ts.KStar;
  bisimR = ts.unify muX muY;
  # bisimR.ok = true (up-to congruence)

  # Handler with continuation（Phase 4.3）
  contTy  = ts.mkTypeDefault (ts.rFn tInt tBool) ts.KStar;
  handler = ts.mkHandlerWithCont "State" tInt contTy tBool;
  # handler.repr.hasCont = true
  # handler.repr.contType = tInt → tBool

in { inherit tFn tMaybeInt result bisimR handler; }
```

---

## 不变量系统

| 不变量        | 描述                                         |
| ------------- | -------------------------------------------- |
| INV-1         | 所有结构 ∈ TypeIR                            |
| INV-2         | 所有计算 = Rewrite(TypeIR)（TRS，fuel 终止） |
| INV-3         | 所有比较 = NormalForm Equality               |
| INV-4         | 所有缓存 key = Hash(serialize(NF))           |
| INV-5         | 所有依赖追踪 = Graph Edge                    |
| INV-6         | Constraint ∈ TypeRepr（不是函数）            |
| INV-US1~5     | UnifiedSubst compose law                     |
| INV-SOL1~5    | Solver worklist correctness                  |
| INV-SCHEME-1  | let-generalization respects Ctx FVs          |
| INV-BIDIR-1   | infer/check sound w.r.t. normalize           |
| INV-MOD-1~8   | Module system invariants                     |
| INV-EFF-4~10★ | Effect handler invariants                    |
| INV-KIND-1★   | Inferred kinds consistent with annotations   |
| INV-MU-1★     | Mu bisimulation up-to congruence sound       |

---

## 模块结构

```
/core
  kind.nix        # Kind + inferKind + solveKindConstraints (Phase 4.3)
  type.nix        # TypeIR + mkScheme; _mkId uses serializeRepr (Phase 4.3 fix)
  meta.nix        # MetaType + bisimMeta (Phase 4.3)

/repr
  all.nix         # TypeRepr 25+ 变体

/normalize
  rewrite.nix     # TRS 主引擎（fuel-based）
  rules.nix       # 11 TRS 规则
  substitute.nix  # capture-safe substitution
  unified_subst.nix # UnifiedSubst（type+row+kind）

/constraint
  ir.nix          # Constraint IR（Equality|Class|Row|Refined|Scheme|Kind）
  unify.nix       # Robinson unification + Mu bisim up-to congruence (Phase 4.3)
  unify_row.nix   # Row polymorphism unification
  solver.nix      # Worklist solver + Kind constraint solving (Phase 4.3)

/meta
  serialize.nix   # de Bruijn canonical serialization
  hash.nix        # canonical hash（INV-4）
  equality.nix    # typeEq via NF

/runtime
  instance.nix    # Instance DB + global coherence

/module
  system.nix      # Sig/Struct/ModFunctor（λM.f1(f2(M))）

/refined
  types.nix       # Refined Types + SMT oracle

/effect
  handlers.nix    # Effect Handlers + continuations (Phase 4.3)

/bidir
  check.nix       # Bidirectional inference + HM let-generalization

/match
  pattern.nix     # Pattern IR + Decision Tree compiler

/incremental
  graph.nix       # Dependency graph（BFS invalidation）
  memo.nix        # Memo layer（epoch-based）
  query.nix       # QueryDB（Salsa-style）

/lib
  default.nix     # 250+ exports（Layer 0~22 topological order）

/tests
  test_all.nix    # 160+ tests, 23 groups

/examples
  demo.nix        # 8 end-to-end scenarios
```

---

## 设计原则

**依赖倒置**：每个模块通过 `{ lib, ...Libs }` 参数接收依赖，无隐式 import。

**层级化**：Layer 0~22 严格拓扑顺序，无循环。

**不变量驱动**：INV-1~6 是系统的形式规范，任何违反都视为 soundness bug。

**增量模式**：Salsa-style QueryDB + Memo，BFS 失效传播。

**数据驱动**：Constraint ∈ TypeRepr（INV-6），solver 操作 IR 而非函数。

**可扩展**：新 TypeRepr 变体只需在 `repr/all.nix` + `meta/serialize.nix` + normalize rules 三处添加。

---

## 版本历史

| 版本  | 核心特性                                                |
| ----- | ------------------------------------------------------- |
| 4.3.0 | Kind inference, Mu bisim up-to congruence, Handler cont |
| 4.2.0 | TypeScheme/HM, Functor λM.f1(f2(M)), Global coherence   |
| 4.1.0 | UnifiedSubst, RISK-A~F 全修复, de Bruijn serialize      |
| 4.0.0 | Constraint IR 化, rowVar solver 注入                    |
| 3.3.0 | Row 多态, VariantRow, EffectMerge                       |
