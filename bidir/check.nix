# bidir/check.nix — Phase 3
# Bidirectional Type Checking（P3-0，Pierce/Turner 风格）
#
# 语义：
#   check : Ctx -> Term -> Type -> CheckResult
#   infer : Ctx -> Term -> InferResult
#
# 规则（Bidirectional）：
#   check(ctx, λx.e, Π(y:A).B)  = check(ctx[x:A], e, B[y↦x])
#   check(ctx, λx.e, A→B)       = check(ctx[x:A], e, B)
#   check(ctx, e, B)             = infer(ctx, e) = A; subtype(A, B)
#   infer(ctx, x)                = ctx.lookup(x)
#   infer(ctx, e : A)            = check(ctx, e, A); A（Ascribe）
#   infer(ctx, f a)              = infer(ctx, f) = Π(x:A).B; check(ctx, a, A); B[x↦a]
#   infer(ctx, f a)              = infer(ctx, f) = A→B; check(ctx, a, A); B
#
# Term IR（值层，与 TypeIR 分离）：
#   Term =
#     TVar    { name }
#   | TLam    { param; body }
#   | TApp    { fn; arg }
#   | TAscribe { term; typ }    ← 显式类型标注（切换 check→infer）
#   | TLet    { name; def; body }
#   | TLit    { value; primType }
#   | TMatch  { scrutinee; branches }  ← ADT pattern matching
#
# Phase 3 实现状态：骨架（完整语义，待 Phase 3.1 完善 dependent types）
{ lib, typeLib, normalizeLib, constraintLib, unifyLib, reprLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault;
  inherit (normalizeLib) normalize;
  inherit (reprLib) rVar rFn rPi rLambda rApply rADT;
  inherit (unifyLib) unify emptySubst;
  inherit (constraintLib) mkEquality;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Term IR 构造器
  # ══════════════════════════════════════════════════════════════════════════════

  _mkTerm = tag: fields: { __termTag = tag; } // fields;

  # Type Variable
  tVar = name: _mkTerm "TVar" { inherit name; };

  # Lambda abstraction
  tLam = param: body: _mkTerm "TLam" { inherit param body; };

  # Application
  tApp = fn: arg: _mkTerm "TApp" { inherit fn arg; };

  # Explicit type ascription（切换 check→infer 的关键）
  tAscribe = term: typ: _mkTerm "TAscribe" { inherit term typ; };

  # Let binding
  tLet = name: def: body: _mkTerm "TLet" { inherit name def body; };

  # Literal（primitive value）
  tLit = value: primType: _mkTerm "TLit" { inherit value primType; };

  # Pattern match
  tMatch = scrutinee: branches: _mkTerm "TMatch" { inherit scrutinee branches; };

  # Branch = { pattern: Pattern; body: Term }
  mkBranch = pattern: body: { inherit pattern body; };

  isTerm = t: builtins.isAttrs t && t ? __termTag;

  # ══════════════════════════════════════════════════════════════════════════════
  # Context（类型环境）
  # ══════════════════════════════════════════════════════════════════════════════

  # Ctx = { bindings: AttrSet String Type; subst: Subst }
  emptyCtx = { bindings = {}; subst = emptySubst; };

  # Type: Ctx -> String -> Type -> Ctx
  ctxBind = ctx: name: typ:
    ctx // { bindings = ctx.bindings // { ${name} = typ; }; };

  # Type: Ctx -> String -> Type?
  ctxLookup = ctx: name:
    ctx.bindings.${name} or null;

  # Type: Ctx -> Subst -> Ctx
  ctxWithSubst = ctx: subst:
    ctx // { subst = subst; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 结果类型
  # CheckResult = { ok: Bool; constraints: [Constraint]; subst: Subst; error?: String }
  # InferResult = { ok: Bool; typ: Type?; constraints: [Constraint]; subst: Subst; error?: String }
  # ══════════════════════════════════════════════════════════════════════════════

  _checkOk = cs: subst: { ok = true; constraints = cs; inherit subst; };
  _checkFail = msg: { ok = false; constraints = []; subst = emptySubst; error = msg; };
  _inferOk = typ: cs: subst: { ok = true; inherit typ constraints subst; };
  _inferFail = msg: { ok = false; typ = null; constraints = []; subst = emptySubst; error = msg; };

  # ══════════════════════════════════════════════════════════════════════════════
  # check : Ctx -> Term -> Type -> CheckResult
  # ══════════════════════════════════════════════════════════════════════════════

  check = ctx: term: typ:
    let
      tag  = term.__termTag or null;
      # normalize 期望类型
      nTyp = normalize typ;
      nVar  = nTyp.repr.__variant or null;
    in

    # ── TLam ~ A→B：检查 lambda ────────────────────────────────────────────
    if tag == "TLam" && nVar == "Fn" then
      let
        ctx' = ctxBind ctx term.param nTyp.repr.from;
      in
      check ctx' term.body nTyp.repr.to

    # ── TLam ~ Π(x:A).B：依赖函数类型检查 ────────────────────────────────
    else if tag == "TLam" && nVar == "Pi" then
      let
        paramTyp = nTyp.repr.paramType;
        ctx'     = ctxBind ctx term.param paramTyp;
        # B[x↦term.param]（在 body 类型中替换参数）
        bodyTyp  = _substTypeInType nTyp.repr.param (tVar term.param) nTyp.repr.body;
      in
      check ctx' term.body bodyTyp

    # ── TLet：let x = e₁ in e₂ ────────────────────────────────────────────
    else if tag == "TLet" then
      let ir1 = infer ctx term.def; in
      if !ir1.ok then _checkFail ir1.error
      else
        let ctx' = ctxBind (ctxWithSubst ctx ir1.subst) term.name ir1.typ; in
        check ctx' term.body typ

    # ── TMatch：模式匹配检查 ──────────────────────────────────────────────
    else if tag == "TMatch" then
      _checkMatch ctx term.scrutinee term.branches nTyp

    # ── 切换到 infer（subsumption）──────────────────────────────────────
    else
      let ir = infer ctx term; in
      if !ir.ok then _checkFail ir.error
      else
        # subtype check：inferred ≤ expected
        _subsume ctx ir.typ nTyp ir.subst ir.constraints;

  # ══════════════════════════════════════════════════════════════════════════════
  # infer : Ctx -> Term -> InferResult
  # ══════════════════════════════════════════════════════════════════════════════

  infer = ctx: term:
    let tag = term.__termTag or null; in

    # ── TVar：查找环境 ─────────────────────────────────────────────────────
    if tag == "TVar" then
      let bound = ctxLookup ctx term.name; in
      if bound != null
      then _inferOk bound [] ctx.subst
      else _inferFail "Unbound variable: ${term.name}"

    # ── TLit：从 primType 直接推断 ─────────────────────────────────────────
    else if tag == "TLit" then
      _inferOk term.primType [] ctx.subst

    # ── TAscribe：显式标注（check + 返回标注类型）─────────────────────────
    else if tag == "TAscribe" then
      let cr = check ctx term.term term.typ; in
      if !cr.ok then _inferFail cr.error
      else _inferOk term.typ cr.constraints cr.subst

    # ── TApp：函数应用 ────────────────────────────────────────────────────
    else if tag == "TApp" then
      _inferApp ctx term.fn term.arg

    # ── TLam：lambda（无标注时产生新类型变量）──────────────────────────────
    else if tag == "TLam" then
      let
        # 生成新类型变量（待 solver 推断）
        freshParam = _freshTypeVar ("_a" ++ term.param);
        freshBody  = _freshTypeVar ("_b" ++ term.param);
        ctx'       = ctxBind ctx term.param freshParam;
        cr         = check ctx' term.body freshBody;
      in
      if !cr.ok then _inferFail cr.error
      else
        let
          fnTyp = mkTypeDefault (rFn freshParam freshBody) (_kindLib.KStar);
        in
        _inferOk fnTyp cr.constraints cr.subst

    # ── TLet：let（推断模式）───────────────────────────────────────────────
    else if tag == "TLet" then
      let ir1 = infer ctx term.def; in
      if !ir1.ok then _inferFail ir1.error
      else
        let ctx' = ctxBind (ctxWithSubst ctx ir1.subst) term.name ir1.typ; in
        infer ctx' term.body

    # ── TMatch：推断 scrutinee，检查 branches ────────────────────────────
    else if tag == "TMatch" then
      _inferMatch ctx term.scrutinee term.branches

    # ── 未知 Term ────────────────────────────────────────────────────────
    else _inferFail "Cannot infer type for ${tag or "?"}";

  # ══════════════════════════════════════════════════════════════════════════════
  # 函数应用推断
  # ══════════════════════════════════════════════════════════════════════════════

  _inferApp = ctx: fn: arg:
    let ir = infer ctx fn; in
    if !ir.ok then _inferFail ir.error
    else
      let nFn = normalize ir.typ; in
      let v   = nFn.repr.__variant or null; in

      # A→B：普通函数应用
      if v == "Fn" then
        let cr = check (ctxWithSubst ctx ir.subst) arg nFn.repr.from; in
        if !cr.ok then _inferFail cr.error
        else _inferOk nFn.repr.to (ir.constraints ++ cr.constraints) cr.subst

      # Π(x:A).B：依赖类型应用
      else if v == "Pi" then
        let cr = check (ctxWithSubst ctx ir.subst) arg nFn.repr.paramType; in
        if !cr.ok then _inferFail cr.error
        else
          # 返回类型 B[x↦arg_type]（简化：用 arg 的推断类型替换）
          let retTyp = nFn.repr.body; in
          _inferOk retTyp (ir.constraints ++ cr.constraints) cr.subst

      # 变量（待推断）：生成新约束
      else if v == "Var" || v == "VarScoped" then
        let
          argIr  = infer (ctxWithSubst ctx ir.subst) arg;
          retVar = _freshTypeVar "_ret";
        in
        if !argIr.ok then _inferFail argIr.error
        else
          let
            expectedFn = mkTypeDefault (rFn argIr.typ retVar) (_kindLib.KStar);
            uc = mkEquality ir.typ expectedFn;
          in
          _inferOk retVar (ir.constraints ++ argIr.constraints ++ [uc]) argIr.subst

      else _inferFail "Cannot apply non-function type: ${v or "?"}";

  # ══════════════════════════════════════════════════════════════════════════════
  # Subsumption（subtype check）
  # ══════════════════════════════════════════════════════════════════════════════

  # 当前：structural subtyping = equality（Phase 3 基础版）
  # Phase 4 扩展：coercive subtyping（Fn contravariance, Record depth subtyping）
  _subsume = ctx: inferred: expected: subst: cs:
    let result = unify subst inferred expected; in
    if result.ok
    then _checkOk cs result.subst
    else _checkFail "Type mismatch: inferred ${_showType inferred} but expected ${_showType expected}. ${result.error or ""}";

  # ══════════════════════════════════════════════════════════════════════════════
  # Pattern Match 检查/推断
  # ══════════════════════════════════════════════════════════════════════════════

  _checkMatch = ctx: scrutinee: branches: expectedTyp:
    let ir = infer ctx scrutinee; in
    if !ir.ok then _checkFail ir.error
    else
      let
        # 检查每个 branch
        branchResults = map (br:
          let ctx' = _bindPattern ctx br.pattern ir.typ; in
          check ctx' br.body expectedTyp) branches;
        allOk = lib.all (r: r.ok) branchResults;
        allCs = lib.concatMap (r: r.constraints or []) branchResults;
      in
      if allOk
      then _checkOk (ir.constraints ++ allCs) ir.subst
      else _checkFail "Pattern match branch type error";

  _inferMatch = ctx: scrutinee: branches:
    let ir = infer ctx scrutinee; in
    if !ir.ok then _inferFail ir.error
    else if branches == [] then _inferFail "Empty match"
    else
      let
        # 推断第一个 branch 的类型
        firstBr  = builtins.head branches;
        ctx'     = _bindPattern ctx firstBr.pattern ir.typ;
        firstIr  = infer ctx' firstBr.body;
      in
      if !firstIr.ok then firstIr
      else
        # 检查其余 branches 与第一个类型一致
        let
          restResults = map (br:
            let ctx'' = _bindPattern ctx br.pattern ir.typ; in
            check ctx'' br.body firstIr.typ) (builtins.tail branches);
          allOk = lib.all (r: r.ok) restResults;
        in
        if allOk
        then _inferOk firstIr.typ (ir.constraints ++ firstIr.constraints) firstIr.subst
        else _inferFail "Inconsistent branch types in match";

  # ── 简单 Pattern 绑定（Phase 3 基础版）────────────────────────────────────
  _bindPattern = ctx: pattern: scrutTyp:
    let tag = pattern.__patternTag or null; in
    if tag == "PVar" then ctxBind ctx pattern.name scrutTyp
    else if tag == "PWild" then ctx
    else if tag == "PCtor" then
      # ADT 构造器：绑定字段
      lib.foldl'
        (acc: field: ctxBind acc field.name field.typ)
        ctx
        (pattern.fields or [])
    else ctx;

  # ══════════════════════════════════════════════════════════════════════════════
  # 辅助函数
  # ══════════════════════════════════════════════════════════════════════════════

  # 新鲜类型变量（简单实现）
  _freshTypeVar = hint:
    mkTypeDefault
      (rVar hint "fresh-${builtins.hashString "md5" hint}")
      (_kindLib.KUnbound);

  # 类型中替换（简化，不走 substLib 避免循环）
  _substTypeInType = varName: term: typ: typ;  # Phase 3.1 完善

  # 显示类型（调试用）
  _showType = t:
    if !isType t then "<?>"
    else t.repr.__variant or "?";

  # Kind lib 引用（避免循环，使用延迟访问）
  _kindLib = import ../core/kind.nix { inherit lib; };

}
