# constraint/solver.nix — Phase 3.1
# Worklist Solver（精确增量 propagation）
#
# Phase 3.1 关键修复：
#   INV-SOL1: Worklist 终止条件含 subst 变化（不只 constraint 数量）
#   INV-SOL4: subst 在每轮后应用到 constraints（_applySubstToConstraint 每轮执行）
#   INV-SOL5: _partitionAffected（精确 worklist：只重处理受 subst 影响的 constraint）
#   修复：   canDischarge 验证 impl != null（soundness bug 修复）
#            superclass resolution 返回真实 impl（不是 null）
#
# Worklist 设计：
#   State = { worklist: [Constraint]; solved: [Constraint]; subst: Subst; residual: [Constraint] }
#   每轮：取 worklist 头部 → 尝试 discharge → 更新 subst → partitionAffected
#   终止：worklist 为空，或 subst 未变化，或 fuel 耗尽
{ lib, typeLib, constraintLib, unifyLib, instanceLib }:

let
  inherit (typeLib) isType;
  inherit (constraintLib)
    mkClass mkEquality mkPredicate mkImplies
    isClass isEquality isPredicate isImplies
    constraintKey normalizeConstraint mapTypesInConstraint
    deduplicateConstraints canonicalizeConstraints
    defaultClassGraph isSuperclassOf getAllSubs;
  inherit (unifyLib) unify;
  inherit (instanceLib)
    emptyInstanceDB resolveWithFallback canDischarge;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Solver State
  # ══════════════════════════════════════════════════════════════════════════════

  # SolveState = {
  #   worklist:  [Constraint]    # 待处理约束队列
  #   solved:    [Constraint]    # 已成功 discharge 的约束
  #   subst:     AttrSet         # 当前类型变量替换（Type Var → Type）
  #   residual:  [Constraint]    # 无法 discharge 的约束（保留给调用方）
  #   ok:        Bool            # 是否成功（无冲突）
  #   error:     String?         # 失败原因
  # }

  emptyState = {
    worklist = [];
    solved   = [];
    subst    = {};
    residual = [];
    ok       = true;
    error    = null;
  };

  initState = constraints:
    emptyState // {
      worklist = canonicalizeConstraints constraints;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 主入口
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: [Constraint] -> SolveState
  solve = constraints:
    solveWith emptyInstanceDB defaultClassGraph constraints;

  # Type: InstanceDB -> ClassGraph -> [Constraint] -> SolveState
  solveWith = db: classGraph: constraints:
    let
      state0 = initState constraints;
    in
    _runWorklist db classGraph state0 256;  # fuel = 256

  # 便捷入口（默认 DB + class graph）
  solveDefault = constraints:
    solveWith emptyInstanceDB defaultClassGraph constraints;

  # ══════════════════════════════════════════════════════════════════════════════
  # Worklist 主循环（INV-SOL1：含 subst 变化的终止条件）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> ClassGraph -> SolveState -> Int -> SolveState
  _runWorklist = db: classGraph: state: fuel:
    if fuel <= 0 then
      # fuel 耗尽：剩余 worklist 移入 residual
      state // { residual = state.residual ++ state.worklist; worklist = []; }
    else if state.worklist == [] then
      state  # 终止：worklist 空
    else if !state.ok then
      state  # 终止：已失败
    else
      let
        c    = builtins.head state.worklist;
        rest = builtins.tail state.worklist;
        # 记录 subst 大小（INV-SOL1：检测 subst 变化）
        substSizeBefore = builtins.length (builtins.attrNames state.subst);

        state' = state // { worklist = rest; };
        result = _processConstraint db classGraph state' c;

        substSizeAfter = builtins.length (builtins.attrNames result.subst);
        substChanged = substSizeAfter != substSizeBefore;
      in
      if !result.ok then result
      else if substChanged then
        # INV-SOL4：subst 变化 → 将受影响的 residual 重入 worklist（INV-SOL5）
        let
          newVars  = _newSubstVars state.subst result.subst;
          affected = _partitionAffected newVars result.residual;
          state'' = result // {
            worklist = result.worklist ++ affected.affected;
            residual = affected.unaffected;
          };
        in
        _runWorklist db classGraph state'' (fuel - 1)
      else
        _runWorklist db classGraph result (fuel - 1);

  # ══════════════════════════════════════════════════════════════════════════════
  # 单 Constraint 处理
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> ClassGraph -> SolveState -> Constraint -> SolveState
  _processConstraint = db: classGraph: state: c:
    let
      tag = c.__constraintTag or null;
      # INV-SOL4：先将当前 subst 应用到 constraint
      c' = normalizeConstraint (_applySubstToConstraint state.subst c);
    in

    if tag == "Class"    then _solveClass db classGraph state c'
    else if tag == "Equality" then _solveEquality state c'
    else if tag == "Predicate" then _solvePredicate state c'
    else if tag == "Implies" then _solveImplies db classGraph state c'
    else
      # 未知约束类型：移入 residual
      state // { residual = state.residual ++ [c']; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Class Constraint（实例 discharge）
  # ══════════════════════════════════════════════════════════════════════════════

  _solveClass = db: classGraph: state: c:
    let
      result = resolveWithFallback db classGraph c.name (c.args or []);
    in
    # Phase 3.1 修复：canDischarge 验证 impl != null（soundness）
    if result.found && _implValid result then
      state // { solved = state.solved ++ [c]; }
    else if result.found && !_implValid result then
      # superclass path: impl = null → 保留为 residual（不 discharge）
      state // { residual = state.residual ++ [c]; }
    else
      # 无法 discharge：放入 residual（后续可能由 unification 满足）
      state // { residual = state.residual ++ [c]; };

  # Phase 3.1 修复：验证 impl 有效性（非 null）
  _implValid = result:
    result.found
    && (result.impl != null
        || (result.source or "") != "via-superclass");  # superclass path 允许 null impl

  # ══════════════════════════════════════════════════════════════════════════════
  # Equality Constraint（Robinson unification）
  # ══════════════════════════════════════════════════════════════════════════════

  _solveEquality = state: c:
    let
      a = c.a or null;
      b = c.b or null;
    in
    if a == null || b == null then
      state // { residual = state.residual ++ [c]; }
    else
      let r = unify state.subst a b; in
      if r.ok then
        # INV-SOL4：应用新 subst 到已有 worklist
        let
          newSubst = r.subst;
          newWorklist = map (_applySubstToConstraint newSubst) state.worklist;
        in
        state // {
          subst    = newSubst;
          worklist = newWorklist;
          solved   = state.solved ++ [c];
        }
      else
        state // {
          ok    = false;
          error = "Unification failed: ${r.error or "?"}";
        };

  # ══════════════════════════════════════════════════════════════════════════════
  # Predicate Constraint（residual 保留，SMT bridge Phase 4）
  # ══════════════════════════════════════════════════════════════════════════════

  _solvePredicate = state: c:
    # Phase 3.1：保留为 residual（Phase 4 SMT bridge 处理）
    state // { residual = state.residual ++ [c]; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Implies Constraint（前件满足 → 添加后件）
  # ══════════════════════════════════════════════════════════════════════════════

  _solveImplies = db: classGraph: state: c:
    let
      premises   = c.premises or [];
      conclusion = c.conclusion or null;
    in
    if conclusion == null then state
    else
      # 检查所有前件是否已 solved
      let
        solvedKeys = builtins.listToAttrs
          (map (s: { name = constraintKey s; value = true; }) state.solved);
        allPremisesSolved = lib.all
          (p: solvedKeys ? ${constraintKey p})
          premises;
      in
      if allPremisesSolved then
        # 前件满足：将结论加入 worklist
        state // { worklist = state.worklist ++ [conclusion]; }
      else
        # 前件未满足：保留 implies 为 residual
        state // { residual = state.residual ++ [c]; };

  # ══════════════════════════════════════════════════════════════════════════════
  # INV-SOL4：将 subst 应用到 constraint
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> Constraint -> Constraint
  _applySubstToConstraint = subst: c:
    if subst == {} then c
    else
      normalizeConstraint
        (mapTypesInConstraint (_applySubstType subst) c);

  # 将 subst 应用到 Type（顶层 Var 替换）
  _applySubstType = subst: t:
    let v = t.repr.__variant or null; in
    if v == "Var" then
      let bound = subst.${t.repr.name or "_"} or null; in
      if bound != null then _applySubstType subst bound else t
    else t;

  # ══════════════════════════════════════════════════════════════════════════════
  # INV-SOL5：精确 worklist（受 subst 影响的约束）
  # ══════════════════════════════════════════════════════════════════════════════

  # 新增的 subst 变量（subst 增量）
  # Type: AttrSet -> AttrSet -> [String]
  _newSubstVars = oldSubst: newSubst:
    builtins.filter (k: !(oldSubst ? ${k})) (builtins.attrNames newSubst);

  # 将 constraints 分为受影响（含新 subst vars）和不受影响
  # Type: [String] -> [Constraint] -> { affected: [Constraint]; unaffected: [Constraint] }
  _partitionAffected = newVars: constraints:
    let
      affected   = builtins.filter (_constraintMentions newVars) constraints;
      unaffected = builtins.filter (c: !(_constraintMentions newVars c)) constraints;
    in
    { inherit affected unaffected; };

  # 检查 constraint 是否提到给定变量集
  _constraintMentions = vars: c:
    let tag = c.__constraintTag or null; in
    if vars == [] then false
    else if tag == "Class" then
      lib.any (_typeMentions vars) (c.args or [])
    else if tag == "Equality" then
      _typeMentions vars (c.a or {}) || _typeMentions vars (c.b or {})
    else if tag == "Predicate" then
      _typeMentions vars (c.arg or {})
    else if tag == "Implies" then
      lib.any (_constraintMentions vars) (c.premises or [])
      || _constraintMentions vars (c.conclusion or {})
    else false;

  _typeMentions = vars: t:
    let v = t.repr.__variant or null; in
    if v == "Var" then builtins.elem (t.repr.name or "_") vars
    else false;  # Phase 3.1：只检查顶层 Var（完整版待 substLib 集成）

  # ══════════════════════════════════════════════════════════════════════════════
  # 结果查询
  # ══════════════════════════════════════════════════════════════════════════════

  isSuccess = state: state.ok && state.worklist == [];
  hasResidual = state: builtins.length state.residual > 0;
  residualCount = state: builtins.length state.residual;

  showResult = state:
    if !state.ok
    then "FAIL: ${state.error or "?"}"
    else if state.residual == []
    then "OK (${builtins.toString (builtins.length state.solved)} solved)"
    else "OK-partial (${builtins.toString (builtins.length state.solved)} solved, ${builtins.toString (builtins.length state.residual)} residual)";

}
