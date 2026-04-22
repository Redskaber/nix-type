# nix-types — Phase 4.2

**Pure Nix 原生类型系统** — 高效、现代、类 Rust 强表达能力

```
版本: 4.2.0 | 语言: 纯 Nix | 哲学: Rust 编译器增量管道 + 形式化不变量
```

---

## 快速开始

```nix
# flake.nix
{
  inputs.nix-types.url = "github:redskaber/nix-type";
  outputs = { self, nix-types, nixpkgs, ... }:
    let ts = nix-types.lib.${system}; in { ... };
}
```

```nix
# 直接 import
let ts = import ./lib/default.nix { inherit lib; }; in

# 基本类型
let tInt  = ts.tInt;
    tBool = ts.tBool;

# Phase 4.2: HM let-generalization
    idScheme = ts.generalize {}
      (ts.mkTypeDefault (ts.rVar "α" "") ts.KStar) [];

# Phase 4.2: Functor transitive composition  λM.f1(f2(M))
    composed = ts.composeFunctors f1 f2;

# Constraint solving
    result = ts.solveSimple [
      (ts.mkEqConstraint tInt tInt)
      (ts.mkClassConstraint "Eq" [tInt])
    ];
in result.ok  # → true
```

---

## 核心不变量

```
INV-1: 所有结构       ∈ TypeIR
INV-2: 所有计算       = Rewrite(TypeIR)      ← TRS，fuel 保证终止
INV-3: 所有比较       = NormalForm Equality
INV-4: 所有缓存 key   = Hash(serialize(NF))
INV-5: 所有依赖追踪   = Graph Edge
INV-6: Constraint     ∈ TypeRepr（不是函数）
```

### Phase 4.2 新增不变量

```
INV-MOD-8:   composeFunctors type-correct（true λM.f1(f2(M)) semantics）
INV-BIDIR-1: infer/check sound w.r.t. normalize
INV-SCHEME-1: generalize respects free variables in Ctx
INV-COH-1:   Global InstanceDB coherence（no overlap）
```

---

## 架构（Phase 4.2）

```
┌──────────────────────────────────────────────────────────────────┐
│                     TypeIR（统一宇宙）                            │
│  Type = { tag; id; kind; repr; meta }                            │
│  Kind = KStar|KArrow|KRow|KEffect|KVar★|KUnbound                │
│  Meta = { eqStrategy; muPolicy; rowPolicy; schemePolicy★; ... } │
└───────┬───────────┬────────────┬──────────────┬─────────────────┘
        │           │            │              │
   TypeRepr    Normalize    Constraint      Meta Layer
  (25+ 变体)  (TRS 11规则)  IR (INV-6)    hash/eq/serial
  rForall★      rules       solver        alpha-NF de Bruijn★
  rHole★       rewrite      unify
  rDynamic★   unified_subst unify_row
        │
   ┌────▼─────────────────────────────────────────────────────┐
   │              Phase 4.2 核心新增                           │
   │  TypeScheme  { __schemeTag; forall★; body; constraints } │
   │  mkScheme / monoScheme / generalize★ (HM let-gen)        │
   │  instantiateScheme (fresh vars per call-site)            │
   └────┬──────────────────┬───────────────┬──────────────────┘
        │                  │               │
   Module★            Bidir★          InstanceDB★
   composeFunctors    infer/check     checkGlobalCoherence
   λM.f1(f2(M))      let-gen         mergeLocalInstances(unify)
   composeFunctorChain eVar/eLam/eApp  partial-unify overlap
```

---

## 文件结构

```
nix-types/
├── core/
│   ├── kind.nix         # Kind 系统（KVar★ + unifyKind★）
│   ├── meta.nix         # MetaType（schemeMeta★）
│   └── type.nix         # TypeIR（mkScheme★/monoScheme★/freeVars★）
├── repr/
│   └── all.nix          # TypeRepr 25+ 变体（rForall★/rHole★/rDynamic★）
├── normalize/
│   ├── substitute.nix   # capture-safe substitution
│   ├── rules.nix        # TRS 11 规则合并版
│   ├── rewrite.nix      # fuel-based TRS 引擎
│   └── unified_subst.nix # type+row+kind 统一替换（INV-US1~5）
├── meta/
│   ├── serialize.nix    # canonical（de Bruijn alpha-NF★）
│   ├── hash.nix         # typeHash/schemeHash★/substHash★
│   └── equality.nix     # NF equality（INV-3）
├── constraint/
│   ├── ir.nix           # Constraint IR（mkSchemeConstraint★/mkKindConstraint★）
│   ├── unify.nix        # Robinson unification + Mu bisimulation
│   ├── unify_row.nix    # Row polymorphism unification
│   └── solver.nix       # Worklist solver（INV-SOL5 requeue）
├── runtime/
│   └── instance.nix     # Instance DB（NF-hash key + global coherence★）
├── module/
│   └── system.nix       # Module System（composeFunctors★ λM.f1(f2(M))）
├── refined/
│   └── types.nix        # Refined Types（PredExpr IR + smtOracle）
├── effect/
│   └── handlers.nix     # Effect Handlers（deep/shallow）
├── bidir/
│   └── check.nix        # Bidir + HM let-generalization★
├── incremental/
│   ├── graph.nix        # 依赖图（INV-G1~4）
│   ├── memo.nix         # Memo 层（epoch-based）
│   └── query.nix        # QueryDB（Salsa-style，RISK-D 修复）
├── match/
│   └── pattern.nix      # Pattern Matching + Decision Tree
├── tests/
│   └── test_all.nix     # 完整测试套件（150+ tests，20 组）
├── examples/
│   └── demo.nix         # 综合示例（6 个端到端场景）
├── lib/
│   └── default.nix      # 统一导出（240 exports，Layer 0~22）
└── flake.nix            # Flake（lib/checks/packages/apps/overlays）
```

> ★ = Phase 4.2 新增  
> 无碎片文件（无 `_p33`, `_p40`, `_phase42` 后缀）

---

## API 参考

### 类型构造

```nix
ts.mkTypeDefault repr kind       # 基本构造（defaultMeta）
ts.mkTypeWith    repr kind meta  # 完整构造
ts.tInt / ts.tBool / ts.tString  # 内建原始类型
ts.tPrim "Char"                  # 任意原始类型

ts.rPrimitive "Int"              # Primitive repr
ts.rVar "α" "scope"             # Var repr（有作用域）
ts.rLambda "x" bodyType         # Lambda repr
ts.rApply fnType [argTypes]     # Apply repr
ts.rFn from to                  # Fn repr
ts.rADT variants closed         # ADT repr
ts.rConstrained base [cs]       # Constrained repr（INV-6）
ts.rMu "X" bodyType             # Mu repr（递归）
ts.rRecord { x = tInt; }        # Record repr
ts.rRefined base "n" predExpr   # Refined repr
ts.rSig { f = tInt; }           # Sig repr
ts.rForall ["α" "β"] body       # ★ Forall repr（高阶多态）
ts.rHole "h1"                   # ★ Hole repr（bidir inference）
ts.rDynamic                     # ★ Dynamic repr（gradual types, Phase 5)
```

### TypeScheme（Phase 4.2 新增）

```nix
ts.mkScheme ["α"] body []      # ∀α. body（with constraints）
ts.monoScheme tInt             # 单态 scheme（forall []）
ts.isScheme s                  # scheme 谓词
ts.schemeBody s                # 提取 body
ts.schemeForall s              # 提取 forall 变量列表
ts.generalize ctx ty []        # HM let-generalization（INV-SCHEME-1）
```

### 类型操作

```nix
ts.normalize' t               # 规范化（fuel=1000）
ts.normalizeDeep t            # 深度规范化（fuel=3000）
ts.normalizeWithFuel 500 t    # 自定义 fuel
ts.typeEq a b                 # NF equality（INV-3）
ts.typeHash t                 # canonical hash（INV-4）
ts.schemeHash s               # ★ scheme hash
ts.freeVars t                 # 自由变量提取
```

### 约束系统

```nix
ts.mkEqConstraint a b           # a ≡ b
ts.mkClassConstraint "Eq" [tInt] # typeclass constraint
ts.mkRowEqConstraint r1 r2       # row equality
ts.mkRefinedConstraint t "n" φ   # refined constraint
ts.mkSchemeConstraint s ty       # ★ scheme constraint（Phase 4.2）
ts.mkKindConstraint "α" KStar    # ★ kind constraint（Phase 4.2）

ts.solve classGraph db [cs]      # full solve（with instance DB）
ts.solveSimple [cs]              # simple solve（no class context）
```

### Module System（Phase 4.2）

```nix
ts.mkSig { x = tInt; }           # Sig 构造
ts.mkStruct sig impls             # Struct 构造（INV-MOD-1 验证）
ts.mkModFunctor "M" sig body      # ModFunctor 构造
ts.applyFunctor functor struct    # Functor 应用（INV-MOD-5 qualified naming）
ts.composeFunctors f1 f2          # ★ λM.f1(f2(M))（INV-MOD-8）
ts.composeFunctorChain [f1 f2 f3] # ★ 传递性 composition
ts.sigCompatible sigA sigB        # 结构子类型检查
ts.sigMerge sigA sigB             # Sig 交集/联集
```

### Bidirectional Inference（Phase 4.2）

```nix
# Expr 构造器
ts.eVar "x"                       # 变量引用
ts.eLam "x" body                  # 无注释 lambda（生成新鲜类型变量）
ts.eLamA "x" tInt body            # 带注释 lambda
ts.eApp fn arg                    # 应用（约束生成，INV-BIDIR-1）
ts.eLet "x" def body              # let 绑定（let-generalization）
ts.eAnn body ty                   # 类型标注
ts.eIf cond then_ else_           # 条件表达式
ts.eLit 42                        # 字面量

# 推断
ts.infer ctx expr                 # 推断模式 → { type; constraints; subst }
ts.check ctx expr ty              # 检查模式 → { ok; constraints; subst }
ts.generalize ctx ty []           # HM 泛化（INV-SCHEME-1）
```

### Instance DB（Phase 4.2 增强）

```nix
ts.mkInstanceRecord "Eq" [tInt] impl []  # 创建实例记录
ts.registerInstance db record            # 注册实例
ts.lookupInstance db "Eq" [tInt]         # 查找实例
ts.canDischarge resolveResult            # INV-I2: impl != null
ts.checkGlobalCoherence db unifyFn       # ★ 全局一致性检查（INV-COH-1）
ts.mergeLocalInstances global local unifyFn  # ★ 升级：partial-unify overlap
```

---

## 测试矩阵

| 组    | 内容                              | 测试数  | 覆盖 INV             |
| ----- | --------------------------------- | ------- | -------------------- |
| T1    | TypeIR 核心（INV-1）              | 7       | INV-1                |
| T2    | Kind 系统（INV-K1）               | 7       | INV-K1               |
| T3    | TypeRepr 全变体（25+）            | 14      | INV-1                |
| T4    | Serialize canonical（de Bruijn）  | 4       | INV-4 前置           |
| T5    | Normalize（INV-2/3）              | 6       | INV-2/3              |
| T6    | Hash（INV-4）                     | 5       | INV-4                |
| T7    | Constraint IR（INV-6）            | 7       | INV-6                |
| T8    | UnifiedSubst（INV-US1~5）         | 6       | INV-US1~5            |
| T9    | Solver（INV-SOL1/4/5）            | 5       | INV-SOL1~5           |
| T10   | Instance DB（INV-I1/2, RISK-A/B） | 6       | coherence            |
| T11   | Refined Types（INV-SMT-1~6）      | 8       | INV-SMT-1~6          |
| T12   | Module System（INV-MOD-1~8★）     | 8       | INV-MOD-1~8          |
| T13   | Effect Handlers（INV-EFF-4~9）    | 7       | INV-EFF-4~9          |
| T14   | QueryDB（INV-QK1~5+schema）       | 6       | INV-QK1~5            |
| T15   | Incremental Graph（INV-G1~4）     | 6       | INV-G1~4             |
| T16   | Pattern Matching                  | 7       | DT                   |
| T17   | Row 多态                          | 2       | INV-ROW              |
| T18   | Bidir + TypeScheme★               | 10      | INV-BIDIR-1,SCHEME-1 |
| T19   | Unification                       | 7       | unify                |
| T20   | 集成测试                          | 6       | all                  |
| **Σ** |                                   | **136** |                      |

---

## 演化路径

```
Phase 1.0 → TypeIR 基础
Phase 2.0 → Mu + NF-hash + Memo
Phase 3.0 → Row + Effect + Constraint Solver + Instance DB
Phase 3.3 → Pattern Matching + Bidir + Pi/Sigma + rowVar
Phase 4.0 → Refined + Module + Effect Handlers + UnifiedSubst + QueryDB
Phase 4.1 → RISK-A~F 修复 + SMT Oracle + 文件合并
Phase 4.2 → ★ 当前: TypeScheme + HM Generalization + Functor λM.f1(f2(M))
                       + Global Coherence + Kind Unification + rForall/rHole/rDynamic
Phase 4.3 → Continuation passing + Mu bisimulation up-to congruence
Phase 5.0 → Gradual Types + HM inference + Dynamic
```

---

## 不变量验证

```nix
let ts = import ./lib/default.nix { inherit lib; }; in

# INV-4: typeEq ⟹ hash-eq
ts.__checkInvariants.inv4 tInt tInt         # → true

# INV-6: Constraint ∈ TypeRepr
ts.__checkInvariants.inv6 (ts.mkEqConstraint tInt tBool)  # → true

# INV-MOD-8: Functor composition（Phase 4.2）
ts.__checkInvariants.invMod8 f1 f2          # → true（ModFunctor）

# INV-BIDIR-1（Phase 4.2）
ts.__checkInvariants.invBidir1 {} (ts.eLit 42)  # → true

# INV-SCHEME-1（Phase 4.2）
ts.__checkInvariants.invScheme1 {} tInt []  # → true
```
