# Nix Type System — Phase 4.0

> 纯 Nix 原生实现的强表达力类型系统  
> 类 Rust 编译器增量管道（Salsa-style QueryKey）· System Fω + Dependent Types · Bidirectional Checking  
> Equi-Recursive Bisimulation · Row Polymorphism · Algebraic Effect Handlers  
> **Phase 4.0 新增：Refined Types (SMT Bridge) · Module System · Effect Handlers · UnifiedSubst · QueryKey Incremental**

---

## 核心不变量（Phase 4.0 全部强制）

```
# Phase 3.x 继承（全部保留）
INV-1:    所有结构             ∈ TypeIR
INV-2:    所有计算             = Rewrite(TypeIR)，split-fuel bounded 终止
INV-3:    所有比较             = NormalForm Equality（单一路径）
INV-4:    所有缓存 key         = NF-hash（typeHash = nfHash ∘ normalize）
INV-5:    所有依赖追踪         = Graph Edge（BFS worklist，queueSet 去重）
INV-6:    Constraint           ∈ TypeRepr（不是函数，不是 runtime）
INV-EQ1-4, INV-K1-6, INV-H2, INV-I1-2, INV-MU, INV-ROW-2/3
INV-SOL1/4/5, INV-SPEC, INV-SER3/4, INV-EFF-2/3, INV-PAT-1/3

# Phase 4.0 新增不变量

## UnifiedSubst（INV-US*）
INV-US1:  apply(compose(σ₂,σ₁), t) = apply(σ₂, apply(σ₁, t))
INV-US2:  apply(id, t) = t
INV-US3:  键前缀严格区分（t:/r:/k:），无命名冲突
INV-US4:  compose domain 排序稳定（确定性）
INV-US5:  applyToConstraint = applyToType ∘ traverse（compose law）

## Refined Types / SMT（INV-SMT*）
INV-SMT-1: Refined ∈ TypeRepr（INV-6 强化）
INV-SMT-2: smtBridge 无副作用（nix string only，不带 IO）
INV-SMT-3: solver residual = SMT obligations（不静默 OK）
INV-SMT-4: predExpr 序列化确定性（用于 hash/equality）

## Module System（INV-MOD*）
INV-MOD-1: Sig checking = structural subtyping on field kinds
INV-MOD-2: Functor application 生成局部 InstanceDB（不污染全局）
INV-MOD-3: Module sealing = rOpaque（nominal typing 强制）
INV-MOD-4: Sig fields = sorted attrNames（canonical form）
INV-MOD-5: Struct impl ⊇ Sig fields（completeness）

## Effect Handlers（INV-EFF-4~7）
INV-EFF-4: handle 后 effect row 中 E 被移除（soundness）
INV-EFF-5: 残余 effect = original - handled（精确 subtract）
INV-EFF-6: open effect row（RowVar）在 subtract 后保留 tail
INV-EFF-7: Handler 操作名不重复（coherence）

## QueryKey Incremental（INV-QK*）
INV-QK1:  QueryKey = tag ":" serialize(inputs)（确定性）
INV-QK2:  失效传播 = 仅失效 deps 中包含 dirtyKey 的查询
INV-QK3:  recompute 后 deps 精确更新（非保守）
INV-QK4:  epoch = 全局单调递增（不回绕）
INV-QK5:  circular deps 检测（DFS）

## Solver P4.0（INV-SOL-P40*）
INV-SOL-P40-1: rowVar binding 通过 UnifiedSubst 统一应用到 constraints
INV-SOL-P40-2: Refined residual 正确收集（smtResidual 字段）
INV-SOL-P40-3: RowEquality → unifyRow → 注入 UnifiedSubst pipeline
```

---

## Phase 4.0 新功能摘要

| 编号    | 功能                                                      | 模块                               | INV                      | 状态 |
| ------- | --------------------------------------------------------- | ---------------------------------- | ------------------------ | ---- |
| P4.0-1  | UnifiedSubst（type+row+kind 统一替换）                   | `normalize/unified_subst.nix`      | INV-US1~5                | ✅   |
| P4.0-2  | Refined Types / PredExpr IR / SMT Bridge                  | `refined/types.nix`                | INV-SMT-1~4              | ✅   |
| P4.0-3  | Module System（Sig/Struct/ModFunctor/sealing）             | `module/system.nix`                | INV-MOD-1~5              | ✅   |
| P4.0-4  | Effect Handlers（algebraic effects dispatch）             | `effect/handlers.nix`              | INV-EFF-4~7              | ✅   |
| P4.0-5  | rules_p40（EffectMerge open row + Refined + Sig norm）    | `normalize/rules_p40.nix`          | INV-EFF-6, INV-MOD-4     | ✅   |
| P4.0-6  | solver_p40（UnifiedSubst + RowEquality + SMT residual）   | `constraint/solver_p40.nix`        | INV-SOL-P40-1~3          | ✅   |
| P4.0-7  | QueryKey DB（Salsa-style 细粒度失效）                    | `incremental/query.nix`            | INV-QK1~5                | ✅   |
| P4.0-8  | lib/default.nix 升级（Phase 4.0 export + p40 namespace） | `lib/default.nix`                  | —                        | ✅   |
| P4.0-9  | 遗留风险 1 修复（rowVar subst 注入 solver pipeline）      | `constraint/solver_p40.nix`        | INV-SOL-P40-1            | ✅   |
| P4.0-10 | 遗留风险 2 修复（EffectMerge 支持 RowVar tail）           | `normalize/rules_p40.nix`          | INV-EFF-6                | ✅   |

---

## 模块文件结构（Phase 4.0）

```
/core
  kind.nix              # Kind 系统（KStar/KArrow/KRow/KEffect/KVar）
  meta.nix              # MetaType 语义控制
  type.nix              # TypeIR 统一结构（Type/Kind/Meta 三位一体）

/repr
  all.nix               # TypeRepr 全变体集（含 Phase 4.0: Refined/Sig/Struct/ModFunctor/Handler）

/normalize
  substitute.nix        # capture-safe 替换（alpha-rename + de Bruijn）
  unified_subst.nix     # UnifiedSubst（type+row+kind 统一，INV-US1~5）← NEW 4.0
  rules.nix             # TRS 规则集 Phase 3.2 base
  rules_p33.nix         # TRS 规则集 Phase 3.3
  rules_p40.nix         # TRS 规则集 Phase 4.0（EffectMerge open + Refined + Sig）← NEW 4.0
  rewrite.nix           # TRS 主引擎（innermost closure，all rules merged）

/constraint
  ir.nix                # Constraint IR（canonical pipeline，O(n) dedup）
  unify.nix             # Robinson + bisimulation Mu
  unify_row.nix         # Row Unification（Wand/Rémy style）
  solver.nix            # Phase 3.3 Solver（保留用于兼容）
  solver_p40.nix        # Phase 4.0 Solver（UnifiedSubst + RowEquality + SMT）← NEW 4.0

/refined                # ← NEW 4.0
  types.nix             # Refined Types（PredExpr IR, SMT Bridge, static eval）

/module                 # ← NEW 4.0
  system.nix            # Module System（Sig/Struct/ModFunctor，checkSig，applyFunctor）

/effect                 # ← NEW 4.0
  handlers.nix          # Effect Handlers（checkHandler，handleAll，subtractEffect）

/runtime
  instance.nix          # Instance DB（specificity + partial unification overlap）

/meta
  serialize.nix         # α-canonical 序列化 v3（de Bruijn，无 toJSON）
  hash.nix              # Canonical hash（单路径 INV-H2）
  equality.nix          # 统一等价核（INV-EQ1-4，Coherence Law）

/incremental
  graph.nix             # 依赖图（Kahn 修正，queueSet BFS，stale，errorMeta）
  memo.nix              # Memo 层（epoch-based，Phase 3.3 兼容）
  query.nix             # QueryKey DB（Salsa-style，细粒度失效）← NEW 4.0

/match
  pattern.nix           # Pattern IR base
  pattern_p33.nix       # Pattern IR Phase 3.3（Lit/Record/Guard/As/Tuple/Or）

/bidir
  check.nix             # Bidirectional Type Checking

/lib
  default.nix           # 统一入口（Phase 4.0：完整 API + p40 namespace）

/tests
  test_all.nix          # 综合测试（T1-T16，Phase 3.3）
  test_phase40.nix      # Phase 4.0 专项测试（T17-T21）← NEW 4.0

/examples
  phase3_demo.nix       # Phase 3 特性演示
  phase33_demo.nix      # Phase 3.3 特性演示
  phase40_demo.nix      # Phase 4.0 全特性演示← NEW 4.0

flake.nix               # Flake：lib export + meta + checks
```

---

## 快速上手（Phase 4.0）

```nix
let ts = import ./lib/default.nix { lib = pkgs.lib; }; in

# 1. Refined Types
let
  tPosInt = ts.mkPosInt {};  # { n : Int | n > 0 }
  tByte   = ts.mkBoundedInt 0 255;

  # SMT Bridge（纯 string）
  rc  = ts.mkRefinedConstraint tPosInt "n" (ts.PGt (ts.PVar "n") (ts.PLit 0));
  smt = ts.smtBridge [rc];
  # → SMTLIB2 string to pass to z3/cvc5
in {}

# 2. Module System
let
  sig    = ts.mkSig { T = ts.KStar; eq = ts.KArrow ts.KStar ts.KStar; };
  struct = ts.mkStruct sig { T = tInt; eq = tIntEq; };
  check  = ts.checkSig sig struct;  # { ok = true }

  sealed = ts.sealModule struct sig;  # Opaque → nominal typing
in {}

# 3. Effect Handlers
let
  allEff = ts.mergeEffects (ts.mkEffType { State = tInt; }) (ts.mkEffType { IO = tUnit; });
  handler = ts.mkHandler "State"
    [(ts.rHandlerBranch "get" [] "resume" tInt)]
    tUnit;
  checkResult = ts.checkHandler allEff handler;
  # { ok=true; residualEffTy = Eff[IO:Unit] }
in {}

# 4. QueryKey Incremental
let
  db    = ts.emptyQueryDB;
  key   = ts.qkNormalize "type:Int";
  db'   = ts.storeResult db key "NF:Int" [];
  hit   = ts.lookupResult db' key;  # { found=true; result.value="NF:Int" }
  # Invalidate → cascades through deps
  db''  = ts.invalidateKey db' key;
in {}
```

---

## TypeRepr 全变体集（Phase 4.0）

```
TypeRepr =
  Primitive    { name }                       # 原子类型
| Var          { name; scope }                # 类型变量
| Lambda       { param; body }                # 类型级 λ
| Apply        { fn; args }                   # 类型级应用
| Constructor  { name; kind; params; body }   # 泛型 ADT 构造器
| Fn           { from; to }                   # 函数类型
| ADT          { variants; closed }           # 代数数据类型
| Constrained  { base; constraints }          # 约束内嵌（INV-6）
| Mu           { var; body }                  # 等递归类型
| Record       { fields }                     # 记录类型
| VariantRow   { variants; extension }        # 变体行
| RowExtend    { label; fieldType; rest }     # 行扩展
| RowEmpty     {}                             # 空行
| RowVar       { name }                       # 行变量
| Pi           { param; domain; body }        # 依赖函数类型
| Sigma        { param; domain; body }        # 依赖积类型
| Effect       { effectRow }                  # 效果类型
| EffectMerge  { left; right }               # 效果合并节点
| Opaque       { inner; tag }                 # 不透明类型
| Ascribe      { expr; type }                # 类型标注
| Refined      { base; predVar; predExpr }   ← NEW 4.0
| Sig          { fields }                     ← NEW 4.0
| Struct       { sig; impl }                  ← NEW 4.0
| ModFunctor   { param; paramTy; body }       ← NEW 4.0
| Handler      { effectTag; branches; returnType } ← NEW 4.0
```

---

## Phase 演化路径

```
Phase 1.0  基础 TypeIR + Kind + Primitive TRS
Phase 2.0  Row Polymorphism + μ-types + Instance DB
Phase 3.0  Dependent Types + Effect System + Bidirectional + Constraint IR
Phase 3.1  Soundness/INV 修复（enterprise-stable）
Phase 3.2  Mu bisimulation + substLib + specificity + row canonical
Phase 3.3  Open row unification + EffectMerge + VariantRowCanon + Complete Pattern
Phase 4.0  ← 当前
           ✅ UnifiedSubst（type+row+kind 统一替换，解决遗留风险 1）
           ✅ EffectMerge open effect row（RowVar tail，解决遗留风险 2）
           ✅ Refined Types（Liquid Types，PredExpr IR，SMT bridge，static eval）
           ✅ Module System（Sig/Struct/ModFunctor，checkSig，sealing，subtyping）
           ✅ Effect Handlers（algebraic effects，checkHandler，handleAll）
           ✅ QueryKey Incremental（Salsa-style，细粒度 BFS 失效，cycle detection）
           ✅ solver_p40（RowEquality constraint，rowVar subst 注入，SMT residual）
Phase 4.1  → Refined subtype automation（implication oracle）
Phase 4.2  → Module Functor composition（transitive functor application）
Phase 4.3  → Effect Handler continuations（delimited control）
Phase 5.0  → Gradual Types + Type Inference（HM + constraint solving unified）
```

---

## 关键设计决策（ADR Phase 4.0）

| ADR     | 决策                                      | 原因                                                    |
| ------- | ----------------------------------------- | ------------------------------------------------------- |
| ADR-14  | UnifiedSubst 三键前缀（t:/r:/k:）         | 防止 type/row/kind 变量名命名冲突（INV-US3）            |
| ADR-15  | PredExpr 作为独立 IR（非 Nix function）   | 满足 INV-6：Constraint ∈ TypeRepr；支持 serialize/hash  |
| ADR-16  | smtBridge = pure String（无 builtins.exec）| 纯 Nix 环境无法执行外部 SMT solver；string 传递给用户   |
| ADR-17  | Sig fields sorted（INV-MOD-4）            | canonical form = 确定性 hash；字段顺序不影响语义        |
| ADR-18  | Functor application 返回 localInstances   | INV-MOD-2：Functor 应用不污染全局 InstanceDB            |
| ADR-19  | QueryKey = tag + inputs（非 UUID）         | INV-QK1：相同输入相同 key；内容可寻址，无随机性         |
| ADR-20  | BFS invalidation（非 epoch bump）         | INV-QK2：精确失效；epoch bump = 全量失效（退化模式）    |
| ADR-21  | RowEquality constraint（新 tag）          | 将 row unification 结果变成 solver 可处理的 constraint  |
| ADR-22  | EffectMerge flatten 保留 RowVar tail      | INV-EFF-6：open effect row 必须保留以支持 polymorphism  |
| ADR-23  | Refined static eval 在 solver 内          | trivial predicates（PTrue/PFalse）不需要 SMT           |
