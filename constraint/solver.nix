# constraint/solver.nix — Phase 4.1
# 统一 Constraint Solver（合并原 solver.nix + solver_p40.nix）
# 修复关键 bugs：
#   - INV-SOL1: subst equality 使用 NF-hash（不再是 .id 比较）
#   - INV-SOL4: substituion 传播完整
#   - INV-SOL5: worklist requeue（真正增量 invalidation）
#   - INV-SOL-P40-1: UnifiedSubst 贯穿整个 pipeline
#   - smtResidual: Refined constraints → SMT 残留（Phase 4.0）
{ lib, typeLib, reprLib, kindLib
, constraintLib, substLib, unifiedSubstLib
, unifyLib, unifyRowLib, instanceLib
, hashLib, normalizeLib }:

let
  inherit (constraintLib)
    isConstraint isEqConstraint isClassConstraint isRowEq isRefinedC isImplies
    normalizeConstraint deduplicateConstraints constraintContainsVar;
  inherit (unifiedSubstLib)
    emptySubst singleTypeBinding singleRowBinding
    composeSubst applySubstToConstraint applySubstToConstraints applyUnifiedSubst
    fromLegacyTypeSubst fromLegacyRowSubst
    toLegacyTypeSubst toLegacyRowSubst
    isEmptySubst;
  inherit (hashLib) typeHash;
  inherit (normalizeLib) normalize';

  # ── Refined: staticEval（谓词静态求值）──────────────────────────────────
  # Type: PredExpr -> { discharged: Bool; residual: Bool; simplExpr: PredExpr }
  _staticEvalPred = p:
    let tag = p.__predTag or p.__variant or null; in
    if tag == "PTrue"  then { discharged = true;  residual = false; simplExpr = p; }
    else if tag == "PFalse" then { discharged = false; residual = false; simplExpr = p; }
    else if tag == "PAnd" then
      let
        l = _staticEvalPred p.left;
        r = _staticEvalPred p.right;
      in
      if !l.discharged then { discharged = false; residual = l.residual || r.residual; simplExpr = p; }
      else if !r.discharged then { discharged = false; residual = r.residual; simplExpr = p; }
      else if l.residual || r.residual then { discharged = false; residual = true; simplExpr = p; }
      else { discharged = true; residual = false; simplExpr = { __predTag = "PTrue"; }; }
    else if tag == "POr" then
      let
        l = _staticEvalPred p.left;
        r = _staticEvalPred p.right;
      in
      if l.discharged && !l.residual then { discharged = true; residual = false; simplExpr = p; }
      else if r.discharged && !r.residual then { discharged = true; residual = false; simplExpr = p; }
      else { discharged = false; residual = true; simplExpr = p; }
    else if tag == "PCmp" then
      let
        lTag = p.lhs.__predTag or null;
        rTag = p.rhs.__predTag or null;
      in
      if lTag == "PLit" && rTag == "PLit" then
        let
          lv  = p.lhs.value;
          rv  = p.rhs.value;
          op  = p.op;
          res = if op == "eq"  then lv == rv
                else if op == "neq" then lv != rv
                else if op == "lt"  then lv < rv
                else if op == "le"  then lv <= rv
                else if op == "gt"  then lv > rv
                else if op == "ge"  then lv >= rv
                else false;
        in { discharged = res; residual = false; simplExpr = p; }
      else { discharged = false; residual = true; simplExpr = p; }
    else
      # PVar, PApp → SMT residual
      { discharged = false; residual = true; simplExpr = p; };

  # ── 单个 Constraint 处理 ──────────────────────────────────────────────────
  # Type: SolverState -> Constraint -> SolverState
  # SolverState = {
  #   subst:        UnifiedSubst
  #   worklist:     [Constraint]
  #   solved:       [Constraint]
  #   classResidual:[Constraint]
  #   smtResidual:  [Constraint]
  #   ok:           Bool
  #   error?:       String
  # }
  _processConstraint = state: classGraph: instanceDB: c:
    let tag = c.__constraintTag or null; in

    if tag == "Equality" then
      let
        lhs' = applyUnifiedSubst state.subst c.lhs;
        rhs' = applyUnifiedSubst state.subst c.rhs;
        # 使用 NF-hash 比较（INV-SOL1 修复）
        lhsHash = typeHash (normalize' lhs');
        rhsHash = typeHash (normalize' rhs');
      in
      if lhsHash == rhsHash then
        # 已满足，从 worklist 移除
        state // { solved = state.solved ++ [ c ]; }
      else
        let
          uResult = unifyLib.unify (toLegacyTypeSubst state.subst) lhs' rhs';
        in
        if !uResult.ok then
          state // { ok = false; error = uResult.error or "Unification failed"; }
        else
          let
            newTypePart = fromLegacyTypeSubst uResult.subst;
            newSubst    = composeSubst state.subst newTypePart;
            # INV-SOL5: apply newSubst to remaining worklist（真正 requeue）
            newWorklist = applySubstToConstraints newSubst state.worklist;
          in
          state // {
            subst    = newSubst;
            worklist = newWorklist;
            solved   = state.solved ++ [ c ];
          }

    else if tag == "RowEquality" then
      let
        lhsRow = applyUnifiedSubst state.subst c.lhsRow;
        rhsRow = applyUnifiedSubst state.subst c.rhsRow;
        rResult = unifyRowLib.unifyRow
          (toLegacyTypeSubst state.subst)
          (toLegacyRowSubst  state.subst)
          lhsRow rhsRow;
      in
      if !rResult.ok then
        state // { ok = false; error = rResult.error or "Row unification failed"; }
      else
        let
          typePart = fromLegacyTypeSubst rResult.typeSubst;
          rowPart  = fromLegacyRowSubst  rResult.rowSubst;
          newSubst = composeSubst state.subst (composeSubst typePart rowPart);
          newWorklist = applySubstToConstraints newSubst state.worklist;
        in
        state // {
          subst    = newSubst;
          worklist = newWorklist;
          solved   = state.solved ++ [ c ];
        }

    else if tag == "Class" then
      let
        args'  = map (applyUnifiedSubst state.subst) (c.args or []);
        c'     = c // { args = args'; };
        result = instanceLib.resolveWithFallback classGraph instanceDB c.className args';
      in
      if result.found then
        # INV: result.impl != null（canDischarge 已验证）
        state // { solved = state.solved ++ [ c' ]; }
      else
        # 保留为 classResidual（无法 discharge）
        state // { classResidual = state.classResidual ++ [ c' ]; }

    else if tag == "Refined" then
      let
        subject' = applyUnifiedSubst state.subst c.subject;
        evalResult = _staticEvalPred c.predExpr;
      in
      if evalResult.discharged && !evalResult.residual then
        state // { solved = state.solved ++ [ c ]; }
      else if evalResult.residual then
        # SMT residual（交给外部 solver）
        state // { smtResidual = state.smtResidual ++ [ (c // { subject = subject'; }) ]; }
      else
        state // { ok = false; error = "Refined predicate statically false"; }

    else if tag == "Implies" then
      let
        premises' = map (applySubstToConstraint state.subst) (c.premises or []);
        # 检查所有 premises 是否已 solved
        allSolved = lib.all (p:
          lib.any (s: s.__constraintTag == p.__constraintTag) state.solved
        ) (c.premises or []);
      in
      if allSolved then
        # 所有 premise 已满足，enqueue conclusion
        state // {
          worklist      = state.worklist ++ [ c.conclusion ];
          classResidual = state.classResidual;
        }
      else
        # 保留 Implies（前提未满足）
        state // { classResidual = state.classResidual ++ [ c ]; }

    else
      # 未知 constraint tag，放入 residual
      state // { classResidual = state.classResidual ++ [ c ]; };

  # ── Worklist Solver（iterative，修复 INV-SOL5）────────────────────────────
  # Type: SolverState -> AttrSet -> DB -> Int -> SolverState
  _solveLoop = state: classGraph: instanceDB: fuel:
    if fuel <= 0 then state
    else if state.worklist == [] then state
    else if !state.ok then state
    else
      let
        c         = builtins.head state.worklist;
        restWork  = builtins.tail state.worklist;
        state1    = state // { worklist = restWork; };
        state2    = _processConstraint state1 classGraph instanceDB c;
      in
      _solveLoop state2 classGraph instanceDB (fuel - 1);

  # ── 公开 Solver 入口 ──────────────────────────────────────────────────────
  # Type: AttrSet(classGraph) -> DB -> [Constraint] -> SolverResult
  # SolverResult = {
  #   ok:            Bool
  #   subst:         UnifiedSubst           -- Phase 4.0 unified
  #   solved:        [Constraint]
  #   classResidual: [Constraint]
  #   smtResidual:   [Constraint]           -- Phase 4.0 new
  #   rowSubst:      AttrSet                -- 向后兼容（extracted）
  # }
  solve = classGraph: instanceDB: constraints:
    let
      # 规范化 + 去重
      normalized = deduplicateConstraints constraints;
      initState  = {
        subst         = emptySubst;
        worklist      = normalized;
        solved        = [];
        classResidual = [];
        smtResidual   = [];
        ok            = true;
      };
      finalState = _solveLoop initState classGraph instanceDB 2000;
    in
    { ok            = finalState.ok;
      subst         = finalState.subst;
      solved        = finalState.solved;
      classResidual = finalState.classResidual;
      smtResidual   = finalState.smtResidual;
      error         = finalState.error or null;
      # 向后兼容
      rowSubst      = toLegacyRowSubst finalState.subst;
    };

  # ── 简化入口（无 class/row）──────────────────────────────────────────────
  solveSimple = constraints:
    solve {} instanceLib.emptyDB constraints;

  # ── 单约束求解（便捷函数）────────────────────────────────────────────────
  solveOne = classGraph: instanceDB: constraint:
    solve classGraph instanceDB [ constraint ];

in {
  inherit solve solveSimple solveOne;
  # 内部导出（测试用）
  inherit _staticEvalPred _processConstraint;
}
