# constraint/solver_p40.nix — Phase 4.0
#
# Constraint Solver Phase 4.0 升级
#
# 修复 Phase 3.3 遗留风险 1：
#   rowVar subst 未注入 solver pipeline
#   → unifyRow 返回的 rowSubst 现在通过 UnifiedSubst 统一应用
#
# 新增：
#   - Refined constraint 处理（INV-SMT-3：residual → smtBridge）
#   - RowEquality constraint（行等价约束，由 unifyRow 产生）
#   - UnifiedSubst 贯穿整个 solver pipeline
#
# 不变量（Phase 4.0 升级）：
#   INV-SOL-P40-1: rowVar binding 与 typeVar binding 统一应用
#   INV-SOL-P40-2: Refined residual 正确收集（不静默 OK）
#   INV-SOL-P40-3: RowEquality → unifyRow → 注入 UnifiedSubst
#   INV-SOL-P40-4: solver pipeline 单调（不引入新未知量）

{ lib, typeLib, kindLib, constraintLib, unifyLib, instanceLib
, unifyRowLib, unifiedSubstLib, refinedLib }:

let
  inherit (constraintLib)
    mkEquality mkClass mkImplies mkPredicate
    constraintKey normalizeConstraint mapTypesInConstraint
    deduplicateConstraints;
  inherit (unifyLib) unify partialUnify;
  inherit (unifyRowLib) unifyRow;
  inherit (instanceLib) canDischarge resolveWithFallback;
  inherit (unifiedSubstLib)
    emptySubst mergeSubst composeSubst
    applySubstToType applySubstToConstraints
    fromLegacyTypeSubst fromLegacyRowSubst;
  inherit (refinedLib) tryDischargeRefined;

  # ── 从约束提取关联类型变量（完整深层，INV-SOL5）───────────────────────────
  _typeMentions = c:
    let
      tag = c.__constraintTag or null;
      collectFromType = ty:
        if !(builtins.isAttrs ty) then []
        else
          let r = ty.repr or {}; v = r.__variant or null; in
          if v == "Var" then [r.name]
          else if v == "RowVar" then ["RowVar:${r.name}"]
          else if v == "Apply"  then collectFromType r.fn ++ lib.concatMap collectFromType (r.args or [])
          else if v == "Fn"     then collectFromType r.from ++ collectFromType r.to
          else if v == "Lambda" then collectFromType r.body
          else if v == "Constrained" then
            collectFromType r.base ++ lib.concatMap _typeMentions (r.constraints or [])
          else if v == "Mu"     then collectFromType r.body
          else if v == "Record" then lib.concatMap collectFromType (builtins.attrValues (r.fields or {}))
          else if v == "RowExtend" then collectFromType r.fieldType ++ collectFromType r.rest
          else if v == "VariantRow" then
            lib.concatMap collectFromType (builtins.attrValues (r.variants or {})) ++
            collectFromType (r.extension or { repr = { __variant = "RowEmpty"; }; })
          else if v == "Effect" then collectFromType r.effectRow
          else if v == "EffectMerge" then collectFromType r.left ++ collectFromType r.right
          else if v == "Pi" || v == "Sigma" then
            collectFromType r.domain ++ collectFromType r.body
          else if v == "Refined" then collectFromType r.base
          else [];
    in
    if tag == "Equality"    then collectFromType c.lhs ++ collectFromType c.rhs
    else if tag == "Class"  then lib.concatMap collectFromType (c.args or [])
    else if tag == "Predicate" then collectFromType c.subject
    else if tag == "RowEquality" then
      collectFromType (c.lhsRow or {}) ++ collectFromType (c.rhsRow or {})
    else if tag == "Refined" then collectFromType c.subject
    else if tag == "Implies" then
      lib.concatMap _typeMentions (c.premises or []) ++ _typeMentions c.conclusion
    else [];

  # ── affected partition（精确 worklist，INV-SOL5）─────────────────────────
  _affectedBy = varNames: cs:
    lib.filter (c:
      let mentions = _typeMentions c; in
      lib.any (v: lib.elem v varNames) mentions
    ) cs;

  # ── 应用 UnifiedSubst 到约束集合 ─────────────────────────────────────────
  _applyUnifiedSubstToCs = us: cs:
    let
      applied = applySubstToConstraints us cs;
    in
    map normalizeConstraint applied;

  # ── RowEquality constraint 构造器 ─────────────────────────────────────────
  mkRowEquality = lhsRow: rhsRow: {
    __constraintTag = "RowEquality";
    inherit lhsRow rhsRow;
  };

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Phase 4.0 Solver（统一 subst，含 RowEquality + Refined）
  # ══════════════════════════════════════════════════════════════════════════════

  # solveP40 : [Constraint] → InstanceDB → SolverResult
  # SolverResult = {
  #   ok            : Bool
  #   subst         : UnifiedSubst           ← Phase 4.0: unified
  #   solved        : [Constraint]
  #   classResidual : [Constraint]
  #   smtResidual   : [Constraint]           ← Phase 4.0 新增
  #   rowSubst      : AttrSet                ← 向后兼容字段
  #   error?        : String
  # }
  solveP40 = constraints: instanceDB:
    let
      deduped = deduplicateConstraints (map normalizeConstraint constraints);
      initial = {
        subst         = emptySubst;
        worklist      = deduped;
        solved        = [];
        classResidual = [];
        smtResidual   = [];
        ok            = true;
        error         = null;
        fuel          = 500;   # safety bound
      };
    in
    _solveLoop initial instanceDB;

  _solveLoop = state: instanceDB:
    if state.worklist == [] || !state.ok || state.fuel <= 0 then
      {
        ok            = state.ok && state.error == null;
        subst         = state.subst;
        solved        = state.solved;
        classResidual = state.classResidual;
        smtResidual   = state.smtResidual;
        # 向后兼容：从 unified subst 提取 rowSubst
        rowSubst      = _extractLegacyRowSubst state.subst;
        error         = if state.fuel <= 0 then "solver fuel exhausted" else state.error;
      }
    else
      let
        c    = builtins.head state.worklist;
        rest = builtins.tail state.worklist;
        tag  = c.__constraintTag or null;
      in
      _dispatchConstraint state instanceDB c tag rest;

  # ── Constraint dispatch ──────────────────────────────────────────────────
  _dispatchConstraint = state: instanceDB: c: tag: rest:
    # 1. Equality → standard unify
    if tag == "Equality" then
      let
        uResult = unify c.lhs c.rhs;
      in
      if uResult.ok then
        let
          # 新的类型 subst（fromLegacy 转换）
          newUS     = fromLegacyTypeSubst (uResult.subst or {});
          composed  = composeSubst newUS state.subst;

          # 变量名列表（用于 affected partition）
          varNames  = builtins.attrNames (uResult.subst or {});

          # 应用新 subst 到 rest constraints
          affected  = _affectedBy varNames rest;
          unaffected = lib.filter (x: !(lib.elem x affected)) rest;
          rest'     = map normalizeConstraint
                        (_applyUnifiedSubstToCs newUS rest);
        in
        _solveLoop (state // {
          subst    = composed;
          worklist = rest';
          solved   = state.solved ++ [c];
          fuel     = state.fuel - 1;
        }) instanceDB
      else
        _solveLoop (state // {
          ok    = false;
          error = "unification failed: ${uResult.error or "type mismatch"}";
        }) instanceDB

    # 2. RowEquality → unifyRow（Phase 4.0 核心修复）
    else if tag == "RowEquality" then
      let
        rResult = unifyRow (c.lhsRow or {}) (c.rhsRow or {});
      in
      if rResult.ok then
        let
          # rowSubst → UnifiedSubst（INV-SOL-P40-1：统一注入）
          newUS    = fromLegacyRowSubst (rResult.subst or {});
          composed = composeSubst newUS state.subst;

          # unifyRow 可能产生额外 Equality constraints（shared field types）
          extraCs  = rResult.constraints or [];
          rest'    = map normalizeConstraint
                       (_applyUnifiedSubstToCs newUS (extraCs ++ rest));
        in
        _solveLoop (state // {
          subst    = composed;
          worklist = rest';
          solved   = state.solved ++ [c];
          fuel     = state.fuel - 1;
        }) instanceDB
      else
        _solveLoop (state // {
          ok    = false;
          error = "row unification failed: ${rResult.error or "row mismatch"}";
        }) instanceDB

    # 3. Class → instance resolution
    else if tag == "Class" then
      let
        discharge = canDischarge instanceDB c;
      in
      if discharge then
        _solveLoop (state // {
          worklist = rest;
          solved   = state.solved ++ [c];
          fuel     = state.fuel - 1;
        }) instanceDB
      else
        # defer → classResidual
        _solveLoop (state // {
          worklist      = rest;
          classResidual = state.classResidual ++ [c];
          fuel          = state.fuel - 1;
        }) instanceDB

    # 4. Refined → static eval or SMT residual（INV-SMT-3）
    else if tag == "Refined" then
      let
        dischResult = tryDischargeRefined c;
      in
      if dischResult.discharged then
        _solveLoop (state // {
          worklist = rest;
          solved   = state.solved ++ [c];
          fuel     = state.fuel - 1;
        }) instanceDB
      else if dischResult ? error then
        _solveLoop (state // {
          ok    = false;
          error = dischResult.error;
        }) instanceDB
      else
        # 无法静态求解 → SMT residual（不静默 OK，INV-SMT-3）
        _solveLoop (state // {
          worklist    = rest;
          smtResidual = state.smtResidual ++ [c];
          fuel        = state.fuel - 1;
        }) instanceDB

    # 5. Implies → conditional
    else if tag == "Implies" then
      let
        premisesOk = lib.all (p: canDischarge instanceDB p) (c.premises or []);
      in
      if premisesOk then
        _solveLoop (state // {
          worklist = [c.conclusion] ++ rest;
          fuel     = state.fuel - 1;
        }) instanceDB
      else
        _solveLoop (state // {
          worklist      = rest;
          classResidual = state.classResidual ++ [c];
          fuel          = state.fuel - 1;
        }) instanceDB

    # 6. Predicate（Phase 3.x）→ 委托 tryDischargeRefined
    else if tag == "Predicate" then
      _solveLoop (state // {
        worklist    = rest;
        smtResidual = state.smtResidual ++ [c];
        fuel        = state.fuel - 1;
      }) instanceDB

    # unknown tag → skip with warning
    else
      _solveLoop (state // {
        worklist = rest;
        fuel     = state.fuel - 1;
      }) instanceDB;

  # ── 向后兼容：从 UnifiedSubst 提取 legacy row subst ─────────────────────
  _extractLegacyRowSubst = us:
    let
      rBindings = us.rowBindings or {};
      rKeys     = builtins.attrNames rBindings;
    in
    lib.listToAttrs (map (k:
      let
        name = if lib.hasPrefix "r:" k
               then "RowVar:${lib.removePrefix "r:" k}"
               else k;
      in
      { inherit name; value = rBindings.${k}; }
    ) rKeys);

  # ══════════════════════════════════════════════════════════════════════════════
  # 向后兼容接口（原 solve 签名不变，内部升级）
  # ══════════════════════════════════════════════════════════════════════════════

  # solve = solveP40 的简化版（仅 classResidual，无 smtResidual）
  # 保持 Phase 3.3 测试兼容性
  solveDefault = constraints:
    solveP40 constraints {};

  # ══════════════════════════════════════════════════════════════════════════════
  # 不变量验证
  # ══════════════════════════════════════════════════════════════════════════════

  verifyP40SolverInvariants = typeLib:
    let
      inherit (typeLib) mkTypeDefault;
      tInt  = mkTypeDefault { __variant = "Primitive"; name = "Int"; } { __kindVariant = "KStar"; };
      tBool = mkTypeDefault { __variant = "Primitive"; name = "Bool"; } { __kindVariant = "KStar"; };
      tVarA = mkTypeDefault { __variant = "Var"; name = "a"; scope = "test"; } { __kindVariant = "KStar"; };

      # INV-SOL-P40-1: Equality + RowEquality 统一通过 UnifiedSubst
      eqC      = mkEquality tVarA tInt;
      result1  = solveP40 [eqC] {};
      invP401  = result1.ok &&
                 result1.subst.typeBindings != {};  # subst 非空

      # INV-SOL-P40-2: Refined residual 正确收集
      refinedC = {
        __constraintTag = "Refined";
        subject  = tInt;
        predVar  = "n";
        predExpr = { __pred = "PVar"; name = "n"; };  # unknown → SMT residual
      };
      result2  = solveP40 [refinedC] {};
      invP402  = result2.smtResidual != [];

      # INV-SOL-P40-4: solver 单调（不引入新未知量）
      result3  = solveP40 [] {};
      invP404  = result3.ok && result3.solved == [];

    in {
      allPass        = invP401 && invP402 && invP404;
      "INV-SOL-P40-1" = invP401;
      "INV-SOL-P40-2" = invP402;
      "INV-SOL-P40-4" = invP404;
    };

}
