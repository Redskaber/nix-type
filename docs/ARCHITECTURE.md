# nix-types Architecture — Phase 4.5.9

## 版本：4.5.9

---

## 核心设计原则

### 1. 序列化边界不变式（INV-SER-1）

> **`builtins.toJSON` 绝不直接碰触含 Type 对象、Constraint 对象、或任何持有函数引用的结构。**

所有序列化必须经由规范路径：

```
meta/serialize.nix → serializeRepr r       （TypeRepr 序列化）
meta/serialize.nix → serializeConstraint c  （Constraint 序列化）
meta/serialize.nix → serializePredExpr pe   （PredExpr 序列化）
meta/serialize.nix → serializeType t        （Type 序列化）
core/kind.nix      → serializeKind k        （Kind 序列化）
meta/hash.nix      → _safeStr v             （最后保护层：isFunction guard）
```

违规的序列化路径会导致 Nix 不可捕获的 `abort: cannot convert a function to JSON`。

### 2. Nix 语言安全规则（INV-NIX-\*）

| 不变式        | 规则                                                                                 |
| ------------- | ------------------------------------------------------------------------------------ |
| **INV-NIX-1** | `or` 不在 `${}` 字符串插值内；改用 `let val = expr; in "...${val}..."`               |
| **INV-NIX-2** | `rec{}` 自引用函数用 `builtins.concatLists(builtins.map f xs)`，不用 `lib.concatMap` |
| **INV-NIX-3** | `rec{}` 内递归函数不裸传给 `builtins.map`；用 lambda 包装器 `(x: f x)`               |
| **INV-NIX-4** | letrec 上下文不用 `foldl'+` 拼接列表；改用 `concatLists(map f xs)`                   |
| **INV-NIX-5** | `patternVars` 用迭代 BFS（\_extractOne × 8），绝不递归自引用                         |
| **INV-LET-1** | `let` 绑定不 shadow 外层函数参数（避免 Nix 互递归 thunk 死循环）                     |

### 3. 不变量驱动设计

每个架构决策锚定到具名 INV——违反即 soundness bug，不接受"实现方便"作为例外。

INV 是唯一真理来源：测试、代码、文档必须三者一致。

---

## 模块层次（Layer 0~22）

```
Layer 0:  core/kind.nix          — Kind 系统（KStar/KArrow/KRow/KEffect/KVar/KUnbound）
                                    + inferKind/solveKindConstraintsFixpoint (INV-KIND-1~3)
Layer 1:  meta/serialize.nix     — 规范序列化（← kindLib）         ★ INV-SER-1 核心
Layer 2:  core/meta.nix          — MetaType 控制层（eqStrategy, muPolicy）
Layer 3:  core/type.nix          — TypeIR 宇宙（_mkId via serializeRepr）
Layer 4:  repr/all.nix           — TypeRepr 构造器（26+ 变体，含 rDynamic/rHole）
Layer 5:  normalize/substitute.nix — 同步 capture-safe 替换（INV-SUB2）
Layer 6:  normalize/rules.nix    — TRS 规则集（11 规则）
Layer 7:  normalize/rewrite.nix  — TRS 主引擎（fuel-based，INV-2）
Layer 8:  meta/hash.nix          — 规范 hash（_safeStr 保护，INV-4）
Layer 9:  meta/equality.nix      — 类型等价（NF-hash equality，INV-3）
Layer 10: constraint/ir.nix      — Constraint IR（← serialLib）
Layer 11: runtime/instance.nix   — Instance DB（_instanceKey 纯字符串，INV-I1-key）
Layer 12: refined/types.nix      — 精化类型 + SMT oracle
Layer 13: normalize/unified_subst.nix — UnifiedSubst（type+row+kind compose，INV-US1~5）
Layer 14: constraint/unify_row.nix — Row 行等式合一（← serialLib）
Layer 15: constraint/unify.nix   — Robinson 合一 + Mu bisim（INV-MU-1）
Layer 16: constraint/solver.nix  — Worklist solver（INV-SOL5）
Layer 17: effect/handlers.nix    — Effect 处理器（INV-EFF-4~11）
Layer 18: module/system.nix      — 模块系统（INV-MOD-1~8）
Layer 19: bidir/check.nix        — 双向类型检查（INV-BIDIR-1~3，INV-SCHEME-1）
Layer 20: match/pattern.nix      — Pattern IR + Decision Tree（INV-PAT-1~3，INV-NIX-5）
Layer 21: incremental/graph.nix
          incremental/memo.nix
          incremental/query.nix  — Salsa-style 增量计算（INV-G1~4，INV-TOPO）
Layer 22: lib/default.nix        — 280+ 导出（拓扑聚合，无逻辑）
          testlib/default.nix    — 测试框架（INV-TEST-1~7）
```

---

## 模块结构

```
nix-types/
├── core/
│   ├── kind.nix          # Kind + inferKind + fixpoint solver (INV-KIND-3)
│   ├── type.nix          # TypeIR + mkScheme + _mkId via serializeRepr
│   └── meta.nix          # MetaType + bisimMeta
├── repr/
│   └── all.nix           # TypeRepr 26+ variants (rDynamic, rHole, rTypeScheme…)
├── normalize/
│   ├── rewrite.nix       # TRS main engine (fuel-based, INV-2)
│   ├── rules.nix         # 11 TRS rewrite rules
│   ├── substitute.nix    # capture-safe simultaneous substitution (INV-SUB2)
│   └── unified_subst.nix # UnifiedSubst (type+row+kind, INV-US1~5)
├── constraint/
│   ├── ir.nix            # Constraint IR (11 constructors)
│   ├── unify.nix         # Robinson + Mu bisim (INV-MU-1)
│   ├── unify_row.nix     # Row unification
│   └── solver.nix        # Worklist solver (DEFAULT_FUEL=2000)
├── meta/
│   ├── serialize.nix     # de Bruijn canonical serialization (INV-SER-1)
│   ├── hash.nix          # canonical hash (INV-4)
│   └── equality.nix      # typeEq via NF-hash
├── runtime/
│   └── instance.nix      # Instance DB + global coherence (INV-I1-key)
├── refined/
│   └── types.nix         # Refined Types + SMT oracle
├── effect/
│   └── handlers.nix      # Effect Handlers + continuations (INV-EFF-11)
├── bidir/
│   └── check.nix         # Bidirectional + HM let-gen (INV-BIDIR-1~3)
├── match/
│   └── pattern.nix       # Pattern IR + Decision Tree (INV-PAT-1~3, INV-NIX-5)
├── incremental/
│   ├── graph.nix         # Dependency graph (BFS, INV-TOPO)
│   ├── memo.nix          # Memo layer (epoch-based)
│   └── query.nix         # QueryDB (Salsa-style, INV-G1~4)
├── module/
│   └── system.nix        # Sig/Struct/ModFunctor (INV-MOD-1~8)
├── lib/
│   └── default.nix       # 280+ exports (topological order, aliases only)
├── testlib/
│   └── default.nix       # Test framework (INV-TEST-1~7)
├── tests/
│   ├── test_all.nix      # 203 tests, 28 groups
│   └── match/
│       └── diagnose_pat.nix
└── examples/
    └── demo.nix          # 8 end-to-end scenarios
```

---

## 数据流 & 执行流

### 典型类型检查管道

```
用户表达式
    │
    ▼
bidir/check.nix::infer
    │  ├── 查 Ctx → _ctxLookup / _ctxExtend
    │  ├── _inferLam / _inferApp / _inferLet / _inferIf
    │  │       └── infer 递归
    │  └── generalize（HM let-gen，INV-SCHEME-1）
    │
    ▼
约束列表 [Constraint]（constraint/ir.nix）
    │
    ▼
constraint/solver.nix::solve
    │  ├── _solveLoop（Worklist，fuel-bounded）
    │  ├── 每轮：unify + applySubstToConstraints
    │  ├── instance lookup → runtime/instance.nix
    │  └── row unify → constraint/unify_row.nix
    │
    ▼
UnifiedSubst（normalize/unified_subst.nix）
    │
    ▼
normalize/rewrite.nix::normalizeWithFuel
    │  └── applyFirstRule（normalize/rules.nix 11 条规则）
    │
    ▼
NF Type（可序列化，可 hash，可比较等价）
```

### 序列化管道（INV-SER-1）

```
Type → serializeRepr(t.repr)
             │
             ▼
       _serializeWithEnv env depth repr
             │  每个 TypeRepr 变体 → 纯字符串
             │  rVar → "V{depth}"（de Bruijn index）
             │  rMu  → "Mu(body)"（递归展开）
             │  ...
             ▼
       规范字符串 → builtins.hashString "sha256"
             │
             ▼
       t.id（Type 的全局唯一标识符）
```

### Salsa 失效传播（INV-G1）

```
markStale(nodeId)
    │
    ▼
incremental/graph.nix::_bfsInvalidate
    │  BFS 沿 revEdges 传播 stale 标记
    │  visited-set 防止无限递归（INV-G2）
    │
    ▼
所有依赖该节点的节点标记为 stale
    │
    ▼
下次查询时 lookupResult 返回 null → 重新计算
```

---

## 关键不变量目录

### 序列化

| 不变式     | 描述                                                  | 引入版本 |
| ---------- | ----------------------------------------------------- | -------- |
| INV-SER-1  | `builtins.toJSON` 不碰 Type/Constraint/函数值         | 4.3      |
| INV-I1-key | `_instanceKey` 用纯字符串拼接，不用 `builtins.toJSON` | 4.3.1    |

### Nix 语言

| 不变式    | 描述                                                    | 引入版本 |
| --------- | ------------------------------------------------------- | -------- |
| INV-NIX-1 | `or` 不在 `${}` 插值内                                  | 4.3      |
| INV-NIX-2 | `lib.concatMap` 不用于 rec fn                           | 4.5.2    |
| INV-NIX-3 | `rec{}` 内递归函数不裸传给 `builtins.map`               | 4.5.3    |
| INV-NIX-4 | letrec 上下文不用 `foldl'+` 拼接列表                    | 4.5.9    |
| INV-NIX-5 | `patternVars` 用迭代 BFS（不递归自引用）                | 4.5      |
| INV-NIX-6 | `[]` 成员如果需要处理因当使用 `(handle obj)` 形式为成员 | 4.5.9    |
| INV-LET-1 | `let` 绑定不 shadow 函数参数                            | 4.3.1    |

### 类型系统

| 不变式       | 描述                                              | 引入版本 |
| ------------ | ------------------------------------------------- | -------- |
| INV-1        | 所有结构 ∈ TypeIR                                 | 4.0      |
| INV-2        | TRS 引擎燃料有界（不发散）                        | 4.0      |
| INV-3        | 类型等价通过 NF-hash                              | 4.0      |
| INV-4        | hash 通过规范序列化（alpha-canonical）            | 4.0      |
| INV-6        | Constraint ∈ TypeRepr（数据驱动，不持函数引用）   | 4.0      |
| INV-SUB2     | 替换同步（非顺序），capture-safe                  | 4.0      |
| INV-MU-1     | Mu bisim up-to congruence（equi-recursive sound） | 4.3      |
| INV-SCHEME-1 | generalize 严格排除 Ctx 自由变量                  | 4.2      |

### Kind

| 不变式     | 描述                                  | 引入版本 |
| ---------- | ------------------------------------- | -------- |
| INV-KIND-1 | 推断 Kind 与注解一致                  | 4.3      |
| INV-KIND-2 | Kind 注解传播一致                     | 4.4      |
| INV-KIND-3 | Kind fixpoint 有界收敛（max 10 iter） | 4.5      |

### 双向类型检查

| 不变式      | 描述                                       | 引入版本 |
| ----------- | ------------------------------------------ | -------- |
| INV-BIDIR-1 | `infer` 模式完整性（所有 Expr 标签均覆盖） | 4.3      |
| INV-BIDIR-2 | `infer(eLamA p ty b) = (ty → bodyTy)`      | 4.4      |
| INV-BIDIR-3 | App result solved when fn type concrete    | 4.5      |

### Pattern

| 不变式    | 描述                                              | 引入版本 |
| --------- | ------------------------------------------------- | -------- |
| INV-PAT-1 | `patternVars` 捕获所有 Var 绑定                   | 4.4      |
| INV-PAT-2 | `isLinear(p) ↔ no duplicate in patternVars(p)`    | 4.4      |
| INV-PAT-3 | `patternVars(Record{…}) = ⋃ patternVars(subPats)` | 4.5      |

### Effect

| 不变式       | 描述                                              | 引入版本 |
| ------------ | ------------------------------------------------- | -------- |
| INV-EFF-4~10 | Effect handler 各项约束                           | 4.3      |
| INV-EFF-11   | `contType.from == paramType` in mkHandlerWithCont | 4.4      |

### Module

| 不变式      | 描述             | 引入版本 |
| ----------- | ---------------- | -------- |
| INV-MOD-1~8 | 模块系统各项约束 | 4.2      |

### 增量计算

| 不变式   | 描述                                              | 引入版本 |
| -------- | ------------------------------------------------- | -------- |
| INV-G1   | BFS 失效传播正确性                                | 4.1      |
| INV-G2   | visited-set 防止无限递归                          | 4.1      |
| INV-G4   | QueryKey 规范化（canonical tag+inputs）           | 4.1      |
| INV-TOPO | `topologicalSort` 统一返回 `{ ok; order; error }` | 4.5.2    |

### UnifiedSubst

| 不变式    | 描述                                          | 引入版本 |
| --------- | --------------------------------------------- | -------- |
| INV-US1~5 | 复合律、幂等性、空性等（`composeSubst` 满足） | 4.1      |

### 测试框架

| 不变式     | 描述                                             | 引入版本 |
| ---------- | ------------------------------------------------ | -------- |
| INV-TEST-1 | `builtins.tryEval` 隔离每个测试                  | 4.3      |
| INV-TEST-2 | Pattern 测试使用 `patternLib.mkPVar`             | 4.3.1    |
| INV-TEST-3 | Unicode key 使用 `? "α"` 语法                    | 4.3.1    |
| INV-TEST-4 | `testGroup` 防御性检查 tests 参数类型            | 4.5.2    |
| INV-TEST-5 | `failedList` 防御性检查 g.failed 字段            | 4.5.2    |
| INV-TEST-6 | `mkTestBool`/`mkTest` 均携带 `diag` 字段供调试   | 4.5.3    |
| INV-TEST-7 | 所有输出路径 JSON-safe（无 Type 对象，无函数值） | 4.5.3    |

---

## 设计模式

### 依赖倒置

每个模块通过 `{ lib, ...Libs }` 参数接收依赖，**无隐式 import**：

```nix
{ lib, kindLib, metaLib, serialLib }:
let
  inherit (kindLib) KStar serializeKind;
  inherit (serialLib) serializeRepr;
in { ... }
```

### 层级化

Layer 0~22 严格拓扑顺序，每层只依赖低层模块：

```
Layer N → Layer M  iff  M < N
```

`lib/default.nix` 是唯一跨层聚合点，不包含业务逻辑。

### 数据驱动

Constraint 是纯 attrset，不持函数引用（INV-6）。Solver 仅操作 IR 数据。TypeRepr 变体通过 `__variant` 字段区分。

### 增量模式（Salsa-style）

```
QueryDB.storeResult(key, value, deps)
    ↓
依赖边: key → deps（key 依赖 deps 中每一项）
反向边: dep → [dependents]（dep 失效时向上传播）
    ↓
markStale(dep) → BFS 传播 → invalidate dependents
    ↓
next lookup → miss → recompute → storeResult
```

### 序列化架构（INV-SER-1）

```
所有 Type 对象     → serializeRepr(t.repr)
所有 Kind 值       → serializeKind(k)
所有 Constraint    → serializeConstraint(c)
所有 PredExpr      → serializePredExpr(pe)
最后保护层         → _safeStr(v)  [isFunction guard]
```

`builtins.toJSON` 只允许用于已知纯 JSON 数据（`{ ok; total; passed }`等）。

---

## 可扩展点

### 新增 TypeRepr 变体

```nix
# 1. repr/all.nix
rMyVariant = arg: mkRepr "MyVariant" { arg = arg; };

# 2. meta/serialize.nix (_serializeWithEnv 链中)
else if r.__variant == "MyVariant" then
  "MyVariant(${_ser env depth r.arg})"

# 3. normalize/rules.nix (如需 TRS 规则)
ruleMyVariant = t:
  if (t.repr.__variant or null) == "MyVariant" then ...
  else null;
# 并加入 allRules 列表
```

### 新增 Constraint 类型

```nix
# 1. constraint/ir.nix
mkMyConstraint = arg: {
  __constraintTag = "My";
  arg = arg;
};

# 2. meta/serialize.nix (serializeConstraint 链中)
else if c.__constraintTag == "My" then
  "My(${serializeRepr c.arg})"

# 3. constraint/solver.nix (_solveLoop 中处理)
else if c.__constraintTag == "My" then
  ...
```

### 新增测试组

```nix
# tests/test_all.nix
tMyGroup = testGroup "T29-MyFeature" [
  (mkTestBool "my-invariant ok" (ts.myPredicate someType))
  (mkTestEq   "my-result"       (ts.myFunc input) expected)
];
```

---

## Phase 5.0 规划

```
新增不变量:
  INV-GRAD-1: Dynamic consistent with all types
  INV-GRAD-2: cast insertion explicit at Dynamic boundaries
  INV-HM-1:   infer yields principal type
  INV-HM-2:   generalize respects free variables in Ctx

实现计划:
  1. isConsistent t1 t2 → Bool (rDynamic 已在 repr/all.nix)
  2. Cast 插入遍：Expr → ExprWithCasts
  3. HM constraint solving loop 集成进 type inference
  4. Decision Tree prefix sharing (Maranget 2008 algorithm)
  5. SMT bridge: real SMTLIB2 backend (当前为 oracle stub)
```
