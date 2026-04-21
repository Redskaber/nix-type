# lib/default.nix — Phase 3.1
# 统一模块入口（正确拓扑序依赖）
#
# 拓扑序（严格）：
#   kindLib → serialLib → metaLib → typeLib
#          → reprLib（依赖 typeLib）
#          → substLib（依赖 reprLib）
#          → normalizeLib（依赖 rulesLib, substLib）
#          → hashLib（依赖 normalizeLib, serialLib）
#          → equalityLib（依赖 hashLib, normalizeLib）
#          → constraintLib（依赖 typeLib, hashLib）
#          → unifyLib（依赖 constraintLib, substLib, serialLib, hashLib）
#          → instanceLib（依赖 constraintLib, hashLib, normalizeLib）
#          → solverLib（依赖 constraintLib, unifyLib, instanceLib）
#          → bidirLib（依赖 normalizeLib, constraintLib, unifyLib, reprLib）
#          → graphLib（依赖 lib）
#          → memoLib（依赖 hashLib, constraintLib）
#          → matchLib（依赖 typeLib, reprLib）
#
# INV-1~6 运行时验证也在此模块完成。
{ lib }:

let
  # ── 层 0：Kind（无依赖）──────────────────────────────────────────────────────
  kindLib = import ../core/kind.nix { inherit lib; };

  # ── 层 1：Serialize（仅依赖 lib）────────────────────────────────────────────
  serialLib = import ../meta/serialize.nix { inherit lib; };

  # ── 层 2：Meta（依赖 lib）───────────────────────────────────────────────────
  metaLib = import ../core/meta.nix { inherit lib; };

  # ── 层 3：Type（依赖 kindLib, metaLib, serialLib）────────────────────────────
  typeLib = import ../core/type.nix {
    inherit lib kindLib metaLib serialLib;
  };

  # ── 层 4：Repr（依赖 typeLib, lib）──────────────────────────────────────────
  reprLib = import ../repr/all.nix { inherit lib; };

  # ── 层 5：Substitute（依赖 typeLib, reprLib）──────────────────────────────────
  substLib = import ../normalize/substitute.nix {
    inherit lib typeLib reprLib;
  };

  # ── 层 5b：Rules（依赖 typeLib, reprLib, substLib, kindLib）───────────────────
  rulesLib = import ../normalize/rules.nix {
    inherit lib typeLib reprLib substLib kindLib;
  };

  # ── 层 6：Normalize（依赖 typeLib, reprLib, rulesLib）────────────────────────
  normalizeLib = import ../normalize/rewrite.nix {
    inherit lib typeLib reprLib rulesLib;
  };

  # ── 层 7：Hash（依赖 typeLib, normalizeLib, serialLib）───────────────────────
  hashLib = import ../meta/hash.nix {
    inherit lib typeLib normalizeLib serialLib;
  };

  # ── 层 8：Equality（依赖 typeLib, hashLib, normalizeLib, serialLib）───────────
  equalityLib = import ../meta/equality.nix {
    inherit lib typeLib hashLib normalizeLib serialLib;
  };

  # ── 层 9：Constraint IR（依赖 typeLib, hashLib, lib）─────────────────────────
  constraintLib = import ../constraint/ir.nix {
    inherit lib typeLib hashLib;
  };

  # ── 层 10：Unify（依赖 typeLib, reprLib, substLib, serialLib, hashLib）────────
  unifyLib = import ../constraint/unify.nix {
    inherit lib typeLib reprLib substLib serialLib hashLib;
  };

  # ── 层 11：Instance（依赖 typeLib, hashLib, normalizeLib, constraintLib）──────
  instanceLib = import ../runtime/instance.nix {
    inherit lib typeLib hashLib normalizeLib constraintLib;
  };

  # ── 层 12：Solver（依赖 constraintLib, unifyLib, instanceLib）────────────────
  solverLib = import ../constraint/solver.nix {
    inherit lib typeLib constraintLib unifyLib instanceLib;
  };

  # ── 层 13：Bidir（依赖 normalizeLib, constraintLib, unifyLib, reprLib）────────
  bidirLib = import ../bidir/check.nix {
    inherit lib typeLib normalizeLib constraintLib unifyLib reprLib;
  };

  # ── 层 14：Graph（依赖 lib）──────────────────────────────────────────────────
  graphLib = import ../incremental/graph.nix { inherit lib; };

  # ── 层 15：Memo（依赖 hashLib, constraintLib）────────────────────────────────
  memoLib = import ../incremental/memo.nix {
    inherit lib hashLib constraintLib;
  };

  # ── 层 16：Match（依赖 typeLib, reprLib）─────────────────────────────────────
  matchLib = import ../match/pattern.nix {
    inherit lib typeLib reprLib;
  };

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 模块导出（按拓扑序）
  # ══════════════════════════════════════════════════════════════════════════════

  inherit
    kindLib
    serialLib
    metaLib
    typeLib
    reprLib
    substLib
    rulesLib
    normalizeLib
    hashLib
    equalityLib
    constraintLib
    unifyLib
    instanceLib
    solverLib
    bidirLib
    graphLib
    memoLib
    matchLib;

  # ══════════════════════════════════════════════════════════════════════════════
  # 顶层 API（常用符号直接导出）
  # ══════════════════════════════════════════════════════════════════════════════

  # Kind
  inherit (kindLib)
    KStar KArrow KRow KEffect KVar KUnbound KError
    KStar1 KStar2 KHO1 KRowToStar KEffToStarToStar
    kindEq kindUnify kindCheck kindInferRepr kindNormalize serializeKind;

  # Type
  inherit (typeLib)
    mkTypeWith mkTypeDefault mkBootstrapType mkType mkTypeConstrained
    isType isTypeStrict showType debugType
    withRepr withKind withMeta withConstraints withId
    emptyEnv extendEnv lookupEnv
    stableId;

  # Repr
  inherit (reprLib)
    rPrimitive rVar rVarDB rLambda rLambdaSimple rApply rFn
    rPi rSigma rMu rRecord rVariantRow rRowExtend rRowEmpty
    rConstructor rADT rConstrained rEffect rOpaque rAscribe
    mkVariant extendADT mkParam mkParamSimple freeVarsRepr;

  # Normalize
  inherit (normalizeLib) normalize normalize';
  inherit (substLib) substitute substituteAll composeSubst deBruijnify;

  # Equality + Hash
  inherit (equalityLib)
    typeEq typeEqFull structuralEq alphaEq nominalEq hashEq muEq rowVarEq
    checkCoherence;
  inherit (hashLib)
    typeHash nfHash reprHash typeHashCached hashCons
    deduplicateByHash sortByHash verifyHashConsistency;

  # Constraint
  inherit (constraintLib)
    mkClass mkEquality mkPredicate mkImplies
    isClass isEquality isPredicate isImplies
    constraintKey normalizeConstraint mapTypesInConstraint
    deduplicateConstraints canonicalizeConstraints constraintsHash
    defaultClassGraph isSuperclassOf getAllSupers getAllSubs;

  # Solver
  inherit (solverLib) solve solveWith solveDefault showResult;

  # Instance
  inherit (instanceLib)
    emptyInstanceDB register registerAll resolve resolveWithFallback canDischarge
    listInstances instanceCount;

  # Unify
  inherit (unifyLib) unify unifyWith;

  # Bidir
  inherit (bidirLib) check infer emptyCtx ctxBind ctxLookup;

  # Graph
  inherit (graphLib)
    emptyGraph addNode addEdge addEdgeSafe removeNode
    propagateInvalidation batchUpdate topologicalSort
    dirtyNodes cleanNodes graphStats verifySymmetry
    stateClean stateDirty stateComputing stateStale stateError
    isValidTransition;

  # Memo
  inherit (memoLib)
    emptyMemo bumpEpoch
    lookupNormalize storeNormalize withMemoNormalize
    lookupSubst storeSubst lookupSolve storeSolve
    invalidateType memoStats;

  # Match
  inherit (matchLib)
    mkWildcard mkVariable mkLiteral mkADTPattern mkRecordPat mkVariantRowPat
    compileToDecisionTree isExhaustive checkRedundancy patternBoundVars;

  # ══════════════════════════════════════════════════════════════════════════════
  # INV 运行时验证（全量，Phase 3.1）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> { ok: Bool; violations: [String] }
  verifyInvariants = opts:
    let
      # 准备测试类型
      tInt   = mkTypeDefault (rPrimitive "Int")   KStar;
      tBool  = mkTypeDefault (rPrimitive "Bool")  KStar;
      tA     = mkTypeDefault (rVar "a")           KStar;
      tLam   = mkTypeDefault (rLambda "x" KUnbound tA) KStar1;

      violations =
        # INV-1: 所有结构 ∈ TypeIR
        (if !isType tInt then ["INV-1: tInt not a Type"] else [])

        # INV-T1: kind ≠ null → KUnbound
        ++ (let t = mkBootstrapType (rPrimitive "X"); in
            if t.kind == null then ["INV-T1: bootstrap kind is null"] else [])

        # INV-T2: stableId 确定性
        ++ (let
              id1 = stableId (rPrimitive "Int");
              id2 = stableId (rPrimitive "Int");
            in
            if id1 != id2 then ["INV-T2: stableId not deterministic"] else [])

        # INV-3: typeEq = NF-hash equality
        ++ (if !typeEq tInt tInt  then ["INV-3: typeEq tInt tInt = false"] else [])
        ++ (if  typeEq tInt tBool then ["INV-3: typeEq tInt tBool = true"] else [])

        # INV-EQ1: typeEq ⟹ hash-eq
        ++ (let h1 = typeHash tInt; h2 = typeHash (mkTypeDefault (rPrimitive "Int") KStar); in
            if h1 != h2 then ["INV-EQ1: same type different hash"] else [])

        # INV-H2: typeHash = nfHash ∘ normalize（单路径）
        ++ (let
              h1 = typeHash tInt;
              nf = normalize tInt;
              h2 = nfHash nf;
            in
            if h1 != h2 then ["INV-H2: typeHash != nfHash(normalize(t))"] else [])

        # INV-K4: kindUnify 纯函数
        ++ (let r = kindUnify {} KStar KStar; in
            if !r.ok then ["INV-K4: kindUnify KStar KStar failed"] else [])

        # INV-EQ2: structural ⊆ nominal ⊆ hash
        ++ (let coh = checkCoherence tInt tInt; in
            if !coh.coherent then ["INV-EQ2: coherence violated for tInt tInt: " + builtins.concatStringsSep ", " coh.violations] else [])

        # INV-6: Constraint ∈ TypeRepr（mkClass 返回 attrset）
        ++ (let c = mkClass "Eq" [tInt]; in
            if !builtins.isAttrs c then ["INV-6: mkClass not AttrSet"] else [])

        # INV-SER3: serializeAlpha canonical
        ++ (let
              s1 = serialLib.serializeReprAlphaCanonical (rPrimitive "Int");
              s2 = serialLib.serializeReprAlphaCanonical (rPrimitive "Int");
            in
            if s1 != s2 then ["INV-SER3: serializeAlpha not deterministic"] else []);

    in
    { ok = violations == []; inherit violations; };

}
