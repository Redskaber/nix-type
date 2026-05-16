# nix-types — Phase 4.5.2

**Pure Nix Native Type System** — System Fω-level expressiveness, implemented entirely in pure Nix with no external runtime dependencies.

[![Phase](https://img.shields.io/badge/phase-4.5.2-blue)]() [![Tests](https://img.shields.io/badge/tests-203%2F203-brightgreen)]() [![INVs](https://img.shields.io/badge/invariants-40%2B-orange)]()

---

## Phase 4.5.2 修复摘要

| Bug                         | 根因                                                                                      | 修复文件                | INV        |
| --------------------------- | ----------------------------------------------------------------------------------------- | ----------------------- | ---------- |
| T16 `patternVars` 失败      | `lib.concatMap` 在 rec-scope 自引用函数上触发 lazy cycle                                  | `match/pattern.nix`     | INV-NIX-2  |
| T25 `INV-PAT-1 via invPat1` | 同 T16 根因（invPat1 内部调用 patternVars）                                               | `match/pattern.nix`     | INV-NIX-2  |
| T25 所有 INV-EFF-11 测试    | `mkHandlerWithCont` 未设置 `contDomainOk`；`checkHandlerContWellFormed` 缺少 `inv_eff_11` | `effect/handlers.nix`   | INV-EFF-11 |
| topologicalSort 类型不一致  | 成功路径返回 list，失败路径返回 attrset                                                   | `incremental/graph.nix` | INV-TOPO   |
| BUG-T9: solve 参数顺序      | `ts.solve ts.emptyDB [] []` → emptyDB 当成 constraints list                               | `tests/test_all.nix`    | INV-TEST   |

**当前测试结果：`203/203 passed`**

---

## Phase 4.5 / 4.5.1 主要特性

| 特性                                 | 描述                                                                                    | INV         |
| ------------------------------------ | --------------------------------------------------------------------------------------- | ----------- |
| **INV-BIDIR-3: App Result Solved** ★ | `_inferApp` 在函数类型已知时直接使用 codomain，无需额外约束求解                         | INV-BIDIR-3 |
| **INV-KIND-3: Fixpoint Solver** ★    | `solveKindConstraintsFixpoint` 有界迭代（max 10）收敛所有 KVar                          | INV-KIND-3  |
| **INV-PAT-3: Nested Record** ★       | `patternVars` Record 分支递归进入子模式；`compileMatch` 同步生成字段访问绑定            | INV-PAT-3   |
| **INV-EFF-11: Cont Domain Check**    | `mkHandlerWithCont` 嵌入 `contDomainOk`；`checkHandlerContWellFormed` 返回 `inv_eff_11` | INV-EFF-11  |

---

## 特性概览

| 特性                  | 状态 | 说明                                                       |
| --------------------- | ---- | ---------------------------------------------------------- |
| TypeIR 统一宇宙       | ✅   | `Type = { tag; id; kind; repr; meta }`                     |
| TRS 规则集（11 规则） | ✅   | β-reduction, row canonical, constraint merge…              |
| Kind 系统             | ✅   | KStar/KArrow/KRow/KEffect/KVar + unifyKind                 |
| Kind Inference        | ✅   | inferKind + solveKindConstraints (INV-KIND-1/2)            |
| Kind Fixpoint         | ✅ ★ | solveKindConstraintsFixpoint bounded 10 iters (INV-KIND-3) |
| 约束 IR（INV-6）      | ✅   | Equality/Class/Row/Refined/Scheme/Kind                     |
| Constraint Solver     | ✅   | Worklist + fuel-bounded                                    |
| UnifiedSubst          | ✅   | type+row+kind compose law (INV-US1~5)                      |
| Robinson Unification  | ✅   | occurs check + Mu bisim up-to congruence (INV-MU-1)        |
| Row Polymorphism      | ✅   | RowExtend + VariantRow + open tail                         |
| ADT + Pattern         | ✅   | Decision Tree O(1) ordinal dispatch                        |
| Nested Record Pattern | ✅ ★ | patternVars 递归子模式 (INV-PAT-3)                         |
| Mu equi-recursive     | ✅   | coinductive bisimulation (INV-MU-1)                        |
| TypeScheme（∀）       | ✅   | HM let-generalization (INV-SCHEME-1)                       |
| Bidirectional check   | ✅   | infer/check + annotated lambda (INV-BIDIR-1/2)             |
| Bidir App Result      | ✅ ★ | App result solved when fn type known (INV-BIDIR-3)         |
| Refined Types         | ✅   | `{ x: T \| φ(x) }` + SMT oracle                            |
| Module Functors       | ✅   | λM.f1(f2(M)) semantics (INV-MOD-8)                         |
| Effect Handlers       | ✅   | deep/shallow + continuations + domain check (INV-EFF-11)   |
| Incremental Engine    | ✅   | Salsa-style Memo + BFS invalidation (INV-G1~4)             |
| Gradual Types prep    | ✅   | rDynamic repr (Phase 5.0 planned)                          |

---

## 快速开始

```bash
# 运行完整测试套件（预期: 203/203 passed）
nix run .#test

# 检查核心不变量
nix run .#check-invariants

# 运行综合示例（8 end-to-end scenarios）
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

  # Kind fixpoint solver (INV-KIND-3)
  kcs = [ { typeVar = "a"; expectedKind = ts.KStar; } ];
  kindOk = ts.checkKindAnnotationFixpoint kcs;
  # kindOk = true

  # Nested Record pattern (INV-PAT-3)
  inner = ts.mkPRecord { c = ts.mkPVar "y"; };
  outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
  vars  = ts.patternVars outer;
  # vars = ["x", "y"]  ← recurses into sub-patterns

  # App result type solved directly (INV-BIDIR-3)
  fn  = ts.eLamA "x" tInt (ts.eVar "x");
  arg = ts.eLit 42;
  r   = ts.infer {} (ts.eApp fn arg);
  # r.type = tInt   (not a fresh unification variable)
  # r.resultSolved = true

  # Handler with continuation domain check (INV-EFF-11)
  contTy  = ts.mkTypeDefault (ts.rFn tInt tBool) ts.KStar;
  handler = ts.mkHandlerWithCont "State" tInt contTy tBool;
  # handler.repr.contDomainOk = true
  wf = ts.checkHandlerContWellFormed handler;
  # wf.inv_eff_11 = true; wf.contDomain = tInt

in { inherit tFn vars r handler wf; }
```

---

## 不变量系统

| 不变量        | 描述                                                      | 引入  |
| ------------- | --------------------------------------------------------- | ----- |
| INV-1         | 所有结构 ∈ TypeIR                                         | 4.0   |
| INV-2         | 所有计算 = Rewrite(TypeIR)（TRS, fuel 终止）              | 4.0   |
| INV-3         | 所有比较 = NormalForm Equality                            | 4.0   |
| INV-4         | 所有缓存 key = Hash(serialize(NF))                        | 4.0   |
| INV-5         | 所有依赖追踪 = Graph Edge                                 | 4.0   |
| INV-6         | Constraint ∈ TypeRepr（非函数值）                         | 4.0   |
| INV-US1~5     | UnifiedSubst compose law                                  | 4.1   |
| INV-SOL1~5    | Solver worklist correctness                               | 4.1   |
| INV-G1~4      | Incremental graph BFS propagation                         | 4.1   |
| INV-SCHEME-1  | let-generalization respects Ctx FVs                       | 4.2   |
| INV-BIDIR-1   | infer/check sound w.r.t. normalize                        | 4.2   |
| INV-MOD-1~8   | Module system invariants                                  | 4.2   |
| INV-MU-1      | Mu bisimulation up-to congruence sound                    | 4.3   |
| INV-EFF-4~10  | Effect handler invariants                                 | 4.3   |
| INV-KIND-1    | Inferred kinds consistent with annotations                | 4.3   |
| INV-SER-1     | builtins.toJSON never receives Type/function values       | 4.3   |
| INV-NIX-1     | `or` never inside `${}` string interpolation              | 4.3   |
| INV-LET-1     | let bindings never shadow function parameters             | 4.3   |
| INV-I1-key    | instanceKey uses pure string concat, not toJSON           | 4.3   |
| INV-BIDIR-2   | infer(eLamA p ty b) = (ty → bodyTy)                       | 4.4   |
| INV-EFF-11    | contType.from == paramType in mkHandlerWithCont           | 4.4   |
| INV-KIND-2    | Kind annotation propagation consistent with inference     | 4.4   |
| INV-PAT-1     | patternVars captures all Var bindings                     | 4.4   |
| INV-PAT-2     | isLinear(p) ↔ no duplicate in patternVars(p)              | 4.4   |
| INV-BIDIR-3 ★ | App result solved when fn type is concrete                | 4.5   |
| INV-KIND-3 ★  | Kind fixpoint convergence (bounded at 10 iters)           | 4.5   |
| INV-PAT-3 ★   | patternVars(Record{…}) = ⋃ patternVars(subPats)           | 4.5   |
| INV-NIX-2     | patternVars uses builtins.concatLists (not lib.concatMap) | 4.5.2 |
| INV-TOPO      | topologicalSort returns `{ ok; order; error }` always     | 4.5.2 |
| INV-TEST-1~5  | Test isolation, defensive attrset checks                  | 4.3~  |

---

## 模块结构

```
nix-types/
├── core/
│   ├── kind.nix          # Kind + inferKind + fixpoint solver (INV-KIND-3)
│   ├── type.nix          # TypeIR + mkScheme + _mkId via serializeRepr
│   └── meta.nix          # MetaType + bisimMeta
├── repr/
│   └── all.nix           # TypeRepr 26+ variants (rDynamic, rHole…)
├── normalize/
│   ├── rewrite.nix       # TRS main engine (fuel-based, INV-2)
│   ├── rules.nix         # 11 TRS rewrite rules
│   ├── substitute.nix    # capture-safe simultaneous substitution
│   └── unified_subst.nix # UnifiedSubst (type+row+kind, INV-US1~5)
├── constraint/
│   ├── ir.nix            # Constraint IR
│   ├── unify.nix         # Robinson + Mu bisim (INV-MU-1)
│   ├── unify_row.nix     # Row unification
│   └── solver.nix        # Worklist solver
├── meta/
│   ├── serialize.nix     # de Bruijn canonical serialization (INV-SER-1)
│   ├── hash.nix          # canonical hash (INV-4)
│   └── equality.nix      # typeEq via NF-hash
├── runtime/
│   └── instance.nix      # Instance DB + global coherence (INV-I1-key)
├── module/
│   └── system.nix        # Sig/Struct/ModFunctor (INV-MOD-1~8)
├── refined/
│   └── types.nix         # Refined Types + SMT oracle
├── effect/
│   └── handlers.nix      # Effect Handlers + continuations + INV-EFF-11
├── bidir/
│   └── check.nix         # Bidirectional + HM let-gen + INV-BIDIR-3
├── match/
│   └── pattern.nix       # Pattern IR + Decision Tree + INV-PAT-1~3
├── incremental/
│   ├── graph.nix         # Dependency graph (BFS, INV-TOPO)
│   ├── memo.nix          # Memo layer (epoch-based)
│   └── query.nix         # QueryDB (Salsa-style)
├── lib/
│   └── default.nix       # 280+ exports (Layer 0~22 topological order)
├── tests/
│   └── test_all.nix      # 203 tests, 28 groups
└── examples/
    └── demo.nix          # 8 end-to-end scenarios
```

---

## 设计原则

**依赖倒置**：每个模块通过 `{ lib, ...Libs }` 参数接收依赖，无隐式 import。

**层级化**：Layer 0~22 严格拓扑顺序，0 层无依赖，每层只依赖低层。

**不变量驱动**：所有架构决策锚定到具名 INV——违反即 soundness bug，不接受"实现方便"作为理由。

**增量模式**：Salsa-style QueryDB + Memo，BFS 失效传播（INV-G1~4）。

**数据驱动**：Constraint ∈ TypeRepr（INV-6），solver 仅操作 IR 数据，不持有函数引用。

**序列化架构**：`builtins.toJSON` 仅用于纯 JSON 安全数据；所有 Type/Kind/Constraint 走专用序列化路径（INV-SER-1）。

**Nix 惯用规则**：

- `or` 不在 `${}` 插值内（INV-NIX-1）
- `let` 绑定不 shadow 函数参数（INV-LET-1）
- 自引用 rec 函数用 `builtins.map`/`builtins.concatLists`，不用 `lib.concatMap`（INV-NIX-2）

**可扩展性**：新 TypeRepr 变体只需在以下三处添加：

1. `repr/all.nix` — 构造器
2. `meta/serialize.nix` — 序列化规则
3. `normalize/rules.nix` — TRS 归约规则

---

## 版本历史

| 版本  | 核心变更                                                                      |
| ----- | ----------------------------------------------------------------------------- |
| 4.5.2 | INV-NIX-2 (patternVars builtins.concatLists); INV-TOPO; INV-EFF-11 完整实现   |
| 4.5.1 | INV-BIDIR-3 App result solved; INV-KIND-3 fixpoint; INV-PAT-3 nested Record   |
| 4.5.0 | Phase 4.5 baseline                                                            |
| 4.4.0 | INV-BIDIR-2 annotated lambda; INV-EFF-11 cont domain; INV-KIND-2; INV-PAT-1/2 |
| 4.3.0 | Kind inference; Mu bisim up-to congruence; Handler cont; INV-SER-1            |
| 4.2.0 | TypeScheme/HM; Functor λM.f1(f2(M)); Global coherence                         |
| 4.1.0 | UnifiedSubst; RISK-A~F 全修复; de Bruijn serialize                            |
| 4.0.0 | Constraint IR 化; rowVar solver 注入                                          |

---

## Phase 5.0 规划

```
INV-GRAD-1: Dynamic consistent with all types
INV-GRAD-2: cast insertion explicit at Dynamic boundaries
INV-HM-1:   infer yields principal type
INV-HM-2:   generalize respects free variables in Ctx
```

- **Gradual Types**：`rDynamic`（已在 repr 中）+ consistency relation + cast insertion
- **Full HM Inference**：constraint solving loop integrated with type inference
- **Decision Tree sharing**：prefix sharing for large ADTs
- **SMT bridge**：real SMTLIB2 backend (currently oracle stub)
