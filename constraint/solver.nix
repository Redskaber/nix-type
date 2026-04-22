# constraint/solver.nix — Phase 4.2
# Worklist 约束 Solver（合并版）
# INV-SOL1: 等价约束规范化（对称性 + NF-hash）
# INV-SOL5: worklist requeue（subst 传播完整）
{ lib, typeLib, reprLib, kindLib, constraintLib, substLib, unifiedSubstLib,
  unifyLib, unifyRowLib, instanceLib, hashLib, normalizeLib }:

let
  inherit (typeLib) isType;
  inherit (constraintLib) isConstraint isEqConstraint isClassConstraint
    isRowEqConstraint isImpliesConstraint isRefinedConstraint
    isSchemeConstraint mkEqConstraint;
  inherit (unifiedSubstLib) emptySubst composeSubst applySubst
    applySubstToConstraints fromLegacyTypeSubst fromLegacyRowSubst isEmpty;
  inherit (unifyLib) unify;
  inherit (unifyRowLib) unifyRow;
  inherit (normalizeLib) normalize' normalizeConstraint deduplicateConstraints;
  inherit (hashLib) typeHash constraintHash;

  DEFAULT_FUEL = 2000;

in rec {

  # ══ Solver 结果结构 ════════════════════════════════════════════════════
  mkSolverResult = ok: subst: solved: classResidual: smtResidual: rowSubst:
    { inherit ok subst solved classResidual smtResidual;
      rowSubst = rowSubst;  # 向后兼容（from subst.rowBindings）
    };

  failResult = error:
    { ok = false; error = error; subst = emptySubst; solved = [];
      classResidual = []; smtResidual = []; rowSubst = {}; };

  # ══ Worklist 初始化 ════════════════════════════════════════════════════
  _initState = constraints: classGraph: instanceDB:
    { worklist      = deduplicateConstraints (map normalizeConstraint constraints);
      subst         = emptySubst;
      solved        = [];
      classResidual = [];
      smtResidual   = [];
      classGraph    = classGraph;
      instanceDB    = instanceDB;
      fuel          = DEFAULT_FUEL; };

  # ══ 主求解循环（worklist，fuel-bounded）══════════════════════════════
  _solveLoop = state:
    if state.fuel <= 0 then
      mkSolverResult
        (state.worklist == [])
        state.subst state.solved
        state.classResidual state.smtResidual
        state.subst.rowBindings
    else if state.worklist == [] then
      mkSolverResult true state.subst state.solved
        state.classResidual state.smtResidual
        state.subst.rowBindings
    else
      let
        c    = builtins.head state.worklist;
        rest = builtins.tail state.worklist;
        tag  = c.__constraintTag or null;
      in
      # ── Equality ────────────────────────────────────────────────────
      if tag == "Equality" then
        let
          lhs  = applySubst state.subst c.lhs;
          rhs  = applySubst state.subst c.rhs;
          r    = unify lhs rhs;
        in
        if !r.ok then
          state // { worklist = []; fuel = 0; }  # fail: terminate
          # Return failure through result
        else
          let
            newSubst   = composeSubst r.subst state.subst;
            # INV-SOL5: requeue all remaining with new subst
            newWorklist = applySubstToConstraints r.subst rest;
          in
          _solveLoop (state // {
            worklist = newWorklist;
            subst    = newSubst;
            solved   = state.solved ++ [ c ];
            fuel     = state.fuel - 1;
          })
      # ── RowEquality ─────────────────────────────────────────────────
      else if tag == "RowEquality" then
        let
          lhsR = applySubst state.subst c.lhsRow;
          rhsR = applySubst state.subst c.rhsRow;
          r    = unifyRow lhsR rhsR;
        in
        if !r.ok then
          state // { worklist = []; fuel = 0; }
        else
          let
            newSubst    = composeSubst r.subst state.subst;
            newWorklist = applySubstToConstraints r.subst rest;
          in
          _solveLoop (state // {
            worklist = newWorklist;
            subst    = newSubst;
            solved   = state.solved ++ [ c ];
            fuel     = state.fuel - 1;
          })
      # ── Class ────────────────────────────────────────────────────────
      else if tag == "Class" then
        let
          normArgs = map (applySubst state.subst) c.args;
          resolved = instanceLib.resolveWithFallback
            state.classGraph state.instanceDB c.className normArgs;
        in
        if resolved.found && resolved.impl != null then
          # INV-SOL: impl != null → discharged（RISK-A 修复）
          _solveLoop (state // {
            worklist = rest;
            solved   = state.solved ++ [ c ];
            fuel     = state.fuel - 1;
          })
        else
          # Class residual（no instance found）
          _solveLoop (state // {
            worklist      = rest;
            classResidual = state.classResidual ++ [ (c // { args = normArgs; }) ];
            fuel          = state.fuel - 1;
          })
      # ── Refined ─────────────────────────────────────────────────────
      else if tag == "Refined" then
        let
          subject  = applySubst state.subst c.subject;
          staticR  = _staticEvalPred c.predVar c.predExpr subject;
        in
        if staticR.ok && staticR.discharged then
          _solveLoop (state // {
            worklist = rest;
            solved   = state.solved ++ [ c ];
            fuel     = state.fuel - 1;
          })
        else
          # SMT residual
          _solveLoop (state // {
            worklist    = rest;
            smtResidual = state.smtResidual ++ [ (c // { subject = subject; }) ];
            fuel        = state.fuel - 1;
          })
      # ── Implies ──────────────────────────────────────────────────────
      else if tag == "Implies" then
        let
          allSolved = builtins.all (p:
            builtins.any (s: (s.__constraintTag or null) == (p.__constraintTag or null) &&
              builtins.toJSON s == builtins.toJSON p
            ) state.solved
          ) c.premises;
        in
        if allSolved then
          _solveLoop (state // {
            worklist = [ c.conclusion ] ++ rest;
            fuel     = state.fuel - 1;
          })
        else
          # Defer implies until premises are solved
          _solveLoop (state // {
            worklist = rest ++ [ c ];  # put back at end
            fuel     = state.fuel - 1;
          })
      # ── Scheme（Phase 4.2）─────────────────────────────────────────
      else if tag == "Scheme" then
        let
          instResult = _instantiateScheme c.scheme;
          eqC        = mkEqConstraint instResult.type c.ty;
        in
        _solveLoop (state // {
          worklist = [ eqC ] ++ instResult.constraints ++ rest;
          fuel     = state.fuel - 1;
        })
      # ── Kind（Phase 4.2）───────────────────────────────────────────
      else if tag == "Kind" then
        # Kind constraints currently deferred to residual
        _solveLoop (state // {
          worklist      = rest;
          classResidual = state.classResidual ++ [ c ];
          fuel          = state.fuel - 1;
        })
      # ── Unknown → residual ──────────────────────────────────────────
      else
        _solveLoop (state // {
          worklist      = rest;
          classResidual = state.classResidual ++ [ c ];
          fuel          = state.fuel - 1;
        });

  # ══ TypeScheme 实例化（Phase 4.2）════════════════════════════════════
  # Type: TypeScheme → { type: Type; constraints: [Constraint] }
  _instantiateScheme = scheme:
    if !builtins.isAttrs scheme || (scheme.__schemeTag or null) != "Scheme" then
      { type = scheme; constraints = []; }
    else
      let
        # 为每个 forall 变量生成新鲜变量
        freshVars = builtins.listToAttrs (map (v:
          let freshName = "_fresh_${v}_${builtins.hashString "sha256" v}"; in
          lib.nameValuePair v (typeLib.mkTypeDefault (reprLib.rVar freshName "inst") kindLib.KStar)
        ) scheme.forall);
        # 应用替换
        instType = lib.foldl' (acc: v:
          substLib.substitute v freshVars.${v} acc
        ) scheme.body scheme.forall;
        # 应用约束替换
        instCons = map (c:
          unifiedSubstLib.applySubstToConstraint
            (unifiedSubstLib.fromLegacyTypeSubst freshVars) c
        ) scheme.constraints;
      in
      { type = instType; constraints = instCons; };

  # ══ Static predicate evaluation（Refined Types）═══════════════════════
  _staticEvalPred = predVar: predExpr: subject:
    let tag = predExpr.__predTag or null; in
    if tag == "PTrue"  then { ok = true; discharged = true; }
    else if tag == "PFalse" then { ok = true; discharged = false; }
    else { ok = false; discharged = false; };  # defer to SMT

  # ══ Public API ════════════════════════════════════════════════════════

  # Type: AttrSet → AttrSet → [Constraint] → SolverResult
  solve = classGraph: instanceDB: constraints:
    let
      state  = _initState constraints classGraph instanceDB;
      result = _solveLoop state;
    in
    if result.ok then result
    else failResult (result.error or "solver failed");

  # Simple solve（no class/instance context）
  solveSimple = constraints:
    solve {} {} constraints;

  # ══ Subst 提取（legacy API）══════════════════════════════════════════
  getTypeSubst = result: result.subst.typeBindings or {};
  getRowSubst  = result: result.subst.rowBindings or {};
}
