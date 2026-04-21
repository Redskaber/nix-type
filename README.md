# Nix Type System — Phase 3.1

> 纯 Nix 原生实现的强表达力类型系统  
> 类 Rust 编译器增量管道 · System Fω + Dependent Types · Bidirectional Checking  
> Equi-Recursive Bisimulation · Row Polymorphism · Effect System (ready)

---

## 核心不变量（Phase 3.1 全部强制）

```
INV-1:   所有结构             ∈ TypeIR
INV-2:   所有计算             = Rewrite(TypeIR)，split-fuel bounded 终止
INV-3:   所有比较             = NormalForm Equality（单一路径，strategy 不影响）
INV-4:   所有缓存 key         = NF-hash（typeHash = nfHash ∘ normalize）
INV-5:   所有依赖追踪         = Graph Edge（BFS worklist，queueSet 去重）
INV-6:   Constraint           ∈ TypeRepr（不是函数，不是 runtime）
INV-T1:  t.kind ≠ null        → KUnbound（construction-safe）
INV-T2:  t.id = H(serializeAlpha(repr))（不依赖 toJSON 属性顺序）
INV-K4:  kindUnify            纯函数，不 mutate
INV-EQ1: typeEq(a,b)          ⟹ typeHash(a) == typeHash(b)
INV-EQ2: structuralEq         ⊆ nominalEq ⊆ hashEq（Coherence Law）
INV-EQ3: muEq                 = coinductive bisimulation（fuel + guard set）
INV-EQ4: rowVarEq             = rigid name equality
INV-H2:  typeHash             = nfHash ∘ normalize（唯一收敛路径）
INV-I1:  每个 (class,args)    最多一个 instance（coherence）
INV-SOL1: Worklist 终止       含 subst 变化检测
INV-SOL4: subst               在每轮后应用到 constraints
INV-SOL5: 精确 worklist       受 subst 影响的 constraints 重入队
INV-SER3: serializeAlpha(α-equiv) = 相同 string（de Bruijn index）
INV-SER4: 消除所有 toJSON 依赖（属性顺序不稳定）
INV-C1:  constraintKey        canonical（不依赖属性顺序）
INV-C2:  constraintsHash      去重 + 稳定排序（O(n)）
INV-C3:  mapTypesInConstraint 完整递归
INV-C4:  normalizeConstraint  幂等（pipeline: subst → normalize）
INV-G1:  BFS worklist         queueSet 防止重复扩展
INV-G5:  topologicalSort      Kahn 正确 in-degree（前驱数）
```

---

## Phase 3.1 修复摘要

| 类别            | 修复内容                                                        | 严重性      |
| --------------- | --------------------------------------------------------------- | ----------- |
| **Soundness**   | `_resolveViaSuper` 返回真实 impl（不是 null）                   | 🔴 Critical |
| **Soundness**   | `canDischarge` 验证 impl 有效性                                 | 🔴 Critical |
| **Soundness**   | `isSuperclassOf` 方向修正（super/sub 语义）                     | 🔴 Critical |
| **INV-3**       | `strategy` 不影响 equality 路径（只影响 normalize 深度）        | 🔴 Critical |
| **INV-EQ1**     | `alphaEq` 统一到 NF-hash（消除双 canonicalization pipeline）    | 🔴 Critical |
| **INV-H2**      | `typeHash = nfHash ∘ normalize` 单路径                          | 🔴 Critical |
| **INV-K1**      | Constructor-partial kind 使用真实 `param.kind`（不假设 KStar）  | 🟠 High     |
| **INV-G5**      | Kahn 算法 in-degree 方向修正（前驱数 = revEdges 长度）          | 🟠 High     |
| **INV-G1**      | BFS worklist `queueSet` 防止重复 BFS expansion                  | 🟠 High     |
| **INV-SOL1**    | Worklist 终止含 subst 大小变化检测                              | 🟠 High     |
| **INV-SOL4**    | subst 在每轮后应用到所有 constraints                            | 🟠 High     |
| **INV-SOL5**    | `_partitionAffected` 精确 worklist                              | 🟠 High     |
| **INV-SER4**    | 消除 `toJSON` 依赖（de Bruijn + 显式 sort）                     | 🟠 High     |
| **INV-SUBST-3** | `substituteAll` 显式 lexicographic 排序                         | 🟡 Medium   |
| **INV-C1**      | `constraintKey` 使用 canonical type ids                         | 🟡 Medium   |
| **INV-C4**      | `normalizeConstraint ∘ mapTypesInConstraint` ordering invariant | 🟡 Medium   |
| **INV-NF**      | Split fuel：betaFuel / depthFuel / muFuel 独立                  | 🟡 Medium   |
| **INV-G4**      | `stale` 状态区分 + `errorMeta` provenance                       | 🟡 Medium   |

---

## 模块文件结构

```
/core
  kind.nix          # Kind 系统（KStar/KArrow/KRow/KEffect/KVar）
  meta.nix          # MetaType 语义控制（NormalizePolicy 分离）
  type.nix          # TypeIR 统一结构（Type/Kind/Meta 三位一体）

/repr
  all.nix           # TypeRepr 全 21 变体（含 Pi/Sigma/Effect/Opaque/Ascribe）

/normalize
  substitute.nix    # capture-safe 替换（alpha-rename + lexicographic 排序）
  rules.nix         # TRS 规则集（split fuel，Constructor-partial kind 修复）
  rewrite.nix       # TRS 主引擎（innermost closure，单一 normalize 入口）

/constraint
  ir.nix            # Constraint IR（canonical pipeline，O(n) dedup）
  unify.nix         # Robinson unification（INV-U4 α-canonical，Pi/Sigma binder）
  solver.nix        # Worklist Solver（INV-SOL1/4/5，soundness 修复）

/runtime
  instance.nix      # Instance DB（superclass 修复，canDischarge soundness）

/meta
  serialize.nix     # α-canonical 序列化 v3（de Bruijn，无 toJSON）
  hash.nix          # Canonical hash（单路径 INV-H2）
  equality.nix      # 统一等价核（INV-EQ1-4，Coherence Law）

/incremental
  graph.nix         # 依赖图（Kahn 修正，queueSet BFS，stale 状态）
  memo.nix          # Memo 层（versioned key，epoch，结构化 cache）

/match
  pattern.nix       # Pattern IR + Decision Tree + Exhaustiveness

/bidir
  check.nix         # Bidirectional Type Checking（Pierce/Turner）

/lib
  default.nix       # 统一入口（18 模块，正确拓扑序，INV 运行时验证）

/tests
  test_all.nix      # 综合测试套件（T1-T14，56 测试用例）
```

---

## Phase 演化路径

```
Phase 1.0  基础 TypeIR + Kind + Primitive TRS
Phase 2.0  Row Polymorphism + μ-types + Instance DB
Phase 3.0  Dependent Types + Effect System + Bidirectional + Constraint IR
Phase 3.1  ← 当前（所有 Soundness/INV 修复，企业级稳定）
Phase 3.2  → constraint/solver Worklist 完整 impl（substLib 集成）
              bidir/_substTypeInType 完整递归
              _unifyMu bisimulation-based
Phase 4.0  Refined Types（SMT bridge）
           Module System（Sig/Struct/Functor）
           Effect Handlers（algebraic effects dispatch）
           First-class Modules（FLAM/OCaml module system 风格）
```

---

## 使用示例

```nix
let
  ts = import ./lib/default.nix { lib = pkgs.lib; };
  inherit (ts) mkTypeDefault rPrimitive rFn rLambda rApply KStar KStar1;

  # 基础类型
  tInt  = mkTypeDefault (rPrimitive "Int")  KStar;
  tBool = mkTypeDefault (rPrimitive "Bool") KStar;

  # 函数类型 Int → Bool
  tIntToBool = mkTypeDefault (rFn tInt tBool) KStar;

  # 泛型 lambda f：(a → b)
  tPolyFn = mkTypeDefault (rLambda "a" ts.KUnbound (mkTypeDefault (rFn (mkTypeDefault (ts.rVar "a") KStar) tBool) KStar)) KStar1;

  # Normalize
  normed = ts.normalize tIntToBool;

  # Type equality
  eq = ts.typeEq normed tIntToBool;

  # Hash
  h = ts.typeHash tInt;

  # Constraint solving
  solved = ts.solveDefault [(ts.mkClass "Eq" [tInt]) (ts.mkClass "Show" [tBool])];

in { inherit normed eq h solved; }
```

---

## 关键设计决策（ADR）

### ADR-1：strategy 不影响 equality 路径

**决策**：`eqStrategy` 只影响 normalize 深度，所有 equality 最终走 NF-hash  
**原因**：INV-3 要求单一 canonical equality，strategy 分支破坏 transitivity

### ADR-2：split fuel 三路系统

**决策**：`betaFuel / depthFuel / muFuel` 独立计数  
**原因**：beta 和 depth 混用导致 mu-unfold 被 beta fuel 耗尽误停

### ADR-3：superclass resolution 返回真实 impl

**决策**：`_resolveViaSuper` 查找 sub-class instances 并返回其 impl  
**原因**：返回 `impl=null` 但 `found=true` 导致 constraint 被错误 discharge（soundness bug）

### ADR-4：serialize 使用 de Bruijn index

**决策**：binder 变量用 de Bruijn index 替换名字（INV-SER3）  
**原因**：消除 α-equivalent 类型产生不同 hash 的问题

### ADR-5：Kahn in-degree = revEdges 长度

**决策**：拓扑排序 in-degree 定义为"前驱数"（反向边数量）  
**原因**：原实现方向反转导致 topologicalSort 结果错误
