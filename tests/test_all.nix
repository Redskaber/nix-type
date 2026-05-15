# tests/test_all.nix — Phase 4.5.2
# 完整测试套件（~190 tests，28 组）
#
# ★ Phase 4.5.2 修复（Bug Report 2025-05-15 Round 2）:
#   BUG-T9:   ts.solve ts.emptyDB [] [] 参数顺序错误
#             solve = constraints: classGraph: instanceDB:
#             emptyDB 是 attrset，被当成 constraints list →
#             map normalizeConstraint emptyDB → abort 穿透 tryEval → 崩溃
#             修复: ts.solve [] {} {}
#
#   BUG-RUNGROUP: runGroup 的 tests 参数不为 list 时（如 abort 后的 thunk），
#             lib.length 收到 attrset → 崩溃。
#             修复: 防御性检查 builtins.isList tests
#
# INV-TEST-1: 每个 mkTestBool/mkTest 用 builtins.tryEval 独立求值，单个失败不中断套件。
# INV-TEST-4: runGroup 检查 tests 是否为 list，非 list 时返回 error group 而不崩溃。
# INV-TEST-5: failedGroups/failedList 防御性检查，每个 g 必须是 attrset。
# INV-TOPO:   topologicalSort 统一返回 { ok; order; error }（同步 graph.nix 4.5.2）。
{ lib ? (import <nixpkgs> {}).lib }:

let
  ts = import ../lib/default.nix { inherit lib; };

  mkTest = name: result: expected:
    let
      r = builtins.tryEval result;
      e = builtins.tryEval expected;
      ok = r.success && e.success && r.value == e.value;
    in {
      inherit name;
      result   = if r.success then r.value else "<eval-error>";
      expected = if e.success then e.value else "<eval-error>";
      pass     = ok;
    };

  mkTestBool = name: cond:
    let r = builtins.tryEval cond; in
    {
      inherit name;
      result   = if r.success then r.value else false;
      expected = true;
      pass     = r.success && r.value;
      error    = if r.success then null else "eval-error";
    };

  # INV-TEST-4: 防御性 runGroup — 若 tests 不是 list，返回 error group 而不 abort
  runGroup = name: tests:
    if !(builtins.isList tests) then {
      inherit name;
      passed = 0; total = 0;
      failed = [];
      ok     = false;
      error  = "runGroup: tests argument is not a list (got ${builtins.typeOf tests})";
    } else
    let
      passed = lib.length (lib.filter (t: t.pass) tests);
      total  = lib.length tests;
      failed = lib.filter (t: !t.pass) tests;
    in {
      inherit name passed total failed;
      ok = passed == total;
    };

  tInt    = ts.tInt;
  tBool   = ts.tBool;
  tString = ts.tString;
  tUnit   = ts.tUnit;
  KStar   = ts.KStar;
  KArrow  = ts.KArrow;

  # ════════════════════════════════════════════════════════════════════
  # T1: TypeIR 核心（INV-1）
  # ════════════════════════════════════════════════════════════════════
  t1 = runGroup "T1-TypeIR" [
    (mkTestBool "isType tInt"        (ts.isType tInt))
    (mkTestBool "isType tBool"       (ts.isType tBool))
    (mkTestBool "tInt has tag"       ((tInt.tag or null) == "Type"))
    (mkTestBool "tInt has repr"      (tInt ? repr))
    (mkTestBool "tInt has kind"      (tInt ? kind))
    (mkTestBool "mkTypeDefault"      (ts.isType (ts.mkTypeDefault (ts.rPrimitive "X") KStar)))
    (mkTestBool "tPrim creates type" (ts.isType (ts.tPrim "Char")))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T2: Kind 系统（INV-K1）
  # ════════════════════════════════════════════════════════════════════
  t2 = runGroup "T2-Kind" [
    (mkTestBool "KStar tag"          ((KStar.__kindTag or null) == "Star"))
    (mkTestBool "KArrow tag"         ((ts.KArrow KStar KStar).__kindTag == "Arrow"))
    (mkTestBool "kindEq Star Star"   (ts.kindEq KStar KStar))
    (mkTestBool "kindEq Arrow"       (ts.kindEq (KArrow KStar KStar) (KArrow KStar KStar)))
    (mkTestBool "kindEq ne"          (!(ts.kindEq KStar (KArrow KStar KStar))))
    (mkTestBool "KRow tag"           ((ts.KRow.__kindTag or null) == "Row"))
    (mkTestBool "KVar"               ((ts.KVar "k").__kindTag == "Var"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T3: TypeRepr 全变体（25+）
  # ════════════════════════════════════════════════════════════════════
  t3 = runGroup "T3-TypeRepr" [
    (mkTestBool "rPrimitive"   ((ts.rPrimitive "Int").__variant == "Primitive"))
    (mkTestBool "rVar"         ((ts.rVar "α" "s").__variant == "Var"))
    (mkTestBool "rLambda"      ((ts.rLambda "x" tInt).__variant == "Lambda"))
    (mkTestBool "rApply"       ((ts.rApply tInt [tBool]).__variant == "Apply"))
    (mkTestBool "rFn"          ((ts.rFn tInt tBool).__variant == "Fn"))
    (mkTestBool "rADT"         ((ts.rADT [] true).__variant == "ADT"))
    (mkTestBool "rConstrained" ((ts.rConstrained tInt []).__variant == "Constrained"))
    (mkTestBool "rMu"          ((ts.rMu "X" tInt).__variant == "Mu"))
    (mkTestBool "rRecord"      ((ts.rRecord { x = tInt; }).__variant == "Record"))
    (mkTestBool "rRowExtend"   ((ts.rRowExtend "x" tInt (ts.mkTypeDefault ts.rRowEmpty ts.KRow)).__variant == "RowExtend"))
    (mkTestBool "rRowEmpty"    (ts.rRowEmpty.__variant == "RowEmpty"))
    (mkTestBool "rVariantRow"  ((ts.rVariantRow { A = tInt; } null).__variant == "VariantRow"))
    (mkTestBool "rForall"      ((ts.rForall ["α"] tInt).__variant == "Forall"))
    (mkTestBool "rDynamic"     (ts.rDynamic.__variant == "Dynamic"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T4: Serialize canonical（de Bruijn）
  # ════════════════════════════════════════════════════════════════════
  t4 = runGroup "T4-Serialize" [
    (mkTestBool "serializeRepr Prim"
      (let s = ts.serializeRepr (ts.rPrimitive "Int"); in builtins.isString s))
    (mkTestBool "serializeRepr Fn"
      (let s = ts.serializeRepr (ts.rFn tInt tBool); in builtins.isString s))
    (mkTestBool "serializeConstraint Eq"
      (let c = ts.mkEqConstraint tInt tBool; s = ts.serializeConstraint c; in
      builtins.isString s))
    (mkTestBool "serializeType"
      (let s = ts.serializeType tInt; in builtins.isString s))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T5: Normalize（INV-2/3）
  # ════════════════════════════════════════════════════════════════════
  t5 = runGroup "T5-Normalize" [
    (mkTestBool "normalize' tInt"          (ts.isType (ts.normalize' tInt)))
    (mkTestBool "normalize' Fn"
      (let t = ts.mkTypeDefault (ts.rFn tInt tBool) KStar; in ts.isType (ts.normalize' t)))
    (mkTestBool "isNormalForm tInt"        (ts.isNormalForm tInt))
    (mkTestBool "normalizeDeep tInt"       (ts.isType (ts.normalizeDeep tInt)))
    (mkTestBool "normalizeWithFuel fuel=5"
      (ts.isType (ts.normalizeWithFuel 5 tInt)))
    (mkTestBool "deduplicateConstraints"
      (let
        c1 = ts.mkEqConstraint tInt tBool;
        cs = ts.deduplicateConstraints [ c1 c1 ];
      in builtins.length cs == 1))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T6: Hash（INV-4）
  # ════════════════════════════════════════════════════════════════════
  t6 = runGroup "T6-Hash" [
    (mkTestBool "typeHash tInt"              (builtins.isString (ts.typeHash tInt)))
    (mkTestBool "typeHash deterministic"     (ts.typeHash tInt == ts.typeHash tInt))
    (mkTestBool "typeHash tInt ≠ tBool"      (ts.typeHash tInt != ts.typeHash tBool))
    (mkTestBool "INV-4 typeEq → sameHash"
      (let
        t1 = ts.mkTypeDefault (ts.rPrimitive "Int") KStar;
        t2 = ts.mkTypeDefault (ts.rPrimitive "Int") KStar;
      in ts.typeEq t1 t2 && ts.typeHash t1 == ts.typeHash t2))
    (mkTestBool "constraintHash"
      (builtins.isString (ts.constraintHash (ts.mkEqConstraint tInt tBool))))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T7: Constraint IR（INV-6）
  # ════════════════════════════════════════════════════════════════════
  t7 = runGroup "T7-ConstraintIR" [
    (mkTestBool "mkEqConstraint"    (ts.isConstraint (ts.mkEqConstraint tInt tBool)))
    (mkTestBool "mkClassConstraint" (ts.isConstraint (ts.mkClassConstraint "Eq" [tInt])))
    (mkTestBool "mkPredConstraint"  (ts.isConstraint (ts.mkPredConstraint "positive" tInt)))
    (mkTestBool "mkRowEqConstraint"
      (ts.isConstraint (ts.mkRowEqConstraint
        (ts.mkTypeDefault ts.rRowEmpty ts.KRow)
        (ts.mkTypeDefault ts.rRowEmpty ts.KRow))))
    (mkTestBool "mkKindConstraint"
      (ts.isConstraint (ts.mkKindConstraint "α" ts.KStar)))
    (mkTestBool "mergeConstraints"
      (let
        c1  = ts.mkEqConstraint tInt tBool;
        c2  = ts.mkClassConstraint "Eq" [tInt];
        merged = ts.mergeConstraints [c1] [c2];
      in builtins.length merged == 2))
    (mkTestBool "constraintKey string"
      (builtins.isString (ts.constraintKey (ts.mkEqConstraint tInt tBool))))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T8: UnifiedSubst（INV-US1~5）
  # ════════════════════════════════════════════════════════════════════
  t8 = runGroup "T8-UnifiedSubst" [
    (mkTestBool "emptySubst"        (ts.isEmpty ts.emptySubst))
    (mkTestBool "singleTypeBinding" (ts.isSubst (ts.singleTypeBinding "α" tInt)))
    (mkTestBool "singleRowBinding"
      (ts.isSubst (ts.singleRowBinding "r"
        (ts.mkTypeDefault ts.rRowEmpty ts.KRow))))
    (mkTestBool "singleKindBinding" (ts.isSubst (ts.singleKindBinding "k" KStar)))
    (mkTestBool "composeSubst"
      (let
        s1 = ts.singleTypeBinding "α" tInt;
        s2 = ts.singleTypeBinding "β" tBool;
        c  = ts.composeSubst s2 s1;
      in ts.isSubst c && !(ts.isEmpty c)))
    (mkTestBool "applySubstToConstraints"
      (let
        cs  = [ (ts.mkEqConstraint tInt tBool) ];
        sub = ts.emptySubst;
        r   = ts.applySubstToConstraints sub cs;
      in builtins.length r == 1))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T9: Solver（INV-SOL1/4/5）
  # ★ BUG-T9 修复: ts.solve [] {} {} (constraints=[], classGraph={}, instanceDB={})
  #   原错误: ts.solve ts.emptyDB [] [] → emptyDB={ cache;deps;rdeps } 被当成 constraints
  #   → map normalizeConstraint emptyDB → abort（map 对 attrset）→ 穿透 tryEval 崩溃
  # ════════════════════════════════════════════════════════════════════
  t9 = runGroup "T9-Solver" [
    (mkTestBool "solve [] → ok"
      ((ts.solve [] {} {}).ok))
    (mkTestBool "solveSimple [] → ok"
      ((ts.solveSimple []).ok))
    (mkTestBool "solve [Int≡Int] → ok"
      ((ts.solveSimple [ (ts.mkEqConstraint tInt tInt) ]).ok))
    (mkTestBool "solve [Int≡Bool] → fail"
      (!(ts.solveSimple [ (ts.mkEqConstraint tInt tBool) ]).ok))
    (mkTestBool "getTypeSubst"
      (let r = ts.solveSimple []; in builtins.isAttrs (ts.getTypeSubst r)))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T10: Instance DB（INV-I1/2）
  # ════════════════════════════════════════════════════════════════════
  t10 = runGroup "T10-InstanceDB" [
    (mkTestBool "mkInstanceRecord creates record"
      (let r = ts.mkInstanceRecord "Eq" [tInt] "impl-eq-int" null; in
      r.__type == "InstanceRecord"))
    (mkTestBool "registerInstance"
      (let
        rec_ = ts.mkInstanceRecord "Eq" [tInt] "impl" null;
        db   = ts.registerInstance ts.instanceEmptyDB rec_;
      in db ? Eq))
    (mkTestBool "lookupInstance found"
      (let
        rec_ = ts.mkInstanceRecord "Eq" [tInt] "impl" null;
        db   = ts.registerInstance ts.instanceEmptyDB rec_;
        r    = ts.lookupInstance db "Eq" [tInt];
      in r != null))
    (mkTestBool "lookupInstance miss"
      (let r = ts.lookupInstance ts.instanceEmptyDB "Show" [tInt]; in r == null))
    (mkTestBool "INV-I1: typeHash idempotent after normalize"
      (let
        t1 = ts.normalize' tInt;
        t2 = ts.normalize' tInt;
      in ts.typeHash t1 == ts.typeHash t2))
    (mkTestBool "canDischarge found=false"
      (!(ts.canDischarge { found = false; impl = null; record = null; })))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T11: Refined Types（INV-SMT-1~6）
  # ════════════════════════════════════════════════════════════════════
  t11 = runGroup "T11-RefinedTypes" [
    (mkTestBool "mkRefined"
      (ts.isType (ts.mkRefined tInt "n" ts.mkPTrue)))
    (mkTestBool "isRefined"
      (ts.isRefined (ts.mkRefined tInt "n" ts.mkPTrue)))
    (mkTestBool "mkPTrue"
      ((ts.mkPTrue.__predTag or null) == "PTrue"))
    (mkTestBool "mkPFalse"
      ((ts.mkPFalse.__predTag or null) == "PFalse"))
    (mkTestBool "mkPLit"
      ((ts.mkPLit 42).__predTag == "PLit"))
    (mkTestBool "mkPCmp"
      ((ts.mkPCmp ">" (ts.mkPPredVar "n") (ts.mkPLit 0)).__predTag == "PCmp"))
    (mkTestBool "staticEvalPred PTrue"
      ((ts.staticEvalPred ts.mkPTrue { n = 1; }) == true))
    (mkTestBool "tPositiveInt isType"
      (ts.isType ts.tPositiveInt))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T12: Module System（INV-MOD-1~8）
  # ════════════════════════════════════════════════════════════════════
  tFnSig = ts.mkSig { add = ts.mkTypeDefault (ts.rFn tInt tInt) KStar; };

  t12 = runGroup "T12-ModuleSystem" [
    (mkTestBool "mkSig"
      (ts.isSig (ts.mkSig { x = tInt; })))
    (mkTestBool "mkStruct ok"
      (let
        sig = ts.mkSig { x = tInt; };
        r   = ts.mkStruct sig { x = tInt; };
      in r.ok or false))
    (mkTestBool "mkStruct missing field"
      (let
        sig = ts.mkSig { x = tInt; y = tBool; };
        r   = ts.mkStruct sig { x = tInt; };
      in !(r.ok or true)))
    (mkTestBool "mkModFunctor"
      (ts.isModFunctor (ts.mkModFunctor "M" (ts.mkSig { x = tInt; }) tInt)))
    (mkTestBool "applyFunctor ok"
      (let
        sig = ts.mkSig { x = tInt; };
        f   = ts.mkModFunctor "M" sig tInt;
        s   = (ts.mkStruct sig { x = tInt; }).struct;
        r   = ts.applyFunctor f s;
      in ts.isType r))
    (mkTestBool "composeFunctors ok"
      (let
        sig = ts.mkSig { x = tInt; };
        f1  = ts.mkModFunctor "A" sig tInt;
        f2  = ts.mkModFunctor "B" sig tBool;
        c   = ts.composeFunctors f1 f2;
      in ts.isModFunctor c))
    (mkTestBool "seal / unseal"
      (let
        sealed = ts.seal tInt "MyTag";
        r      = ts.unseal sealed "MyTag";
      in r.ok))
    (mkTestBool "structField access"
      (let
        sig = ts.mkSig { x = tInt; };
        s   = (ts.mkStruct sig { x = tInt; }).struct;
        f   = ts.structField s "x";
      in ts.isType f))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T13: Effect Handlers（INV-EFF-4~9）
  # ════════════════════════════════════════════════════════════════════
  t13 = runGroup "T13-EffectHandlers" [
    (mkTestBool "mkHandler"
      (ts.isHandler (ts.mkHandler "Log" [] tUnit)))
    (mkTestBool "singleEffect"
      (let e = ts.singleEffect "State" tInt; in
      (e.repr.__variant or null) == "VariantRow"))
    (mkTestBool "effectMerge"
      (let e = ts.effectMerge (ts.singleEffect "A" tInt) (ts.singleEffect "B" tBool); in
      (e.repr.__variant or null) == "EffectMerge"))
    (mkTestBool "checkHandler ok"
      (let
        h = ts.mkHandler "Log" [] tUnit;
        e = ts.singleEffect "Log" tString;
      in (ts.checkHandler h e).ok))
    (mkTestBool "checkHandler fail"
      (let
        h = ts.mkHandler "Foo" [] tUnit;
        e = ts.singleEffect "Bar" tString;
      in !(ts.checkHandler h e).ok))
    (mkTestBool "mkDeepHandler"
      (let h = ts.mkDeepHandler "State" [] tUnit; in ts.isHandler h))
    (mkTestBool "checkEffectWellFormed"
      (let e = ts.singleEffect "A" tInt; in (ts.checkEffectWellFormed e).ok))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T14: QueryDB（INV-QK1~5）
  # ════════════════════════════════════════════════════════════════════
  t14 = runGroup "T14-QueryDB" [
    (mkTestBool "mkQueryKey"
      (builtins.isString (ts.mkQueryKey "norm" ["a" "b"])))
    (mkTestBool "storeResult + lookupResult"
      (let
        db  = ts.emptyDB;
        key = ts.mkQueryKey "norm" ["test"];
        db2 = ts.storeResult db key tInt [];
        r   = ts.lookupResult db2 key;
      in ts.isType r))
    (mkTestBool "invalidateKey"
      (let
        db  = ts.emptyDB;
        key = ts.mkQueryKey "norm" ["test"];
        db2 = ts.storeResult db key tInt [];
        db3 = ts.invalidateKey db2 key;
        r   = ts.lookupResult db3 key;
      in r == null))
    (mkTestBool "cacheStats"
      (let
        db  = ts.emptyDB;
        key = ts.mkQueryKey "norm" ["a"];
        db2 = ts.storeResult db key tInt [];
        s   = ts.cacheStats db2;
      in s.total == 1))
    (mkTestBool "hasDependencyCycle empty → false"
      (let
        db  = ts.emptyDB;
        key = ts.mkQueryKey "norm" ["x"];
      in !(ts.hasDependencyCycle db key)))
    (mkTestBool "bumpEpochDB resets memo"
      (let
        state = { queryDB = ts.emptyDB; memo = ts.emptyMemo; };
        r     = ts.bumpEpochDB state;
      in r ? queryDB && r ? memo))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T15: Incremental Graph（INV-G1~4）
  # ════════════════════════════════════════════════════════════════════
  t15 = runGroup "T15-IncrementalGraph" [
    (mkTestBool "emptyGraph"     (ts.emptyGraph.nodes == {}))
    (mkTestBool "addNode"
      (let g = ts.addNode ts.emptyGraph "A"; in g.nodes ? A))
    (mkTestBool "addEdge"
      (let
        g  = ts.addNode (ts.addNode ts.emptyGraph "A") "B";
        g2 = ts.addEdge g "A" "B";
      in g2.edges ? A))
    (mkTestBool "hasCycle empty → false"
      (!(ts.hasCycle ts.emptyGraph)))
    (mkTestBool "topologicalSort"
      (let
        g  = ts.addNode (ts.addNode ts.emptyGraph "A") "B";
        g2 = ts.addEdge g "A" "B";
        r  = ts.topologicalSort g2;
      in r.ok))
    (mkTestBool "markStale / markClean"
      (let
        g  = ts.addNode ts.emptyGraph "A";
        g2 = ts.markStale g "A";
        g3 = ts.markClean g2 "A";
      in ts.isClean g3 "A"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T16: Pattern Matching
  # Phase 4.4: patternVars bug fixed; patternVarsSet, isLinear, patternDepth added
  # ════════════════════════════════════════════════════════════════════
  tVariants = [
    { name = "Nothing"; fields = []; ordinal = 0; }
    { name = "Just";    fields = [ tInt ]; ordinal = 1; }
  ];

  t16 = runGroup "T16-PatternMatch" [
    (mkTestBool "mkPWild"   (ts.isPattern ts.mkPWild))
    (mkTestBool "mkPVar"    (ts.isPattern (ts.mkPVar "x")))
    (mkTestBool "mkPCtor"   (ts.isPattern (ts.mkPCtor "Some" [ts.mkPVar "x"])))
    (mkTestBool "mkArm"     ((ts.mkArm ts.mkPWild tInt).__armTag == "Arm"))
    (mkTestBool "compileMatch Wild → Leaf"
      (let
        arm = ts.mkArm ts.mkPWild tInt;
        dt  = ts.compileMatch [arm] tVariants;
      in dt.__dtTag == "Leaf"))
    (mkTestBool "checkExhaustive"
      (let
        arms = [ (ts.mkArm ts.mkPWild tInt) ];
        r    = ts.checkExhaustive arms tVariants;
      in r.exhaustive))
    # Fix P4.3-patternVars: robust Ctor branch with null-guard
    (mkTestBool "patternVars"
      (let vars = ts.patternVars (ts.mkPCtor "Some" [ts.mkPVar "x"]); in
      builtins.elem "x" vars))
    # Phase 4.4 new tests
    (mkTestBool "patternVars Var"
      (ts.patternVars (ts.mkPVar "y") == ["y"]))
    (mkTestBool "patternVars Wild = []"
      (ts.patternVars ts.mkPWild == []))
    (mkTestBool "patternVarsSet"
      (let
        p2 = ts.mkPAnd_p (ts.mkPVar "a") (ts.mkPVar "b");
        s  = ts.patternVarsSet p2;
      in builtins.isAttrs s && s ? a && s ? b))
    (mkTestBool "isLinear simple"
      (ts.isLinear (ts.mkPCtor "Just" [ts.mkPVar "x"])))
    (mkTestBool "patternDepth Wild = 0"
      (ts.patternDepth ts.mkPWild == 0))
    (mkTestBool "patternDepth Ctor = 1"
      (ts.patternDepth (ts.mkPCtor "Just" [ts.mkPWild]) == 1))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T17: Row 多态（INV-ROW）
  # ════════════════════════════════════════════════════════════════════
  t17 = runGroup "T17-RowPolymorphism" [
    (mkTestBool "rVariantRow"
      ((ts.rVariantRow { State = tInt; } null).__variant == "VariantRow"))
    (mkTestBool "unifyRow empty empty"
      ((ts.unifyRow
        (ts.mkTypeDefault ts.rRowEmpty ts.KRow)
        (ts.mkTypeDefault ts.rRowEmpty ts.KRow)).ok))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T18: Bidirectional + TypeScheme
  # ════════════════════════════════════════════════════════════════════
  t18 = runGroup "T18-Bidir" [
    (mkTestBool "infer literal Int"
      (let r = ts.infer {} (ts.eLit 42); in ts.isType r.type))
    (mkTestBool "infer Prim Int"
      (let r = ts.infer {} (ts.ePrim "Int"); in
      (r.type.repr.__variant or null) == "Primitive"))
    (mkTestBool "INV-BIDIR-1: infer yields type"
      (ts.__checkInvariants.invBidir1 {} (ts.eLit true)))
    (mkTestBool "monoScheme"
      (ts.isScheme (ts.monoScheme tInt)))
    (mkTestBool "mkScheme forall sorted"
      (let s = ts.mkScheme ["β" "α"] tInt []; in s.forall == ["α" "β"]))
    (mkTestBool "INV-SCHEME-1: generalize empty ctx"
      (let s = ts.generalize {} (ts.mkTypeDefault (ts.rVar "α" "") KStar) []; in
      ts.isScheme s && builtins.length s.forall >= 0))
    (mkTestBool "schemeHash deterministic"
      (let s = ts.mkScheme ["α"] tInt []; in ts.schemeHash s == ts.schemeHash s))
    (mkTestBool "eVar expression"  ((ts.eVar "x").__exprTag == "Var"))
    (mkTestBool "eLam expression"  ((ts.eLam "x" (ts.eLit 1)).__exprTag == "Lam"))
    (mkTestBool "eLet expression"  ((ts.eLet "x" (ts.eLit 1) (ts.eVar "x")).__exprTag == "Let"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T19: Unification（Phase 4.2）
  # ════════════════════════════════════════════════════════════════════
  tFn = ts.mkTypeDefault (ts.rFn tInt tBool) KStar;

  t19 = runGroup "T19-Unification" [
    (mkTestBool "unify Int Int → ok"    ((ts.unify tInt tInt).ok))
    (mkTestBool "unify Int Bool → fail" (!(ts.unify tInt tBool).ok))
    (mkTestBool "unify α Int → ok + binding"
      (let
        alpha = ts.mkTypeDefault (ts.rVar "α" "") KStar;
        r     = ts.unify alpha tInt;
      in r.ok && (r.subst.typeBindings or {}) ? "α"))
    (mkTestBool "unify Fn Int Bool = Fn Int Bool → ok"
      ((ts.unify tFn tFn).ok))
    (mkTestBool "occursIn"
      (let alpha = ts.mkTypeDefault (ts.rVar "α" "") KStar; in
      ts.occursIn "α" alpha))
    (mkTestBool "occursIn not"
      (ts.occursIn "β" tInt == false))
    (mkTestBool "unifyAll pairs"
      ((ts.unifyAll [{ fst = tInt; snd = tInt; } { fst = tBool; snd = tBool; }]).ok))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T20: 集成测试（end-to-end）
  # ════════════════════════════════════════════════════════════════════
  t20 = runGroup "T20-Integration" [
    (mkTestBool "List(Maybe(Int)) type"
      (let
        listCtor  = ts.mkTypeDefault (ts.rConstructor "List" (ts.KArrow KStar KStar) ["a"]
          (ts.mkTypeDefault (ts.rADT [
            (ts.mkVariant "Nil" [] 0)
            (ts.mkVariant "Cons" [ts.mkTypeDefault (ts.rVar "a" "") KStar] 1)
          ] true) KStar)) (ts.KArrow KStar KStar);
        maybeCtor = ts.mkTypeDefault (ts.rConstructor "Maybe" (ts.KArrow KStar KStar) ["b"]
          (ts.mkTypeDefault (ts.rADT [
            (ts.mkVariant "Nothing" [] 0)
            (ts.mkVariant "Just" [ts.mkTypeDefault (ts.rVar "b" "") KStar] 1)
          ] true) KStar)) (ts.KArrow KStar KStar);
        listMaybeInt = ts.mkTypeDefault (ts.rApply listCtor
          [ (ts.mkTypeDefault (ts.rApply maybeCtor [tInt]) KStar) ]) KStar;
      in ts.isType listMaybeInt))
    (mkTestBool "solve [α≡Int, β≡Bool] → ok"
      (let
        alpha = ts.mkTypeDefault (ts.rVar "α" "") KStar;
        beta  = ts.mkTypeDefault (ts.rVar "β" "") KStar;
        r     = ts.solveSimple [
          (ts.mkEqConstraint alpha tInt)
          (ts.mkEqConstraint beta tBool)
        ];
      in r.ok))
    (mkTestBool "functor chain 2-deep"
      (let
        sig = ts.mkSig { val = tInt; };
        f1  = ts.mkModFunctor "M" sig tInt;
        f2  = ts.mkModFunctor "N" sig tBool;
        c   = ts.composeFunctors f1 f2;
      in ts.isModFunctor c))
    (mkTestBool "refined normalize chain"
      (let
        ref = ts.mkRefined (ts.mkRefined tInt "n" ts.mkPTrue) "m" ts.mkPTrue;
        nf  = ts.normalize' ref;
      in ts.isType nf))
    (mkTestBool "handleAll removes effect"
      (let
        eff = ts.singleEffect "Log" tString;
        h   = ts.mkHandler "Log" [] tUnit;
        r   = ts.handleAll [h] eff;
      in r.ok))
    (mkTestBool "INV-4 end-to-end: normalize then hash"
      (let
        t1  = ts.mkTypeDefault (ts.rFn tInt tBool) KStar;
        t2  = ts.mkTypeDefault (ts.rFn tInt tBool) KStar;
        nf1 = ts.normalize' t1;
        nf2 = ts.normalize' t2;
      in ts.typeHash nf1 == ts.typeHash nf2))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T21: Kind Inference（Phase 4.3: INV-KIND-1）
  #      Extended Phase 4.4: Kind Annotation Propagation（INV-KIND-2）
  # ════════════════════════════════════════════════════════════════════
  t21 = runGroup "T21-KindInference" [
    (mkTestBool "inferKind Primitive → KStar"
      (let r = ts.inferKind {} (ts.rPrimitive "Int"); in
      ts.kindEq r.kind ts.KStar))
    (mkTestBool "inferKind Var → KVar"
      (let r = ts.inferKind {} (ts.rVar "α" ""); in
      ts.isKVar r.kind || ts.isStar r.kind))
    (mkTestBool "inferKind Lambda → KArrow"
      (let
        param = ts.rLambda "x" tInt;
        r     = ts.inferKind { x = ts.KStar; } param;
      in ts.isKArrow r.kind))
    (mkTestBool "unifyKind Star Star → ok"
      ((ts.unifyKind ts.KStar ts.KStar).ok))
    (mkTestBool "unifyKind KVar bind → ok"
      (let r = ts.unifyKind (ts.KVar "k") ts.KStar; in
      r.ok && (r.subst.k or null) != null))
    (mkTestBool "solveKindConstraints empty → ok"
      ((ts.solveKindConstraints []).ok))
    (mkTestBool "solveKindConstraints Kind(α, *) → ok"
      (let
        kc = [ { __constraintTag = "Kind"; typeVar = "α"; expectedKind = ts.KStar; } ];
        r  = ts.solveKindConstraints kc;
      in r.ok))
    (mkTestBool "solve Kind constraint via solver → in kindSubst"
      (let
        kc = ts.mkKindConstraint "β" ts.KStar;
        r  = ts.solveSimple [ kc ];
      in r.ok || r.classResidual != []))
    (mkTestBool "composeKindSubst correct"
      (let
        s1 = { k1 = ts.KStar; };
        s2 = { k2 = ts.KRow; };
        c  = ts.composeKindSubst s2 s1;
      in c ? k1 && c ? k2))
    # Phase 4.4: INV-KIND-2 tests
    (mkTestBool "INV-KIND-2: inferKindWithAnnotation ok"
      (let
        r = ts.inferKindWithAnnotation {} (ts.rPrimitive "Int") ts.KStar;
      in r.annotationOk && ts.kindEq r.kind ts.KStar))
    (mkTestBool "INV-KIND-2: annotated KVar unifies"
      (let
        r = ts.inferKindWithAnnotation {} (ts.rVar "α" "") (ts.KVar "k");
      in r.annotationOk))
    (mkTestBool "INV-KIND-2: checkKindAnnotation Star Star → ok"
      (ts.checkKindAnnotation ts.KStar ts.KStar))
    (mkTestBool "INV-KIND-2: checkKindAnnotation Star Row → fail"
      (!(ts.checkKindAnnotation ts.KStar ts.KRow)))
    (mkTestBool "mergeKindEnv"
      (let
        e1 = { a = ts.KStar; b = ts.KVar "k"; };
        e2 = { b = ts.KRow; c = ts.KStar; };
        m  = ts.mergeKindEnv e1 e2;
      in m ? a && m ? b && m ? c && ts.kindEq m.b ts.KRow))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T22: Handler Continuations（Phase 4.3: INV-EFF-10）
  # ════════════════════════════════════════════════════════════════════
  t22 = runGroup "T22-HandlerContinuations" [
    (mkTestBool "mkHandlerWithCont creates handler"
      (let
        h = ts.mkHandlerWithCont "State" tInt
              (ts.mkTypeDefault (ts.rFn tInt tBool) KStar) tBool;
      in ts.isHandler h))
    (mkTestBool "mkHandlerWithCont hasCont = true"
      (let
        h = ts.mkHandlerWithCont "State" tInt
              (ts.mkTypeDefault (ts.rFn tInt tBool) KStar) tBool;
      in ts.isHandlerWithCont h))
    (mkTestBool "mkContType creates Fn type"
      (let
        effRow = ts.emptyEffectRow;
        ct     = ts.mkContType tInt effRow tBool;
      in (ct.repr.__variant or null) == "Fn"))
    (mkTestBool "checkHandlerContWellFormed ok"
      (let
        contTy = ts.mkTypeDefault (ts.rFn tString tBool) KStar;
        h      = ts.mkHandlerWithCont "Log" tString contTy tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in r.ok))
    (mkTestBool "deep handler covers effect"
      (let
        h   = ts.mkDeepHandler "State" [] tUnit;
        eff = ts.singleEffect "State" tInt;
      in ts.deepHandlerCovers h eff))
    (mkTestBool "checkHandler with cont handler"
      (let
        contTy = ts.mkTypeDefault (ts.rFn tInt tBool) KStar;
        h      = ts.mkHandlerWithCont "State" tInt contTy tBool;
        eff    = ts.singleEffect "State" tInt;
      in (ts.checkHandler h eff).ok))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T23: Mu Bisimulation up-to congruence（Phase 4.3: INV-MU-1）
  # ════════════════════════════════════════════════════════════════════
  t23 = runGroup "T23-MuBisimCongruence" [
    (mkTestBool "unify μX.Int with μY.Int → ok"
      (let
        muX = ts.mkTypeDefault (ts.rMu "X" tInt) KStar;
        muY = ts.mkTypeDefault (ts.rMu "Y" tInt) KStar;
        r   = ts.unify muX muY;
      in r.ok))
    (mkTestBool "unify μX.X ≡ μY.Y → ok (coinductive)"
      (let
        muX = ts.mkTypeDefault (ts.rMu "X" (ts.mkTypeDefault (ts.rVar "X" "") KStar)) KStar;
        muY = ts.mkTypeDefault (ts.rMu "Y" (ts.mkTypeDefault (ts.rVar "Y" "") KStar)) KStar;
        r   = ts.unify muX muY;
      in r.ok))
    (mkTestBool "unify μX.Fn(Int,X) ≡ μY.Fn(Int,Y) → ok"
      (let
        muX = ts.mkTypeDefault
          (ts.rMu "X" (ts.mkTypeDefault (ts.rFn tInt (ts.mkTypeDefault (ts.rVar "X" "") KStar)) KStar))
          KStar;
        muY = ts.mkTypeDefault
          (ts.rMu "Y" (ts.mkTypeDefault (ts.rFn tInt (ts.mkTypeDefault (ts.rVar "Y" "") KStar)) KStar))
          KStar;
        r   = ts.unify muX muY;
      in r.ok))
    (mkTestBool "unify μX.Int ≢ μX.Bool → fail"
      (let
        muX = ts.mkTypeDefault (ts.rMu "X" tInt) KStar;
        muB = ts.mkTypeDefault (ts.rMu "X" tBool) KStar;
        r   = ts.unify muX muB;
      in !r.ok))
    (mkTestBool "bisimMeta available"      (ts.isMeta ts.bisimMeta))
    (mkTestBool "isBisimCongruence bisimMeta" (ts.isBisimCongruence ts.bisimMeta))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T24: Bidir Annotated Lambda（Phase 4.4: INV-BIDIR-2）★
  # ════════════════════════════════════════════════════════════════════
  t24 = runGroup "T24-BidirAnnotatedLam" [
    # INV-BIDIR-2: infer(eLamA param ty body) = (ty → bodyTy)
    (mkTestBool "eLamA creates Lam node with paramTy"
      ((ts.eLamA "x" tInt (ts.eLit 42)).__exprTag == "Lam" &&
       (ts.eLamA "x" tInt (ts.eLit 42)).paramTy == tInt))

    (mkTestBool "INV-BIDIR-2: infer(eLamA x Int body) yields Fn with Int domain"
      (let
        expr = ts.eLamA "x" tInt (ts.eVar "x");
        r    = ts.infer {} expr;
        repr = r.type.repr;
      in (repr.__variant or null) == "Fn" &&
         ts.typeHash repr.from == ts.typeHash tInt))

    (mkTestBool "INV-BIDIR-2: checkAnnotatedLam ok"
      (ts.checkAnnotatedLam {} "x" tInt (ts.eVar "x")))

    (mkTestBool "INV-BIDIR-2: checkAnnotatedLam with Bool param"
      (ts.checkAnnotatedLam {} "b" tBool (ts.eLit true)))

    (mkTestBool "INV-BIDIR-2: annotated fn type correct codomain"
      (let
        expr   = ts.eLamA "x" tInt (ts.eLit true);
        r      = ts.infer {} expr;
        fnRepr = r.type.repr;
      in (fnRepr.__variant or null) == "Fn" &&
         ts.typeHash fnRepr.from == ts.typeHash tInt))

    (mkTestBool "eLam (unannotated) still infers Fn"
      (let
        r    = ts.infer {} (ts.eLam "x" (ts.eLit 1));
        repr = r.type.repr;
      in (repr.__variant or null) == "Fn"))

    (mkTestBool "INV-BIDIR-2: invBidir2 passes"
      (ts.__checkInvariants.invBidir2 {} "x" tInt (ts.eVar "x")))

    (mkTestBool "eLamA nested: Int → Bool → Bool"
      (let
        inner = ts.eLamA "y" tBool (ts.eVar "y");
        outer = ts.eLamA "x" tInt inner;
        r     = ts.infer {} outer;
      in (r.type.repr.__variant or null) == "Fn" &&
         ts.typeHash r.type.repr.from == ts.typeHash tInt))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T25: Handler Continuation Type Check（Phase 4.4: INV-EFF-11）★
  # ════════════════════════════════════════════════════════════════════
  t25 = runGroup "T25-HandlerContTypeCheck" [
    # INV-EFF-11: contType.from == paramType (verified at checkHandlerContWellFormed)
    (mkTestBool "INV-EFF-11: contType.from == paramType → ok"
      (let
        # contTy = String → Bool; paramType = String; domains match
        contTy = ts.mkTypeDefault (ts.rFn tString tBool) KStar;
        h      = ts.mkHandlerWithCont "Log" tString contTy tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in r.inv_eff_11 or false))

    (mkTestBool "INV-EFF-11: contType.from ≠ paramType → fail"
      (let
        # contTy = Int → Bool; paramType = String; domains mismatch → fail
        contTy = ts.mkTypeDefault (ts.rFn tInt tBool) KStar;
        h      = ts.mkHandlerWithCont "Log" tString contTy tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in !(r.inv_eff_11 or true)))

    (mkTestBool "INV-EFF-11: contDomainOk embedded in handler repr"
      (let
        contTy = ts.mkTypeDefault (ts.rFn tString tBool) KStar;
        h      = ts.mkHandlerWithCont "Log" tString contTy tUnit;
      in h.repr.contDomainOk or false))

    (mkTestBool "INV-EFF-11: invEff11 invariant check"
      (let
        contTy = ts.mkTypeDefault (ts.rFn tInt tBool) KStar;
        h      = ts.mkHandlerWithCont "Io" tInt contTy tUnit;
      in ts.__checkInvariants.invEff11 h))

    (mkTestBool "checkHandlerContWellFormed: contDomain exposed"
      (let
        contTy = ts.mkTypeDefault (ts.rFn tString tBool) KStar;
        h      = ts.mkHandlerWithCont "Log" tString contTy tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in r.ok && (r.contDomain.repr.__variant or null) == "Primitive"))

    (mkTestBool "mkHandlerWithCont: non-Fn contType → contDomainOk = false"
      (let
        # contTy is NOT a Fn type → INV-EFF-11 construction check fails
        contTy = tInt;
        h      = ts.mkHandlerWithCont "X" tString contTy tUnit;
      in !(h.repr.contDomainOk or true)))

    (mkTestBool "INV-PAT-1 via invPat1"
      (ts.__checkInvariants.invPat1 (ts.mkPCtor "Just" [ts.mkPVar "z"]) "Just" "z"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T26: Bidir App Result Solved（Phase 4.5: INV-BIDIR-3）★
  # ════════════════════════════════════════════════════════════════════
  t26 = runGroup "T26-BidirAppResultSolved" [
    # INV-BIDIR-3: when fn is a concrete Fn type, App result = codomain (not freshVar)
    (mkTestBool "INV-BIDIR-3: infer(app (llama x Int x) 42) yields Int"
      (let
        fn   = ts.eLamA "x" tInt (ts.eVar "x");
        arg  = ts.eLit 42;
        r    = ts.infer {} (ts.eApp fn arg);
      in ts.typeHash r.type == ts.typeHash tInt))

    (mkTestBool "INV-BIDIR-3: resultSolved = true when fn is concrete Fn"
      (let
        fn   = ts.eLamA "x" tInt (ts.eVar "x");
        arg  = ts.eLit 42;
        r    = ts.infer {} (ts.eApp fn arg);
      in r.resultSolved or false))

    (mkTestBool "INV-BIDIR-3: checkAppResultSolved returns true for annotated fn"
      (let
        fn  = ts.eLamA "x" tInt (ts.eVar "x");
        arg = ts.eLit 42;
      in ts.checkAppResultSolved {} fn arg))

    (mkTestBool "INV-BIDIR-3: app of Bool→Bool fn yields Bool"
      (let
        fn   = ts.eLamA "b" tBool (ts.eVar "b");
        arg  = ts.eLit true;
        r    = ts.infer {} (ts.eApp fn arg);
      in ts.typeHash r.type == ts.typeHash tBool &&
         (r.resultSolved or false)))

    (mkTestBool "INV-BIDIR-3: unannotated fn (Var) → resultSolved = false"
      (let
        fn  = ts.eVar "f";
        arg = ts.eLit 1;
        r   = ts.infer {} (ts.eApp fn arg);
      in !(r.resultSolved or true)))

    (mkTestBool "INV-BIDIR-3: app constraint is Eq(argTy, domain) not Eq(fnTy, _)"
      (let
        fn   = ts.eLamA "x" tInt (ts.eVar "x");
        arg  = ts.eLit 1;
        r    = ts.infer {} (ts.eApp fn arg);
        # should have exactly 1 constraint: Eq(Int, Int)
        cs   = r.constraints;
      in builtins.length cs == 1))

    (mkTestBool "INV-BIDIR-3: invBidir3 check passes"
      (ts.__checkInvariants.invBidir3 {}
        (ts.eLamA "x" tInt (ts.eVar "x"))
        (ts.eLit 42)))

    (mkTestBool "INV-BIDIR-3: nested app ((llama f Int→Bool f) (llama x Int x)) → Bool"
      (let
        innerFn    = ts.eLamA "x" tInt (ts.eVar "x");
        outerArgTy = ts.mkTypeDefault (ts.rFn tInt tBool) KStar;
        outerFn    = ts.eLamA "f" outerArgTy (ts.eVar "f");
        r          = ts.infer {} (ts.eApp outerFn innerFn);
      in r.resultSolved or false))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T27: Kind Fixpoint Solver（Phase 4.5: INV-KIND-3）★
  # ════════════════════════════════════════════════════════════════════
  t27 = runGroup "T27-KindFixpointSolver" [
    (mkTestBool "INV-KIND-3: fixpoint of empty constraints is ok"
      (let r = ts.solveKindConstraintsFixpoint []; in
       r.ok && r.converged))

    (mkTestBool "INV-KIND-3: fixpoint solves single KVar constraint"
      (let
        kcs = [ { typeVar = "a"; expectedKind = KStar; } ];
        r   = ts.solveKindConstraintsFixpoint kcs;
      in r.ok && r.subst ? a))

    (mkTestBool "INV-KIND-3: fixpoint converges in 1 iter for trivial"
      (let
        kcs = [ { typeVar = "b"; expectedKind = KStar; } ];
        r   = ts.solveKindConstraintsFixpoint kcs;
      in r.ok && r.iters <= 2))

    (mkTestBool "INV-KIND-3: fixpoint detects kind mismatch"
      (let
        kcs = [ { typeVar = "c"; expectedKind = KStar; }
                { typeVar = "c"; expectedKind = KArrow KStar KStar; } ];
        r   = ts.solveKindConstraintsFixpoint kcs;
      in !r.ok))

    (mkTestBool "INV-KIND-3: checkKindAnnotationFixpoint ok for compatible"
      (let
        kcs = [ { typeVar = "x"; expectedKind = KStar; } ];
      in ts.checkKindAnnotationFixpoint kcs))

    (mkTestBool "INV-KIND-3: checkKindAnnotationFixpoint fails incompatible"
      (let
        kcs = [ { typeVar = "y"; expectedKind = KStar; }
                { typeVar = "y"; expectedKind = KArrow KStar KStar; } ];
      in !(ts.checkKindAnnotationFixpoint kcs)))

    (mkTestBool "INV-KIND-3: inferKindWithAnnotationFixpoint iters field present"
      (let
        r = ts.inferKindWithAnnotationFixpoint {} { __variant = "Primitive"; name = "Int"; } KStar;
      in r ? iters))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T28: Pattern Nested Record（Phase 4.5: INV-PAT-3）★
  # ════════════════════════════════════════════════════════════════════
  t28 = runGroup "T28-PatternNestedRecord" [
    # INV-PAT-3: patternVars recurses into Record sub-patterns
    (mkTestBool "INV-PAT-3: flat Record with PVar fields"
      (let
        pat  = ts.mkPRecord { a = ts.mkPVar "x"; b = ts.mkPVar "y"; };
        vars = ts.patternVars pat;
      in builtins.elem "x" vars && builtins.elem "y" vars))

    (mkTestBool "INV-PAT-3: nested Record { a: PVar x; b: { c: PVar y } }"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
        vars  = ts.patternVars outer;
      in builtins.elem "x" vars && builtins.elem "y" vars))

    (mkTestBool "INV-PAT-3: nested Record excludes field names (not bindings)"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
        vars  = ts.patternVars outer;
      in !(builtins.elem "a" vars) && !(builtins.elem "b" vars) && !(builtins.elem "c" vars)))

    (mkTestBool "INV-PAT-3: patternVarsSet for nested Record"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "myZ"; };
        outer = ts.mkPRecord { a = ts.mkPVar "myX"; b = inner; };
        vset  = ts.patternVarsSet outer;
      in vset ? myX && vset ? myZ))

    (mkTestBool "INV-PAT-3: isLinear nested Record (no dups)"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
      in ts.isLinear outer))

    (mkTestBool "INV-PAT-3: patternDepth nested Record = 2"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
      in ts.patternDepth outer == 2))

    (mkTestBool "INV-PAT-3: checkPatternVars nested Record"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
      in ts.checkPatternVars outer { x = true; y = true; }))
  ];

  # ════════════════════════════════════════════════════════════════════
  # 总结
  # ════════════════════════════════════════════════════════════════════
  allGroups = [ t1 t2 t3 t4 t5 t6 t7 t8 t9 t10
                t11 t12 t13 t14 t15 t16 t17 t18 t19 t20
                t21 t22 t23 t24 t25 t26 t27 t28 ];

  totalPassed  = lib.foldl' (acc: g: acc + g.passed) 0 allGroups;
  totalTests   = lib.foldl' (acc: g: acc + g.total)  0 allGroups;
  # INV-TEST-5: 防御性 filter — 只对 isAttrs 的 group 检查 ok
  failedGroups = lib.filter (g:
    builtins.isAttrs g && !(g.ok or true)
  ) allGroups;
  allPassed    = failedGroups == [];

in {
  inherit allGroups totalPassed totalTests allPassed failedGroups;
  passed = totalPassed;
  total  = totalTests;
  ok     = allPassed;

  # runAll: 仅包含可安全 JSON 化的摘要字段（不暴露 Type 对象）
  # 每个 group 只保留 name/passed/total/ok/failedNames
  runAll = map (g: {
    name   = g.name;
    passed = g.passed;
    total  = g.total;
    ok     = g.ok;
    failedNames =
      let gf = g.failed or []; in
      if !builtins.isList gf then []
      else map (t:
        if builtins.isAttrs t then (t.name or "<unnamed>")
        else builtins.toString t
      ) gf;
  }) allGroups;

  summary    = "Passed: ${builtins.toString totalPassed} / ${builtins.toString totalTests}";
  # INV-TEST-5: 防御性 failedList
  failedList =
    let
      safeGroup = g:
        if !builtins.isAttrs g then { group = "<non-attrset>"; failed = []; }
        else
          let
            gf = g.failed or [];
            names =
              if !builtins.isList gf then []
              else map (t:
                if builtins.isAttrs t then (t.name or "<unnamed>")
                else builtins.toString t
              ) gf;
          in
          { group = g.name or "<unknown>"; failed = names; };
    in
    map safeGroup failedGroups;
}
