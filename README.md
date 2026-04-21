# nix-types — Phase 4.1

**Pure Nix 原生类型系统** — 高效、现代、类 Rust 强表达能力的类型系统框架

```
版本: 4.1.0 | 语言: 纯 Nix | 哲学: Rust 编译器增量管道 + 形式化不变量
```

---

## 快速开始

```nix
# flake.nix
{
  inputs.nix-types.url = "github:yourorg/nix-types";

  outputs = { self, nix-types, ... }:
    let
      ts = nix-types.lib.${system};
    in {
      # 使用类型系统
    };
}
```

```nix
# 直接 import
let ts = import ./lib/default.nix { inherit lib; }; in

let tInt = ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar;
    tBool = ts.mkTypeDefault (ts.rPrimitive "Bool") ts.KStar;

    # 约束求解
    result = ts.solveSimple [
      (ts.mkEqConstraint tInt tInt)
      (ts.mkClassConstraint "Eq" [ tInt ])
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

---

## 架构（Phase 4.1）

```
┌─────────────────────────────────────────────────────────────────────┐
│                     TypeIR（统一宇宙）                               │
│  Type = { tag; id; kind; repr; meta }                               │
│  Kind = KStar|KArrow|KRow|KEffect|KVar|KUnbound                    │
│  Meta = { eqStrategy; muPolicy; rowPolicy; bidirPolicy; ... }      │
└──────────────┬──────────────┬──────────────┬──────────────┬─────────┘
               │              │              │              │
        TypeRepr         Normalize      Constraint      Meta Layer
        (25+ 变体)      (TRS rules)    IR (INV-6)    (hash/eq/serial)
               │              │              │
        ┌──────▼──────────────▼──────────────▼──────────────────────┐
        │                 UnifiedSubst (Phase 4.0)                   │
        │   { typeBindings:"t:"; rowBindings:"r:"; kindBindings:"k:" }│
        └──────────────────────────────────────────────────────────┘
               │
    ┌──────────┼──────────────────────────────────────────────┐
    │          │              │              │                 │
 Refined   Module         Effect         QueryDB           Solver
 Types     System        Handlers       (Salsa)          (Unified)
 P4.0+P4.1 INV-MOD-1~7  INV-EFF-4~9   INV-QK1~5       INV-SOL1~5
```

### TypeRepr 变体全集（25+）

| 变体                     | 语义                        | Phase   |
| ------------------------ | --------------------------- | ------- |
| `Primitive`              | 原子类型（Int/Bool/String） | 1.0     |
| `Var` / `VarK`           | 类型变量（带 scope + kind） | 1.0     |
| `Lambda` / `LambdaK`     | 类型级 λ（表达力闭合）      | 1.0     |
| `Apply`                  | 类型级应用（计算核心）      | 1.0     |
| `Constructor`            | 泛型 ADT 构造器             | 1.0     |
| `Fn`                     | 函数类型                    | 1.0     |
| `ADT`                    | 代数数据类型                | 1.0     |
| `Constrained`            | 约束内嵌（**INV-6**）       | 1.0     |
| `Mu`                     | 等递归类型                  | 2.0     |
| `Record`                 | 记录类型                    | 3.0     |
| `RowExtend/Empty/Var`    | 行多态                      | 3.0     |
| `VariantRow`             | 变体行（Effect 基础）       | 3.2     |
| `Pi` / `Sigma`           | 依赖类型                    | 3.3     |
| `Effect` / `EffectMerge` | 效果类型                    | 3.3     |
| `Opaque` / `Ascribe`     | 封装 / 类型标注             | 3.3     |
| `Refined`                | 精化类型 `{n:T\|φ(n)}`      | **4.0** |
| `Sig` / `Struct`         | 模块签名 / 实现             | **4.0** |
| `ModFunctor`             | 参数化模块                  | **4.0** |
| `Handler`                | Effect Handler              | **4.0** |

---

## Phase 4.1 核心改进

### 修复的关键 Bug

| Risk   | 问题                                                     | 修复                                                 | 影响 INV        |
| ------ | -------------------------------------------------------- | ---------------------------------------------------- | --------------- |
| RISK-A | `canDischarge` 接受 `impl=null` 的 superclass resolution | 验证 `impl != null`                                  | soundness       |
| RISK-B | `instanceKey` 使用 `toJSON+md5`（α-等价类型不同 key）    | NF-hash（`typeHash`）                                | INV-4 coherence |
| RISK-C | worklist solver 无真正 requeue（one-pass 退化）          | `applySubstToConstraints` 写回 worklist              | INV-SOL5        |
| RISK-D | `memoLib` + `queryLib` 双缓存无同步协议                  | `cacheNormalize` / `bumpEpochDB` 统一入口            | 一致性          |
| RISK-E | `applyFunctor` 直接替换 param 导致 scope 错误            | qualified naming (`param_field`)                     | INV-MOD-5       |
| INV-G1 | `topologicalSort` in-degree 方向错误                     | 使用 `edges` 计算 in-degree，`revEdges` 做 decrement | 正确性          |

### 新增能力

```nix
# INV-SMT-5: Refined subtype 自动化（用户提供 SMT oracle）
checkRefinedSubtype sub sup (_: "unsat")
# → { ok = true; witness = "SMT: unsat"; }

# INV-MOD-6: Functor 组合
composeFunctors f1 f2  # → ModFunctor(F∘G)

# INV-MOD-7: Instance merge with coherence check
mergeLocalInstances globalDB localDB

# INV-EFF-8/9: Deep/Shallow handlers
mkDeepHandler "E" branches returnType    # deep.flag = true
mkShallowHandler "E" branches returnType # shallow.flag = true

# INV-QK-SCHEMA: QueryKey validation
validateQueryKey "norm:abc"   # true
validateQueryKey "unknown:x"  # false

# INV-G2: clean-stale state
markStale graph nodeId  # clean-valid → clean-stale
```

---

## 文件结构

```
nix-types/
├── core/
│   ├── kind.nix         # Kind 系统（KStar/KArrow/KRow/KEffect/KVar）
│   ├── meta.nix         # MetaType 语义控制层
│   └── type.nix         # 统一 Type 结构（三位一体）
├── repr/
│   └── all.nix          # TypeRepr 全变体构造器（25+）
├── normalize/
│   ├── substitute.nix   # capture-safe substitution（全变体覆盖）
│   ├── rules.nix        # TRS 规则集（合并 Phase 1~4.1，11 条规则）
│   ├── rewrite.nix      # TRS 主引擎（fuel-based 强制终止）
│   └── unified_subst.nix# UnifiedSubst（INV-US1~5 + schema validation）
├── meta/
│   ├── serialize.nix    # canonical 序列化（INV-4 前置）
│   ├── hash.nix         # NF-hash（INV-4 核心）
│   └── equality.nix     # NF-equality（INV-3）
├── constraint/
│   ├── ir.nix           # Constraint IR（INV-6，6 种变体）
│   ├── unify.nix        # Robinson 合一（含 Mu bisimulation guard）
│   ├── unify_row.nix    # Row 合一（开放行多态）
│   └── solver.nix       # 统一 Solver（合并 solver+solver_p40）
├── runtime/
│   └── instance.nix     # Instance DB（INV-I1~2，RISK-A/B 修复）
├── refined/
│   └── types.nix        # Refined Types（PredExpr IR + smtOracle）
├── module/
│   └── system.nix       # Module System（Sig/Struct/ModFunctor）
├── effect/
│   └── handlers.nix     # Effect Handlers（deep/shallow，INV-EFF-4~9）
├── bidir/
│   └── check.nix        # 双向类型推断
├── incremental/
│   ├── graph.nix        # 依赖图（INV-G1~4 全修复）
│   ├── memo.nix         # Memo 层（epoch-based）
│   └── query.nix        # QueryDB（Salsa-style，双缓存统一入口）
├── match/
│   └── pattern.nix      # Pattern Matching + Decision Tree（合并）
├── tests/
│   └── test_all.nix     # 完整测试套件（127 tests，18 组，合并所有阶段）
├── examples/
│   └── demo.nix         # 综合示例（6 个端到端场景）
├── lib/
│   └── default.nix      # 统一导出（Layer 0~22 拓扑顺序）
└── flake.nix            # Flake（lib/checks/packages/apps/overlays）
```

> **注意**：不再有 `rules_p33.nix`、`rules_p40.nix`、`solver_p40.nix`、`pattern_p33.nix`、
> `test_phase32.nix`、`test_phase40.nix`、`phase40_demo.nix` 等碎片文件。

---

## API 参考

### 类型构造

```nix
ts.mkTypeDefault repr kind       # 基本构造（defaultMeta）
ts.mkTypeWith    repr kind meta  # 完整构造
ts.rPrimitive "Int"              # Primitive repr
ts.rVar "α" "scope"             # Var repr
ts.rLambda "x" bodyType         # Lambda repr
ts.rApply fnType [argTypes]     # Apply repr
ts.rFn from to                  # Fn repr
ts.rADT variants closed         # ADT repr
ts.rConstrained base [cs]       # Constrained repr（INV-6）
ts.rMu "X" bodyType             # Mu repr（递归）
ts.rRecord { x = tInt; }        # Record repr
ts.rRefined base "n" predExpr   # Refined repr
ts.rSig { f = tInt; }           # Sig repr
ts.mkVariant "Some" [tInt] 0    # ADT Variant
```

### 类型操作

```nix
ts.normalize' t        # 规范化（1000 fuel）
ts.typeEq a b          # NF equality（INV-3）
ts.typeHash t          # canonical hash（INV-4）
ts.typeId t            # stable identity
```

### 约束系统

```nix
ts.mkEqConstraint a b            # a ≡ b
ts.mkClassConstraint "Eq" [tInt] # typeclass constraint
ts.mkRowEqConstraint r1 r2       # row equality
ts.mkRefinedConstraint t "n" φ   # refined constraint
ts.solve classGraph db [cs]      # 求解（UnifiedSubst 返回）
ts.solveSimple [cs]              # 简化入口
```

### UnifiedSubst

```nix
ts.singleTypeBinding "α" tInt    # 单条 type binding
ts.singleRowBinding "r" rowTy    # 单条 row binding
ts.composeSubst s1 s2            # 组合（INV-US1）
ts.applyUnifiedSubst subst t     # 应用
ts.fromLegacyTypeSubst { α=tInt }# 从旧格式转换
```

### Refined Types

```nix
ts.mkRefined tInt "n" (ts.mkPCmp "gt" (ts.mkPVar "n") (ts.mkPLit 0))
ts.staticEvalPred predExpr       # 静态求值
ts.smtBridge [refinedConstraints] # 生成 SMTLIB2
ts.checkRefinedSubtype sub sup smtOracle  # INV-SMT-5
```

### Module System

```nix
ts.mkSig { x = tInt; }           # 接口签名
ts.mkStruct sig impl             # 实现
ts.checkSig struct sig           # 结构检查
ts.applyFunctor functor arg      # Functor 应用（qualified）
ts.composeFunctors f1 f2         # Functor 组合
ts.mergeLocalInstances g l       # Instance 合并（coherence）
```

### Effect Handlers

```nix
ts.mkDeepHandler "E" branches rt    # deep handler
ts.mkShallowHandler "E" branches rt # shallow handler
ts.effectMerge e1 e2               # effect merge
ts.checkHandler handler effType    # 类型检查
ts.handleAll [handlers] effType    # 批量处理
ts.subtractEffect effRow label     # 移除 effect
```

### 增量缓存

```nix
# 统一写入两层缓存（RISK-D 修复）
ts.cacheNormalize db memo typeId nf deps
# → { queryDB; memo }

# 全量失效（同步两层）
ts.queryLib.bumpEpochDB { queryDB; memo }

# QueryKey schema（INV-QK-SCHEMA）
ts.queryLib.mkQueryKey "norm" ["typeId"]
ts.queryLib.validateQueryKey "norm:abc"  # → true
```

---

## 不变量索引

| 代码          | 含义                         | 实现位置                      |
| ------------- | ---------------------------- | ----------------------------- |
| INV-1         | 所有结构 ∈ TypeIR            | `core/type.nix`               |
| INV-2         | 所有计算 = Rewrite(TypeIR)   | `normalize/rewrite.nix`       |
| INV-3         | 所有比较 = NF equality       | `meta/equality.nix`           |
| INV-4         | 缓存 key = Hash(NF)          | `meta/hash.nix`               |
| INV-5         | 依赖追踪 = Graph Edge        | `incremental/graph.nix`       |
| INV-6         | Constraint ∈ TypeRepr        | `constraint/ir.nix`           |
| INV-K1        | per-parameter kind           | `core/kind.nix`               |
| INV-US1       | compose law                  | `normalize/unified_subst.nix` |
| INV-US3       | 前缀不冲突 t:/r:/k:          | `normalize/unified_subst.nix` |
| INV-SOL1      | subst equality = NF-hash     | `constraint/solver.nix`       |
| INV-SOL5      | worklist requeue             | `constraint/solver.nix`       |
| INV-SMT-5     | checkRefinedSubtype sound    | `refined/types.nix`           |
| INV-SMT-6     | trivial cases skip SMT       | `refined/types.nix`           |
| INV-MOD-4     | Sig fields 字母序            | `normalize/rules.nix`         |
| INV-MOD-6     | composeFunctors type-correct | `module/system.nix`           |
| INV-MOD-7     | mergeLocalInstances coherent | `module/system.nix`           |
| INV-EFF-8     | deep handler = handle all    | `effect/handlers.nix`         |
| INV-EFF-9     | shallow handler = first only | `effect/handlers.nix`         |
| INV-QK1       | QueryKey 确定性              | `incremental/query.nix`       |
| INV-QK2       | 精确失效 BFS                 | `incremental/query.nix`       |
| INV-QK5       | 循环检测 DFS                 | `incremental/query.nix`       |
| INV-QK-SCHEMA | key 格式验证                 | `incremental/query.nix`       |
| INV-G1        | BFS propagation 正确方向     | `incremental/graph.nix`       |
| INV-G2        | clean-stale 状态区分         | `incremental/graph.nix`       |
| INV-G4        | removeNode 无 dangling edge  | `incremental/graph.nix`       |

---

## 演化路径

```
Phase 1.0 → TypeIR 基础（Primitive/Var/Lambda/Apply/Fn/ADT/Constrained）
Phase 2.0 → Mu 递归类型 + NF-hash + Memo
Phase 3.0 → Row 多态 + Effect + Constraint Solver + Instance DB
Phase 3.3 → Pattern Matching + Bidirectional + Pi/Sigma + rowVar
Phase 4.0 → Refined Types + Module System + Effect Handlers + UnifiedSubst + QueryDB
Phase 4.1 → ★ 当前：RISK-A~E 修复 + SMT Oracle + Functor Compose + 文件合并
Phase 4.2 → Functor transitive composition + Global InstanceDB coherence
Phase 4.3 → Continuation passing + Mu bisimulation up-to congruence
Phase 5.0 → Gradual Types + HM inference + Dynamic
```
