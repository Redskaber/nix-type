# TODO-Phase3.md — Phase 3.2 完成状态 + Phase 3.3/4 规划

---

## Phase 3.1 修复完成状态（全部 ✅）

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

## Phase 3.2 修复完成状态（全部 ✅）

| 修复编号 | 问题                                                    | 修复文件                | INV      | 状态 |
| -------- | ------------------------------------------------------- | ----------------------- | -------- | ---- |
| P3.2-1   | `bidir/_substTypeInType` 仅顶层 Var                     | `bidir/check.nix`       | INV-DEP  | ✅   |
| P3.2-2   | `_unifyMu` 仅 alpha-canonical（保守近似）               | `constraint/unify.nix`  | INV-MU   | ✅   |
| P3.2-3   | INV-I2 overlap 仅 exact match                           | `runtime/instance.nix`  | INV-I2   | ✅   |
| P3.2-4   | `_typeMentions` 仅顶层 Var                              | `constraint/solver.nix` | INV-SOL5 | ✅   |
| P3.2-5   | `ruleRowCanonical` 为 no-op                             | `normalize/rules.nix`   | INV-ROW  | ✅   |
| P3.2-6   | instance selection 使用 lexicographic（非 specificity） | `runtime/instance.nix`  | INV-SPEC | ✅   |
| P3.2-X1  | `ruleEffectNormalize` 为 no-op                          | `normalize/rules.nix`   | INV-EFF  | ✅   |
| P3.2-X2  | `_applySubstType` 仅顶层 Var（solver + unify 共用）     | `constraint/unify.nix`  | INV-SOL4 | ✅   |
| P3.2-X3  | `partialUnify` API 缺失                                 | `constraint/unify.nix`  | INV-I2   | ✅   |

---

## 当前已知限制（Phase 3.3 目标）

| 限制                                       | 位置                   | 描述                                                      | Phase |
| ------------------------------------------ | ---------------------- | --------------------------------------------------------- | ----- |
| Open record row unification 不完整         | `constraint/unify.nix` | 不同 rowVar 的 open record 统一需要 row constraint        | 3.3   |
| Mu bisimulation up-to congruence           | `constraint/unify.nix` | 当前 guard set 是 syntactic pair；up-to 可处理更多情况    | 3.3   |
| Effect row merge / intersection            | `normalize/rules.nix`  | Effect ++ Effect → merged row（需要 row concatenation）   | 3.3   |
| `ruleRowCanonical` 跨 RowExtend/VariantRow | `normalize/rules.nix`  | 目前只处理 RowExtend；VariantRow 需要独立规则             | 3.3   |
| Instance byClass 索引的 overlap 精确性     | `runtime/instance.nix` | 当前 partial unification 是保守 conservative overlap      | 3.3   |
| `bidir/check` Match pattern 变量绑定完整性 | `bidir/check.nix`      | 当前 pattern vars 只处理 Var / Ctor；需 Record / Lit 模式 | 3.3   |

---

## Phase 3.3 计划

```
P3.3-1: Row unification 完整（open record pair 对齐，rowVar binding）
P3.3-2: Mu bisimulation up-to congruence（不只 syntactic pair guard）
P3.3-3: Effect row merge（row concatenation ++ 运算）
P3.3-4: ruleVariantRowCanonical（独立于 ruleRowCanonical）
P3.3-5: Pattern matching 完整变量绑定（Record / Lit / Guard patterns）
P3.3-6: Instance overlap 精确 partial unification（完整 Robinson）
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

**关键设计**：

- Predicate 约束严格隔离（nix string-based，不带 IO）
- solver residual 中的 Predicate → 传递给外部 SMT bridge
- INV-6 保证：Predicate ∈ TypeRepr（不是函数）

### P4-2：Module System

```nix
# Sig = record of types + values
rSig     = fields: mkRepr "Sig"     { inherit fields; };
rStruct  = sig: impl: mkRepr "Struct"  { inherit sig impl; };
rFunctor = param: body: mkRepr "Functor" { inherit param body; };

# Module sealing（Opaque repr）
seal = mod: sig: mkTypeDefault (rOpaque sig (typeHash mod)) KStar;
```

**关键设计**：

- Functor application 生成局部 InstanceDB（隔离实例）
- Sig checking = structural subtyping on Record types
- Module sealing 使用已有的 rOpaque repr

### P4-3：Effect Handlers

```nix
# handle : Eff(E ++ R, A) → Handler(E, A, B) → Eff(R, B)
mkHandler = effectTag: branches: returnType:
  mkTypeDefault (rADT (map mkHandlerBranch branches) true) KStar;

# Effect row subtraction：Eff(E ++ R) - E → Eff(R)
subtractEffect = effTy: tag:
  ... # Phase 3.3 row merge 基础上实现
```

### P4-4：First-class Modules

```nix
# 与 P4-2 共享基础；Functor = Sig → Sig
tSig = mkTypeDefault (rSig {
  Eq  = KStar;
  eq  = mkTypeDefault (rFn tInt (mkTypeDefault (rFn tInt tBool) KStar)) KStar;
}) KStar;
```

---

## 架构风险矩阵（Phase 3.2 → 4）

| 风险                                      | 等级  | 缓解策略                                       |
| ----------------------------------------- | ----- | ---------------------------------------------- |
| Mu bisimulation fuel 设置过保守           | 🟡 低 | \_defaultMuFuel = 32，可配置；guard set 兜底   |
| Specificity 在 HKT instance 上的语义      | 🟠 中 | HKT instance 的 Var 计数需要 kind-aware 版本   |
| Row unification 和 Constraint solver 交互 | 🟠 中 | rowVar binding → 生成 Equality constraint      |
| Effect merge 与 TypeRepr 闭包             | 🟠 中 | Effect = VariantRow（统一 TypeRepr）已为此铺垫 |
| SMT bridge 副作用污染 TypeIR              | 🔴 高 | 严格隔离：nix string-based SMT，不带入 IO      |
| Functor + Instance 交互                   | 🟠 中 | Functor application 生成局部 InstanceDB        |
| Module sealing + nominal typing           | 🟡 低 | Opaque repr（已实现）+ rSig（Phase 4）         |

---

## 测试覆盖状态（Phase 3.2）

| 测试组             | 测试数 | 覆盖 INV               |
| ------------------ | ------ | ---------------------- |
| T1 基础 TypeIR     | 8      | INV-T1/2/3/4           |
| T2 α-equivalence   | 4      | INV-SER3/EQ            |
| T3 Kind            | 8      | INV-K1-6               |
| T4 Constructor     | 2      | INV-K1                 |
| T5 μ-types         | 5      | INV-EQ3/MU             |
| T6 HKT             | 3      | INV-K2                 |
| T7 Row             | 5      | INV-EQ4/ROW            |
| T8 Instance        | 9      | INV-I1/2/SPEC          |
| T9 Solver          | 7      | INV-SOL1/4/5           |
| T10 Graph          | 6      | INV-G1/4/5             |
| T11 Memo           | 3      | INV-M1-4               |
| T12 Pattern        | 5      | -                      |
| T13 INV 全量       | 8      | 所有 INV（含 P3.2 新） |
| T14 Phase 3.1 专项 | 6      | 修复验证               |
| T15 Phase 3.2 专项 | 9      | P3.2-1~6 + X1/X2/X3    |
| **合计**           | **87** |                        |
