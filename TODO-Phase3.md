# TODO-Phase3.md — Phase 3.1 完成状态 + Phase 4 规划

---

## Phase 3.1 修复完成状态

| 修复编号 | 问题                                                 | 修复文件                                    | INV         | 状态 |
| -------- | ---------------------------------------------------- | ------------------------------------------- | ----------- | ---- |
| SOL-1    | `_resolveViaSuper` 返回 `impl=null`（soundness bug） | `runtime/instance.nix`                      | INV-I3      | ✅   |
| SOL-2    | `canDischarge` 不验证 impl                           | `runtime/instance.nix`                      | soundness   | ✅   |
| SOL-3    | superclass 查询方向反转                              | `runtime/instance.nix`, `constraint/ir.nix` | INV-I2      | ✅   |
| EQ-1     | strategy 分支破坏 INV-3                              | `meta/equality.nix`                         | INV-3       | ✅   |
| EQ-2     | `alphaEq` ≠ `structuralEq`（双 pipeline）            | `meta/equality.nix`                         | INV-EQ2     | ✅   |
| HASH-1   | `typeHash/nfHash` 双路径                             | `meta/hash.nix`                             | INV-H2      | ✅   |
| SER-1    | `toJSON` 属性顺序依赖                                | `meta/serialize.nix`                        | INV-SER4    | ✅   |
| SER-2    | Constructor binder 循环                              | `meta/serialize.nix`                        | INV-SER5    | ✅   |
| SUBST-1  | `substituteAll` attrNames 不稳定                     | `normalize/substitute.nix`                  | INV-SUBST-3 | ✅   |
| KIND-1   | Constructor-partial kind = KStar（错误）             | `normalize/rules.nix`                       | INV-K1      | ✅   |
| FUEL-1   | beta/depth/mu fuel 混用                              | `normalize/rules.nix`, `rewrite.nix`        | INV-NF      | ✅   |
| SOL-4    | Worklist 终止不含 subst 变化                         | `constraint/solver.nix`                     | INV-SOL1    | ✅   |
| SOL-5    | subst 未应用到 constraints                           | `constraint/solver.nix`                     | INV-SOL4    | ✅   |
| SOL-6    | 无精确 worklist（affected partition）                | `constraint/solver.nix`                     | INV-SOL5    | ✅   |
| IR-1     | `constraintKey` 依赖 toJSON                          | `constraint/ir.nix`                         | INV-C1      | ✅   |
| IR-2     | `mapTypesInConstraint` 不完整                        | `constraint/ir.nix`                         | INV-C3      | ✅   |
| IR-3     | `normalizeConstraint` ordering                       | `constraint/ir.nix`                         | INV-C4      | ✅   |
| IR-4     | `deduplicateConstraints` O(n²)                       | `constraint/ir.nix`                         | INV-C2      | ✅   |
| GRAPH-1  | Kahn in-degree 方向错误                              | `incremental/graph.nix`                     | INV-G5      | ✅   |
| GRAPH-2  | BFS worklist 无去重                                  | `incremental/graph.nix`                     | INV-G1      | ✅   |
| GRAPH-3  | stale 状态缺失                                       | `incremental/graph.nix`                     | INV-G       | ✅   |
| GRAPH-4  | errorMeta provenance 缺失                            | `incremental/graph.nix`                     | debug       | ✅   |
| MEMO-1   | cache value = string identity                        | `incremental/memo.nix`                      | INV-M       | ✅   |

---

## 当前已知限制（Phase 3.1 → 3.2 修复）

| 限制                                | 位置                    | 描述                                       | Phase |
| ----------------------------------- | ----------------------- | ------------------------------------------ | ----- |
| `bidir/_substTypeInType` 仅顶层 Var | `bidir/check.nix`       | 完整版需 substLib 集成                     | 3.2   |
| `_unifyMu` bisimulation-based       | `constraint/unify.nix`  | 当前保守 alpha-canonical 近似              | 3.2   |
| `_typeMentions` 仅顶层 Var          | `constraint/solver.nix` | 完整版需 freeVarsRepr 集成                 | 3.2   |
| `_resolveViaSuper` 选择算法         | `runtime/instance.nix`  | 当前 lexicographic，应是 specificity-based | 3.2   |
| INV-I2 overlap detection            | `runtime/instance.nix`  | 当前 exact match，应是 partial unification | 3.2   |
| Row canonical sort                  | `normalize/rules.nix`   | `ruleRowCanonical` 仍 TODO                 | 3.2   |
| Effect normalize                    | `normalize/rules.nix`   | Effect body normalize 委托                 | 3.2   |

---

## Phase 3.2 计划（当前限制修复）

```
P3.2-1: substLib 集成到 bidir/_substTypeInType（完整 dependent type check）
P3.2-2: _unifyMu bisimulation（guard set + fuel，不是 alpha-canonical 近似）
P3.2-3: INV-I2 overlap: partial unification overlap detection
P3.2-4: _typeMentions 完整（freeVarsRepr 传播）
P3.2-5: ruleRowCanonical 完整 RowExtend spine sort
P3.2-6: specificity-based instance selection（最小特化）
```

---

## Phase 4.0 规划

### P4-1：Refined Types（Liquid Types）

```nix
# Predicate constraint（SMT bridge，nix-string based）
mkRefined = baseType: predFn:
  mkTypeWith (rConstrained baseType [mkPredicate predFn baseType]) KStar defaultMeta;

# 示例：{ n : Int | n > 0 }
tPosInt = mkRefined tInt "gt_zero";
```

### P4-2：Module System

```nix
# Sig = record of types + values
# Struct = implementation of Sig
# Functor = Sig → Sig
rSig     = fields: mkRepr "Sig"     { inherit fields; };
rStruct  = sig: impl: mkRepr "Struct"  { inherit sig impl; };
rFunctor = param: body: mkRepr "Functor" { inherit param body; };
```

### P4-3：Effect Handlers

```nix
# handle : Eff(E ++ R, A) → Handler(E, A, B) → Eff(R, B)
mkHandler = effectTag: branches: returnType:
  mkTypeDefault (rADT (map mkHandlerBranch branches) true) KStar;
```

### P4-4：First-class Modules

```nix
# Module signature
tSig = mkTypeDefault (rSig {
  Eq   = tInt;
  eq   = mkTypeDefault (rFn tInt (mkTypeDefault (rFn tInt tBool) KStar)) KStar;
}) KStar;
```

---

## 架构风险矩阵（Phase 3.1 → 4）

| 风险                                   | 等级  | 缓解策略                                   |
| -------------------------------------- | ----- | ------------------------------------------ |
| Dependent type + fuel 张力（循环类型） | 🔴 高 | type/term fuel 独立计数                    |
| Mu unification soundness               | 🟠 中 | bisimulation fuel + guard set（Phase 3.2） |
| Effect row + Constraint 交互           | 🟠 中 | Effect = VariantRow（统一 TypeRepr）       |
| SMT bridge 副作用污染 TypeIR           | 🔴 高 | 严格隔离：nix string-based SMT，不带入 IO  |
| Functor + Instance 交互                | 🟠 中 | Functor application 生成局部 InstanceDB    |
| Module sealing + nominal typing        | 🟡 低 | Opaque repr（已实现）+ rSig（Phase 4）     |

---

## 测试覆盖状态

| 测试组             | 测试数 | 覆盖 INV     |
| ------------------ | ------ | ------------ |
| T1 基础 TypeIR     | 8      | INV-T1/2/3/4 |
| T2 α-equivalence   | 4      | INV-SER3/EQ  |
| T3 Kind            | 8      | INV-K1-6     |
| T4 Constructor     | 2      | INV-K1 修复  |
| T5 μ-types         | 3      | INV-EQ3      |
| T6 HKT             | 3      | INV-K2       |
| T7 Row             | 3      | INV-EQ4      |
| T8 Instance        | 7      | INV-I1/2/3   |
| T9 Solver          | 5      | INV-SOL1/4/5 |
| T10 Graph          | 6      | INV-G1/4/5   |
| T11 Memo           | 3      | INV-M1-4     |
| T12 Pattern        | 5      | -            |
| T13 INV 全量       | 6      | 所有 INV     |
| T14 Phase 3.1 专项 | 6      | 修复验证     |
| **合计**           | **69** |              |
