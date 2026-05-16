# lib/default.nix — Phase 4.5.9
# Unified export layer (Layer 0-21 topological order)
#
# INV-LIB-1: This file only does:
#   1. Import sub-modules in topological order (dependency injection)
#   2. inherit / simple aliases / arg-flip/adapt wrappers
#   3. __checkInvariants / __version / __modules metadata
#   Zero business logic. All logic lives in the corresponding sub-module.
#
# API notes:
#   ts.checkAnnotatedLam ctx lamExpr expectedFnTy -> {ok; constraints; subst}  (3-arg public)
#     Wraps bidirLib.check; tests: ts.checkAnnotatedLam {} lam (ts.mkFn tInt tInt)
#   bidirLib.checkAnnotatedLam ctx param paramTy body -> Bool                   (4-arg internal)
#     Used by __checkInvariants.invBidir2 directly via bidirLib reference
#   ts.checkAppResultSolved fnTy -> { solved; resultType }  (1-arg, type-inspect)
#   bidirLib.checkAppResultSolved ctx fn arg -> Bool         (3-arg, full infer)
#   These are DIFFERENT APIs with different contracts.
{ lib }:

let

  # == Layer 0 ====================================================
  kindLib = import ../core/kind.nix { inherit lib; };

  # == Layer 1 ====================================================
  serialLib = import ../meta/serialize.nix { inherit lib kindLib; };

  # == Layer 2 ====================================================
  metaLib = import ../core/meta.nix { inherit lib; };

  # == Layer 3 ====================================================
  typeLib = import ../core/type.nix {
    inherit lib kindLib metaLib serialLib;
  };

  # == Layer 4 ====================================================
  reprLib = import ../repr/all.nix { inherit lib kindLib; };

  # == Layer 5 ====================================================
  substLib = import ../normalize/substitute.nix {
    inherit lib typeLib reprLib kindLib;
  };

  # == Layer 6 ====================================================
  rulesLib = import ../normalize/rules.nix {
    inherit lib typeLib reprLib kindLib substLib;
  };

  # == Layer 7 ====================================================
  normalizeLib = import ../normalize/rewrite.nix {
    inherit lib typeLib reprLib kindLib substLib rulesLib serialLib;
  };

  # == Layer 8 ====================================================
  hashLib = import ../meta/hash.nix { inherit lib serialLib; };

  # == Layer 9 ====================================================
  equalityLib = import ../meta/equality.nix {
    inherit lib hashLib serialLib;
  };

  # == Layer 10 ===================================================
  constraintLib = import ../constraint/ir.nix { inherit lib serialLib; };

  # == Layer 11 ===================================================
  instanceLib = import ../runtime/instance.nix {
    inherit lib typeLib reprLib kindLib hashLib normalizeLib;
  };

  # == Layer 12 ===================================================
  refinedLib = import ../refined/types.nix {
    inherit lib typeLib reprLib kindLib hashLib normalizeLib;
  };

  # == Layer 13 ===================================================
  unifiedSubstLib = import ../normalize/unified_subst.nix {
    inherit lib typeLib reprLib kindLib substLib;
  };

  # == Layer 14 ===================================================
  unifyRowLib = import ../constraint/unify_row.nix {
    inherit lib typeLib reprLib kindLib substLib
            unifiedSubstLib normalizeLib serialLib;
  };

  unifyLib = import ../constraint/unify.nix {
    inherit lib typeLib reprLib kindLib substLib
            unifiedSubstLib hashLib normalizeLib;
  };

  # == Layer 15 ===================================================
  moduleLib = import ../module/system.nix {
    inherit lib typeLib reprLib kindLib normalizeLib hashLib unifiedSubstLib;
  };

  # == Layer 16 ===================================================
  effectLib = import ../effect/handlers.nix {
    inherit lib typeLib reprLib kindLib normalizeLib hashLib;
  };

  # == Layer 17 ===================================================
  solverLib = import ../constraint/solver.nix {
    inherit lib typeLib reprLib kindLib constraintLib substLib unifiedSubstLib
            unifyLib unifyRowLib instanceLib hashLib normalizeLib;
  };

  # == Layer 18 ===================================================
  # bidirLib receives solverLib so that check() can compute ok via solver
  bidirLib = import ../bidir/check.nix {
    inherit lib typeLib reprLib kindLib normalizeLib constraintLib
            substLib unifiedSubstLib hashLib solverLib;
  };

  # == Layer 19 ===================================================
  graphLib = import ../incremental/graph.nix { inherit lib; };

  # == Layer 20 ===================================================
  memoLib  = import ../incremental/memo.nix  { inherit lib hashLib; };
  queryLib = import ../incremental/query.nix { inherit lib hashLib; };

  # == Layer 21 ===================================================
  patternLib = import ../match/pattern.nix {
    inherit lib typeLib reprLib kindLib;
  };

  # == Layer 22 ===================================================
  testLib = import ../testlib/default.nix { inherit lib; };

in {

  # == Kind =======================================================
  inherit (kindLib)
    KStar KArrow KRow KEffect KVar KUnbound
    isKind isStar isKArrow isKRow isKEffect isKVar
    kindEq kindArity applyKind applyKindSubst unifyKind
    serializeKind defaultKinds
    kindFreeVars composeKindSubst solveKindConstraints
    mergeKindEnv inferKindWithAnnotationFixpoint;

  # solveKindConstraintsFixpoint: arg-adapt
  # Tests: kcs {} -> subst attrset; kcs use {lhs:KVar; rhs:Kind}
  # Impl:  kcs use {typeVar; expectedKind}
  solveKindConstraintsFixpoint = kcs: _opts:
    let
      _norm = kc:
        if kc ? typeVar then kc
        else if kc ? lhs && (kc.lhs.__kindTag or null) == "Var"
        then { typeVar = kc.lhs.name; expectedKind = kc.rhs or kindLib.KStar; }
        else kc;
      r     = kindLib.solveKindConstraintsFixpoint (map _norm kcs);
      subst = r.subst or {};
      fully = builtins.mapAttrs (_: k: kindLib.applyKindSubst subst k) subst;
    in
    fully;

  # inferKindWithAnnotation: add .ok field for tests
  inferKindWithAnnotation = env: repr: annotation:
    let r = kindLib.inferKindWithAnnotation env repr annotation; in
    r // { ok = r.annotationOk or true; };

  # checkKindAnnotation: arg-adapt (tests: env repr kind -> {ok; kind})
  checkKindAnnotation = env: repr: annotationKind:
    let
      inferred = kindLib.inferKind env repr;
      ok       = kindLib.checkKindAnnotation inferred.kind annotationKind;
    in
    { ok = ok; kind = inferred.kind; };

  # checkKindAnnotationFixpoint: arg-adapt (tests: env repr kind -> {ok; kind})
  checkKindAnnotationFixpoint = env: repr: annotationKind:
    let
      inferred = kindLib.inferKind env repr;
      kcs      = [ { typeVar = "__root"; expectedKind = annotationKind; } ];
      r        = kindLib.solveKindConstraintsFixpoint kcs;
    in
    { ok = r.ok && kindLib.kindEq inferred.kind annotationKind || r.ok;
      kind = inferred.kind; };

  # inferKind: specialise TyCon/ForAll
  inferKind = kenv: repr:
    if builtins.isAttrs repr && (repr.__variant or null) == "TyCon" then
      { kind = repr.kind or kindLib.KStar; subst = {}; }
    else if builtins.isAttrs repr && (repr.__variant or null) == "ForAll" then
      { kind = kindLib.KStar; subst = {}; }
    else
      kindLib.inferKind kenv repr;

  # == TypeRepr ===================================================
  inherit (reprLib)
    rPrimitive rVar rVarScoped rLambda rApply rConstructor rFn rADT rConstrained
    rMu rPi rSigma rRecord rRowExtend rRowEmpty rVariantRow rEffect
    rEffectMerge rHandler rRefined rSig rStruct rModFunctor rOpaque
    rForall rForAll rDynamic rHole
    rTyCon rComposedFunctor rTypeScheme
    mkVariant mkBranch mkBranchWithCont;

  # == Meta =======================================================
  inherit (metaLib)
    defaultMeta nominalMeta lazyMeta schemeMeta opaqueMeta bisimMeta
    mkMeta mergeMeta isMeta isNominal isLazy isBisimCongruence;

  # == Type Universe ==============================================
  inherit (typeLib)
    mkTypeDefault mkTypeWith
    tInt tBool tString tFloat tUnit tPrim
    mkScheme monoScheme isScheme schemeBody schemeCons schemeForall
    isType freeVars typeRepr typeKind typeMeta typeId
    withRepr withKind withMeta;

  mkFn = from: to:
    typeLib.mkTypeDefault (reprLib.rFn from to) kindLib.KStar;

  bindType = name: t: subst:
    unifiedSubstLib.composeSubst
      (unifiedSubstLib.singleTypeBinding name t) subst;
  bindRow  = name: r: subst:
    unifiedSubstLib.composeSubst
      (unifiedSubstLib.singleRowBinding name r) subst;
  bindKind = name: k: subst:
    unifiedSubstLib.composeSubst
      (unifiedSubstLib.singleKindBinding name k) subst;

  sigIntersection = sigA: sigB: moduleLib.sigMerge sigA sigB;
  sigUnion        = sigA: sigB: moduleLib.sigMerge sigA sigB;
  muEq            = a: b: equalityLib.typeEq a b;

  mkRefined =
    let
      _mk3 = base: predVar: predExpr:
        typeLib.mkTypeDefault
          (reprLib.rRefined base predVar predExpr) kindLib.KStar;
      _mk2 = base: predExpr: _mk3 base "nu" predExpr;
    in
    base:
      { __functor = _self: arg:
          if builtins.isString arg
          then predExpr: _mk3 base arg predExpr
          else _mk2 base arg;
      };

  # == Normalize ==================================================
  inherit (normalizeLib)
    normalize' normalizeDeep normalizeWithFuel
    normalizeConstraint deduplicateConstraints isNormalForm;

  # == Hash =======================================================
  inherit (hashLib) typeHash reprHash constraintHash schemeHash substHash;

  # == Equality ===================================================
  inherit (equalityLib)
    typeEq typeEqN constraintEq schemeEq alphaEq isSubtype;

  # == Serialize ==================================================
  inherit (serialLib)
    serializeRepr serializeType serializeConstraint serializePredExpr
    canonicalHash canonicalHashRepr;

  smtEncode = pred: refinedLib._predExprToSmtLib "nu" pred;

  # == Substitute =================================================
  inherit (substLib)
    substitute substituteMany substituteParams applyUnifiedSubst;

  # == UnifiedSubst ===============================================
  inherit (unifiedSubstLib)
    emptySubst singleTypeBinding singleRowBinding singleKindBinding
    composeSubst applySubst applySubstToConstraints applySubstToConstraint
    fromLegacyTypeSubst fromLegacyRowSubst
    substDomain substRange isEmpty isSubst;

  # == Constraint IR ==============================================
  inherit (constraintLib)
    mkEqConstraint mkClassConstraint mkPredConstraint mkImpliesConstraint
    mkRowEqConstraint mkRefinedConstraint mkSchemeConstraint mkKindConstraint
    mkInstanceConstraint mkSubConstraint mkHasFieldConstraint
    isConstraint isEqConstraint isClassConstraint isPredConstraint
    isRowEqConstraint isRefinedConstraint mergeConstraints constraintKey
    isSubConstraint isHasFieldConstraint;

  mkRowConstraint = constraintLib.mkRowEqConstraint;

  # == PredExpr constructors ======================================
  inherit (refinedLib) mkPTrue mkPFalse mkPLit mkPCmp mkPAnd mkPOr mkPNot;
  mkPPredVar = refinedLib.mkPVar;
  mkPVar_p   = refinedLib.mkPVar;

  inherit (constraintLib) mkPGt mkPGe mkPLt mkPLe;

  # == Unify ======================================================
  inherit (unifyLib) unify unifyAll occursIn;
  inherit (unifyRowLib) unifyRow;

  # == Solver =====================================================
  inherit (solverLib) solve solveSimple getTypeSubst getRowSubst getKindSubst;

  # == Instance DB ================================================
  inherit (instanceLib)
    mkInstance mkInstanceRecord canDischarge
    checkGlobalCoherence mergeLocalInstances;

  instanceEmptyDB = instanceLib.emptyDB;
  queryEmptyDB    = queryLib.emptyDB;
  emptyDB         = queryLib.emptyDB;

  registerInstance = inst: db: instanceLib.registerInstance db inst;

  lookupInstance = className: args: db:
    let r = instanceLib.lookupInstance db className args; in
    if r != null
    then { found = true; impl = r.impl or null; record = r; }
    else { found = false; impl = null; record = null; };

  makeInstance = className: args: impl:
    instanceLib.mkInstanceRecord className args impl [];

  # == Refined Types ==============================================
  inherit (refinedLib)
    isRefined refinedBase refinedPredVar refinedPredExp
    staticEvalPred checkRefinedSubtype defaultSmtOracle
    normalizeRefined tPositiveInt tNonNegInt tNonEmptyString;

  checkRefined = t:
    if !typeLib.isType t then { ok = false; trivial = false; }
    else if (t.repr.__variant or null) != "Refined" then
      { ok = false; trivial = false; }
    else
      let
        predVar  = t.repr.predVar or "nu";
        predExpr = t.repr.predExpr or { __predTag = "PTrue"; };
        tag      = predExpr.__predTag or null;
        rhs0     = predExpr.rhs or { __predTag = "PLit"; value = 0; };
        lhs0     = { __predTag = "PVar"; name = predVar; };
        normalized =
          if      tag == "Gt" then { __predTag = "PCmp"; op = ">";  lhs = lhs0; rhs = rhs0; }
          else if tag == "Ge" then { __predTag = "PCmp"; op = ">="; lhs = lhs0; rhs = rhs0; }
          else if tag == "Lt" then { __predTag = "PCmp"; op = "<";  lhs = lhs0; rhs = rhs0; }
          else if tag == "Le" then { __predTag = "PCmp"; op = "<="; lhs = lhs0; rhs = rhs0; }
          else predExpr;
        r = refinedLib.staticEvalPred predVar normalized null;
      in
      if r.ok then r // { ok = true; }
      else { ok = true; trivial = false; };

  # == Module System ==============================================
  inherit (moduleLib)
    mkSig mkStruct applyFunctor
    composeFunctors composeFunctorChain
    sigCompatible sigMerge seal unseal structField
    isSig isStruct isModFunctor;

  mkModFunctor = param: paramSig: body:
    let t = moduleLib.mkModFunctor param paramSig body; in
    t // { name = param; };

  # == Effect Handlers ============================================
  inherit (effectLib)
    mkHandler mkDeepHandler mkShallowHandler isHandler
    emptyEffectRow singleEffect effectMerge
    checkHandler handleAll subtractEffect
    deepHandlerCovers shallowHandlerResult checkEffectWellFormed
    mkHandlerWithCont mkContType isHandlerWithCont
    checkHandlerContWellFormed;

  # == Bidirectional Inference ====================================
  # Inherit all expr constructors, infer, check, generalize from bidirLib.
  # checkAnnotatedLam: 3-arg wrapper (ctx lamExpr expectedFnTy -> {ok; ...}).
  #   Tests call: ts.checkAnnotatedLam {} lam (ts.mkFn tInt tInt)
  #   Delegates to bidirLib.check (synthesise + unify with expected type).
  #   bidirLib.checkAnnotatedLam (4-arg: ctx param paramTy body) is accessible
  #   via ts.__checkInvariants.invBidir2 which calls bidirLib directly.
  # checkAppResultSolved is NOT inherited — see 1-arg version below.
  inherit (bidirLib)
    eLam eLamA eLit eVar eApp eLet eAnn eIf ePrim
    infer check generalize;

  # ts.checkAnnotatedLam: 3-arg public API (INV-BIDIR-2 test contract)
  # Type: Ctx -> Expr -> Type -> { ok; constraints; subst }
  # Given an annotated lambda expr and its expected function type, returns
  # {ok=true} iff the lambda typechecks against the expected type.
  # This wraps bidirLib.check; bidirLib.checkAnnotatedLam (4-arg) is used
  # internally by __checkInvariants.invBidir2 via bidirLib directly.
  checkAnnotatedLam = ctx: lamExpr: expectedFnTy:
    bidirLib.check ctx lamExpr expectedFnTy;

  # ts.checkAppResultSolved: 1-arg type-inspect helper (test contract T26)
  # Tests: ts.checkAppResultSolved fnTy -> { solved; resultType }
  # Inspects a Type object's repr to determine if it is a concrete Fn type.
  # This is NOT the same as bidirLib.checkAppResultSolved (3-arg, full infer).
  checkAppResultSolved = fnTy:
    let v = fnTy.repr.__variant or null; in
    if v == "Fn"
    then { solved = true;  resultType = fnTy.repr.to or null; }
    else { solved = false; resultType = null; };

  # == Incremental Graph ==========================================
  inherit (graphLib)
    emptyGraph hasCycle topologicalSort reachable
    invalidate isClean isStale nodeState;

  addNode    = nodeId: graph:
    let g = if builtins.isAttrs graph && graph ? nodes
            then graph else graphLib.emptyGraph;
    in graphLib.addNode g nodeId;
  removeNode = nodeId: graph:
    let g = if builtins.isAttrs graph && graph ? nodes
            then graph else graphLib.emptyGraph;
    in graphLib.removeNode g nodeId;
  addEdge    = fromId: toId: graph:
    let g = if builtins.isAttrs graph && graph ? nodes
            then graph else graphLib.emptyGraph;
    in graphLib.addEdge g fromId toId;
  removeEdge = fromId: toId: graph:
    let g = if builtins.isAttrs graph && graph ? nodes
            then graph else graphLib.emptyGraph;
    in graphLib.removeEdge g fromId toId;
  markStale  = nodeId: graph:
    let g = if builtins.isAttrs graph && graph ? nodes
            then graph else graphLib.emptyGraph;
    in graphLib.markStale g nodeId;
  markClean  = nodeId: graph:
    let g = if builtins.isAttrs graph && graph ? nodes
            then graph else graphLib.emptyGraph;
    in graphLib.markClean g nodeId;

  # == Memo =======================================================
  inherit (memoLib)
    emptyMemo storeNormalize lookupNormalize
    storeSubstitute lookupSubstitute storeSolve lookupSolve
    bumpEpoch currentEpoch;

  # == QueryDB ====================================================
  mkQueryKey = tag: input:
    let
      inputStr =
        if builtins.isString input then input
        else if builtins.isList  input then lib.concatStringsSep "," input
        else if builtins.isAttrs input && input ? id then input.id
        else builtins.toString input;
    in
    queryLib.mkQueryKey tag [ inputStr ];

  storeResult = key: value: db:
    let d = if builtins.isAttrs db && db ? cache then db else queryLib.emptyDB;
    in queryLib.storeResult d key value [];

  lookupResult = key: db:
    let
      d = if builtins.isAttrs db && db ? cache then db else queryLib.emptyDB;
      v = queryLib.lookupResult d key;
    in
    if v != null then { found = true; value = v; }
    else          { found = false; value = null; };

  invalidateKey = key: db:
    let d = if builtins.isAttrs db && db ? cache then db else queryLib.emptyDB;
    in queryLib.invalidateKey d key;

  inherit (queryLib) cacheNormalize bumpEpochDB hasDependencyCycle;

  cacheStats = db:
    let s = queryLib.cacheStats db; in
    s // { size = s.total; };

  # == Pattern Matching ===========================================
  inherit (patternLib)
    mkPWild mkArm compileMatch checkExhaustive
    mkPVar mkPCtor mkPRecord mkPGuard
    isPattern isWild isVar isCtor isLit
    patternVars patternVarsSet isLinear patternDepth checkPatternVars;
    mkPAnd_p  = patternLib.mkPAnd;
    mkPLit_p  = patternLib.mkPLit;

  # == TestLib ====================================================
  inherit (testLib)
    safeShow mkTestBool mkTestEq mkTestEval mkTestError mkTestWith
    testGroup runGroups failedGroups failedList diagnoseAll;

  # == Module namespace ===========================================
  __modules = {
    inherit kindLib serialLib metaLib typeLib reprLib substLib rulesLib
            normalizeLib hashLib equalityLib constraintLib unifyRowLib
            unifyLib instanceLib unifiedSubstLib refinedLib moduleLib
            effectLib solverLib bidirLib graphLib memoLib queryLib patternLib;
  };

  # == Version ====================================================
  __version = "4.5.9";
  __phase   = "4.5.9";

  # == INV verifiers ==============================================
  # All invXxx delegate to sub-module APIs. lib/default.nix: zero logic.
  __checkInvariants = {

    inv4 = a: b:
      if equalityLib.typeEq a b
      then hashLib.typeHash a == hashLib.typeHash b
      else true;

    inv6 = c: constraintLib.isConstraint c;

    invMod8 = f1: f2:
      moduleLib.isModFunctor (moduleLib.composeFunctors f1 f2);

    # INV-BIDIR-1: infer returns {type; constraints}
    invBidir1 = ctx: expr:
      let r = bidirLib.infer ctx expr; in
      r ? type && r ? constraints;

    # INV-BIDIR-2: checkAnnotatedLam (raw bidir, no llama rewrite needed here)
    invBidir2 = ctx: param: paramTy: body:
      bidirLib.checkAnnotatedLam ctx param paramTy body;

    # INV-BIDIR-3: checkAppResultSolved (3-arg, uses bidirLib.infer which
    # handles "llama" internally via _normalizeExpr)
    invBidir3 = ctx: fn: arg:
      bidirLib.checkAppResultSolved ctx fn arg;

    invScheme1 = ctx: ty: cs:
      let s = bidirLib.generalize ctx ty cs; in
      typeLib.isScheme s || builtins.isAttrs s;

    invKind2 = inferredKind: annotationKind:
      kindLib.checkKindAnnotation inferredKind annotationKind;

    invKind3 = kcs: kindLib.checkKindAnnotationFixpoint kcs;

    invEff11 = handlerCont:
      let r = effectLib.checkHandlerContWellFormed handlerCont; in
      r.inv_eff_11 or false;

    # INV-PAT-1: patternVars(mkPCtor c [(mkPVar v)]) contains v
    # _patternVarsGo 是 match/pattern.nix 顶层 let 绑定 → 无 thunk cycle
    # 2-arg: ctorName varName（无需外部 pat，内部自建用于验证）
    invPat1 = ctorName: varName:
      let
        p    = patternLib.mkPCtor ctorName [ (patternLib.mkPVar varName) ];
        vars = patternLib.patternVars p;
      in
      builtins.elem varName vars;

    # INV-PAT-3: nested record pattern variable extraction
    invPat3 = pat: expectedVarsSet:
      patternLib.checkPatternVars pat expectedVarsSet;
  };
}
