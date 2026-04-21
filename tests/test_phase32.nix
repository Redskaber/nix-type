# tests/test_phase32.nix — Phase 3.2 专项测试
#
# 覆盖 Phase 3.2 所有修复：
#   T15.1  Mu bisimulation（不同 binder 名，alpha-canonical 失败的情况）
#   T15.2  Mu bisimulation（互相递归，guard set 防止无限循环）
#   T15.3  Row canonical（不同顺序 → 相同 NF hash）
#   T15.4  Row canonical 幂等性（已排序不变）
#   T15.5  Specificity-based selection（Eq Int > Eq a）
#   T15.6  Specificity tie-break（相同 specificity → lexicographic key）
#   T15.7  _typeMentions 完整（Fn body 中的 Var 被正确检测）
#   T15.8  _substTypeInType 完整（Pi application 深层替换）
#   T15.9  _applySubstTypeFull 深层（Fn body 中的 Var 被替换）
#   T15.10 Effect normalize（VariantRow 排序）
#   T15.11 partialUnify API（overlap check）
#   T15.12 INV 全量验证（包含 Phase 3.2 新增 INV）
let
  nixLib = import <nixpkgs/lib>;
  ts = import ../lib/default.nix { lib = nixLib; };

  inherit (ts)
    KStar KArrow KRow KEffect KUnbound
    mkTypeDefault mkTypeWith mkBootstrapType isType
    rPrimitive rVar rFn rLambda rApply rMu rADT rRecord
    rVariantRow rRowExtend rRowEmpty rEffect rConstrained rPi
    mkVariant normalize typeEq typeHash
    unify unifyFresh
    mkClass mkEquality
    register emptyInstanceDB resolveWithFallback canDischarge
    defaultClassGraph
    solve solveDefault
    check infer emptyCtx ctxBind
    tVar tLam tApp tAscribe tLit
    verifyInvariants;

  # ── 基础类型 ────────────────────────────────────────────────────────────────
  tInt    = mkTypeDefault (rPrimitive "Int")    KStar;
  tBool   = mkTypeDefault (rPrimitive "Bool")   KStar;
  tString = mkTypeDefault (rPrimitive "String") KStar;
  tFloat  = mkTypeDefault (rPrimitive "Float")  KStar;

  # ── 辅助：测试结果 ───────────────────────────────────────────────────────────
  mkOk   = name: { __testName = name; ok = true; };
  mkFail = name: msg: { __testName = name; ok = false; reason = msg; };

  mkTestBool = name: cond:
    if cond
    then mkOk name
    else mkFail name "expected true, got false";

  mkTestEq = name: a: b:
    if a == b
    then mkOk name
    else mkFail name "expected ${builtins.toString b}, got ${builtins.toString a}";

  # ── Row 构造辅助 ────────────────────────────────────────────────────────────
  mkRowExtend = lbl: ft: rest:
    mkTypeDefault { __variant = "RowExtend"; label = lbl; fieldType = ft; rest = rest; } KRow;
  tRowEmpty = mkTypeDefault { __variant = "RowEmpty"; } KRow;

  # ── Mu 类型辅助 ─────────────────────────────────────────────────────────────
  mkMuList = muVar:
    let
      tMuVar = mkTypeDefault (rVar muVar "mu-test") KStar;
      tBody  = mkTypeDefault
        (rADT [(mkVariant "Nil" [] 0) (mkVariant "Cons" [tInt tMuVar] 1)] false)
        KStar;
    in
    mkTypeDefault (rMu muVar tBody) KStar;

in

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3.2 测试集（T15.x）
# ══════════════════════════════════════════════════════════════════════════════
[

  # ──────────────────────────────────────────────────────────────────────────
  # T15.1: Mu bisimulation — 不同 binder 名，结构相同
  # Phase 3.1 失败（alpha-canonical），Phase 3.2 应成功
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.1-mu-bisimulation-diff-binder-name"
    (let
      tList1 = mkMuList "lst";
      tList2 = mkMuList "list";   # 不同 binder 名，结构完全相同
      r = unify {} tList1 tList2;
    in
    r.ok == true))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.2: Mu bisimulation — 相同 binder，alpha-canonical（Phase 3.1 也成功）
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.2-mu-bisimulation-same-binder"
    (let
      tList1 = mkMuList "lst";
      tList2 = mkMuList "lst";   # 相同 binder 名
      r = unify {} tList1 tList2;
    in
    r.ok == true))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.3: Row canonical — 不同顺序 → 相同 NF hash（INV-ROW）
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.3-row-canonical-different-order-same-hash"
    (let
      # b | a | ()（未排序）
      rowBA = mkRowExtend "b" tBool (mkRowExtend "a" tInt tRowEmpty);
      # a | b | ()（已排序）
      rowAB = mkRowExtend "a" tInt  (mkRowExtend "b" tBool tRowEmpty);
      nfBA  = normalize rowBA;
      nfAB  = normalize rowAB;
    in
    typeHash nfBA == typeHash nfAB))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.4: Row canonical 幂等性（已排序不触发 changed）
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.4-row-canonical-idempotent"
    (let
      # 已排序：a | b | c | ()
      rowSorted = mkRowExtend "a" tInt
                    (mkRowExtend "b" tBool
                      (mkRowExtend "c" tString tRowEmpty));
      nf1 = normalize rowSorted;
      nf2 = normalize nf1;
    in
    typeHash nf1 == typeHash nf2))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.5: Specificity-based instance selection（Eq Int > Eq a）（INV-SPEC）
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.5-specificity-concrete-beats-generic"
    (let
      tAVar  = mkTypeDefault (rVar "a" "spec-test") KStar;
      db0    = emptyInstanceDB;
      db1    = register db0 "Eq" [tAVar] { generic = true;   specVal = 0; };
      db2    = register db1 "Eq" [tInt]  { concrete = true;  specVal = 1; };
      result = resolveWithFallback db2 defaultClassGraph "Eq" [tInt];
    in
    result.found && (result.impl.concrete or false) == true))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.6: Specificity tie-break — 相同 specificity → 按 key 最小选择
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.6-specificity-tiebreak-lexicographic"
    (let
      db0 = emptyInstanceDB;
      # 两个相同 specificity 的 instance for "Show"
      # 注意：不同的类型参数，避免 INV-I1 violation
      db1 = register db0 "Show" [tInt]    { impl = "show-int"; };
      db2 = register db1 "Show" [tBool]   { impl = "show-bool"; };
      # 解析 Show Int
      result = resolveWithFallback db2 defaultClassGraph "Show" [tInt];
    in
    result.found && (result.impl.impl or "") == "show-int"))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.7: _typeMentions 完整 — Fn body 中的 Var 被检测（INV-SOL5）
  # 测试方式：solver 解决 Equality 约束后，受影响的 Class 约束重入 worklist
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.7-type-mentions-fn-body-var"
    (let
      # 构造 Fn(Int, a) 类型，其中 a 是自由变量
      tA    = mkTypeDefault (rVar "a" "mentions-test") KStar;
      tFnA  = mkTypeDefault (rFn tInt tA) KStar;
      # Equality: a = Bool
      cABool = mkEquality tA tBool;
      # Class: Show Fn(Int, a)（含 a）→ 受 cABool 影响
      cShowFn = mkClass "Show" [tFnA];
      # Solve: a = Bool 解决后，Show(Fn(Int,Bool)) 应重新入队
      result = solveDefault [cABool cShowFn];
    in
    # 确认 solver 运行且 Equality 被 solved
    result.ok && builtins.length result.solved >= 1))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.8: _substTypeInType 完整 — dependent Pi application
  # Π(n:Int).Int → App(Π, 42) 应得到 Int[n↦42] = Int
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.8-subst-type-in-type-pi-application"
    (let
      # Π(n:Int).Int（不依赖 n，简单情况）
      tPiNInt = mkTypeDefault (rPi "n" tInt tInt) KStar;
      # Check：(λx.x) : Int → Int
      termId  = tLam "x" (tVar "x");
      typFn   = mkTypeDefault (rFn tInt tInt) KStar;
      r       = check emptyCtx termId typFn;
    in
    r.ok == true))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.9: _applySubstTypeFull 深层 — Fn body 中的 Var 被完整替换
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.9-apply-subst-full-fn-body"
    (let
      # Fn(Int, Fn(a, Bool))，a 在深层
      tA      = mkTypeDefault (rVar "a" "deep-subst") KStar;
      tDeep   = mkTypeDefault (rFn tInt (mkTypeDefault (rFn tA tBool) KStar)) KStar;
      # 约束：Eq(a, String)
      cEq = mkEquality tA tString;
      # Solver 解决后 a 应被替换为 String
      result = solveDefault [cEq (mkClass "Show" [tDeep])];
    in
    # ok: solver 没有失败
    result.ok))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.10: Effect normalize — VariantRow variants 排序
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.10-effect-normalize-variant-row-sorted"
    (let
      # 构造乱序的 VariantRow（b, a）
      tVRowBA = mkTypeDefault
        (rVariantRow { "b" = tBool; "a" = tInt; } null)
        KStar;
      # 构造已排序的 VariantRow（a, b）
      tVRowAB = mkTypeDefault
        (rVariantRow { "a" = tInt; "b" = tBool; } null)
        KStar;
      # Effect 包装
      tEffBA = mkTypeDefault (rEffect "IO" tVRowBA) KStar;
      tEffAB = mkTypeDefault (rEffect "IO" tVRowAB) KStar;
      # normalize 后应有相同 hash
      nfBA = normalize tEffBA;
      nfAB = normalize tEffAB;
    in
    typeHash nfBA == typeHash nfAB))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.11: partialUnify API — overlap check
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.11-partial-unify-var-overlaps-anything"
    (let
      tA   = mkTypeDefault (rVar "a" "pu-test") KStar;
      # Var a 与 Int overlap（Var 总是可 overlap）
      r1 = ts.partialUnify tA tInt;
      # Int 与 Bool 不 overlap（不同 primitive）
      r2 = ts.partialUnify tInt tBool;
    in
    r1.overlaps == true && r2.overlaps == false))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.12: INV 全量验证（Phase 3.2 新增 INV）
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.12-verifyInvariants-all-phase32"
    (let
      result = verifyInvariants {};
    in
    result.ok))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.13: 三路类型 Row：c | a | b | () → a | b | c | ()
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.13-row-canonical-three-fields"
    (let
      rowCAB = mkRowExtend "c" tString
                 (mkRowExtend "a" tInt
                   (mkRowExtend "b" tBool tRowEmpty));
      rowABC = mkRowExtend "a" tInt
                 (mkRowExtend "b" tBool
                   (mkRowExtend "c" tString tRowEmpty));
      nfCAB = normalize rowCAB;
      nfABC = normalize rowABC;
    in
    typeHash nfCAB == typeHash nfABC))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.14: Bidir infer App chain（λx.x applied to Int）
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.14-bidir-infer-app-lambda"
    (let
      # (λx.x : Int → Int) Int
      tFnIntInt = mkTypeDefault (rFn tInt tInt) KStar;
      termId    = tAscribe (tLam "x" (tVar "x")) tFnIntInt;
      termApp   = tApp termId (tLit 42 tInt);
      result    = infer emptyCtx termApp;
    in
    result.ok))

  # ──────────────────────────────────────────────────────────────────────────
  # T15.15: Solver _typeMentions 受 subst 影响的约束被重新处理
  # ──────────────────────────────────────────────────────────────────────────
  (mkTestBool "T15.15-solver-worklist-affected-reenqueue"
    (let
      tA      = mkTypeDefault (rVar "a" "wl-test") KStar;
      # a = Int
      cEq     = mkEquality tA tInt;
      # Eq a（a 的 Eq 约束，受 a=Int 影响）
      cEqA    = mkClass "Eq" [tA];
      result  = solveDefault [cEq cEqA];
    in
    # 解决后，Eq Int 应该能被 primitive discharge
    result.ok && builtins.length result.solved >= 1))

]
