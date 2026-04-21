# lib/default.nix — Phase 3
# 统一模块入口（Nix Type System Library Phase 3）
#
# 模块装配顺序（严格依赖拓扑序）：
#   1.  kindLib       — 无依赖
#   2.  metaLib       — 无依赖
#   3.  reprLib       — 无依赖（仅 lib）
#   4.  serialLib     — 无依赖（仅 lib）
#   5.  typeLib       — kindLib, metaLib, serialLib（延迟）
#   6.  substLib      — typeLib, reprLib
#   7.  rulesLib      — reprLib, substLib, kindLib, typeLib
#   8.  normalizeLib  — typeLib, reprLib, rulesLib, substLib, kindLib
#   9.  hashLib       — serialLib, normalizeLib, typeLib
#   10. eqLib         — typeLib, normalizeLib, serialLib, metaLib
#   11. constraintLib — lib（无 typeLib 依赖，避免循环）
#   12. unifyLib      — reprLib, typeLib, serialLib
#   13. solverLib     — constraintLib, unifyLib
#   14. graphLib      — lib
#   15. memoLib       — hashLib
#   16. matchLib      — typeLib, reprLib
#   17. instanceLib   — typeLib, hashLib, constraintLib, normalizeLib
#   18. bidirLib      — typeLib, normalizeLib, constraintLib, unifyLib, reprLib
#
# Phase 3 新增模块：
#   - bidirLib（bidir/check.nix）— Bidirectional Type Checking（P3-0）
#   - Pi/Sigma/Effect 全链路（repr → rules → normalize → unify → bidir）
#   - Open ADT（extendADT）
#   - Worklist Solver（constraint/solver.nix Phase 3）
{ lib }:

let

  # ── 1. Kind System ─────────────────────────────────────────────────────────
  kindLib = import ../core/kind.nix { inherit lib; };

  # ── 2. MetaType ────────────────────────────────────────────────────────────
  metaLib = import ../core/meta.nix { inherit lib; };

  # ── 3. TypeRepr ────────────────────────────────────────────────────────────
  reprLib = import ../repr/all.nix { inherit lib; };

  # ── 4. Serializer（α-canonical，Phase 3）──────────────────────────────────
  serialLib = import ../meta/serialize.nix { inherit lib; };

  # ── 5. TypeIR Core（依赖 serialLib 延迟传入）──────────────────────────────
  typeLib = import ../core/type.nix {
    inherit lib kindLib metaLib serialLib;
  };

  # ── 6. Substitution ────────────────────────────────────────────────────────
  substLib = import ../normalize/substitute.nix {
    inherit lib reprLib typeLib;
  };

  # ── 7. TRS Rules（Phase 3：Pi-reduction + kind 修复）──────────────────────
  rulesLib = import ../normalize/rules.nix {
    inherit lib reprLib substLib kindLib typeLib;
  };

  # ── 8. Normalize Engine ────────────────────────────────────────────────────
  normalizeLib = import ../normalize/rewrite.nix {
    inherit lib reprLib rulesLib substLib kindLib typeLib;
  };

  # ── 9. Hash（Phase 3：统一 typeHash = nfHash ∘ normalize）────────────────
  hashLib = import ../meta/hash.nix {
    inherit lib serialLib normalizeLib typeLib;
  };

  # ── 10. Equality（Phase 3：Coherence Law + muEq bisimulation）────────────
  eqLib = import ../meta/equality.nix {
    inherit lib typeLib normalizeLib serialLib metaLib;
  };

  # ── 11. Constraint IR（Phase 3：normalizeConstraint + dedup）─────────────
  constraintLib = import ../constraint/ir.nix { inherit lib; };

  # ── 12. Unification（Phase 3：alpha-canonical Lambda + Pi/Sigma）─────────
  unifyLib = import ../constraint/unify.nix {
    inherit lib reprLib typeLib;
    serialLib = serialLib;
  };

  # ── 13. Constraint Solver（Phase 3：Worklist）────────────────────────────
  solverLib = import ../constraint/solver.nix {
    inherit lib constraintLib unifyLib;
  };

  # ── 14. Dependency Graph ──────────────────────────────────────────────────
  graphLib = import ../incremental/graph.nix { inherit lib; };

  # ── 15. Memo Layer（Phase 3：epoch + NF-hash key）────────────────────────
  memoLib = import ../incremental/memo.nix { inherit lib hashLib; };

  # ── 16. Pattern Matching（Phase 3：Decision Tree + exhaustiveness）────────
  matchLib = import ../match/pattern.nix { inherit lib typeLib reprLib; };

  # ── 17. Instance Database（Phase 3：coherence + superclass）─────────────
  instanceLib = import ../runtime/instance.nix {
    inherit lib typeLib hashLib normalizeLib constraintLib;
  };

  # ── 18. Bidirectional Type Checking（Phase 3 新增，P3-0）────────────────
  bidirLib = import ../bidir/check.nix {
    inherit lib typeLib normalizeLib constraintLib unifyLib reprLib;
  };

in {

  # ══════════════════════════════════════════════════════════════════════════════
  # 模块级 re-export（供直接使用）
  # ══════════════════════════════════════════════════════════════════════════════

  inherit
    kindLib metaLib reprLib serialLib typeLib substLib
    rulesLib normalizeLib hashLib eqLib constraintLib
    unifyLib solverLib graphLib memoLib matchLib
    instanceLib bidirLib;

  # ══════════════════════════════════════════════════════════════════════════════
  # 顶层 API（便捷 re-export）
  # ══════════════════════════════════════════════════════════════════════════════

  # ── Kind ─────────────────────────────────────────────────────────────────
  inherit (kindLib)
    KStar KArrow KRow KEffect KVar KUnbound KError
    KStar1 KStar2 KHO1 KRowToStar KEffToStarToStar
    kindEq kindCheck kindUnify kindNormalize kindSubst kindInferRepr
    serializeKind;

  # ── Meta ─────────────────────────────────────────────────────────────────
  inherit (metaLib)
    defaultMeta nominalMeta opaqueMeta recursiveMeta rowMeta effectMeta
    mergeMeta validateMeta isMeta isNominal isOpaque;

  # ── TypeRepr ─────────────────────────────────────────────────────────────
  inherit (reprLib)
    rPrimitive rVar rVarDB rVarScoped
    rLambda rApply rFn
    rConstructor rADT rConstrained
    rMu rRecord rVariantRow rRowExtend rRowEmpty
    rPi rSigma rEffect rOpaque rAscribe  # Phase 3 新增
    mkVariant mkADTFromVariants extendADT  # Open ADT
    freeVarsRepr buildRowSpine;

  # ── TypeIR Core ───────────────────────────────────────────────────────────
  inherit (typeLib)
    mkType mkTypeWith mkTypeDefault mkBootstrapType
    withRepr withKind withMeta withConstraints
    isType isTypeStrict
    reprOf kindOf metaOf idOf phaseOf labelOf
    reprVariant validateType showType debugType stableId;

  # ── Normalize ────────────────────────────────────────────────────────────
  inherit (normalizeLib)
    normalize normalizeWith normalize'
    isNormalForm isNormalFormDeep
    normalizeAndCheckKind;

  # ── Substitution ──────────────────────────────────────────────────────────
  inherit (substLib)
    substitute substituteAll composeSubst
    deBruijnify flattenRow buildRow freeVars;

  # ── Serialize ─────────────────────────────────────────────────────────────
  inherit (serialLib)
    serializeRepr serializeReprAlphaCanonical;

  # ── Hash / Equality ───────────────────────────────────────────────────────
  inherit (hashLib)
    typeHash nfHash memoKey memoKeyNS
    combineHashes combineTwo
    hashCons emptyHashConsTable
    typeHashCached emptyHashMemo
    verifyHashConsistency verifyHashInvariants;

  inherit (eqLib)
    typeEq alphaEq nominalEq structuralEq muEq rowEq
    listTypeEq attrTypeEq checkCoherence;

  # ── Constraint ────────────────────────────────────────────────────────────
  inherit (constraintLib)
    mkClass mkEquality mkPredicate mkImplies
    isConstraint isClass isEquality isPredicate isImplies
    constraintKey constraintsHash deduplicateConstraints mergeConstraints
    normalizeConstraint mapTypesInConstraint
    defaultClassGraph isSuperclassOf;

  # ── Unification ───────────────────────────────────────────────────────────
  inherit (unifyLib)
    unify emptySubst occursIn
    unifyRecord unifyVariantRow;

  # ── Solver（Phase 3：Worklist）──────────────────────────────────────────
  inherit (solverLib)
    solve solveDefault solveWithDB solveWithGraph
    emptyInstanceDB register resolve withBuiltinInstances;

  # ── Incremental ───────────────────────────────────────────────────────────
  inherit (graphLib)
    emptyGraph addNode removeNode addEdge
    setNodeState propagateDirty batchUpdate
    getNode getDeps getRevDeps getState dirtyNodes
    topologicalSort showGraph NodeState;

  inherit (memoLib)
    emptyMemo bumpEpoch invalidateType
    memoLookupNormalize memoStoreNormalize
    memoLookupSubst memoStoreSubst
    memoLookupSolve memoStoreSolve
    withMemoNormalize memoStats showMemoStats;

  # ── Pattern Matching ──────────────────────────────────────────────────────
  inherit (matchLib)
    pWild pVar pLit pCtor pRecord pVariant pGuard pOr pTuple
    mkFieldPat mkRecordPat mkVariantRowPat
    compilePats checkExhaustiveness checkRedundancy;

  # ── Instance DB ───────────────────────────────────────────────────────────
  inherit (instanceLib)
    emptyInstanceDB register resolve withBuiltinInstances  # Duplicated name definition
    resolveWithFallback canDischarge listInstances instanceCount;

  # ── Bidirectional（Phase 3 新增）─────────────────────────────────────────
  inherit (bidirLib)
    check infer
    tVar tLam tApp tAscribe tLet tLit tMatch mkBranch
    emptyCtx ctxBind ctxLookup;

  # ══════════════════════════════════════════════════════════════════════════════
  # 版本信息
  # ══════════════════════════════════════════════════════════════════════════════

  version = "3.0.0-phase3";
  phase   = 3;

  # ══════════════════════════════════════════════════════════════════════════════
  # 系统不变量验证（运行时）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: {} -> { ok: Bool; violations: [String] }
  verifyInvariants = {}:
    let
      # INV-1：TypeIR 基础
      testType = typeLib.mkTypeDefault
        (reprLib.rPrimitive "TestInt") kindLib.KStar;
      inv1 = typeLib.isType testType;

      # INV-T1：kind ≠ null（KUnbound 替代）
      nullKindType = typeLib.withKind testType null;
      inv_t1 = nullKindType.kind != null;

      # INV-T2：stableId 确定性
      repr1 = reprLib.rPrimitive "X";
      repr2 = reprLib.rPrimitive "X";
      id1   = typeLib.stableId repr1;
      id2   = typeLib.stableId repr2;
      inv_t2 = id1 == id2;

      # INV-H2：typeHash = nfHash ∘ normalize
      h1 = hashLib.typeHash testType;
      nf = normalizeLib.normalize testType;
      h2 = hashLib.nfHash nf;
      inv_h2 = h1 == h2;

      # INV-3：NF equality
      t1 = typeLib.mkTypeDefault (reprLib.rPrimitive "Int") kindLib.KStar;
      t2 = typeLib.mkTypeDefault (reprLib.rPrimitive "Int") kindLib.KStar;
      inv3 = eqLib.typeEq t1 t2;

      # INV-6：Constraint ∈ TypeRepr（Constrained repr 存在）
      c   = constraintLib.mkClass "Show" [testType];
      ct  = typeLib.mkTypeDefault (reprLib.rConstrained testType [c]) kindLib.KStar;
      inv6 = ct.repr.__variant == "Constrained";

      # INV-EQ2：Coherence Law（structural ⊆ nominal ⊆ hash）
      coh = eqLib.checkCoherence t1 t2;
      inv_eq2 = coh.coherent;

      # INV-K4：kindUnify 纯函数（返回 ok）
      ku = kindLib.kindUnify {} kindLib.KStar kindLib.KStar;
      inv_k4 = ku.ok;

      violations =
        (if !inv1    then ["INV-1: TypeIR construction"]        else [])
        ++ (if !inv_t1 then ["INV-T1: null kind → KUnbound"]   else [])
        ++ (if !inv_t2 then ["INV-T2: stableId determinism"]   else [])
        ++ (if !inv_h2 then ["INV-H2: typeHash = nfHash∘norm"] else [])
        ++ (if !inv3   then ["INV-3: NF equality"]             else [])
        ++ (if !inv6   then ["INV-6: Constraint ∈ TypeRepr"]   else [])
        ++ (if !inv_eq2 then ["INV-EQ2: Coherence Law"]        else [])
        ++ (if !inv_k4  then ["INV-K4: kindUnify pure"]        else []);
    in
    { ok = builtins.length violations == 0; inherit violations; };

}
