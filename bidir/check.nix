# bidir/check.nix — Phase 4.5.6
# 双向类型推断（Bidirectional Type Checking）
#
# ★ INV-BIDIR-1: infer + check sound w.r.t. normalize
# ★ INV-BIDIR-2: infer(eLamA param ty body) yields (ty -> bodyTy)
# ★ INV-BIDIR-3: infer(eApp fn arg).resultSolved = true when fn type = Fn
# ★ INV-BIDIR-4: check ctx expr ty -> { ok: Bool } via solver (not always true)
# ★ INV-SCHEME-1: generalize respects free variables in Ctx
# ★ INV-EXPR-1:
#     eLamA produces __exprTag = "llama" (tests check this tag)
#     eLit  produces { __exprTag = "Lit"; value = v } (tests check .__exprTag)
#     infer internally normalises: "llama" -> "Lam", "Lit" -> literal lookup
#
# ── API boundary (INV-LIB-1) ─────────────────────────────────────────
#   This module is the sole authority for all bidir logic.
#   lib/default.nix only does inherit; it must NOT redefine any API here.
#   EXCEPT: ts.checkAnnotatedLam is a 3-arg public wrapper in lib/default.nix
#     (ctx lamExpr expectedFnTy -> {ok; ...}) that delegates to check().
#     This module's checkAnnotatedLam is 4-arg (ctx param paramTy body -> Bool)
#     and is only used by __checkInvariants.invBidir2 via bidirLib direct access.
#   ts.checkAppResultSolved is a 1-arg type-inspect helper
#   exposed at lib level for tests (different contract from this module's
#   3-arg checkAppResultSolved used by invBidir3).
{ lib, typeLib, reprLib, kindLib, normalizeLib, constraintLib,
  substLib, unifiedSubstLib, hashLib, solverLib }:

let
  inherit (typeLib) mkTypeDefault freeVars mkScheme monoScheme
                    isScheme schemeBody schemeCons schemeForall;
  inherit (reprLib) rVar rFn rPrimitive;
  inherit (kindLib) KStar;
  inherit (normalizeLib) normalize';
  inherit (constraintLib) mkEqConstraint;
  inherit (hashLib) typeHash;

  # ── Fresh variable (hash-based, deterministic) ───────────────────────
  _freshVar = hint: seed:
    let
      seedStr =
        if builtins.isString seed  then seed
        else if builtins.isInt seed then builtins.toString seed
        else if builtins.isAttrs seed
          then builtins.hashString "sha256"
                 (builtins.concatStringsSep "," (builtins.attrNames seed))
        else "?";
      name = "_${hint}_${builtins.substring 0 8
               (builtins.hashString "sha256" seedStr)}";
    in
    mkTypeDefault (rVar name "bidir") KStar;

  # ── Context helpers ──────────────────────────────────────────────────
  _emptyCtx  = {};
  _ctxExtend = ctx: name: scheme: ctx // { ${name} = scheme; };
  _ctxLookup = ctx: name: ctx.${name} or null;

  # ── Literal type from Nix value ──────────────────────────────────────
  _litType = v:
    if      builtins.isInt    v then mkTypeDefault (rPrimitive "Int")    KStar
    else if builtins.isBool   v then mkTypeDefault (rPrimitive "Bool")   KStar
    else if builtins.isString v then mkTypeDefault (rPrimitive "String") KStar
    else if builtins.isFloat  v then mkTypeDefault (rPrimitive "Float")  KStar
    else                             mkTypeDefault (rPrimitive "Unknown") KStar;

  # ── _normalizeExpr: "llama" -> "Lam", hoisted to top-level let ───────
  # Must be top-level (not inside rec{}) to avoid Nix lazy thunk cycles
  # when passed as higher-order argument. (INV-NIX-2)
  _normalizeExpr = expr:
    if !builtins.isAttrs expr then expr
    else
      let tag = expr.__exprTag or null; in
      if      tag == "llama" then
        _normalizeExpr (expr // { __exprTag = "Lam"; })
      else if tag == "Lam"   then
        expr // { body = _normalizeExpr (expr.body or expr); }
      else if tag == "App"   then
        expr // { fn  = _normalizeExpr expr.fn;
                  arg = _normalizeExpr expr.arg; }
      else if tag == "Let"   then
        expr // { def  = _normalizeExpr expr.def;
                  body = _normalizeExpr expr.body; }
      else if tag == "Ann"   then
        expr // { body = _normalizeExpr expr.body; }
      else if tag == "If"    then
        expr // { cond  = _normalizeExpr expr.cond;
                  then_ = _normalizeExpr expr.then_;
                  else_ = _normalizeExpr expr.else_; }
      else expr;

  # ── Context normaliser: ensure all values are TypeScheme ─────────────
  _normalizeCtx = ctx:
    builtins.mapAttrs (_: v:
      if typeLib.isScheme v then v else typeLib.monoScheme v
    ) ctx;

in rec {

  # ══════════════════════════════════════════════════════════════════════
  # Expr constructors (INV-EXPR-1)
  # ══════════════════════════════════════════════════════════════════════

  # Unannotated lambda
  eLam  = param: body:
    { __exprTag = "Lam"; param = param; body = body; };

  # Annotated lambda — produces "llama" tag (INV-EXPR-1)
  eLamA = param: paramTy: body:
    { __exprTag = "llama"; param = param; paramTy = paramTy; body = body; };

  # Literal — produces "Lit" tag (INV-EXPR-1)
  eLit  = value: { __exprTag = "Lit"; value = value; };

  eVar  = name:            { __exprTag = "Var"; name = name; };
  eApp  = fn: arg:         { __exprTag = "App"; fn = fn; arg = arg; };
  eLet  = name: def: body: { __exprTag = "Let"; name = name; def = def; body = body; };
  eAnn  = body: ty:        { __exprTag = "Ann"; body = body; ty = ty; };
  eIf   = cond: then_: else_:
    { __exprTag = "If"; cond = cond; then_ = then_; else_ = else_; };
  ePrim = primType: { __exprTag = "Prim"; primType = primType; };

  # ══════════════════════════════════════════════════════════════════════
  # infer — synthesise mode
  # Type: Ctx -> Expr -> { type; constraints; subst; resultSolved? }
  # ══════════════════════════════════════════════════════════════════════
  infer = ctx: expr:
    let
      nctx = _normalizeCtx ctx;
      # Normalise "llama" -> "Lam" before dispatching
      e    = _normalizeExpr (if builtins.isAttrs expr then expr else expr);
      tag  = if builtins.isAttrs e then e.__exprTag or null else null;
    in
    # 1. Plain non-attrset literal (backward compat with eLit = value: value)
    if !builtins.isAttrs e then
      { type = _litType e; constraints = []; subst = unifiedSubstLib.emptySubst; }
    # 2. Tagged Lit
    else if tag == "Lit" then
      { type = _litType (e.value or null);
        constraints = []; subst = unifiedSubstLib.emptySubst; }
    # 3. Var
    else if tag == "Var" then _inferVar nctx e.name
    # 4. Lam (includes normalised "llama")
    else if tag == "Lam" then _inferLam nctx e
    # 5. App
    else if tag == "App" then _inferApp nctx e
    # 6. Let
    else if tag == "Let" then _inferLet nctx e
    # 7. Ann
    else if tag == "Ann" then
      let r = check nctx e.body e.ty; in
      { type = e.ty; constraints = r.constraints; subst = r.subst; }
    # 8. If
    else if tag == "If"  then _inferIf nctx e
    # 9. Prim
    else if tag == "Prim" then
      { type = mkTypeDefault (rPrimitive e.primType) KStar;
        constraints = []; subst = unifiedSubstLib.emptySubst; }
    # 10. Unknown
    else
      { type = _freshVar "unknown" (builtins.length (builtins.attrNames e));
        constraints = []; subst = unifiedSubstLib.emptySubst; };

  # ══════════════════════════════════════════════════════════════════════
  # check — checking mode (INV-BIDIR-4)
  # Type: Ctx -> Expr -> Type -> { ok: Bool; constraints; subst }
  # ok = true iff solver(inferred.constraints ++ [Eq(inferred,expected)]).ok
  # ══════════════════════════════════════════════════════════════════════
  check = ctx: expr: expectedTy:
    let
      r     = infer ctx expr;
      eqC   = mkEqConstraint (normalize' r.type) (normalize' expectedTy);
      allCs = r.constraints ++ [ eqC ];
      sol   = solverLib.solveSimple allCs;
    in
    { ok = sol.ok; constraints = allCs; subst = sol.subst; };

  # ══════════════════════════════════════════════════════════════════════
  # Internal inference helpers (all top-level let — no rec{} thunk risk)
  # ══════════════════════════════════════════════════════════════════════

  _inferVar = ctx: name:
    let scheme = _ctxLookup ctx name; in
    if scheme == null then
      let fresh = _freshVar name name; in
      { type = fresh; constraints = []; subst = unifiedSubstLib.emptySubst; }
    else
      _instantiateScheme scheme;

  _instantiateScheme = scheme:
    if !isScheme scheme then
      { type = schemeBody scheme; constraints = schemeCons scheme;
        subst = unifiedSubstLib.emptySubst; }
    else
      let
        forall  = schemeForall scheme;
        body    = schemeBody   scheme;
        freshBs = builtins.listToAttrs
          (map (v: lib.nameValuePair v (_freshVar v v)) forall);
        instBody = lib.foldl'
          (acc: v: substLib.substitute v freshBs.${v} acc) body forall;
      in
      { type = instBody; constraints = []; subst = unifiedSubstLib.emptySubst; };

  # INV-BIDIR-1/2: lambda inference
  # Note: expr has already been normalised ("llama" -> "Lam") by infer
  _inferLam = ctx: expr:
    let
      paramName   = expr.param;
      paramTy     = expr.paramTy or null;
      paramScheme =
        if paramTy != null then monoScheme paramTy
        else monoScheme (_freshVar paramName paramName);
      newCtx      = _ctxExtend ctx paramName paramScheme;
      bodyR       = infer newCtx expr.body;
      paramTyUsed = schemeBody paramScheme;
      fnTy        = mkTypeDefault (rFn paramTyUsed bodyR.type) KStar;
    in
    { type      = fnTy;
      constraints = bodyR.constraints;
      subst     = bodyR.subst;
      annotated = paramTy != null;
      paramTy   = paramTyUsed; };

  # INV-BIDIR-3: application inference
  # CASE 1 — fn type = Fn(domain, codomain) => result = codomain (solved)
  # CASE 2 — fn type = other                => result = freshVar  (deferred)
  _inferApp = ctx: expr:
    let
      fnR       = infer ctx expr.fn;
      argR      = infer ctx expr.arg;
      fnRepr    = fnR.type.repr or {};
      fnVariant = fnRepr.__variant or null;
    in
    if fnVariant == "Fn" then
      let
        domain   = fnRepr.from or (mkTypeDefault (rPrimitive "Unknown") KStar);
        codomain = fnRepr.to   or (mkTypeDefault (rPrimitive "Unknown") KStar);
        argEqC   = mkEqConstraint (normalize' argR.type) (normalize' domain);
      in
      { type         = codomain;
        constraints  = fnR.constraints ++ argR.constraints ++ [ argEqC ];
        subst        = unifiedSubstLib.emptySubst;
        resultSolved = true; }
    else
      let
        resultFresh  = _freshVar "res"
          (builtins.length (builtins.attrNames expr));
        expectedFnTy = mkTypeDefault (rFn argR.type resultFresh) KStar;
        fnEqC        = mkEqConstraint
          (normalize' fnR.type) (normalize' expectedFnTy);
      in
      { type         = resultFresh;
        constraints  = fnR.constraints ++ argR.constraints ++ [ fnEqC ];
        subst        = unifiedSubstLib.emptySubst;
        resultSolved = false; };

  # INV-SCHEME-1: HM let-generalisation
  _inferLet = ctx: expr:
    let
      name   = expr.name;
      defR   = infer ctx expr.def;
      scheme = generalize ctx defR.type defR.constraints;
      newCtx = _ctxExtend ctx name scheme;
      bodyR  = infer newCtx expr.body;
    in
    { type = bodyR.type; constraints = bodyR.constraints;
      subst = unifiedSubstLib.emptySubst; };

  _inferIf = ctx: expr:
    let
      condR  = infer ctx expr.cond;
      thenR  = infer ctx expr.then_;
      elseR  = infer ctx expr.else_;
      condBoolC = mkEqConstraint (normalize' condR.type)
        (mkTypeDefault (rPrimitive "Bool") KStar);
      branchEqC = mkEqConstraint
        (normalize' thenR.type) (normalize' elseR.type);
    in
    { type = thenR.type;
      constraints = condR.constraints ++ thenR.constraints
                    ++ elseR.constraints ++ [ condBoolC branchEqC ];
      subst = unifiedSubstLib.emptySubst; };

  # ══════════════════════════════════════════════════════════════════════
  # Generalisation (INV-SCHEME-1)
  # generalize(Ctx, T, cs) = forall(fv(T) \ fv(Ctx)).T
  # ══════════════════════════════════════════════════════════════════════
  generalize = ctx: ty: constraints:
    let
      tyFvs   = freeVars (normalize' ty);
      ctxFvs  = _ctxFreeVars ctx;
      toGen   = lib.filter (v: !(builtins.elem v ctxFvs)) tyFvs;
    in
    if toGen == [] then monoScheme ty
    else mkScheme toGen ty constraints;

  _ctxFreeVars = ctx:
    let
      schemes = builtins.attrValues ctx;
      fvs     = lib.concatMap (s:
        if isScheme s then freeVars (schemeBody s) else freeVars s
      ) schemes;
    in
    lib.unique fvs;

  # ══════════════════════════════════════════════════════════════════════
  # Public verifiers
  # ══════════════════════════════════════════════════════════════════════

  # INV-BIDIR-2: annotated lambda has correct domain type
  # Type: Ctx -> String -> Type -> Expr -> Bool
  # Used by __checkInvariants.invBidir2
  checkAnnotatedLam = ctx: param: paramTy: body:
    let
      r      = infer ctx (eLamA param paramTy body);
      fnRepr = r.type.repr or {};
    in
    (fnRepr.__variant or null) == "Fn" &&
    typeHash (fnRepr.from or (mkTypeDefault (rPrimitive "Unknown") KStar)) ==
    typeHash (normalize' paramTy);

  # INV-BIDIR-3: application resultSolved=true when fn type is concrete Fn
  # Type: Ctx -> Expr -> Expr -> Bool
  # Used by __checkInvariants.invBidir3
  # Note: infer handles "llama" tag internally via _normalizeExpr
  checkAppResultSolved = ctx: fn: arg:
    let r = infer ctx (eApp fn arg); in
    r.resultSolved or false;
}
