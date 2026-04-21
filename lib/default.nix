# lib/default.nix — Phase 4.1
# 统一导出入口：所有模块的聚合
# 严格按依赖拓扑顺序（Layer 0 → 22）
{ lib }:

let
  # ── Layer 0: Kind ─────────────────────────────────────────────────────────
  kindLib = import ../core/kind.nix { inherit lib; };

  # ── Layer 1: Serialize（仅依赖 lib + kindLib）─────────────────────────────
  serialLib = import ../meta/serialize.nix { inherit lib kindLib; };

  # ── Layer 2: Meta ─────────────────────────────────────────────────────────
  metaLib = import ../core/meta.nix { inherit lib; };

  # ── Layer 3: Type（依赖 kindLib + metaLib + serialLib）───────────────────
  typeLib = import ../core/type.nix { inherit lib kindLib metaLib; };

  # ── Layer 4: Repr（依赖 typeLib + kindLib）────────────────────────────────
  reprLib = import ../repr/all.nix { inherit lib kindLib; };

  # ── Layer 5: Subst（依赖 reprLib + typeLib）───────────────────────────────
  substLib = import ../normalize/substitute.nix {
    inherit lib typeLib reprLib kindLib;
  };

  # ── Layer 6: Rules（依赖 substLib + kindLib + reprLib + typeLib）──────────
  # Phase 4.1: 合并所有规则（不再有 rules_p33.nix / rules_p40.nix）
  rulesLib = import ../normalize/rules.nix {
    inherit lib typeLib reprLib kindLib substLib;
  };

  # ── Layer 7: Normalize ────────────────────────────────────────────────────
  normalizeLib = import ../normalize/rewrite.nix {
    inherit lib typeLib reprLib rulesLib kindLib;
  };

  # ── Layer 8: Hash ─────────────────────────────────────────────────────────
  hashLib = import ../meta/hash.nix {
    inherit lib typeLib normalizeLib serialLib;
  };

  # ── Layer 9: Equality ─────────────────────────────────────────────────────
  equalityLib = import ../meta/equality.nix {
    inherit lib typeLib normalizeLib serialLib hashLib;
  };

  # ── Layer 10: Constraint IR ───────────────────────────────────────────────
  constraintLib = import ../constraint/ir.nix {
    inherit lib typeLib reprLib kindLib serialLib;
  };

  # ── Layer 11: Unification ─────────────────────────────────────────────────
  unifyRowLib = import ../constraint/unify_row.nix {
    inherit lib typeLib reprLib kindLib substLib normalizeLib;
  };

  unifyLib = import ../constraint/unify.nix {
    inherit lib typeLib reprLib kindLib substLib hashLib normalizeLib;
  };

  # ── Layer 12: Instance DB ─────────────────────────────────────────────────
  instanceLib = import ../runtime/instance.nix {
    inherit lib typeLib reprLib kindLib hashLib normalizeLib;
  };

  # ── Layer 13: UnifiedSubst ────────────────────────────────────────────────
  unifiedSubstLib = import ../normalize/unified_subst.nix {
    inherit lib typeLib kindLib reprLib substLib;
  };

  # ── Layer 14: Refined Types ───────────────────────────────────────────────
  refinedLib = import ../refined/types.nix {
    inherit lib typeLib reprLib kindLib hashLib normalizeLib;
  };

  # ── Layer 15: Module System ───────────────────────────────────────────────
  moduleLib = import ../module/system.nix {
    inherit lib typeLib reprLib kindLib normalizeLib hashLib unifiedSubstLib;
  };

  # ── Layer 16: Effect Handlers ─────────────────────────────────────────────
  effectLib = import ../effect/handlers.nix {
    inherit lib typeLib reprLib kindLib normalizeLib hashLib;
  };

  # ── Layer 17: Solver（统一，合并 solver + solver_p40）────────────────────
  solverLib = import ../constraint/solver.nix {
    inherit lib typeLib reprLib kindLib
            constraintLib substLib unifiedSubstLib
            unifyLib unifyRowLib instanceLib
            hashLib normalizeLib;
  };

  # ── Layer 18: Bidirectional ───────────────────────────────────────────────
  bidirLib = import ../bidir/check.nix {
    inherit lib typeLib reprLib kindLib normalizeLib constraintLib substLib hashLib;
  };

  # ── Layer 19: Incremental Graph ───────────────────────────────────────────
  graphLib = import ../incremental/graph.nix { inherit lib; };

  # ── Layer 20: Memo + Query ────────────────────────────────────────────────
  memoLib  = import ../incremental/memo.nix { inherit lib hashLib; };
  queryLib = import ../incremental/query.nix { inherit lib hashLib; };

  # ── Layer 21: Pattern Matching ────────────────────────────────────────────
  patternLib = import ../match/pattern.nix {
    inherit lib typeLib reprLib kindLib;
  };

  # ── Phase 4.1 Meta ────────────────────────────────────────────────────────
  meta = {
    name        = "nix-types";
    version     = "4.1.0";
    phase       = "4.1";
    description = "Pure Nix native type system — Phase 4.1";
    license     = "MIT";
    homepage    = "https://github.com/redskaber/nix-type";

    capabilities = {
      # Phase 1-3
      kindSystem          = true;
      systemFomega        = true;
      dependentTypes      = true;
      rowPolymorphism     = true;
      effectSystem        = true;
      equiRecursive       = true;
      bidirectional       = true;
      constraintSolver    = true;
      instanceDB          = true;
      patternMatching     = true;
      incrementalGraph    = true;
      memoization         = true;
      openRowUnification  = true;
      effectRowMerge      = true;
      variantRowCanonical = true;
      # Phase 4.0
      refinedTypes        = true;
      moduleSystem        = true;
      effectHandlers      = true;
      unifiedSubst        = true;
      queryKeyIncremental = true;
      # Phase 4.1 新增
      smtOracleInterface  = true;   # checkRefinedSubtype with user-provided SMT
      dualCacheConsistency = true;  # QueryDB + Memo 统一入口
      qualifiedModuleName = true;   # ModFunctor qualified naming（RISK-E 修复）
      queryKeyValidation  = true;   # schema validation（INV-QK-SCHEMA）
      canDischargeSound   = true;   # impl != null 验证（RISK-A 修复）
      nfHashInstanceKey   = true;   # NF-hash based instance key（RISK-B 修复）
      worklistRequeue     = true;   # 真正 incremental worklist（INV-SOL5）
      functorCompose      = true;   # composeFunctors（INV-MOD-6）
      instanceMerge       = true;   # mergeLocalInstances（INV-MOD-7）
      staleCleanState     = true;   # clean-stale FSM（INV-G2 修复）
      topoSortFixed       = true;   # Kahn in-degree 方向修正（INV-G1）
    };
  };

in {
  # ── 所有库导出 ────────────────────────────────────────────────────────────
  inherit
    kindLib serialLib metaLib typeLib reprLib substLib
    rulesLib normalizeLib hashLib equalityLib
    constraintLib unifyLib unifyRowLib
    instanceLib unifiedSubstLib
    refinedLib moduleLib effectLib
    solverLib bidirLib
    graphLib memoLib queryLib
    patternLib;

  # ── Meta 信息 ─────────────────────────────────────────────────────────────
  inherit meta;

  # ── 顶层便捷 API（常用函数直接导出）──────────────────────────────────────
  inherit (typeLib)    mkTypeDefault mkTypeWith isType;
  inherit (kindLib)    KStar KArrow KRow KEffect kindInferRepr kindEq;
  inherit (reprLib)
    rPrimitive rVar rVarK rLambda rLambdaK rApply rConstructor rFn rADT
    rConstrained rMu rRecord rRowExtend rRowEmpty rRowVar rVariantRow
    rPi rSigma rEffect rEffectMerge rOpaque rAscribe
    rRefined rSig rStruct rModFunctor rHandler
    mkVariant;
  inherit (constraintLib)
    mkEqConstraint mkClassConstraint mkPredConstraint
    mkImpliesConstraint mkRowEqConstraint mkRefinedConstraint
    normalizeConstraint deduplicateConstraints constraintKey;
  inherit (normalizeLib)  normalize' normalizeWithFuel;
  inherit (equalityLib)   typeEq reprEq;
  inherit (hashLib)       typeHash instanceKey;
  inherit (unifiedSubstLib)
    emptySubst singleTypeBinding singleRowBinding
    composeSubst applyUnifiedSubst fromLegacyTypeSubst fromLegacyRowSubst;
  inherit (solverLib)     solve solveSimple solveOne;
  inherit (instanceLib)
    emptyDB registerInstance resolveWithFallback canDischarge listInstances;
  inherit (refinedLib)
    mkRefined mkPositiveInt mkNonNegInt
    staticEvalPred smtBridge refinedSubtypeObligation checkRefinedSubtype
    mkPTrue mkPFalse mkPAnd mkPOr mkPNot mkPCmp mkPVar mkPLit mkPApp;
  inherit (moduleLib)
    mkSig mkStruct mkModFunctor checkSig applyFunctor
    composeFunctors seal unseal mergeLocalInstances;
  inherit (effectLib)
    mkHandler mkDeepHandler mkShallowHandler effectMerge
    checkHandler handleAll subtractEffect;
  inherit (queryLib)
    emptyQueryDB mkQueryKey storeResult lookupResult
    invalidateKey detectCycle bumpEpochDB cacheNormalize;
  inherit (patternLib)
    mkPatConstructor mkPatVar mkPatWildcard mkPatLiteral mkPatOr mkPatRecord
    mkArm compileMatch checkExhaustive;

  # ── p41 namespace（Phase 4.1 专属 API）───────────────────────────────────
  p41 = {
    # 双缓存统一操作
    cacheNormalize      = queryLib.cacheNormalize;
    cacheHash           = queryLib.cacheHash;
    bumpEpochDB         = queryLib.bumpEpochDB;
    # Refined subtype 自动化
    checkRefinedSubtype = refinedLib.checkRefinedSubtype;
    # ModFunctor qualified naming
    applyFunctor        = moduleLib.applyFunctor;
    composeFunctors     = moduleLib.composeFunctors;
    # QueryKey validation
    validateQueryKey    = queryLib.validateQueryKey;
    mkQueryKey          = queryLib.mkQueryKey;
    # Effect Handler continuations
    mkDeepHandler       = effectLib.mkDeepHandler;
    mkShallowHandler    = effectLib.mkShallowHandler;
    # Graph stale-clean
    markStale           = graphLib.markStale;
    STATE_CLEAN_STALE   = graphLib.STATE_CLEAN_STALE;
    STATE_CLEAN_VALID   = graphLib.STATE_CLEAN_VALID;
  };
}
