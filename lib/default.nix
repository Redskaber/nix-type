# lib/default.nix — Phase 4.2
# 统一导出（Layer 0~22 拓扑顺序）
# 所有 duplicate 名称通过命名空间前缀消歧义
{ lib }:

let

  # ══ Layer 0 ════════════════════════════════════════════════════════
  kindLib = import ../core/kind.nix { inherit lib; };

  # ══ Layer 1 ════════════════════════════════════════════════════════
  serialLib = import ../meta/serialize.nix { inherit lib kindLib; };

  # ══ Layer 2 ════════════════════════════════════════════════════════
  metaLib = import ../core/meta.nix { inherit lib; };

  # ══ Layer 3 ════════════════════════════════════════════════════════
  typeLib = import ../core/type.nix {
    inherit lib kindLib metaLib;
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
    inherit lib typeLib reprLib kindLib substLib rulesLib;
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
  unifyRowLib = import ../constraint/unify_row.nix {
    inherit lib typeLib reprLib kindLib substLib normalizeLib;
  };

  unifyLib = import ../constraint/unify.nix {
    inherit lib typeLib reprLib kindLib substLib hashLib normalizeLib;
  };

  # ══ Layer 12 ═══════════════════════════════════════════════════════
  instanceLib = import ../runtime/instance.nix {
    inherit lib typeLib reprLib kindLib hashLib normalizeLib;
  };

  # ══ Layer 13 ═══════════════════════════════════════════════════════
  unifiedSubstLib = import ../normalize/unified_subst.nix {
    inherit lib typeLib reprLib kindLib substLib;
  };

  # ══ Layer 14 ═══════════════════════════════════════════════════════
  refinedLib = import ../refined/types.nix {
    inherit lib typeLib reprLib kindLib hashLib normalizeLib;
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
                    serializeKind defaultKinds;

  # ══ TypeRepr ═══════════════════════════════════════════════════════
  inherit (reprLib)
    rPrimitive rVar rLambda rApply rConstructor rFn rADT rConstrained
    rMu rPi rSigma rRecord rRowExtend rRowEmpty rVariantRow rEffect
    rEffectMerge rHandler rRefined rSig rStruct rModFunctor rOpaque
    rForall rDynamic rHole mkVariant mkBranch mkBranchWithCont;

  # ══ Meta ═══════════════════════════════════════════════════════════
  inherit (metaLib) defaultMeta nominalMeta lazyMeta schemeMeta opaqueMeta
                    mkMeta mergeMeta isMeta isNominal isLazy;

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

  # PredExpr constructors (canonical — from refinedLib for Refined semantics)
  # Also available as pred.* namespace below
  mkPTrue  = refinedLib.mkPTrue;
  mkPFalse = refinedLib.mkPFalse;
  mkPLit   = refinedLib.mkPLit;
  mkPVar   = refinedLib.mkPVar;
  mkPCmp   = refinedLib.mkPCmp;
  mkPAnd   = refinedLib.mkPAnd;
  mkPOr    = refinedLib.mkPOr;
  mkPNot   = refinedLib.mkPNot;

  # ══ Unify ══════════════════════════════════════════════════════════
  inherit (unifyLib) unify unifyAll occursIn;
  inherit (unifyRowLib) unifyRow;

  # ══ Solver ═════════════════════════════════════════════════════════
  inherit (solverLib) solve solveSimple getTypeSubst getRowSubst;

  # ══ Instance DB ════════════════════════════════════════════════════
  inherit (instanceLib) mkInstance mkInstanceRecord registerInstance
                        lookupInstance resolveWithFallback canDischarge
                        checkGlobalCoherence mergeLocalInstances;
  # 'emptyDB' disambiguation: instanceLib vs queryLib
  instanceEmptyDB = instanceLib.emptyDB;
  queryEmptyDB    = queryLib.emptyDB;
  # Default emptyDB = queryLib (most commonly used directly)
  emptyDB = queryLib.emptyDB;

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
                      deepHandlerCovers shallowHandlerResult checkEffectWellFormed;

  # ══ Bidirectional Inference ════════════════════════════════════════
  inherit (bidirLib) infer check generalize
                     eVar eLam eLamA eApp eLet eAnn eIf ePrim eLit;

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
  inherit (patternLib) mkPWild mkArm compileMatch checkExhaustive patternVars;
  # Pattern constructors — disambiguated from PredExpr ones
  mkPCtor   = patternLib.mkPCtor;
  mkPRecord = patternLib.mkPRecord;
  mkPAnd_p  = patternLib.mkPAnd;   # pattern AND (vs pred AND)
  mkPVar_p  = patternLib.mkPVar;   # pattern Var (vs pred Var)
  mkPLit_p  = patternLib.mkPLit;   # pattern Lit (vs pred Lit)
  mkPGuard  = patternLib.mkPGuard;

  # ══ Module namespace references (for advanced users) ═══════════════
  __modules = {
    inherit kindLib serialLib metaLib typeLib reprLib substLib rulesLib
            normalizeLib hashLib equalityLib constraintLib unifyRowLib
            unifyLib instanceLib unifiedSubstLib refinedLib moduleLib
            effectLib solverLib bidirLib graphLib memoLib queryLib patternLib;
  };

  # ══ Version ════════════════════════════════════════════════════════
  __version = "4.2.0";
  __phase   = "4.2";

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

    invScheme1 = ctx: ty: cs:
      let s = bidirLib.generalize ctx ty cs; in
      typeLib.isScheme s || builtins.isAttrs s;
  };
}
