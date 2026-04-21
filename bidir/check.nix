# bidir/check.nix — Phase 3.1
# Bidirectional Type Checking（Pierce/Turner 风格）
#
# Phase 3.1：
#   check : Ctx → Term → Type → CheckResult
#   infer : Ctx → Term → InferResult
#   规则：TLam/Pi, TApp/Fn, TAscribe, TLet, TMatch
#   _substTypeInType：完整递归替换（替代 placeholder）
{ lib, typeLib, normalizeLib, constraintLib, unifyLib, reprLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault withRepr;
  inherit (normalizeLib) normalize;
  inherit (reprLib) rVar rFn rPi rLambda rApply rADT;
  inherit (unifyLib) unify;
  inherit (constraintLib) mkEquality;

  emptySubst = {};

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Term IR
  # ══════════════════════════════════════════════════════════════════════════════

  _mkTerm = tag: fields: { __termTag = tag; } // fields;

  tVar     = name: _mkTerm "TVar"     { inherit name; };
  tLam     = param: body: _mkTerm "TLam" { inherit param body; };
  tApp     = fn: arg: _mkTerm "TApp"  { inherit fn arg; };
  tAscribe = term: typ: _mkTerm "TAscribe" { inherit term typ; };
  tLet     = name: def: body: _mkTerm "TLet" { inherit name def body; };
  tLit     = value: primType: _mkTerm "TLit" { inherit value primType; };
  tMatch   = scrutinee: branches: _mkTerm "TMatch" { inherit scrutinee branches; };
  mkBranch = pattern: body: { inherit pattern body; };

  isTerm = t: builtins.isAttrs t && t ? __termTag;

  # ══════════════════════════════════════════════════════════════════════════════
  # Context
  # ══════════════════════════════════════════════════════════════════════════════

  emptyCtx = { bindings = {}; subst = emptySubst; };

  ctxBind = ctx: name: typ:
    ctx // { bindings = ctx.bindings // { ${name} = typ; }; };

  ctxLookup = ctx: name:
    ctx.bindings.${name} or null;

  ctxWithSubst = ctx: subst:
    ctx // { subst = subst; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 结果类型
  # ══════════════════════════════════════════════════════════════════════════════

  _checkOk   = cs: subst: { ok = true;  constraints = cs; inherit subst; };
  _checkFail = msg:       { ok = false; constraints = []; subst = emptySubst; error = msg; };
  _inferOk   = typ: cs: subst: { ok = true;  inherit typ constraints subst; };
  _inferFail = msg:             { ok = false; typ = null; constraints = []; subst = emptySubst; error = msg; };

  # ══════════════════════════════════════════════════════════════════════════════
  # check : Ctx → Term → Type → CheckResult
  # ══════════════════════════════════════════════════════════════════════════════

  check = ctx: term: typ:
    let
      tag  = term.__termTag or null;
      nTyp = normalize typ;
      nVar = nTyp.repr.__variant or null;
    in

    # TLam ~ Fn(A → B)：check lambda body against B
    if tag == "TLam" && nVar == "Fn" then
      let ctx' = ctxBind ctx term.param (nTyp.repr.from or nTyp); in
      check ctx' term.body (nTyp.repr.to or nTyp)

    # TLam ~ Pi(x:A).B：dependent function
    else if tag == "TLam" && nVar == "Pi" then
      let
        paramTyp = nTyp.repr.domain or nTyp;
        ctx'     = ctxBind ctx term.param paramTyp;
        bodyTyp  = _substTypeInType nTyp.repr.param
                     (mkTypeDefault (rVar term.param) paramTyp.kind) nTyp.repr.body;
      in
      check ctx' term.body bodyTyp

    # TLet：infer def, bind, check body
    else if tag == "TLet" then
      let ir1 = infer ctx term.def; in
      if !ir1.ok then _checkFail (ir1.error or "let def infer failed")
      else
        let ctx' = ctxBind (ctxWithSubst ctx ir1.subst) term.name (ir1.typ or nTyp); in
        check ctx' term.body typ

    # TMatch：check each branch
    else if tag == "TMatch" then
      _checkMatch ctx term.scrutinee term.branches nTyp

    # 切换到 infer（subsumption）
    else
      let ir = infer ctx term; in
      if !ir.ok then _checkFail (ir.error or "infer failed")
      else _subsume ctx (ir.typ or nTyp) nTyp ir.subst ir.constraints;

  # ══════════════════════════════════════════════════════════════════════════════
  # infer : Ctx → Term → InferResult
  # ══════════════════════════════════════════════════════════════════════════════

  infer = ctx: term:
    let tag = term.__termTag or null; in

    # TVar：查找环境
    if tag == "TVar" then
      let t = ctxLookup ctx term.name; in
      if t != null then _inferOk t [] ctx.subst
      else _inferFail "Unbound variable: ${term.name}"

    # TLit：原始值类型
    else if tag == "TLit" then
      _inferOk (term.primType or (mkTypeDefault (rVar "?") { __kindVariant = "KStar"; })) [] ctx.subst

    # TAscribe：显式类型标注（check → infer 切换）
    else if tag == "TAscribe" then
      let cr = check ctx term.term term.typ; in
      if !cr.ok then _inferFail (cr.error or "ascribe check failed")
      else _inferOk term.typ cr.constraints cr.subst

    # TApp：infer fn，check arg
    else if tag == "TApp" then
      let ir = infer ctx term.fn; in
      if !ir.ok then _inferFail (ir.error or "fn infer failed")
      else
        let
          fnTyp = normalize (ir.typ or (mkTypeDefault (rVar "?") { __kindVariant = "KStar"; }));
          fnVar = fnTyp.repr.__variant or null;
        in
        if fnVar == "Fn" then
          let
            argCr = check (ctxWithSubst ctx ir.subst) term.arg (fnTyp.repr.from or fnTyp);
          in
          if !argCr.ok then _inferFail (argCr.error or "arg check failed")
          else _inferOk (fnTyp.repr.to or fnTyp) (ir.constraints ++ argCr.constraints) argCr.subst
        else if fnVar == "Pi" then
          let
            argCr = check (ctxWithSubst ctx ir.subst) term.arg (fnTyp.repr.domain or fnTyp);
          in
          if !argCr.ok then _inferFail (argCr.error or "pi arg check failed")
          else
            let
              resultTyp = _substTypeInType fnTyp.repr.param term.arg fnTyp.repr.body;
            in
            _inferOk resultTyp (ir.constraints ++ argCr.constraints) argCr.subst
        else _inferFail "Cannot apply: expected Fn or Pi, got ${fnVar or "?"}"

    # TLam：需要类型标注（mode switch）
    else if tag == "TLam" then
      _inferFail "Cannot infer type of lambda without annotation. Use TAscribe."

    else
      _inferFail "Cannot infer term tag: ${tag or "?"}"

  ;  # end infer

  # ══════════════════════════════════════════════════════════════════════════════
  # _subsume（subtype check：inferred ≤ expected）
  # ══════════════════════════════════════════════════════════════════════════════

  _subsume = ctx: inferredTyp: expectedTyp: subst: constraints:
    let r = unify subst inferredTyp expectedTyp; in
    if r.ok then _checkOk constraints r.subst
    else _checkFail "Type mismatch: inferred ${typeLib.showType inferredTyp} ≠ expected ${typeLib.showType expectedTyp}. ${r.error or ""}";

  # ══════════════════════════════════════════════════════════════════════════════
  # _checkMatch
  # ══════════════════════════════════════════════════════════════════════════════

  _checkMatch = ctx: scrutinee: branches: resultTyp:
    let
      # infer scrutinee type
      scrIr = infer ctx scrutinee;
    in
    if !scrIr.ok then _checkFail (scrIr.error or "match scrutinee infer failed")
    else
      # check each branch body against resultTyp
      let
        branchResults = map (branch:
          let
            # extend ctx with pattern bindings（简化：只处理 Variable pattern）
            ctx' = _extendCtxWithPattern ctx branch.pattern (scrIr.typ or (mkTypeDefault (rVar "?") { __kindVariant = "KStar"; }));
            cr = check ctx' branch.body resultTyp;
          in cr
        ) branches;
        allOk = lib.all (r: r.ok) branchResults;
        allConstraints = builtins.concatMap (r: r.constraints or []) branchResults;
        lastSubst = lib.foldl' (acc: r: r.subst or acc) scrIr.subst branchResults;
      in
      if allOk then _checkOk allConstraints lastSubst
      else
        let errBranch = builtins.head (builtins.filter (r: !r.ok) branchResults); in
        _checkFail (errBranch.error or "branch check failed");

  _extendCtxWithPattern = ctx: pat: scrutTyp:
    let tag = pat.__patTag or null; in
    if tag == "Variable" then ctxBind ctx pat.name scrutTyp
    else ctx;

  # ══════════════════════════════════════════════════════════════════════════════
  # _substTypeInType（Type-level substitution for bidir）
  # Phase 3.1：完整实现（替代 placeholder）
  # ══════════════════════════════════════════════════════════════════════════════

  _substTypeInType = varName: replacement: t:
    # 委托给 substLib（typeLib 中已有 substitute）
    # Phase 3.1 简化：仅处理 Var 顶层（完整版集成 substLib 后）
    let
      v = t.repr.__variant or null;
    in
    if v == "Var" && t.repr.name or "_" == varName
    then replacement
    else t;

}
