# Nix Type System — Phase 3.2

> 纯 Nix 原生实现的强表达力类型系统  
> 类 Rust 编译器增量管道 · System Fω + Dependent Types · Bidirectional Checking  
> Equi-Recursive Bisimulation · Row Polymorphism · Effect System · Specificity-based Instance Selection

---

## 核心不变量（Phase 3.2 全部强制）

```
INV-1:   所有结构             ∈ TypeIR
INV-2:   所有计算             = Rewrite(TypeIR)，split-fuel bounded 终止
INV-3:   所有比较             = NormalForm Equality（单一路径）
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
INV-I1:  每个 (class,args)    最多一个 instance（coherence，overlap 用 specificity 解决）
INV-I2:  overlap detection    = partial unification（不只 exact match）
INV-MU:  _unifyMu             = bisimulation（guard set + fuel，真正 equi-recursive）
INV-ROW: ruleRowCanonical     幂等（不同顺序 RowExtend → 相同 NF hash）
INV-SOL1: Worklist 终止       含 subst 变化检测
INV-SOL4: subst               完整深层应用（_applySubstTypeFull，不只顶层 Var）
INV-SOL5: 精确 worklist       受 subst 影响的 constraints 重入队
INV-SPEC: instance selection  specificity-based（具体 > 泛化，tie-break lexicographic）
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

## Phase 3.2 修复摘要

| 编号    | 问题                                    | 修复内容                                                        | 严重性      |
| ------- | --------------------------------------- | --------------------------------------------------------------- | ----------- |
| P3.2-1  | `bidir/_substTypeInType` 只处理顶层 Var | 改用 `substLib.substitute`（完整 capture-safe 递归）            | 🔴 Critical |
| P3.2-2  | `_unifyMu` 仅 alpha-canonical 近似      | 真正 bisimulation：guard set + fuel + coinductive hypothesis    | 🔴 Critical |
| P3.2-3  | INV-I2 overlap 仅 exact match           | partial unification overlap detection（Var + Primitive + Ctor） | 🟠 High     |
| P3.2-4  | `_typeMentions` 仅顶层 Var              | 完整 `_reprMentions` 全 21 TypeRepr 变体递归传播                | 🟠 High     |
| P3.2-5  | `ruleRowCanonical` 为 no-op             | 完整 RowExtend spine unspine → sort by label → rebuild          | 🟠 High     |
| P3.2-6  | instance selection 使用 lexicographic   | specificity-based：non-Var args 计数，具体 > 泛化               | 🟠 High     |
| P3.2-X1 | `ruleEffectNormalize` 为 no-op          | Effect body VariantRow 按名字字母序排列（触发 hash 重算）       | 🟡 Medium   |
| P3.2-X2 | `_applySubstType` 只处理顶层 Var        | `_applySubstTypeFull` 完整 21 变体深层替换（solver 使用）       | 🟠 High     |
| P3.2-X3 | `unifyLib.partialUnify` 缺失            | 新增 conservative overlap check API（供 instanceLib 使用）      | 🟡 Medium   |

---

## Phase 3.2 核心设计决策

### ADR-6：Mu bisimulation 使用 guard set

**决策**：`_unifyMu` 用 `guardSet`（`id_a:id_b` 对集合）做 coinductive hypothesis  
**原因**：equi-recursive semantics 要求 µ-types 在展开等价时被接受；alpha-canonical 只能处理语法相同的情况，guard set 支持结构相同但 binder 名不同的情况  
**算法**：

```
unifyMu(guard, a, b):
  key = canonical_pair(a.id, b.id)
  if key ∈ guard → ok (coinductive)
  if fuel = 0 → fallback alpha-canonical
  unfoldA = substitute(a.var, a, a.body)
  unfoldB = substitute(b.var, b, b.body)
  unifyCore(guard ∪ {key}, unfoldA, unfoldB, fuel-1)
```

### ADR-7：Specificity-based instance selection

**决策**：`specificity(inst) = count(non-Var args)`，选最高 specificity  
**原因**：类似 Haskell `OVERLAPPING` 语义，具体 `Eq Int` 比泛化 `Eq a` 更优先  
**Tie-breaking**：相同 specificity → lexicographic key 最小（确定性）

### ADR-8：Row canonical via spine unspine

**决策**：展开 RowExtend 链 → sort labels → rebuild  
**原因**：`{ b: Bool | { a: Int } }` 和 `{ a: Int | { b: Bool } }` 应规范到相同 NF  
**幂等性**：已排序的链 → no change（`alreadySorted` 检查）

### ADR-9：\_substTypeInType 委托 substLib

**决策**：bidir 中所有类型替换委托给 `substLib.substitute`  
**原因**：capture-safe substitution 是复杂语义，不应在 bidir 层重新实现  
**效果**：dependent type checking 中 `Π(x:A).B` apply arg → `B[x↦arg]` 完整正确

---

## 模块文件结构（Phase 3.2）

```
/core
  kind.nix          # Kind 系统（KStar/KArrow/KRow/KEffect/KVar）
  meta.nix          # MetaType 语义控制
  type.nix          # TypeIR 统一结构（Type/Kind/Meta 三位一体）

/repr
  all.nix           # TypeRepr 全 21 变体（含 Pi/Sigma/Effect/Opaque/Ascribe）

/normalize
  substitute.nix    # capture-safe 替换（alpha-rename + lexicographic 排序）
  rules.nix         # TRS 规则集 Phase 3.2（ruleRowCanonical完整 + ruleEffectNormalize）
  rewrite.nix       # TRS 主引擎（innermost closure，单一 normalize 入口）

/constraint
  ir.nix            # Constraint IR（canonical pipeline，O(n) dedup）
  unify.nix         # Robinson + bisimulation Mu（Phase 3.2：_applySubstTypeFull）
  solver.nix        # Worklist Solver（Phase 3.2：完整 _typeMentions）

/runtime
  instance.nix      # Instance DB（Phase 3.2：specificity + partial unification overlap）

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
  check.nix         # Bidirectional Type Checking（Phase 3.2：substLib 集成）

/lib
  default.nix       # 统一入口（Phase 3.2：完整 INV 验证，specificity INV）

/tests
  test_all.nix      # 综合测试套件（T1-T15，含 Phase 3.2 专项）
```

---

## Phase 演化路径

```
Phase 1.0  基础 TypeIR + Kind + Primitive TRS
Phase 2.0  Row Polymorphism + μ-types + Instance DB
Phase 3.0  Dependent Types + Effect System + Bidirectional + Constraint IR
Phase 3.1  Soundness/INV 修复（enterprise-stable）
Phase 3.2  ← 当前
           ✅ _unifyMu bisimulation（guard set + fuel）
           ✅ _substTypeInType 完整（substLib 集成）
           ✅ INV-I2 overlap: partial unification
           ✅ _typeMentions 完整（freeVarsRepr 全变体）
           ✅ ruleRowCanonical 完整（spine sort）
           ✅ specificity-based instance selection
Phase 3.3  → Row unification 完整（open record 对齐）
              Effect row merge / intersection types
              _unifyMu up-to congruence（更完整 bisimulation）
Phase 4.0  Refined Types（SMT bridge）
           Module System（Sig/Struct/Functor）
           Effect Handlers（algebraic effects dispatch）
           First-class Modules
```

---

## 使用示例（Phase 3.2 新特性）

```nix
let
  ts = import ./lib/default.nix { lib = pkgs.lib; };
  inherit (ts)
    mkTypeDefault rPrimitive rVar rFn rLambda rApply rMu rADT
    KStar KStar1 mkVariant
    normalize typeEq typeHash
    unify unifyFresh
    register emptyInstanceDB resolveWithFallback
    check infer emptyCtx ctxBind tLam tVar tApp tAscribe tLit;

  tInt  = mkTypeDefault (rPrimitive "Int")  KStar;
  tBool = mkTypeDefault (rPrimitive "Bool") KStar;

  # ── Mu bisimulation：两个结构相同（不同 binder 名）的递归类型 ──────────────
  tList1 =
    let
      body = mkTypeDefault (rADT [(mkVariant "Nil" [] 0) (mkVariant "Cons" [tInt] 1)] false) KStar;
    in mkTypeDefault (rMu "lst"  body) KStar;

  tList2 =
    let
      body = mkTypeDefault (rADT [(mkVariant "Nil" [] 0) (mkVariant "Cons" [tInt] 1)] false) KStar;
    in mkTypeDefault (rMu "list" body) KStar;

  # Phase 3.2：两者 unify 成功（bisimulation，alpha-canonical 失败的情况）
  muUnifyResult = unify {} tList1 tList2;   # { ok = true; ... }

  # ── Specificity-based instance selection ──────────────────────────────────
  tAVar  = mkTypeDefault (rVar "a" "inst") KStar;
  db0    = emptyInstanceDB;
  db1    = ts.register db0 "Eq" [tAVar] { generic = true; };   # specificity=0
  db2    = ts.register db1 "Eq" [tInt]  { concrete = true; };  # specificity=1
  # 解析 Eq Int → 选 concrete（specificity=1 > 0）
  resolved = resolveWithFallback db2 ts.defaultClassGraph "Eq" [tInt];
  # resolved.impl.concrete == true ✓

  # ── Row canonical：不同顺序 → 相同 NF hash ───────────────────────────────
  mkRow = lbl: ft: rest:
    mkTypeDefault { __variant = "RowExtend"; label = lbl; fieldType = ft; rest = rest; } ts.KRow;
  tEnd  = mkTypeDefault { __variant = "RowEmpty"; } ts.KRow;
  rowBA = mkRow "b" tBool (mkRow "a" tInt tEnd);   # b | a | ()
  rowAB = mkRow "a" tInt  (mkRow "b" tBool tEnd);  # a | b | ()
  hashEq = typeHash (normalize rowBA) == typeHash (normalize rowAB);  # true ✓

  # ── Bidirectional check with full substitution ──────────────────────────
  # Π(n:Int).Int  ←→  lambda application
  tPiIntInt = mkTypeDefault (ts.rPi "n" tInt tInt) KStar;
  termId    = tLam "x" (tVar "x");
  typFn     = mkTypeDefault (rFn tInt tInt) KStar;
  checkOk   = check emptyCtx termId typFn;   # { ok = true; ... }

in {
  inherit muUnifyResult resolved hashEq checkOk;
  invariants = ts.verifyInvariants {};
}
```

---

## 关键设计决策（ADR 汇总）

| ADR   | 决策                              | 原因                                         |
| ----- | --------------------------------- | -------------------------------------------- |
| ADR-1 | `eqStrategy` 不影响 equality 路径 | INV-3 要求单一 canonical equality            |
| ADR-2 | split fuel 三路（beta/depth/mu）  | mu-unfold 不被 beta fuel 耗尽误停            |
| ADR-3 | `_resolveViaSuper` 返回真实 impl  | 返回 null 导致 soundness bug                 |
| ADR-4 | serialize 使用 de Bruijn index    | α-equivalent 类型得到相同 hash               |
| ADR-5 | Kahn in-degree = revEdges 长度    | 原实现方向反转，topo sort 错误               |
| ADR-6 | Mu bisimulation 用 guard set      | equi-recursive 语义需 coinductive hypothesis |
| ADR-7 | Specificity-based instance 选择   | 具体 `Eq Int` 优先于泛化 `Eq a`              |
| ADR-8 | Row canonical via spine unspine   | RowExtend 不同顺序 → 相同 NF                 |
| ADR-9 | `_substTypeInType` 委托 substLib  | capture-safe 替换语义不应重复实现            |
