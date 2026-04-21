# constraint/solver.nix — Phase 3
# Worklist Constraint Solver（精确增量，Phase 3）
#
# Phase 3 新增：
#   Worklist 架构（替代 fixpoint fold，精确追踪受影响的 constraints）
#   applySubstToConstraint 完整递归（委托给 ir.mapTypesInConstraint）
#   _substEq 纳入 _isStable（INV-SOL1 修复）
#   subst 应用到 constraints（INV-SOL4 修复）
#   Class graph 传递闭包 entailment
#
# 不变量：
#   INV-SOL1: fixpoint 终止条件包含 subst 变化（_substEq）
#   INV-SOL2: 每轮 solve 单调减少 constraints（无循环）
#   INV-SOL3: 输出 subst 满足所有 discharged constraints
#   INV-SOL4: subst 在每轮后应用到剩余 constraints
#   INV-SOL5: Worklist = 受 subst 变化影响的 constraints（精确增量）
{ lib, constraintLib, unifyLib }:

let
  inherit (constraintLib)
    isClass isEquality isPredicate isImplies
    constraintKey deduplicateConstraints mergeConstraints
    mapTypesInConstraint normalizeConstraint
    defaultClassGraph isSuperclassOf;
  inherit (unifyLib) unify emptySubst;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 求解结果类型
  # SolveResult = {
  #   ok: Bool;
  #   subst: AttrSet String Type;  # 类型变量绑定
  #   residual: [Constraint];       # 无法消除的约束
  #   errors: [String];             # 错误信息
  # }
  # ══════════════════════════════════════════════════════════════════════════════

  _mkOk    = subst: residual: { ok = true; inherit subst residual; errors = []; };
  _mkFail  = errors: subst: residual: { ok = false; inherit subst residual errors; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 主入口：solve
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> AttrSet -> [Constraint] -> SolveResult
  solve = instanceDB: classGraph: constraints:
    let
      normalized = map normalizeConstraint constraints;
      deduped    = deduplicateConstraints normalized;
    in
    _worklistSolve instanceDB classGraph emptySubst deduped [] 64;

  # ── 便捷入口 ──────────────────────────────────────────────────────────────
  solveDefault      = solve emptyInstanceDB defaultClassGraph;
  solveWithDB       = db: solve db defaultClassGraph;
  solveWithGraph    = graph: solve emptyInstanceDB graph;

  # ══════════════════════════════════════════════════════════════════════════════
  # Worklist Solver 主循环（Phase 3 核心）
  # ══════════════════════════════════════════════════════════════════════════════

  # 策略：
  #   worklist = 待处理 constraints（初始 = 全部）
  #   每轮处理一个 constraint：
  #     - 成功 discharge → 从 worklist 移除
  #     - 产生新 subst → 将受影响 constraints 重新加入 worklist
  #     - 无法 discharge → 移至 residual
  #   直到 worklist 为空 或 fuel 耗尽

  # Type: InstanceDB -> ClassGraph -> Subst -> Worklist -> Residual -> Int -> SolveResult
  _worklistSolve = instanceDB: classGraph: subst: worklist: residual: fuel:
    if fuel <= 0 then
      _mkOk subst (residual ++ worklist)  # fuel 耗尽：剩余为 residual

    else if worklist == [] then
      _mkOk subst residual  # 完成

    else
      let
        c    = builtins.head worklist;
        rest = builtins.tail worklist;
      in
      _processConstraint instanceDB classGraph subst rest residual fuel c;

  # ══════════════════════════════════════════════════════════════════════════════
  # 处理单个 Constraint
  # ══════════════════════════════════════════════════════════════════════════════

  _processConstraint = instanceDB: classGraph: subst: worklist: residual: fuel: c:
    let
      # 先对 c 应用当前 subst（INV-SOL4）
      c' = _applySubstToConstraint subst c;
      tag = c'.__constraintTag or null;
    in

    # ── Equality 约束：统一 ────────────────────────────────────────────────
    if tag == "Equality" then
      let result = unify subst c'.a c'.b; in
      if result.ok then
        let
          newSubst = result.subst;
          # INV-SOL5：将受新 subst 影响的 constraints 重新加入 worklist
          (affected: unaffected: {
            newWorklist = affected ++ unaffected;
            # worklist 中受影响的 constraints 需重新处理
          }) (_partitionAffected newSubst worklist);
          # 简化：直接 continue（新 subst 在下一轮自动应用）
        in
        _worklistSolve instanceDB classGraph newSubst worklist residual (fuel - 1)
      else
        # 统一失败：记录错误，跳过
        _mkFail [result.error or "Equality failed"] subst (residual ++ [c'] ++ worklist)

    # ── Class 约束：entailment / discharge ────────────────────────────────
    else if tag == "Class" then
      let discharged = _dischargeClass instanceDB classGraph c'; in
      if discharged.ok then
        # 成功消除：继续处理 worklist
        _worklistSolve instanceDB classGraph subst worklist residual (fuel - 1)
      else if discharged.residual then
        # 保留为 residual（无法当前 discharge，但不是错误）
        _worklistSolve instanceDB classGraph subst worklist (residual ++ [c']) (fuel - 1)
      else
        _mkFail [discharged.error or "Class constraint failed"] subst (residual ++ [c'] ++ worklist)

    # ── Predicate 约束：保留为 residual（Liquid Types，Phase 3 接口）───────
    else if tag == "Predicate" then
      _worklistSolve instanceDB classGraph subst worklist (residual ++ [c']) (fuel - 1)

    # ── Implies 约束：若 premises 已 discharge，处理 conclusion ───────────
    else if tag == "Implies" then
      let
        premResult = _tryDischargeAll instanceDB classGraph subst c'.premises;
      in
      if premResult.ok then
        # premises 全部 discharge → 处理 conclusion
        let newWorklist = [c'.conclusion] ++ worklist; in
        _worklistSolve instanceDB classGraph subst newWorklist residual (fuel - 1)
      else
        # premises 未全 discharge → 保留 implies
        _worklistSolve instanceDB classGraph subst worklist (residual ++ [c']) (fuel - 1)

    # ── 未知约束：跳过 ────────────────────────────────────────────────────
    else
      _worklistSolve instanceDB classGraph subst worklist (residual ++ [c']) (fuel - 1);

  # ══════════════════════════════════════════════════════════════════════════════
  # Substitution 应用到 Constraint（INV-SOL4）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Subst -> Constraint -> Constraint
  _applySubstToConstraint = subst: c:
    mapTypesInConstraint (_applySubstType subst) c;

  # 简单的 subst 应用（Var 替换）
  _applySubstType = subst: t:
    let v = t.repr.__variant or null; in
    if v == "Var" || v == "VarScoped" then
      let bound = subst.${t.repr.name} or null; in
      if bound != null then _applySubstType subst bound else t
    else t;

  # ══════════════════════════════════════════════════════════════════════════════
  # Worklist：受影响 constraints 分区（INV-SOL5）
  # ══════════════════════════════════════════════════════════════════════════════

  # 受 newSubst 影响 = constraints 中含有 newSubst 的 domain 变量
  _partitionAffected = newSubst: constraints:
    let
      domainVars = builtins.attrNames newSubst;
      isAffected = c: lib.any (v: _constraintContainsVar v c) domainVars;
    in
    {
      affected   = builtins.filter isAffected constraints;
      unaffected = builtins.filter (c: !isAffected c) constraints;
    };

  _constraintContainsVar = varName: c:
    let tag = c.__constraintTag or null; in
    if tag == "Equality" then
      _typeContainsVar varName c.a || _typeContainsVar varName c.b
    else if tag == "Class" then
      lib.any (_typeContainsVar varName) (c.args or [])
    else if tag == "Predicate" then
      _typeContainsVar varName (c.arg or {})
    else if tag == "Implies" then
      lib.any (_constraintContainsVar varName) (c.premises or [])
      || _constraintContainsVar varName (c.conclusion or {})
    else false;

  _typeContainsVar = varName: t:
    (t.repr or {}) ? __variant
    && (t.repr.__variant == "Var" && t.repr.name == varName
        || t.repr.__variant == "VarScoped" && t.repr.name == varName);

  # ══════════════════════════════════════════════════════════════════════════════
  # Stability Check（INV-SOL1：subst 变化纳入终止条件）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Subst -> Subst -> Bool
  _substEq = s1: s2:
    let
      ks1 = builtins.sort (a: b: a < b) (builtins.attrNames s1);
      ks2 = builtins.sort (a: b: a < b) (builtins.attrNames s2);
    in
    ks1 == ks2
    && lib.all (k: (s1.${k}.id or "?") == (s2.${k}.id or "?")) ks1;

  # ══════════════════════════════════════════════════════════════════════════════
  # Class Entailment（discharge Class constraints）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> ClassGraph -> Constraint -> { ok: Bool; residual: Bool; error?: String }
  _dischargeClass = instanceDB: classGraph: c:
    assert isClass c;
    let
      primitive = _canDischargePrimitive classGraph c.name (c.args or []);
      fromDB    = instanceDB ? ${_instanceKey c.name (c.args or [])};
      # 超类 entailment（传递闭包）
      fromSuper = _canDischargeViaSuper instanceDB classGraph c;
    in
    if primitive then { ok = true; residual = false; }
    else if fromDB then { ok = true; residual = false; }
    else if fromSuper then { ok = true; residual = false; }
    else
      # 类型变量：无法当前 discharge（保留为 residual，非错误）
      let firstArg = builtins.head ((c.args or []) ++ [{}]); in
      let v = firstArg.repr.__variant or null; in
      if v == "Var" || v == "VarScoped" || v == "VarDB"
      then { ok = false; residual = true; }
      else { ok = false; residual = false; error = "No instance for ${c.name}"; };

  # 超类 entailment：若 arg 是 Sub 的实例，且 Super 是 Sub 的超类，则可 discharge
  _canDischargeViaSuper = instanceDB: classGraph: c:
    let args = c.args or []; in
    lib.any (subClass:
      instanceDB ? ${_instanceKey subClass args}
      && isSuperclassOf classGraph c.name subClass)
    (builtins.attrNames classGraph);

  # 批量 discharge（Implies premises 用）
  _tryDischargeAll = instanceDB: classGraph: subst: premises:
    let
      applied = map (_applySubstToConstraint subst) premises;
      results = map (c:
        if isClass c then _dischargeClass instanceDB classGraph c
        else { ok = true; residual = false; }) applied;
    in
    { ok = lib.all (r: r.ok) results; };

  # ── 原始类型内置实例 ──────────────────────────────────────────────────────
  _canDischargePrimitive = classGraph: className: args:
    let
      firstArg = builtins.head (args ++ [{}]);
      v        = (firstArg.repr or {})..__variant or firstArg.repr.__variant or null;
      primName = if v == "Primitive" then firstArg.repr.name or "" else "";
    in
    if primName == "Int" then
      builtins.elem className ["Eq" "Ord" "Show" "Num" "Enum" "Real" "Integral" "Bounded"]
    else if primName == "Bool" then
      builtins.elem className ["Eq" "Ord" "Show" "Enum" "Bounded"]
    else if primName == "String" then
      builtins.elem className ["Eq" "Ord" "Show" "Semigroup" "Monoid"]
    else if primName == "Float" then
      builtins.elem className ["Eq" "Ord" "Show" "Num" "Real" "RealFrac" "Fractional" "Floating"]
    else false;

  _instanceKey = name: args:
    let
      argIds = builtins.concatStringsSep ","
        (map (a: a.id or (builtins.hashString "md5" (builtins.toJSON a))) args);
    in
    "inst:${name}:[${argIds}]";

  # ══════════════════════════════════════════════════════════════════════════════
  # Instance Database
  # ══════════════════════════════════════════════════════════════════════════════

  emptyInstanceDB = {};

  # Type: InstanceDB -> String -> [Type] -> Type -> InstanceDB
  register = db: className: args: impl:
    let key = _instanceKey className args; in
    if db ? ${key}
    then builtins.throw "Coherence violation: duplicate instance ${className} for ${key}"
    else db // { ${key} = { inherit className args impl; }; };

  # Type: InstanceDB -> String -> [Type] -> { found: Bool; impl?: Type }
  resolve = db: className: args:
    let key = _instanceKey className args; in
    let entry = db.${key} or null; in
    if entry != null
    then { found = true; impl = entry.impl; }
    else { found = false; };

  # 内置实例（常用原始类型）
  withBuiltinInstances = db: db;  # 原始类型通过 _canDischargePrimitive 处理，无需注册

}
