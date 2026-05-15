# lib/default.nix — Phase 4.4
# 统一导出（Layer 0~22 拓扑顺序）
#
# Phase 4.4 变更（基于 Phase 4.3-Fix）:
#   - core/kind.nix: inferKindWithAnnotation, checkKindAnnotation, mergeKindEnv (INV-KIND-2)
#   - bidir/check.nix: annotated lambda uses paramTy directly (INV-BIDIR-2); checkAnnotatedLam
#   - effect/handlers.nix: checkHandlerContWellFormed now verifies contType.from == paramType (INV-EFF-11)
#   - match/pattern.nix: patternVars bug fix; patternVarsSet, isLinear, patternDepth
#   - tests/test_all.nix: T24 (Bidir Annotated Lambda) + T25 (Handler Cont Type Check) — 170 tests total
#   - Version: 4.4.0
#
# Fix P4.3-patternVars (T16 regression):
#   patternVars "Ctor" branch used `pat.field` instead of `pat.fields or []`,
#   causing attribute-missing evaluation error → tryEval marks test as failed.
#   Fixed in match/pattern.nix with explicit null-guard + correct field name.
#
# INV maintained:
#   INV-1..INV-MU-1 (inherited from 4.3)
#   INV-BIDIR-2: infer(eLamA p ty b) = (ty → bodyTy)
#   INV-EFF-11:  contType.from == paramType
#   INV-KIND-2:  kind annotation propagation consistent with inference
#   INV-PAT-1:   patternVars captures all Var bindings
#   INV-PAT-2:   isLinear(p) ↔ no duplicate in patternVars(p)
{ lib }:

let

  # ══ Layer 0 ════════════════════════════════════════════════════════
  kindLib = import ../core/kind.nix { inherit lib; };

  # ══ Layer 1 ════════════════════════════════════════════════════════
  serialLib = import ../meta/serialize.nix { inherit lib kindLib; };

  # ══ Layer 2 ════════════════════════════════════════════════════════
  metaLib = import ../core/meta.nix { inherit lib; };

  # ══ Layer 3 ════════════════════════════════════════════════════════
  # Phase 4.3 Fix: typeLib requires serialLib for canonical _mkId
  typeLib = import ../core/type.nix {
    inherit lib kindLib metaLib serialLib;
  };

  # ══ Layer 4 ════════════════════════════════════════════════════════
  reprLib = import ../repr/all.nix { inherit lib kindLib; };

  # ══ Layer 5 ════════════════════════════════════════════════════════
  substLib = import ../normalize/substitute.nix {
    inherit lib typeLib reprLib kindLib;
  };

  # ══ Layer 6 ════════════════════════════════════════════════════════
  rulesLib = import ../normalize/rules.nix {
    inherit lib typeLib reprLib kindLib substLib;
  };

  # ══ Layer 7 ════════════════════════════════════════════════════════
  normalizeLib = import ../normalize/rewrite.nix {
    inherit lib typeLib reprLib kindLib substLib rulesLib serialLib;
  };

  # ══ Layer 8 ════════════════════════════════════════════════════════
  hashLib = import ../meta/hash.nix { inherit lib serialLib; };

  # ══ Layer 9 ════════════════════════════════════════════════════════
  equalityLib = import ../meta/equality.nix {
    inherit lib hashLib serialLib;
  };

  # ══ Layer 10 ═══════════════════════════════════════════════════════
  constraintLib = import ../constraint/ir.nix {
    inherit lib serialLib;
  };

  # ══ Layer 11 ═══════════════════════════════════════════════════════
  instanceLib = import ../runtime/instance.nix {
    inherit lib typeLib reprLib kindLib hashLib normalizeLib;
  };

  # ══ Layer 12 ═══════════════════════════════════════════════════════
  refinedLib = import ../refined/types.nix {
    inherit lib typeLib reprLib kindLib hashLib normalizeLib;
  };

  # ══ Layer 13 ═══════════════════════════════════════════════════════
  unifiedSubstLib = import ../normalize/unified_subst.nix {
    inherit lib typeLib reprLib kindLib substLib;
  };

  # ══ Layer 14 ═══════════════════════════════════════════════════════
  unifyRowLib = import ../constraint/unify_row.nix {
    inherit lib typeLib reprLib kindLib substLib unifiedSubstLib normalizeLib serialLib;
  };

  unifyLib = import ../constraint/unify.nix {
    inherit lib typeLib reprLib kindLib substLib unifiedSubstLib hashLib normalizeLib;
  };

  # ══ Layer 15 ═══════════════════════════════════════════════════════
  moduleLib = import ../module/system.nix {
    inherit lib typeLib reprLib kindLib normalizeLib hashLib unifiedSubstLib;
  };

  # ══ Layer 16 ═══════════════════════════════════════════════════════
  effectLib = import ../effect/handlers.nix {
    inherit lib typeLib reprLib kindLib normalizeLib hashLib;
  };

  # ══ Layer 17 ═══════════════════════════════════════════════════════
  solverLib = import ../constraint/solver.nix {
    inherit lib typeLib reprLib kindLib constraintLib substLib unifiedSubstLib
            unifyLib unifyRowLib instanceLib hashLib normalizeLib;
  };

  # ══ Layer 18 ═══════════════════════════════════════════════════════
  bidirLib = import ../bidir/check.nix {
    inherit lib typeLib reprLib kindLib normalizeLib constraintLib substLib unifiedSubstLib hashLib;
  };

  # ══ Layer 19 ═══════════════════════════════════════════════════════
  graphLib = import ../incremental/graph.nix { inherit lib; };

  # ══ Layer 20 ═══════════════════════════════════════════════════════
  memoLib  = import ../incremental/memo.nix  { inherit lib hashLib; };
  queryLib = import ../incremental/query.nix { inherit lib hashLib; };

  # ══ Layer 21 ═══════════════════════════════════════════════════════
  patternLib = import ../match/pattern.nix {
    inherit lib typeLib reprLib kindLib;
  };

in {

  # ══ Kind ═══════════════════════════════════════════════════════════
  inherit (kindLib) KStar KArrow KRow KEffect KVar KUnbound
                    isKind isStar isKArrow isKRow isKEffect isKVar
                    kindEq kindArity applyKind applyKindSubst unifyKind
                    serializeKind defaultKinds
                    # Phase 4.3:
                    kindFreeVars composeKindSubst inferKind solveKindConstraints
                    # Phase 4.4:
                    inferKindWithAnnotation checkKindAnnotation mergeKindEnv
                    # Phase 4.5: INV-KIND-3
                    solveKindConstraintsFixpoint checkKindAnnotationFixpoint
                    inferKindWithAnnotationFixpoint;

  # ══ TypeRepr ═══════════════════════════════════════════════════════
  inherit (reprLib)
    rPrimitive rVar rLambda rApply rConstructor rFn rADT rConstrained
    rMu rPi rSigma rRecord rRowExtend rRowEmpty rVariantRow rEffect
    rEffectMerge rHandler rRefined rSig rStruct rModFunctor rOpaque
    rForall rDynamic rHole mkVariant mkBranch mkBranchWithCont;

  # ══ Meta ═══════════════════════════════════════════════════════════
  inherit (metaLib) defaultMeta nominalMeta lazyMeta schemeMeta opaqueMeta bisimMeta
                    mkMeta mergeMeta isMeta isNominal isLazy isBisimCongruence;

  # ══ Type Universe ══════════════════════════════════════════════════
  inherit (typeLib) mkTypeDefault mkTypeWith
                    tInt tBool tString tFloat tUnit tPrim
                    mkScheme monoScheme isScheme schemeBody schemeCons schemeForall
                    isType freeVars typeRepr typeKind typeMeta typeId
                    withRepr withKind withMeta;

  # ══ Normalize ══════════════════════════════════════════════════════
  inherit (normalizeLib) normalize' normalizeDeep normalizeWithFuel
                         normalizeConstraint deduplicateConstraints isNormalForm;

  # ══ Hash ═══════════════════════════════════════════════════════════
  inherit (hashLib) typeHash reprHash constraintHash schemeHash substHash;

  # ══ Equality ═══════════════════════════════════════════════════════
  inherit (equalityLib) typeEq typeEqN constraintEq schemeEq alphaEq isSubtype;

  # ══ Serialize ══════════════════════════════════════════════════════
  inherit (serialLib) serializeRepr serializeType serializeConstraint
                      serializePredExpr
                      canonicalHash canonicalHashRepr;

  # ══ Substitute ═════════════════════════════════════════════════════
  inherit (substLib) substitute substituteMany substituteParams applyUnifiedSubst;

  # ══ UnifiedSubst ═══════════════════════════════════════════════════
  inherit (unifiedSubstLib) emptySubst singleTypeBinding singleRowBinding singleKindBinding
                            composeSubst applySubst applySubstToConstraints
                            applySubstToConstraint fromLegacyTypeSubst fromLegacyRowSubst
                            substDomain substRange isEmpty isSubst;

  # ══ Constraint IR ══════════════════════════════════════════════════
  inherit (constraintLib)
    mkEqConstraint mkClassConstraint mkPredConstraint mkImpliesConstraint
    mkRowEqConstraint mkRefinedConstraint mkSchemeConstraint mkKindConstraint
    mkInstanceConstraint
    isConstraint isEqConstraint isClassConstraint isPredConstraint
    isRowEqConstraint isRefinedConstraint mergeConstraints constraintKey;

  # PredExpr constructors（from refinedLib）
  mkPTrue    = refinedLib.mkPTrue;
  mkPFalse   = refinedLib.mkPFalse;
  mkPLit     = refinedLib.mkPLit;
  mkPPredVar = refinedLib.mkPVar;
  mkPVar_p   = refinedLib.mkPVar;   # compat alias
  mkPCmp     = refinedLib.mkPCmp;
  mkPAnd     = refinedLib.mkPAnd;
  mkPOr      = refinedLib.mkPOr;
  mkPNot     = refinedLib.mkPNot;

  # ══ Unify ══════════════════════════════════════════════════════════
  inherit (unifyLib) unify unifyAll occursIn;
  inherit (unifyRowLib) unifyRow;

  # ══ Solver ═════════════════════════════════════════════════════════
  inherit (solverLib) solve solveSimple getTypeSubst getRowSubst getKindSubst;

  # ══ Instance DB ════════════════════════════════════════════════════
  inherit (instanceLib) mkInstance mkInstanceRecord registerInstance
                        lookupInstance resolveWithFallback canDischarge
                        checkGlobalCoherence mergeLocalInstances;
  instanceEmptyDB = instanceLib.emptyDB;
  queryEmptyDB    = queryLib.emptyDB;
  emptyDB         = queryLib.emptyDB;

  # ══ Refined Types ══════════════════════════════════════════════════
  inherit (refinedLib) mkRefined isRefined refinedBase refinedPredVar refinedPredExp
                       staticEvalPred checkRefinedSubtype defaultSmtOracle
                       normalizeRefined tPositiveInt tNonNegInt tNonEmptyString;

  # ══ Module System ══════════════════════════════════════════════════
  inherit (moduleLib) mkSig mkStruct mkModFunctor applyFunctor
                      composeFunctors composeFunctorChain
                      sigCompatible sigMerge seal unseal structField
                      isSig isStruct isModFunctor;

  # ══ Effect Handlers ════════════════════════════════════════════════
  inherit (effectLib) mkHandler mkDeepHandler mkShallowHandler isHandler
                      emptyEffectRow singleEffect effectMerge
                      checkHandler handleAll subtractEffect
                      deepHandlerCovers shallowHandlerResult checkEffectWellFormed
                      # Phase 4.3:
                      mkHandlerWithCont mkContType isHandlerWithCont
                      checkHandlerContWellFormed;

  # ══ Bidirectional Inference ════════════════════════════════════════
  inherit (bidirLib) infer check generalize
                     eVar eLam eLamA eApp eLet eAnn eIf ePrim eLit
                     # Phase 4.4:
                     checkAnnotatedLam
                     # Phase 4.5: INV-BIDIR-3
                     checkAppResultSolved;

  # ══ Incremental Graph ══════════════════════════════════════════════
  inherit (graphLib) emptyGraph addNode removeNode addEdge removeEdge
                     invalidateNode topologicalSort hasCycle reachable
                     markStale markClean nodeState isClean isStale;

  # ══ Memo ═══════════════════════════════════════════════════════════
  inherit (memoLib) emptyMemo storeNormalize lookupNormalize
                    storeSubstitute lookupSubstitute storeSolve lookupSolve
                    bumpEpoch currentEpoch;

  # ══ QueryDB ════════════════════════════════════════════════════════
  inherit (queryLib) mkQueryKey storeResult lookupResult
                     invalidateKey cacheNormalize bumpEpochDB
                     hasDependencyCycle cacheStats;

  # ══ Pattern Matching ═══════════════════════════════════════════════
  inherit (patternLib) mkPWild mkArm compileMatch checkExhaustive
                       # Phase 4.3: patternVars (bug-fixed in 4.4)
                       patternVars
                       # Phase 4.4: new pattern utilities
                       patternVarsSet isLinear patternDepth
                       # Phase 4.5: INV-PAT-3
                       checkPatternVars;
  mkPVar    = patternLib.mkPVar;    # Pattern Var { __patTag = "Var"; name = ... }
  mkPCtor   = patternLib.mkPCtor;
  mkPRecord = patternLib.mkPRecord;
  mkPAnd_p  = patternLib.mkPAnd;
  mkPLit_p  = patternLib.mkPLit;
  mkPGuard  = patternLib.mkPGuard;
  isPattern = patternLib.isPattern;
  isWild    = patternLib.isWild;
  isVar     = patternLib.isVar;
  isCtor    = patternLib.isCtor;
  isLit     = patternLib.isLit;

  # ══ Module namespace references ════════════════════════════════════
  __modules = {
    inherit kindLib serialLib metaLib typeLib reprLib substLib rulesLib
            normalizeLib hashLib equalityLib constraintLib unifyRowLib
            unifyLib instanceLib unifiedSubstLib refinedLib moduleLib
            effectLib solverLib bidirLib graphLib memoLib queryLib patternLib;
  };

  # ══ Version ════════════════════════════════════════════════════════
  __version = "4.5.0";
  __phase   = "4.5";

  # ══ INV verification ═══════════════════════════════════════════════
  __checkInvariants = {
    inv4 = a: b:
      if equalityLib.typeEq a b
      then hashLib.typeHash a == hashLib.typeHash b
      else true;

    inv6 = c: constraintLib.isConstraint c;

    invMod8 = f1: f2:
      let composed = moduleLib.composeFunctors f1 f2; in
      moduleLib.isModFunctor composed;

    invBidir1 = ctx: expr:
      let r = bidirLib.infer ctx expr; in
      r ? type && r ? constraints;

    # Phase 4.4: INV-BIDIR-2
    invBidir2 = ctx: param: paramTy: body:
      bidirLib.checkAnnotatedLam ctx param paramTy body;

    # Phase 4.5: INV-BIDIR-3
    invBidir3 = ctx: fn: arg:
      bidirLib.checkAppResultSolved ctx fn arg;

    invScheme1 = ctx: ty: cs:
      let s = bidirLib.generalize ctx ty cs; in
      typeLib.isScheme s || builtins.isAttrs s;

    # Phase 4.4: INV-KIND-2
    invKind2 = inferredKind: annotationKind:
      kindLib.checkKindAnnotation inferredKind annotationKind;

    # Phase 4.5: INV-KIND-3
    invKind3 = kcs: kindLib.checkKindAnnotationFixpoint kcs;

    # Phase 4.4: INV-EFF-11
    invEff11 = handlerCont:
      let r = effectLib.checkHandlerContWellFormed handlerCont; in
      r.inv_eff_11 or false;

    # Phase 4.4: INV-PAT-1
    invPat1 = pat: ctorName: varName:
      let
        p    = patternLib.mkPCtor ctorName [ patternLib.mkPVar varName ];
        vars = patternLib.patternVars p;
      in
      builtins.elem varName vars;

    # Phase 4.5: INV-PAT-3
    invPat3 = pat: expectedVarsSet:
      patternLib.checkPatternVars pat expectedVarsSet;
  };
}
