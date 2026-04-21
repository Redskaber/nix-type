# bidir/check.nix — Phase 4.1
# 双向类型推断（Bidirectional Type Checking）
# check mode: 给定类型，验证表达式合法
# infer mode: 推断表达式类型
{ lib, typeLib, reprLib, kindLib, normalizeLib, constraintLib, substLib, hashLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith;
  inherit (reprLib)
    rVar rFn rLambda rPi rSigma rAscribe rConstrained
    isVar isLambda isApply isFn isPi;
  inherit (kindLib) KStar;
  inherit (normalizeLib) normalize';
  inherit (hashLib) typeHash;
  inherit (substLib) substitute;

in rec {

  # ── 类型上下文（Ctx）─────────────────────────────────────────────────────
  # Ctx = AttrSet(varName -> Type)
  emptyCtx = {};
  extendCtx = ctx: varName: ty: ctx // { ${varName} = ty; };
  lookupCtx = ctx: varName: ctx.${varName} or null;

  # ── Check mode（验证 expr : ty）──────────────────────────────────────────
  # Type: Ctx -> Expr -> Type -> CheckResult
  # CheckResult = { ok: Bool; constraints: [Constraint]; error?: String }
  check = ctx: expr: ty:
    let
      v    = expr.__exprTag or expr.__variant or null;
      nty  = normalize' ty;
      ntyV = nty.repr.__variant or null;
    in

    if v == "Lam" && ntyV == "Fn" then
      # λx.e : A → B  ⟹  check (Γ,x:A) e B
      let
        paramTy  = nty.repr.from;
        bodyTy   = nty.repr.to;
        ctx'     = extendCtx ctx expr.param paramTy;
        bodyExpr = expr.body;
      in check ctx' bodyExpr bodyTy

    else if v == "Lam" && ntyV == "Pi" then
      # λx.e : Π(x:A).B  ⟹  check (Γ,x:A) e B
      let
        paramTy  = nty.repr.domain;
        bodyTy   = nty.repr.body;
        ctx'     = extendCtx ctx expr.param paramTy;
      in check ctx' expr.body bodyTy

    else if v == "Ascribe" then
      # (e : T) in check mode → check e T（忽略给定类型？或合一？）
      let r = infer ctx expr.expr; in
      if !r.ok then r
      else
        let
          actualHash   = typeHash (normalize' r.ty);
          expectedHash = typeHash nty;
        in
        if actualHash == expectedHash
        then { ok = true; constraints = r.constraints; }
        else
          { ok = false; constraints = r.constraints;
            error = "Type ascription mismatch"; }

    else
      # 默认：infer 然后 subsume（简化：直接 hash 比较）
      let r = infer ctx expr; in
      if !r.ok then r
      else
        let
          actualHash   = typeHash (normalize' r.ty);
          expectedHash = typeHash nty;
        in
        if actualHash == expectedHash
        then { ok = true; constraints = r.constraints; }
        else
          # 生成 Equality constraint（让 solver 处理）
          let eqC = constraintLib.mkEqConstraint r.ty nty; in
          { ok          = true;  # 暂时 ok，solver 会验证
            constraints = r.constraints ++ [ eqC ]; };

  # ── Infer mode（推断 expr 的类型）────────────────────────────────────────
  # Type: Ctx -> Expr -> InferResult
  # InferResult = { ok: Bool; ty: Type; constraints: [Constraint]; error?: String }
  infer = ctx: expr:
    let v = expr.__exprTag or expr.__variant or null; in

    if v == "Var" then
      let ty = lookupCtx ctx expr.name; in
      if ty == null
      then { ok = false; ty = _unknownTy; constraints = [];
             error = "Unbound variable: ${expr.name}"; }
      else { ok = true; ty = ty; constraints = []; }

    else if v == "Lit" then
      let ty = _litType expr.value; in
      { ok = true; ty = ty; constraints = []; }

    else if v == "App" then
      let
        fnResult  = infer ctx expr.fn;
      in
      if !fnResult.ok then fnResult
      else
        let
          fnTy = normalize' fnResult.ty;
          fnV  = fnTy.repr.__variant or null;
        in
        if fnV == "Fn" then
          let
            argResult = check ctx expr.arg fnTy.repr.from;
          in
          if !argResult.ok then argResult
          else { ok = true; ty = fnTy.repr.to;
                 constraints = fnResult.constraints ++ argResult.constraints; }
        else if fnV == "Pi" then
          let
            argResult = check ctx expr.arg fnTy.repr.domain;
            resultTy  = substitute fnTy.repr.param expr.arg fnTy.repr.body;
          in
          if !argResult.ok then argResult
          else { ok = true; ty = resultTy;
                 constraints = fnResult.constraints ++ argResult.constraints; }
        else
          # 未知函数类型：生成新 unification var
          { ok = true; ty = _freshVar "ret";
            constraints = fnResult.constraints; }

    else if v == "Lam" then
      # 无类型注释的 λ：infer 生成新类型变量
      let
        paramTy  = if expr.paramTy or null != null then expr.paramTy
                   else _freshVar "param_${expr.param}";
        ctx'     = extendCtx ctx expr.param paramTy;
        bodyResult = infer ctx' expr.body;
      in
      if !bodyResult.ok then bodyResult
      else
        let fnTy = mkTypeDefault (rFn paramTy bodyResult.ty) KStar; in
        { ok = true; ty = fnTy; constraints = bodyResult.constraints; }

    else if v == "Ascribe" then
      # (e : T) → check e T, result type is T
      let r = check ctx expr.expr expr.type; in
      if !r.ok then r
      else { ok = true; ty = expr.type; constraints = r.constraints; }

    else if v == "Let" then
      let
        rhsResult = infer ctx expr.rhs;
      in
      if !rhsResult.ok then rhsResult
      else
        let
          ctx' = extendCtx ctx expr.var rhsResult.ty;
          bodyResult = infer ctx' expr.body;
        in
        if !bodyResult.ok then bodyResult
        else { ok = true; ty = bodyResult.ty;
               constraints = rhsResult.constraints ++ bodyResult.constraints; }

    else
      # 未知表达式形式
      { ok = true; ty = _freshVar "unknown"; constraints = []; };

  # ── 辅助 ─────────────────────────────────────────────────────────────────

  _unknownTy = mkTypeDefault (reprLib.rPrimitive "?") KStar;

  _freshVar = prefix:
    mkTypeDefault
      (rVar (prefix + "_" + builtins.substring 0 8
        (builtins.hashString "md5" prefix)) "bidir")
      KStar;

  _litType = value:
    if builtins.isInt value    then mkTypeDefault (reprLib.rPrimitive "Int")  KStar
    else if builtins.isBool value   then mkTypeDefault (reprLib.rPrimitive "Bool") KStar
    else if builtins.isString value then mkTypeDefault (reprLib.rPrimitive "String") KStar
    else if builtins.isFloat value  then mkTypeDefault (reprLib.rPrimitive "Float") KStar
    else _unknownTy;
}
