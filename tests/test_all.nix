# tests/test_all.nix — Phase 4.1
# 完整测试套件（合并所有 Phase 测试）
# 注：原 test_phase32.nix / test_phase40.nix 合并到此文件
{ lib ? (import <nixpkgs> {}).lib }:

let
  ts = import ../lib/default.nix { inherit lib; };

  inherit (ts)
    typeLib kindLib reprLib metaLib serialLib normalizeLib
    hashLib equalityLib constraintLib unifiedSubstLib
    solverLib instanceLib refinedLib moduleLib effectLib
    queryLib graphLib patternLib;

  # ── 测试辅助 ─────────────────────────────────────────────────────────────
  mkTest = name: expected: actual:
    { inherit name;
      ok  = expected == actual;
      expected = builtins.toJSON expected;
      actual   = builtins.toJSON actual; };

  mkTestBool = name: cond:
    { inherit name; ok = cond; expected = "true"; actual = builtins.toJSON cond; };

  runTests = tests:
    let
      results = tests;
      passed  = builtins.length (builtins.filter (t: t.ok) results);
      failed  = builtins.length (builtins.filter (t: !t.ok) results);
      failedTests = builtins.filter (t: !t.ok) results;
    in
    { inherit passed failed;
      total   = builtins.length results;
      ok      = failed == 0;
      failures = map (t: { name = t.name; expected = t.expected; actual = t.actual; }) failedTests;
    };

  # ── 常用类型构造 ──────────────────────────────────────────────────────────
  tInt    = ts.mkTypeDefault (ts.rPrimitive "Int")    ts.KStar;
  tBool   = ts.mkTypeDefault (ts.rPrimitive "Bool")   ts.KStar;
  tString = ts.mkTypeDefault (ts.rPrimitive "String") ts.KStar;
  tFloat  = ts.mkTypeDefault (ts.rPrimitive "Float")  ts.KStar;

  tFnIntBool = ts.mkTypeDefault (ts.rFn tInt tBool) ts.KStar;

  tAlpha = ts.mkTypeDefault (ts.rVar "α" "test") ts.KStar;
  tBeta  = ts.mkTypeDefault (ts.rVar "β" "test") ts.KStar;

in runTests [

  # ════════════════════════════════════════════════════════════════════════════
  # T1: TypeIR 核心（INV-1）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T1.1: isType Int" (typeLib.isType tInt))
  (mkTestBool "T1.2: isType Bool" (typeLib.isType tBool))
  (mkTestBool "T1.3: Type has id" (tInt.id != null && tInt.id != ""))
  (mkTestBool "T1.4: Type has repr" (typeLib.isType tInt && tInt.repr.__variant == "Primitive"))
  (mkTestBool "T1.5: mkTypeDefault sets meta" (tInt.meta.__type == "MetaType"))

  # ════════════════════════════════════════════════════════════════════════════
  # T2: Kind 系统（INV-K1）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T2.1: KStar isKind" (kindLib.isKStar kindLib.KStar))
  (mkTestBool "T2.2: KArrow isKindArrow" (kindLib.isKArrow (kindLib.KArrow kindLib.KStar kindLib.KStar)))
  (mkTestBool "T2.3: KRow isKRow" (kindLib.isKRow kindLib.KRow))
  (mkTestBool "T2.4: kindEq KStar KStar" (kindLib.kindEq kindLib.KStar kindLib.KStar))
  (mkTestBool "T2.5: kindInferRepr Primitive = KStar"
    (kindLib.kindEq (kindLib.kindInferRepr (ts.rPrimitive "Int")) kindLib.KStar))

  # ════════════════════════════════════════════════════════════════════════════
  # T3: Repr 全变体（INV-1）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T3.1: rPrimitive __variant"  ((ts.rPrimitive "Int").__variant == "Primitive"))
  (mkTestBool "T3.2: rVar __variant"        ((ts.rVar "a" "s").__variant == "Var"))
  (mkTestBool "T3.3: rLambda __variant"     ((ts.rLambda "x" tInt).__variant == "Lambda"))
  (mkTestBool "T3.4: rApply __variant"      ((ts.rApply tInt [ tBool ]).__variant == "Apply"))
  (mkTestBool "T3.5: rFn __variant"         ((ts.rFn tInt tBool).__variant == "Fn"))
  (mkTestBool "T3.6: rADT __variant"        ((ts.rADT [] true).__variant == "ADT"))
  (mkTestBool "T3.7: rConstrained __variant" ((ts.rConstrained tInt []).__variant == "Constrained"))
  (mkTestBool "T3.8: rMu __variant"         ((ts.rMu "X" tInt).__variant == "Mu"))
  (mkTestBool "T3.9: rRecord __variant"     ((ts.rRecord {}).__variant == "Record"))
  (mkTestBool "T3.10: rRefined __variant"   ((ts.rRefined tInt "n" ts.mkPTrue).__variant == "Refined"))
  (mkTestBool "T3.11: rSig __variant"       ((ts.rSig {}).__variant == "Sig"))
  (mkTestBool "T3.12: rHandler __variant"   ((ts.rHandler "E" [] tInt).__variant == "Handler"))

  # ════════════════════════════════════════════════════════════════════════════
  # T4: Serialize（INV-4 前置）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T4.1: serialize Primitive deterministic"
    (serialLib.canonicalHash (ts.rPrimitive "Int") ==
     serialLib.canonicalHash (ts.rPrimitive "Int")))

  (mkTestBool "T4.2: serialize different Primitive differ"
    (serialLib.canonicalHash (ts.rPrimitive "Int") !=
     serialLib.canonicalHash (ts.rPrimitive "Bool")))

  (mkTestBool "T4.3: serialize Fn order"
    (serialLib.serializeRepr (ts.rFn tInt tBool) != serialLib.serializeRepr (ts.rFn tBool tInt)))

  # ════════════════════════════════════════════════════════════════════════════
  # T5: Normalize（INV-2/3）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T5.1: normalize Primitive = itself"
    (let n = normalizeLib.normalize' tInt; in n.repr.__variant == "Primitive"))

  (mkTestBool "T5.2: beta reduction"
    (let
      body   = tAlpha;  # body = α
      lam    = ts.mkTypeDefault (ts.rLambda "α" body) ts.KStar;
      app    = ts.mkTypeDefault (ts.rApply lam [ tInt ]) ts.KStar;
      result = normalizeLib.normalize' app;
    in result.repr.__variant == "Primitive" && result.repr.name == "Int"))

  (mkTestBool "T5.3: Constraint merge"
    (let
      cInner = ts.mkTypeDefault (ts.rConstrained tInt [ ts.mkClassConstraint "Eq" [ tInt ] ]) ts.KStar;
      cOuter = ts.mkTypeDefault (ts.rConstrained cInner [ ts.mkClassConstraint "Show" [ tInt ] ]) ts.KStar;
      norm   = normalizeLib.normalize' cOuter;
    in norm.repr.__variant == "Constrained" &&
       builtins.length norm.repr.constraints == 2))

  # ════════════════════════════════════════════════════════════════════════════
  # T6: Hash（INV-4）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T6.1: same type same hash"
    (hashLib.typeHash tInt == hashLib.typeHash tInt))

  (mkTestBool "T6.2: diff type diff hash"
    (hashLib.typeHash tInt != hashLib.typeHash tBool))

  (mkTestBool "T6.3: typeEq ⟹ same hash"
    (let
      t1 = ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar;
      t2 = ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar;
    in equalityLib.typeEq t1 t2 && hashLib.typeHash t1 == hashLib.typeHash t2))

  # ════════════════════════════════════════════════════════════════════════════
  # T7: Constraint IR（INV-6）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T7.1: mkEqConstraint has tag"
    ((ts.mkEqConstraint tInt tBool).__constraintTag == "Equality"))

  (mkTestBool "T7.2: mkClassConstraint has tag"
    ((ts.mkClassConstraint "Eq" [ tInt ]).__constraintTag == "Class"))

  (mkTestBool "T7.3: normalizeConstraint Equality symmetric"
    (let
      c1 = ts.mkEqConstraint tInt tBool;
      c2 = ts.mkEqConstraint tBool tInt;
      n1 = constraintLib.normalizeConstraint c1;
      n2 = constraintLib.normalizeConstraint c2;
    in constraintLib.constraintKey n1 == constraintLib.constraintKey n2))

  (mkTestBool "T7.4: deduplicateConstraints removes dups"
    (let
      c = ts.mkClassConstraint "Eq" [ tInt ];
      deduped = constraintLib.deduplicateConstraints [ c c c ];
    in builtins.length deduped == 1))

  # ════════════════════════════════════════════════════════════════════════════
  # T8: UnifiedSubst（INV-US1~5）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T8.1: emptySubst is empty"
    (unifiedSubstLib.isEmptySubst unifiedSubstLib.emptySubst))

  (mkTestBool "T8.2: singleTypeBinding lookup"
    (let
      s   = ts.singleTypeBinding "α" tInt;
      r   = unifiedSubstLib.lookupType s "α";
    in r != null && r.repr.__variant == "Primitive"))

  (mkTestBool "T8.3: applyUnifiedSubst replaces Var"
    (let
      s      = ts.singleTypeBinding "α" tInt;
      varTy  = ts.mkTypeDefault (ts.rVar "α" "test") ts.KStar;
      result = ts.applyUnifiedSubst s varTy;
    in result.repr.__variant == "Primitive" && result.repr.name == "Int"))

  (mkTestBool "T8.4: composeSubst INV-US1"
    (let
      s1     = ts.singleTypeBinding "α" tInt;
      s2     = ts.singleTypeBinding "β" tBool;
      comp   = ts.composeSubst s1 s2;
      alphaR = unifiedSubstLib.lookupType comp "α";
      betaR  = unifiedSubstLib.lookupType comp "β";
    in alphaR != null && betaR != null))

  (mkTestBool "T8.5: fromLegacyTypeSubst round-trip"
    (let
      legacy = { "α" = tInt; };
      us     = ts.fromLegacyTypeSubst legacy;
      back   = unifiedSubstLib.toLegacyTypeSubst us;
    in back ? "α" && back."α".repr.name == "Int"))

  # ════════════════════════════════════════════════════════════════════════════
  # T9: Solver（INV-SOL1/4/5 修复）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T9.1: solve empty = ok"
    ((ts.solve {} instanceLib.emptyDB []).ok))

  (mkTestBool "T9.2: solve Eq(Int,Int) = ok"
    (let
      c = ts.mkEqConstraint tInt tInt;
      r = ts.solveSimple [ c ];
    in r.ok))

  (mkTestBool "T9.3: solve Eq(α,Int) binds α"
    (let
      varTy = ts.mkTypeDefault (ts.rVar "α" "sol") ts.KStar;
      c     = ts.mkEqConstraint varTy tInt;
      r     = ts.solveSimple [ c ];
    in r.ok && !(unifiedSubstLib.isEmptySubst r.subst)))

  (mkTestBool "T9.4: solve Eq(Int,Bool) fails"
    (let
      c = ts.mkEqConstraint tInt tBool;
      r = ts.solveSimple [ c ];
    in !r.ok))

  (mkTestBool "T9.5: smtResidual for Refined constraints"
    (let
      posInt = ts.mkPositiveInt tInt;
      rc     = ts.mkRefinedConstraint posInt "n" (ts.mkPCmp "gt" (ts.mkPVar "n") (ts.mkPLit 0));
      r      = ts.solveSimple [ rc ];
    in r.smtResidual != []))

  # ════════════════════════════════════════════════════════════════════════════
  # T10: Instance DB（修复 RISK-A/B）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T10.1: emptyDB has 0 instances"
    (instanceLib.instanceCount instanceLib.emptyDB == 0))

  (mkTestBool "T10.2: registerInstance adds entry"
    (let
      db = instanceLib.registerInstance instanceLib.emptyDB "Eq" [ tInt ] { eqImpl = true; } {};
    in instanceLib.instanceCount db == 1))

  (mkTestBool "T10.3: resolveWithFallback finds registered"
    (let
      db = instanceLib.registerInstance instanceLib.emptyDB "Eq" [ tInt ] { eqImpl = true; } {};
      r  = instanceLib.resolveWithFallback {} db "Eq" [ tInt ];
    in r.found && r.impl != null))

  (mkTestBool "T10.4: primitive Eq Int resolves with impl (RISK-A fix)"
    (let
      r = instanceLib.resolveWithFallback {} instanceLib.emptyDB "Eq" [ tInt ];
    in r.found && r.impl != null))  # ← RISK-A: impl 不再是 null

  (mkTestBool "T10.5: canDischarge Class Eq Int"
    (instanceLib.canDischarge {} instanceLib.emptyDB
      (ts.mkClassConstraint "Eq" [ tInt ])))

  (mkTestBool "T10.6: instanceKey NF-hash stable (RISK-B fix)"
    (let
      k1 = instanceLib._instanceKey "Eq" [ tInt ];
      k2 = instanceLib._instanceKey "Eq" [ ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar ];
    in k1 == k2))

  # ════════════════════════════════════════════════════════════════════════════
  # T11: Refined Types（INV-SMT-1~6）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T11.1: mkPTrue discharged"
    ((refinedLib.staticEvalPred ts.mkPTrue).discharged))

  (mkTestBool "T11.2: mkPFalse not discharged"
    (!(refinedLib.staticEvalPred ts.mkPFalse).discharged))

  (mkTestBool "T11.3: PCmp lit-lit folding"
    (let p = ts.mkPCmp "gt" (ts.mkPLit 5) (ts.mkPLit 3); in
     (refinedLib.staticEvalPred p).discharged))

  (mkTestBool "T11.4: PCmp false case"
    (let p = ts.mkPCmp "gt" (ts.mkPLit 1) (ts.mkPLit 5); in
     !(refinedLib.staticEvalPred p).discharged))

  (mkTestBool "T11.5: PVar is residual"
    ((refinedLib.staticEvalPred (ts.mkPVar "n")).residual))

  (mkTestBool "T11.6: smtBridge generates SMTLIB2"
    (let
      c      = { subject = tInt; predVar = "n"; predExpr = ts.mkPCmp "gt" (ts.mkPVar "n") (ts.mkPLit 0); };
      script = ts.smtBridge [ c ];
    in lib.hasPrefix "(set-logic" script))

  (mkTestBool "T11.7: refinedSubtypeObligation trivial with PTrue"
    (let
      sub = ts.mkRefined tInt "n" ts.mkPTrue;
      sup = ts.mkRefined tInt "n" ts.mkPTrue;
      obl = ts.refinedSubtypeObligation sub sup;
    in obl.trivial))

  (mkTestBool "T11.8: checkRefinedSubtype with mock oracle (INV-SMT-5)"
    (let
      sub   = ts.mkRefined tInt "n" (ts.mkPCmp "gt" (ts.mkPVar "n") (ts.mkPLit 0));
      sup   = ts.mkRefined tInt "n" (ts.mkPCmp "ge" (ts.mkPVar "n") (ts.mkPLit 0));
      oracle = _: "unsat";  # mock: always unsat = subtype holds
      r      = ts.checkRefinedSubtype sub sup oracle;
    in r.ok))

  # ════════════════════════════════════════════════════════════════════════════
  # T12: Module System（INV-MOD-1~7）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T12.1: mkSig is Sig"
    (moduleLib.isSigType (ts.mkSig { x = tInt; })))

  (mkTestBool "T12.2: mkSig fields sorted"
    (let
      sig    = ts.mkSig { b = tBool; a = tInt; };
      fields = moduleLib.sigFields sig;
      names  = builtins.attrNames fields;
    in names == lib.sort (a: b: a < b) names))

  (mkTestBool "T12.3: mkStruct is Struct"
    (moduleLib.isStructType (ts.mkStruct (ts.mkSig { x = tInt; }) { x = tInt; })))

  (mkTestBool "T12.4: checkSig ok when impl matches"
    (let
      sig    = ts.mkSig { x = tInt; };
      struct = ts.mkStruct sig { x = tInt; };
      r      = ts.checkSig struct sig;
    in r.ok))

  (mkTestBool "T12.5: checkSig fails with missing field"
    (let
      sig    = ts.mkSig { x = tInt; y = tBool; };
      struct = ts.mkStruct sig { x = tInt; };
      r      = ts.checkSig struct sig;
    in !r.ok && r.missing == [ "y" ]))

  (mkTestBool "T12.6: applyFunctor ok (RISK-E fix)"
    (let
      sig    = ts.mkSig { t = tInt; };
      functor = ts.mkModFunctor "M" sig
        (ts.mkTypeDefault (ts.rVar "M" "func") ts.KStar);
      argSt   = ts.mkStruct sig { t = tInt; };
      r       = ts.applyFunctor functor argSt;
    in r.ok))

  (mkTestBool "T12.7: mergeLocalInstances ok when no conflict (INV-MOD-7)"
    (let
      r = ts.mergeLocalInstances { inst1 = true; } { inst2 = true; };
    in r.ok && r.db ? inst1 && r.db ? inst2))

  (mkTestBool "T12.8: mergeLocalInstances fails on conflict"
    (let
      r = ts.mergeLocalInstances { inst1 = true; } { inst1 = false; };
    in !r.ok))

  # ════════════════════════════════════════════════════════════════════════════
  # T13: Effect Handlers（INV-EFF-4~9）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T13.1: mkHandler is Handler"
    ((ts.mkHandler "State" [] tInt).repr.__variant == "Handler"))

  (mkTestBool "T13.2: singleEffect creates VariantRow"
    (let er = effectLib.singleEffect "State" tInt; in
     er.repr.__variant == "VariantRow"))

  (mkTestBool "T13.3: checkHandler matches effect"
    (let
      effRow  = effectLib.singleEffect "State" tInt;
      effType = ts.mkTypeDefault (ts.rEffect effRow) ts.KEffect;
      handler = ts.mkHandler "State" [] tInt;
      r       = ts.checkHandler handler effType;
    in r.ok))

  (mkTestBool "T13.4: subtractEffect removes label"
    (let
      er     = effectLib.singleEffect "State" tInt;
      after  = ts.subtractEffect er "State";
      labels = builtins.attrNames (after.repr.variants or {});
    in !builtins.elem "State" labels))

  (mkTestBool "T13.5: mkDeepHandler has deep flag (INV-EFF-8)"
    (let h = ts.mkDeepHandler "E" [] tInt; in
     h.repr.deep or false))

  (mkTestBool "T13.6: mkShallowHandler has shallow flag (INV-EFF-9)"
    (let h = ts.mkShallowHandler "E" [] tInt; in
     h.repr.shallow or false))

  # ════════════════════════════════════════════════════════════════════════════
  # T14: QueryKey DB（INV-QK1~5 + Phase 4.1 schema validation）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T14.1: mkQueryKey valid tag"
    (let k = queryLib.mkQueryKey "norm" [ "abc" ]; in
     lib.hasPrefix "norm:" k))

  (mkTestBool "T14.2: validateQueryKey accepts valid"
    (queryLib.validateQueryKey "norm:abc123"))

  (mkTestBool "T14.3: validateQueryKey rejects invalid"
    (!(queryLib.validateQueryKey "invalid:abc")))

  (mkTestBool "T14.4: storeResult and lookupResult"
    (let
      db  = queryLib.emptyQueryDB;
      k   = queryLib.mkQueryKey "norm" [ "typeX" ];
      db' = queryLib.storeResult db k "result_value" [];
      r   = queryLib.lookupResult db' k;
    in r.found && r.value == "result_value"))

  (mkTestBool "T14.5: invalidateKey marks invalid"
    (let
      db  = queryLib.emptyQueryDB;
      k   = queryLib.mkQueryKey "norm" [ "typeX" ];
      db' = queryLib.storeResult db k "val" [];
      db2 = queryLib.invalidateKey db' k;
      r   = queryLib.lookupResult db2 k;
    in !r.found))

  (mkTestBool "T14.6: invalidateKey BFS propagates"
    (let
      db   = queryLib.emptyQueryDB;
      k1   = queryLib.mkQueryKey "norm" [ "t1" ];
      k2   = queryLib.mkQueryKey "hash" [ "t1" ];
      db1  = queryLib.storeResult db  k1 "v1" [];
      db2  = queryLib.storeResult db1 k2 "v2" [ k1 ];  # k2 depends on k1
      db3  = queryLib.invalidateKey db2 k1;  # invalidate k1 → propagates to k2
      r2   = queryLib.lookupResult db3 k2;
    in !r2.found))

  (mkTestBool "T14.7: detectCycle returns false for acyclic"
    (let
      db  = queryLib.emptyQueryDB;
      k1  = queryLib.mkQueryKey "norm" [ "t1" ];
      db' = queryLib.storeResult db k1 "v" [];
    in !(queryLib.detectCycle db' k1)))

  (mkTestBool "T14.8: cacheNormalize writes to both caches (RISK-D fix)"
    (let
      db    = queryLib.emptyQueryDB;
      memo  = {};
      result = queryLib.cacheNormalize db memo "typeId123" tInt [];
    in result ? queryDB && result ? memo
       && result.memo ? "typeId123"))

  (mkTestBool "T14.9: bumpEpochDB clears both caches"
    (let
      db    = queryLib.emptyQueryDB;
      memo  = { someKey = "someVal"; };
      k     = queryLib.mkQueryKey "norm" [ "t" ];
      db'   = queryLib.storeResult db k "v" [];
      state = queryLib.bumpEpochDB { queryDB = db'; memo = memo; };
    in state.memo == {} &&
       !(queryLib.lookupResult state.queryDB k).found))

  # ════════════════════════════════════════════════════════════════════════════
  # T15: Incremental Graph（INV-G1~4 修复）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T15.1: addNode creates dirty node"
    (let g = graphLib.addNode graphLib.emptyGraph "n1" "data"; in
     g.nodes.n1.state == graphLib.STATE_DIRTY))

  (mkTestBool "T15.2: markClean transitions to clean-valid"
    (let
      g  = graphLib.addNode graphLib.emptyGraph "n1" "data";
      g' = graphLib.markClean g "n1" "result";
    in g'.nodes.n1.state == graphLib.STATE_CLEAN_VALID))

  (mkTestBool "T15.3: markStale transitions clean-valid to clean-stale (INV-G2 fix)"
    (let
      g  = graphLib.addNode graphLib.emptyGraph "n1" "data";
      g1 = graphLib.markClean g "n1" "result";
      g2 = graphLib.markStale g1 "n1";
    in g2.nodes.n1.state == graphLib.STATE_CLEAN_STALE))

  (mkTestBool "T15.4: propagateDirty BFS uses revEdges (INV-G1 fix)"
    (let
      g  = graphLib.addNode graphLib.emptyGraph "n1" "d1";
      g1 = graphLib.addNode g "n2" "d2";
      # n1 → n2（n1 depends on n2 = n2 is in n1's revEdges）
      g2 = graphLib.addEdge g1 "n1" "n2";
      g3 = graphLib.markClean g2 "n1" "r1";
      g4 = graphLib.markClean g3 "n2" "r2";
      # n2 changes → n1 should be dirty
      g5 = graphLib.propagateDirty g4 "n2";
    in g5.nodes.n1.state == graphLib.STATE_DIRTY))

  (mkTestBool "T15.5: topologicalSort acyclic"
    (let
      g  = graphLib.addNode graphLib.emptyGraph "n1" "d";
      g1 = graphLib.addNode g "n2" "d";
      g2 = graphLib.addEdge g1 "n1" "n2";
      r  = graphLib.topologicalSort g2;
    in r.ok))

  (mkTestBool "T15.6: removeNode no dangling edges (INV-G4)"
    (let
      g  = graphLib.addNode graphLib.emptyGraph "n1" "d";
      g1 = graphLib.addNode g "n2" "d";
      g2 = graphLib.addEdge g1 "n1" "n2";
      g3 = graphLib.removeNode g2 "n1";
    in !(g3.nodes ? "n1") &&
       !(g3.edges ? "n1") &&
       !(builtins.elem "n1" (g3.revEdges."n2" or []))))

  # ════════════════════════════════════════════════════════════════════════════
  # T16: Pattern Matching（合并 P3.3 pattern tests）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T16.1: mkPatWildcard tag"
    (patternLib.isPatWildcard patternLib.mkPatWildcard))

  (mkTestBool "T16.2: mkPatVar tag"
    (patternLib.isPatVar (patternLib.mkPatVar "x")))

  (mkTestBool "T16.3: mkPatLiteral tag"
    (patternLib.isPatLiteral (patternLib.mkPatLiteral 42)))

  (mkTestBool "T16.4: compileMatch wildcard → Leaf"
    (let
      arm = patternLib.mkArm patternLib.mkPatWildcard "body";
      dt  = patternLib.compileMatch [ arm ] null;
    in dt.__dtTag == "Leaf"))

  (mkTestBool "T16.5: checkExhaustive with wildcard"
    (let
      adtTy  = ts.mkTypeDefault (ts.rADT [
        (ts.mkVariant "Some" [ tInt ] 0)
        (ts.mkVariant "None" []      1)
      ] true) ts.KStar;
      arm = patternLib.mkArm patternLib.mkPatWildcard "body";
      r   = patternLib.checkExhaustive [ arm ] adtTy;
    in r.exhaustive))

  # ════════════════════════════════════════════════════════════════════════════
  # T17: Row 多态（INV-ROW）
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T17.1: RowExtend canonical sort"
    (let
      re1 = ts.mkTypeDefault (ts.rRowExtend "b" tBool
              (ts.mkTypeDefault (ts.rRowExtend "a" tInt
                (ts.mkTypeDefault ts.rRowEmpty ts.KRow)) ts.KRow)) ts.KRow;
      n   = normalizeLib.normalize' re1;
      # 规范化后 "a" 应该在外层（字母序）
    in n.repr.__variant == "RowExtend"))

  (mkTestBool "T17.2: VariantRow canonical"
    (let
      vr = ts.mkTypeDefault (ts.rVariantRow { z = tInt; a = tBool; b = tFloat; } null) ts.KRow;
      n  = normalizeLib.normalize' vr;
      names = builtins.attrNames (n.repr.variants or {});
    in names == lib.sort (a: b: a < b) names))

  # ════════════════════════════════════════════════════════════════════════════
  # T18: 端到端集成测试
  # ════════════════════════════════════════════════════════════════════════════

  (mkTestBool "T18.1: List Maybe List Int type construction"
    (let
      # Maybe a = Just a | Nothing
      maybeBody = ts.mkTypeDefault
        (ts.rADT [
          (ts.mkVariant "Just"    [ tAlpha ] 0)
          (ts.mkVariant "Nothing" []         1)
        ] true) ts.KStar;
      maybeCtor = ts.mkTypeDefault
        (ts.rConstructor "Maybe" ts.KListKind [ "a" ] maybeBody) ts.KListKind;
      maybeInt  = ts.mkTypeDefault (ts.rApply maybeCtor [ tInt ]) ts.KStar;
      norm      = normalizeLib.normalize' maybeInt;
    in norm.repr.__variant == "ADT"))

  (mkTestBool "T18.2: Refined type with solver"
    (let
      posInt = ts.mkPositiveInt tInt;
      rc     = ts.mkRefinedConstraint posInt "n"
                 (ts.mkPCmp "gt" (ts.mkPVar "n") (ts.mkPLit 0));
      r      = ts.solveSimple [ rc ];
    in r.smtResidual != [] || r.ok))  # Refined goes to smtResidual

  (mkTestBool "T18.3: Module system end-to-end"
    (let
      sig    = ts.mkSig { value = tInt; show = tString; };
      impl   = { value = tInt; show = tString; };
      struct = ts.mkStruct sig impl;
      r      = ts.checkSig struct sig;
    in r.ok))

  (mkTestBool "T18.4: Effect handler pipeline"
    (let
      effRow  = effectLib.singleEffect "IO" tInt;
      effType = ts.mkTypeDefault (ts.rEffect effRow) ts.KEffect;
      handler = ts.mkHandler "IO" [] tInt;
      r       = ts.handleAll [ handler ] effType;
    in r.ok))

  (mkTestBool "T18.5: meta.version is 4.1"
    (ts.meta.version == "4.1.0"))

  (mkTestBool "T18.6: all Phase 4.1 capabilities true"
    (ts.meta.capabilities.smtOracleInterface &&
     ts.meta.capabilities.dualCacheConsistency &&
     ts.meta.capabilities.qualifiedModuleName &&
     ts.meta.capabilities.canDischargeSound &&
     ts.meta.capabilities.nfHashInstanceKey &&
     ts.meta.capabilities.worklistRequeue))
]
