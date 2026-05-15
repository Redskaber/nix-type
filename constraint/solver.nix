# constraint/solver.nix — Phase 4.3
# Worklist 约束 Solver（合并版）
# INV-SOL1:   等价约束规范化（对称性 + NF-hash）
# INV-SOL5:   worklist requeue（subst 传播完整）
# INV-KIND-1: Kind constraints 真正求解（Phase 4.3 新增）
#             Phase 4.2 中 Kind 约束仅 defer → classResidual
#             Phase 4.3 调用 kindLib.solveKindConstraints → 真正 unifyKind
{ lib, typeLib, reprLib, kindLib, constraintLib, substLib, unifiedSubstLib,
  unifyLib, unifyRowLib, instanceLib, hashLib, normalizeLib }:

let
  inherit (typeLib) isType;
  inherit (kindLib) unifyKind solveKindConstraints composeKindSubst applyKindSubst;
  inherit (constraintLib) isConstraint isEqConstraint isClassConstraint
    isRowEqConstraint isImpliesConstraint isRefinedConstraint
    isSchemeConstraint mkEqConstraint;
  inherit (unifiedSubstLib) emptySubst composeSubst applySubst singleKindBinding
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
      rowSubst = rowSubst;
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
      # Phase 4.3: separate kind constraint accumulator
      kindConstraints = [];
      classGraph    = classGraph;
      instanceDB    = instanceDB;
      fuel          = DEFAULT_FUEL;
      failed        = false;
      error         = null;
    };

  # ── 从 state 构造最终 SolverResult ──────────────────────────────────
  _stateToResult = state:
    if state.failed or false then
      failResult (state.error or "solver failed")
    else
      # Phase 4.3: solve collected Kind constraints
      let
        kindResult = solveKindConstraints (state.kindConstraints or []);
        # Integrate kind subst into unified subst
        finalSubst =
          if kindResult.ok then
            # merge kind bindings into subst
            let kb = kindResult.subst; in
            lib.foldl' (acc: kvar:
              let newKindBinding = singleKindBinding kvar kb.${kvar}; in
              composeSubst newKindBinding acc
            ) state.subst (builtins.attrNames kb)
          else state.subst;
      in
      mkSolverResult
        (state.worklist == [] && kindResult.ok)
        finalSubst
        state.solved
        (state.classResidual ++ kindResult.residual)
        state.smtResidual
        (finalSubst.rowBindings or {});

  # ══ 主求解循环（worklist，fuel-bounded）══════════════════════════════
  _solveLoop = state:
    if state.fuel <= 0 then
      _stateToResult state
    else if state.worklist == [] then
      _stateToResult state
    else if state.failed or false then
      _stateToResult state
    else
      let
        c    = builtins.head state.worklist;
        rest = builtins.tail state.worklist;
        tag  = c.__constraintTag or null;
      in

      # ── Equality ──────────────────────────────────────────────────
      if tag == "Equality" then
        let
          lhs = applySubst state.subst c.lhs;
          rhs = applySubst state.subst c.rhs;
          r   = unify lhs rhs;
        in
        if !r.ok then
          failResult (r.error or "unification failed")
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

      # ── RowEquality ───────────────────────────────────────────────
      else if tag == "RowEquality" then
        let
          lhsR = applySubst state.subst c.lhsRow;
          rhsR = applySubst state.subst c.rhsRow;
          r    = unifyRow lhsR rhsR;
        in
        if !r.ok then
          failResult (r.error or "row unification failed")
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

      # ── Class ─────────────────────────────────────────────────────
      else if tag == "Class" then
        let
          resolvedArgs = map (applySubst state.subst) (c.args or []);
          resolution   = instanceLib.resolveWithFallback
            state.classGraph state.instanceDB c.className resolvedArgs;
        in
        if instanceLib.canDischarge resolution then
          _solveLoop (state // {
            worklist = rest;
            solved   = state.solved ++ [ c ];
            fuel     = state.fuel - 1;
          })
        else
          # Not resolved: defer to residual
          _solveLoop (state // {
            worklist      = rest;
            classResidual = state.classResidual ++ [ c ];
            fuel          = state.fuel - 1;
          })

      # ── Refined ───────────────────────────────────────────────────
      else if tag == "Refined" then
        let
          subject = applySubst state.subst c.subject;
          predVar = c.predVar or "v";
          predExpr = c.predExpr or { __predTag = "PTrue"; };
          # Inline static evaluation for trivial cases
          static =
            let ptag = predExpr.__predTag or null; in
            if ptag == "PTrue"  then { trivial = true; result = true; }
            else if ptag == "PFalse" then { trivial = true; result = false; }
            else { trivial = false; };
        in
        if static.trivial or false then
          _solveLoop (state // {
            worklist = rest;
            solved   = state.solved ++ [ c ];
            fuel     = state.fuel - 1;
          })
        else
          _solveLoop (state // {
            worklist    = rest;
            smtResidual = state.smtResidual ++ [ c ];
            fuel        = state.fuel - 1;
          })

      # ── Implies ───────────────────────────────────────────────────
      else if tag == "Implies" then
        let premises = c.premises or []; in
        if premises == [] then
          # No premises: enqueue conclusion
          _solveLoop (state // {
            worklist = rest ++ [ c.conclusion ];
            solved   = state.solved ++ [ c ];
            fuel     = state.fuel - 1;
          })
        else
          # Defer: try to discharge premises first
          _solveLoop (state // {
            worklist      = rest;
            classResidual = state.classResidual ++ [ c ];
            fuel          = state.fuel - 1;
          })

      # ── Scheme（Phase 4.2: HM instantiation constraints）─────────
      else if tag == "Scheme" then
        let
          scheme = c.scheme or {};
          ty     = c.ty or null;
        in
        if !builtins.isAttrs scheme || (scheme.__schemeTag or null) != "Scheme" then
          _solveLoop (state // {
            worklist = rest;
            classResidual = state.classResidual ++ [ c ];
            fuel = state.fuel - 1;
          })
        else
          let
            forall = scheme.forall or [];
            body   = scheme.body;
            # Generate fresh type variables for each forall var
            freshBindings = builtins.listToAttrs (lib.imap0 (i: v:
              lib.nameValuePair v
                (typeLib.mkTypeDefault (reprLib.rVar "_si_${v}_${builtins.toString i}" "scheme") kindLib.KStar)
            ) forall);
            instBody = lib.foldl' (acc: v:
              substLib.substitute v freshBindings.${v} acc
            ) body forall;
            # Generate equality constraint between instantiated body and ty
            newCs = if ty != null then [ (mkEqConstraint instBody ty) ] else [];
          in
          _solveLoop (state // {
            worklist = rest ++ newCs;
            solved   = state.solved ++ [ c ];
            fuel     = state.fuel - 1;
          })

      # ── Kind（Phase 4.3: INV-KIND-1 — 真正求解，不再 defer）──────
      else if tag == "Kind" then
        let
          typeVar      = c.typeVar or null;
          expectedKind = c.expectedKind or kindLib.KStar;
        in
        if typeVar == null then
          # Malformed: skip
          _solveLoop (state // {
            worklist = rest;
            fuel     = state.fuel - 1;
          })
        else
          # Phase 4.3: accumulate for batch kind solving at end
          _solveLoop (state // {
            worklist        = rest;
            kindConstraints = (state.kindConstraints or []) ++ [ c ];
            solved          = state.solved ++ [ c ];
            fuel            = state.fuel - 1;
          })

      # ── Unknown tag: defer ────────────────────────────────────────
      else
        _solveLoop (state // {
          worklist      = rest;
          classResidual = state.classResidual ++ [ c ];
          fuel          = state.fuel - 1;
        });

  # ══ 主 solve API ════════════════════════════════════════════════════════
  # Type: [Constraint] → SolverResult
  solveSimple = constraints:
    solve constraints {} {};

  # Type: [Constraint] → ClassGraph → InstanceDB → SolverResult
  solve = constraints: classGraph: instanceDB:
    let state = _initState constraints classGraph instanceDB; in
    _solveLoop state;

  # ══ Convenience helpers ════════════════════════════════════════════════
  getTypeSubst = result:
    result.subst.typeBindings or {};

  getRowSubst = result:
    result.subst.rowBindings or {};

  getKindSubst = result:
    result.subst.kindBindings or {};
}
