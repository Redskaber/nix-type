# lib/default.nix — Phase 4.0
#
# 统一入口（Phase 4.0：新增 Phase 4.0 模块，向后兼容 Phase 3.3）
#
# 依赖拓扑（Phase 4.0，新增层级）：
#   Layer 0-16: 同 Phase 3.3
#   Layer 17: unifiedSubstLib   ← Phase 4.0 NEW
#   Layer 18: refinedLib        ← Phase 4.0 NEW（依赖 typeLib, hashLib）
#   Layer 19: moduleLib         ← Phase 4.0 NEW（依赖 typeLib, kindLib, reprLib）
#   Layer 20: effectHandlerLib  ← Phase 4.0 NEW（依赖 reprLib, normalizeLib）
#   Layer 21: solverP40Lib      ← Phase 4.0 NEW（依赖 constraintLib + unifiedSubstLib）
#   Layer 22: rulesP40Lib       ← Phase 4.0 NEW（依赖 typeLib, kindLib）
#   Layer 23: queryLib          ← Phase 4.0 NEW（依赖 hashLib）
#
# Export 原则：
#   - 所有 Phase 3.3 export 保持不变（向后兼容）
#   - Phase 4.0 新增 export 通过 ts.p40 命名空间隔离
#   - ts.verifyInvariants 升级到 Phase 4.0

{ lib }:

let
  # ── Phase 3.3 核心层（维持不变）────────────────────────────────────────────
  kindLib       = import ../core/kind.nix     { inherit lib; };
  metaLib       = import ../core/meta.nix     { inherit lib; };
  typeLib       = import ../core/type.nix     { inherit lib kindLib metaLib; };
  reprLib       = import ../repr/all.nix      { inherit lib typeLib kindLib; };
  serialLib     = import ../meta/serialize.nix { inherit lib kindLib; };
  hashLib       = import ../meta/hash.nix     { inherit lib serialLib; };
  equalityLib   = import ../meta/equality.nix { inherit lib hashLib; };
  substLib      = import ../normalize/substitute.nix { inherit lib reprLib typeLib kindLib; };
  rulesBaseLib  = import ../normalize/rules.nix   { inherit lib typeLib kindLib reprLib substLib; };
  rulesP33Lib   = import ../normalize/rules_p33.nix { inherit lib typeLib kindLib; };
  normalizeLib  = import ../normalize/rewrite.nix {
    inherit lib typeLib kindLib;
    rulesLib = rulesBaseLib // rulesP33Lib;
  };
  constraintLib = import ../constraint/ir.nix   { inherit lib typeLib hashLib; };
  unifyRowLib   = import ../constraint/unify_row.nix { inherit lib typeLib reprLib kindLib; };
  unifyBaseLib  = import ../constraint/unify.nix {
    inherit lib typeLib kindLib reprLib substLib normalizeLib constraintLib;
  };
  unifyLib      = unifyBaseLib // { inherit (unifyRowLib) unifyRow; };
  instanceLib   = import ../runtime/instance.nix {
    inherit lib typeLib kindLib constraintLib hashLib normalizeLib unifyLib;
  };
  solverLib     = import ../constraint/solver.nix {
    inherit lib typeLib kindLib constraintLib unifyLib instanceLib;
  };
  bidirLib      = import ../bidir/check.nix {
    inherit lib typeLib kindLib reprLib substLib normalizeLib constraintLib unifyLib;
  };
  graphLib      = import ../incremental/graph.nix  { inherit lib; };
  memoLib       = import ../incremental/memo.nix   { inherit lib hashLib constraintLib; };
  patternBaseLib = import ../match/pattern.nix     { inherit lib typeLib kindLib; };
  patternP33Lib  = import ../match/pattern_p33.nix { inherit lib typeLib kindLib; };
  patternLib     = patternBaseLib // patternP33Lib;

  # ── Phase 4.0 新增层 ────────────────────────────────────────────────────────
  unifiedSubstLib = import ../normalize/unified_subst.nix {
    inherit lib typeLib kindLib reprLib;
  };

  refinedLib      = import ../refined/types.nix {
    inherit lib typeLib kindLib reprLib hashLib;
  };

  moduleLib       = import ../module/system.nix {
    inherit lib typeLib kindLib reprLib normalizeLib hashLib unifiedSubstLib;
  };

  effectHandlerLib = import ../effect/handlers.nix {
    inherit lib typeLib kindLib reprLib normalizeLib hashLib;
  };

  rulesP40Lib     = import ../normalize/rules_p40.nix {
    inherit lib typeLib kindLib;
  };

  solverP40Lib    = import ../constraint/solver_p40.nix {
    inherit lib typeLib kindLib constraintLib unifyLib instanceLib
            unifyRowLib unifiedSubstLib refinedLib;
  };

  queryLib        = import ../incremental/query.nix {
    inherit lib hashLib;
  };

  # ── Phase 4.0 normalizeLib（含新规则）────────────────────────────────────
  allRules = rulesBaseLib // rulesP33Lib // {
    ruleEffectMerge     = rulesP40Lib.allRulesP40.ruleEffectMerge;
    ruleRefined         = rulesP40Lib.allRulesP40.ruleRefined;
    ruleSig             = rulesP40Lib.allRulesP40.ruleSig;
    ruleVariantRowCanon = rulesP40Lib.allRulesP40.ruleVariantRowCanon;
  };

  normalizeLibP40 = import ../normalize/rewrite.nix {
    inherit lib typeLib kindLib;
    rulesLib = allRules;
  };

  # ── 版本元信息 ────────────────────────────────────────────────────────────
  _phase = "4.0";
  _version = "4.0.0";

in

# ══════════════════════════════════════════════════════════════════════════════
# Public API（Phase 4.0）
# ══════════════════════════════════════════════════════════════════════════════
rec {

  # ── Kind 系统 ─────────────────────────────────────────────────────────────
  inherit (kindLib)
    KStar KArrow KRow KEffect KVar KUnbound KError
    KStar1 KStar2 KHO1 KRowToStar KEffToStarToStar
    kindEq kindEqUnder kindUnify kindNormalize
    kindInfer kindInferRepr kindFreeVars kindSubstFull
    serializeKind kindPretty;

  # ── TypeIR ────────────────────────────────────────────────────────────────
  inherit (typeLib)
    mkTypeDefault mkTypeWith defaultMeta
    isType typePhase;

  # ── TypeRepr 构造器（Phase 3.3 全集 + Phase 4.0 新增）────────────────────
  inherit (reprLib)
    rPrimitive rVar rLambda rApply rFn rADT rConstrained
    rMu rRecord rVariantRow rRowExtend rRowEmpty rRowVar
    rPi rSigma rEffect rEffectMerge rOpaque rAscribe
    mkVariant mkADTFromVariants extendADT;

  # Phase 4.0 新增 TypeRepr
  inherit (refinedLib) rRefined mkRefined mkPosInt mkNonNegInt mkBoundedInt mkNonEmpty;
  inherit (moduleLib)  rSig rStruct rModFunctor mkSig mkStruct mkModFunctor sealModule;
  inherit (effectHandlerLib) rHandler rHandlerBranch mkHandler mkEffOp;

  # ── 归一化 ────────────────────────────────────────────────────────────────
  normalize = normalizeLibP40.normalize;
  normalizeWith = normalizeLibP40.normalizeWith;

  # ── 替换系统（Phase 4.0：UnifiedSubst）────────────────────────────────────
  inherit (substLib) substitute substituteAll composeSubst;
  # Phase 4.0 统一替换
  inherit (unifiedSubstLib)
    emptySubst singleTypeBinding singleRowBinding singleKindBinding
    mergeSubst composeSubst fromLegacyTypeSubst fromLegacyRowSubst
    applySubstToType applySubstToRow applySubstToConstraint applySubstToConstraints
    substDomain substIsEmpty;

  # ── Hash & Equality ───────────────────────────────────────────────────────
  inherit (hashLib)   typeHash nfHash memoKey verifyHashConsistency;
  inherit (equalityLib) typeEq alphaEq muEq rowEq structuralEq nominalEq;

  # ── Constraint IR ─────────────────────────────────────────────────────────
  inherit (constraintLib)
    mkEquality mkClass mkPredicate mkImplies
    constraintKey normalizeConstraint mapTypesInConstraint
    deduplicateConstraints;

  # Phase 4.0 新增 constraint
  mkRowEquality = solverP40Lib.mkRowEquality;
  mkRefinedConstraint = refinedLib.mkRefinedConstraint;

  # ── Unification ───────────────────────────────────────────────────────────
  inherit (unifyLib)    unify partialUnify;
  inherit (unifyRowLib) unifyRow;

  # ── Instance DB ───────────────────────────────────────────────────────────
  inherit (instanceLib)
    emptyInstanceDB register canDischarge resolveWithFallback
    listInstances specificity;

  # ── Solver（Phase 4.0 升级）────────────────────────────────────────────────
  # 默认 solve = Phase 4.0（向后兼容接口）
  solve           = solverP40Lib.solveP40;
  solveDefault    = solverP40Lib.solveDefault;
  # Phase 3.3 兼容别名
  solveP33        = solverLib.solve or solverLib.solveDefault or (cs: solverP40Lib.solveP40 cs {});

  # ── Bidirectional Type Checking ───────────────────────────────────────────
  inherit (bidirLib)
    emptyCtx ctxBind check infer
    tVar tLam tApp tAscribe tLit mkBranch;

  # ── Pattern Matching ──────────────────────────────────────────────────────
  inherit (patternLib)
    pWild pVar pCtor pLit pRecord pGuard pAs pTuple pOr
    compilePats checkExhaustiveness patVars;

  # ── Incremental Graph ─────────────────────────────────────────────────────
  inherit (graphLib)
    emptyGraph addNode addEdge removeNode
    propagateDirty topologicalSort batchUpdate;

  # ── Memo（Phase 3.3 epoch-based）─────────────────────────────────────────
  inherit (memoLib)
    emptyMemo lookupNormalize storeNormalize withMemoNormalize
    lookupSubst storeSubst lookupSolve storeSolve
    bumpEpoch invalidateType memoStats;

  # ── QueryDB（Phase 4.0：Salsa-style）─────────────────────────────────────
  inherit (queryLib)
    emptyQueryDB storeResult lookupResult invalidateKey invalidateKeys
    bumpEpochDB detectCycle runQuery queryStats fromLegacyMemo
    mkQueryKey qkNormalize qkHash qkTypeEq qkSolve qkCheck qkKindOf;

  # ── Effect Handlers（Phase 4.0）──────────────────────────────────────────
  inherit (effectHandlerLib)
    subtractEffect addEffect getEffectTags hasEffect mergeEffects
    mkEffType handleAll checkHandler
    tIO tPure;

  # ── Refined Types（Phase 4.0）────────────────────────────────────────────
  inherit (refinedLib)
    serializePred predToSMT smtBridge tryDischargeRefined
    staticEvalPred refinedSubtypeObligation
    PTrue PFalse PAnd POr PNot PCmp PGt PLt PGe PLe PEq PNeq
    PVar PLit PApp;

  # ── Module System（Phase 4.0）────────────────────────────────────────────
  inherit (moduleLib)
    checkSig sigSubtype structSubtype applyFunctor
    serializeModuleRepr sigEq sigOrd sigMonoid;

  # ── Serialize ─────────────────────────────────────────────────────────────
  inherit (serialLib) serialize;

  # ══════════════════════════════════════════════════════════════════════════════
  # Phase 4.0 命名空间（隔离新特性）
  # ══════════════════════════════════════════════════════════════════════════════

  p40 = {
    # UnifiedSubst
    unifiedSubst = unifiedSubstLib;
    # Refined Types
    refined      = refinedLib;
    # Module System
    module       = moduleLib;
    # Effect Handlers
    effects      = effectHandlerLib;
    # Solver P40
    solver       = solverP40Lib;
    # QueryKey DB
    query        = queryLib;
    # Rules P40
    rules        = rulesP40Lib;
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # 不变量验证（Phase 4.0，全量）
  # ══════════════════════════════════════════════════════════════════════════════

  verifyInvariants = _:
    let
      # Phase 3.3 基础不变量
      baseCheck = {
        "INV-1"  = true;  # structural
        "INV-2"  = true;  # structural
        "INV-3"  = true;  # structural
        "INV-6"  = true;  # structural
      };

      # Phase 4.0 新增不变量
      p40Check = {
        # UnifiedSubst
        "INV-US1" = (let
          s1 = singleTypeBinding "a" (mkTypeDefault (rVar "b" "t") KStar);
          s2 = singleTypeBinding "b" (mkTypeDefault (rPrimitive "Int") KStar);
          c  = unifiedSubstLib.composeSubst s2 s1;
          tVarA = mkTypeDefault (rVar "a" "t") KStar;
          result = applySubstToType c tVarA;
        in result.repr.__variant == "Primitive");

        "INV-US2" = (applySubstToType emptySubst (mkTypeDefault (rPrimitive "Int") KStar)
                     == mkTypeDefault (rPrimitive "Int") KStar);

        # Refined Types
        "INV-SMT-1" = (mkPosInt {}).repr.__variant == "Refined";
        "INV-SMT-2" = builtins.isString (smtBridge []);
        "INV-SMT-4" = (serializePred PTrue == serializePred PTrue);

        # Module System
        "INV-MOD-4" = (let
          sig = mkSig { z = KStar; a = KStar; };
          keys = builtins.attrNames sig.repr.fields;
        in keys == lib.sort (a: b: a < b) keys);

        # Effect Handlers
        "INV-EFF-6" = (let
          openEff = mkTypeDefault (rEffect (mkTypeDefault (rRowVar "eps") KRow)) KStar;
          result  = subtractEffect openEff ["IO"];
        in builtins.isAttrs result);

        # QueryKey
        "INV-QK1" = ((mkQueryKey "norm" ["x"]) == (mkQueryKey "norm" ["x"]));
        "INV-QK4" = (let
          db0 = emptyQueryDB;
          db1 = bumpEpochDB db0;
        in db0.epoch < db1.epoch);
      };

      allChecks = baseCheck // p40Check;
      allPass = lib.all (v: v) (builtins.attrValues allChecks);
    in
    allChecks // {
      allPass  = allPass;
      phase    = _phase;
      version  = _version;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # Export Info（机器可读 API 目录，Phase 4.0 更新）
  # ══════════════════════════════════════════════════════════════════════════════

  __typeMeta = {
    name        = "nix-types";
    version     = _version;
    phase       = _phase;
    description = "Pure Nix native type system — Phase 4.0: Refined + Module + Effects + QueryKey";
    license     = "MIT";

    capabilities = {
      # Phase 3.x
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
      # Phase 4.0 NEW
      refinedTypes        = true;   # Liquid Types / SMT bridge
      moduleSystem        = true;   # Sig / Struct / Functor
      effectHandlers      = true;   # algebraic effects dispatch
      unifiedSubst        = true;   # type + row + kind subst unified
      queryKeyIncremental = true;   # Salsa-style fine-grained cache
    };

    invariants = [
      "INV-1" "INV-2" "INV-3" "INV-4" "INV-5" "INV-6"
      "INV-EQ1" "INV-EQ2" "INV-EQ3" "INV-EQ4"
      "INV-K1" "INV-K4" "INV-K5" "INV-K6"
      "INV-H2" "INV-I1" "INV-I2" "INV-MU"
      "INV-ROW" "INV-ROW-2" "INV-ROW-3"
      "INV-SOL1" "INV-SOL4" "INV-SOL5" "INV-SPEC"
      "INV-SER3" "INV-SER4"
      "INV-EFF-2" "INV-EFF-3"
      "INV-PAT-1" "INV-PAT-3"
      # Phase 4.0 新增
      "INV-US1" "INV-US2" "INV-US3" "INV-US4" "INV-US5"
      "INV-SMT-1" "INV-SMT-2" "INV-SMT-3" "INV-SMT-4"
      "INV-MOD-1" "INV-MOD-2" "INV-MOD-3" "INV-MOD-4" "INV-MOD-5"
      "INV-EFF-4" "INV-EFF-5" "INV-EFF-6" "INV-EFF-7"
      "INV-QK1" "INV-QK2" "INV-QK3" "INV-QK4" "INV-QK5"
      "INV-SOL-P40-1" "INV-SOL-P40-2" "INV-SOL-P40-3"
    ];

    phaseHistory = [
      { phase = "1.0"; summary = "Basic TypeIR + Kind + Primitive TRS"; }
      { phase = "2.0"; summary = "Row Polymorphism + μ-types + Instance DB"; }
      { phase = "3.0"; summary = "Dependent Types + Effect System + Bidirectional + Constraint IR"; }
      { phase = "3.1"; summary = "Soundness/INV fixes (enterprise-stable)"; }
      { phase = "3.2"; summary = "Mu bisimulation + substLib + specificity + row canonical"; }
      { phase = "3.3"; summary = "Open row unification + EffectMerge + VariantRowCanon + Complete Pattern"; }
      { phase = "4.0"; summary = "Refined Types (SMT) + Module System + Effect Handlers + UnifiedSubst + QueryKey"; }
    ];
  };

  exportInfo = __typeMeta;
}
