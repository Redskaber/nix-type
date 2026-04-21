# constraint/solver.nix — Phase 3.2
# Worklist Solver（完整 _typeMentions + freeVarsRepr 集成）
#
# Phase 3.2 新增：
#   P3.2-4: _typeMentions 完整递归（freeVarsRepr 全 TypeRepr 变体传播）
#   _applySubstType 改为 unifyLib._applySubstTypeFull（完整深层替换）
#
# Phase 3.1 继承（所有 soundness 修复）：
#   INV-SOL1: Worklist 终止含 subst 变化检测
#   INV-SOL4: subst 在每轮后应用到所有 constraints
#   INV-SOL5: _partitionAffected 精确 worklist
#   canDischarge 验证 impl 有效性
#
# Worklist 语义：
#   State = { worklist; solved; subst; residual; ok; error }
#   每轮：head(worklist) → apply subst → try discharge → update subst
#   受 subst 影响的 residual → 重入 worklist（INV-SOL5）
{ lib, typeLib, constraintLib, unifyLib, instanceLib }:

let
  inherit (typeLib) isType;
  inherit (constraintLib)
    mkClass mkEquality mkPredicate mkImplies
    isClass isEquality isPredicate isImplies
    constraintKey normalizeConstraint mapTypesInConstraint
    deduplicateConstraints canonicalizeConstraints
    defaultClassGraph isSuperclassOf getAllSubs;
  inherit (unifyLib) unify _applySubstTypeFull;
  inherit (instanceLib)
    emptyInstanceDB resolveWithFallback canDischarge;

  # ── 完整 _typeMentions（Phase 3.2）──────────────────────────────────────────
  # 使用 reprLib.freeVarsRepr 而不是只检查顶层 Var
  # 注意：reprLib 没有在这里 import（避免循环），使用内联版本

  # Type: String -> TypeRepr -> Bool
  _reprMentions = name: repr:
    let v = repr.__variant or null; in
    if v == "Var" then repr.name or "" == name
    else if v == "Primitive" || v == "RowEmpty" || v == "Opaque" then false
    else if v == "Lambda" then repr.param or "" == name || _reprMentions name (repr.body or {}).repr or {}
    else if v == "Pi" || v == "Sigma" then
      _reprMentions name (repr.domain or {}).repr or {}
      || (repr.param or "" != name && _reprMentions name (repr.body or {}).repr or {})
    else if v == "Apply" then
      _reprMentions name (repr.fn or {}).repr or {}
      || lib.any (a: _reprMentions name a.repr or {}) (repr.args or [])
    else if v == "Fn" then
      _reprMentions name (repr.from or {}).repr or {}
      || _reprMentions name (repr.to or {}).repr or {}
    else if v == "Constructor" then
      (repr.params or []) == []
      || (builtins.filter (p: p.name or "" == name) (repr.params or []) == []
          && _reprMentions name (repr.body or {}).repr or {})
    else if v == "Mu" then
      repr.var or "" != name && _reprMentions name (repr.body or {}).repr or {}
    else if v == "ADT" then
      lib.any (var:
        lib.any (f: _reprMentions name f.repr or {}) (var.fields or [])
      ) (repr.variants or [])
    else if v == "Record" then
      lib.any (k: _reprMentions name (repr.fields or {}).${k}.repr or {})
              (builtins.attrNames (repr.fields or {}))
    else if v == "VariantRow" then
      lib.any (k: _reprMentions name (repr.variants or {}).${k}.repr or {})
              (builtins.attrNames (repr.variants or {}))
      || (repr.tail or null != null && _reprMentions name (repr.tail or {}).repr or {})
    else if v == "RowExtend" then
      _reprMentions name (repr.fieldType or {}).repr or {}
      || _reprMentions name (repr.rest or {}).repr or {}
    else if v == "Effect" then
      _reprMentions name (repr.effectRow or {}).repr or {}
    else if v == "Constrained" then
      _reprMentions name (repr.base or {}).repr or {}
      || lib.any (_cMentions name) (repr.constraints or [])
    else if v == "Ascribe" then
      _reprMentions name (repr.inner or {}).repr or {}
      || _reprMentions name (repr.ty or {}).repr or {}
    else false;

  # Constraint 内的 type mentions
  _cMentions = name: c:
    let tag = c.__constraintTag or null; in
    if tag == "Class" then lib.any (a: _reprMentions name a.repr or {}) (c.args or [])
    else if tag == "Equality" then
      _reprMentions name (c.a or {}).repr or {}
      || _reprMentions name (c.b or {}).repr or {}
    else if tag == "Predicate" then
      _reprMentions name (c.arg or {}).repr or {}
    else if tag == "Implies" then
      lib.any (_cMentions name) (c.premises or [])
      || _cMentions name (c.conclusion or {})
    else false;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Solver State
  # ══════════════════════════════════════════════════════════════════════════════

  emptyState = {
    worklist = [];
    solved   = [];
    subst    = {};
    residual = [];
    ok       = true;
    error    = null;
    # Phase 3.2：额外统计（调试用）
    rounds   = 0;
    classResidual = [];
  };

  initState = constraints:
    emptyState // {
      worklist = canonicalizeConstraints constraints;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 公共入口
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: [Constraint] -> SolveState
  solve = constraints:
    solveWith emptyInstanceDB defaultClassGraph constraints;

  # Type: InstanceDB -> ClassGraph -> [Constraint] -> SolveState
  solveWith = db: classGraph: constraints:
    _runWorklist db classGraph (initState constraints) 256;

  solveDefault = constraints:
    solveWith emptyInstanceDB defaultClassGraph constraints;

  # ══════════════════════════════════════════════════════════════════════════════
  # Worklist 主循环（INV-SOL1：含 subst 变化终止检测）
  # ══════════════════════════════════════════════════════════════════════════════

  _runWorklist = db: classGraph: state: fuel:
    if fuel <= 0
    then state // { residual = state.residual ++ state.worklist; worklist = []; }
    else if state.worklist == [] then state
    else if !state.ok then state
    else
      let
        c    = builtins.head state.worklist;
        rest = builtins.tail state.worklist;
        substSizeBefore = builtins.length (builtins.attrNames state.subst);
        state'  = state // { worklist = rest; rounds = (state.rounds or 0) + 1; };
        result  = _processConstraint db classGraph state' c;
        substSizeAfter = builtins.length (builtins.attrNames result.subst);
        substChanged   = substSizeAfter != substSizeBefore;
      in
      if !result.ok then result
      else if substChanged then
        # INV-SOL5：将受影响的 residual 重入 worklist
        let
          newVars   = _newSubstVars state.subst result.subst;
          partition = _partitionAffected newVars result.residual;
          state''   = result // {
            worklist = result.worklist ++ partition.affected;
            residual = partition.unaffected;
          };
        in
        _runWorklist db classGraph state'' (fuel - 1)
      else
        _runWorklist db classGraph result (fuel - 1);

  # ══════════════════════════════════════════════════════════════════════════════
  # 单 Constraint 处理
  # ══════════════════════════════════════════════════════════════════════════════

  _processConstraint = db: classGraph: state: c:
    let
      # INV-SOL4：先将当前 subst 应用到 constraint（完整深层替换）
      c' = normalizeConstraint (_applySubstToConstraint state.subst c);
      tag = c'.__constraintTag or null;
    in
    if tag == "Class"    then _solveClass db classGraph state c'
    else if tag == "Equality" then _solveEquality state c'
    else if tag == "Predicate" then _solvePredicate state c'
    else if tag == "Implies"  then _solveImplies db classGraph state c'
    else state // { residual = state.residual ++ [c']; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Class Constraint（soundness 修复 + specificity-based）
  # ══════════════════════════════════════════════════════════════════════════════

  _solveClass = db: classGraph: state: c:
    let
      result = resolveWithFallback db classGraph (c.name or "") (c.args or []);
    in
    if result.found && _implValid result
    then state // { solved = state.solved ++ [c]; }
    else if result.found && !_implValid result
    then
      # superclass path: impl = null → 不 discharge（安全残留）
      state // {
        residual = state.residual ++ [c];
        classResidual = (state.classResidual or []) ++ [c];
      }
    else
      state // {
        residual = state.residual ++ [c];
        classResidual = (state.classResidual or []) ++ [c];
      };

  # Phase 3.1 修复：验证 impl 有效性
  _implValid = result:
    result.found
    && (result.impl != null
        || (result.source or "") == "primitive");

  # ══════════════════════════════════════════════════════════════════════════════
  # Equality Constraint（Robinson unification）
  # ══════════════════════════════════════════════════════════════════════════════

  _solveEquality = state: c:
    let
      a = c.a or null;
      b = c.b or null;
    in
    if a == null || b == null
    then state // { residual = state.residual ++ [c]; }
    else
      let r = unify state.subst a b; in
      if r.ok
      then
        let
          newSubst  = r.subst;
          # INV-SOL4：应用新 subst 到已有 worklist（完整替换）
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
  # Predicate Constraint（residual，Phase 4 SMT bridge）
  # ══════════════════════════════════════════════════════════════════════════════

  _solvePredicate = state: c:
    state // { residual = state.residual ++ [c]; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Implies Constraint（前件满足 → 添加结论）
  # ══════════════════════════════════════════════════════════════════════════════

  _solveImplies = db: classGraph: state: c:
    let
      premises   = c.premises or [];
      conclusion = c.conclusion or null;
    in
    if conclusion == null then state
    else
      let
        solvedKeys = builtins.listToAttrs
          (map (s: { name = constraintKey s; value = true; }) state.solved);
        allPremisesSolved = lib.all
          (p: solvedKeys ? ${constraintKey p})
          premises;
      in
      if allPremisesSolved
      then state // { worklist = state.worklist ++ [conclusion]; }
      else state // { residual = state.residual ++ [c]; };

  # ══════════════════════════════════════════════════════════════════════════════
  # INV-SOL4：将 subst 完整应用到 constraint（Phase 3.2：完整深层替换）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> Constraint -> Constraint
  _applySubstToConstraint = subst: c:
    if subst == {} then c
    else
      normalizeConstraint
        (mapTypesInConstraint (_applySubstTypeFull subst) c);

  # ══════════════════════════════════════════════════════════════════════════════
  # INV-SOL5：精确 worklist 分区（Phase 3.2：_typeMentions 完整递归）
  # ══════════════════════════════════════════════════════════════════════════════

  # 新增的 subst 变量
  _newSubstVars = oldSubst: newSubst:
    builtins.filter (k: !(oldSubst ? ${k})) (builtins.attrNames newSubst);

  # 将 constraints 分为受影响和不受影响（Phase 3.2：完整 mentions 检查）
  _partitionAffected = newVars: constraints:
    let
      affected   = builtins.filter (_constraintMentions newVars) constraints;
      unaffected = builtins.filter (c: !(_constraintMentions newVars c)) constraints;
    in
    { inherit affected unaffected; };

  # Phase 3.2：完整 constraint mentions 检查（全变体覆盖）
  _constraintMentions = vars: c:
    if vars == [] then false
    else lib.any (name: _cMentions name c) vars;

  # Phase 3.2：完整 type mentions（使用 _reprMentions 全变体实现）
  _typeMentions = vars: t:
    lib.any (name: _reprMentions name (t.repr or {})) vars;

  # ══════════════════════════════════════════════════════════════════════════════
  # 结果查询工具
  # ══════════════════════════════════════════════════════════════════════════════

  isSuccess  = state: state.ok && state.worklist == [];
  hasResidual = state: builtins.length state.residual > 0;
  residualCount = state: builtins.length state.residual;

  showResult = state:
    if !state.ok
    then "FAIL: ${state.error or "?"}"
    else if state.residual == []
    then "OK (${builtins.toString (builtins.length state.solved)} solved, ${builtins.toString (state.rounds or 0)} rounds)"
    else "OK-partial (${builtins.toString (builtins.length state.solved)} solved, ${builtins.toString (builtins.length state.residual)} residual, ${builtins.toString (state.rounds or 0)} rounds)";

}
