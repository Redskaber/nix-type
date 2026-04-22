# bidir/check.nix — Phase 4.2
# 双向类型推断 + HM-style let-generalization
# INV-BIDIR-1: infer + check sound w.r.t. normalize（Phase 4.2 新增）
# INV-SCHEME-1: generalize respects free variables in Ctx（Phase 4.2 新增）
{ lib, typeLib, reprLib, kindLib, normalizeLib, constraintLib,
  substLib, unifiedSubstLib, hashLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith freeVars mkScheme monoScheme
                    isScheme schemeBody schemeCons schemeForall;
  inherit (reprLib) rVar rFn rForall rHole rPrimitive rADT;
  inherit (kindLib) KStar KArrow;
  inherit (normalizeLib) normalize';
  inherit (constraintLib) mkEqConstraint mkClassConstraint mkSchemeConstraint;
  inherit (hashLib) typeHash;

  # ── fresh variable counter（纯函数式，用 hash 保证唯一性）──────────
  _freshVar = hint: seed:
    let name = "_${hint}_${builtins.substring 0 8 (builtins.hashString "sha256" (builtins.toJSON seed))}"; in
    mkTypeDefault (rVar name "bidir") KStar;

  # ── Context = attrset name → TypeScheme ─────────────────────────────
  emptyCtx = {};

  ctxExtend = ctx: name: scheme:
    ctx // { ${name} = scheme; };

  ctxLookup = ctx: name:
    ctx.${name} or null;

in rec {

  # ══ 推断模式（Synthesize/Infer）══════════════════════════════════════
  # Type: Ctx → Expr → { type: Type; constraints: [Constraint]; subst: UnifiedSubst }
  infer = ctx: expr:
    if !builtins.isAttrs expr then
      # 字面量
      _inferLiteral expr
    else
      let tag = expr.__exprTag or null; in
      if tag == "Var" then
        _inferVar ctx expr.name
      else if tag == "Lam" then
        _inferLam ctx expr
      else if tag == "App" then
        _inferApp ctx expr
      else if tag == "Let" then
        _inferLet ctx expr
      else if tag == "Ann" then
        # 标注表达式：check 模式
        let r = check ctx expr.body expr.ty; in
        { type = expr.ty; constraints = r.constraints; subst = r.subst; }
      else if tag == "If" then
        _inferIf ctx expr
      else if tag == "Prim" then
        { type = mkTypeDefault (rPrimitive expr.primType) KStar;
          constraints = []; subst = unifiedSubstLib.emptySubst; }
      else
        # Unknown expr: return hole
        { type = _freshVar "unknown" expr;
          constraints = []; subst = unifiedSubstLib.emptySubst; };

  # ══ 检查模式（Check）══════════════════════════════════════════════════
  # Type: Ctx → Expr → Type → { ok: Bool; constraints: [Constraint]; subst: UnifiedSubst }
  check = ctx: expr: expectedTy:
    let
      r = infer ctx expr;
      # 生成等价约束
      eqC = mkEqConstraint (normalize' r.type) (normalize' expectedTy);
    in
    { ok = true;
      constraints = r.constraints ++ [ eqC ];
      subst       = r.subst; };

  # ══ Var 推断 ══════════════════════════════════════════════════════════
  _inferVar = ctx: name:
    let scheme = ctxLookup ctx name; in
    if scheme == null then
      # 未绑定变量：生成新鲜类型变量
      let fresh = _freshVar name name; in
      { type = fresh; constraints = []; subst = unifiedSubstLib.emptySubst; }
    else
      # 实例化 scheme（Phase 4.2: HM instantiation）
      _instantiateScheme scheme;

  # ══ TypeScheme 实例化 ══════════════════════════════════════════════════
  _instantiateScheme = scheme:
    if !isScheme scheme then
      # 单态
      { type = schemeBody scheme; constraints = schemeCons scheme;
        subst = unifiedSubstLib.emptySubst; }
    else
      let
        forall = schemeForall scheme;
        body   = schemeBody scheme;
        cons   = schemeCons scheme;
        # 为每个 forall 变量生成新鲜变量
        freshBindings = builtins.listToAttrs (map (v:
          lib.nameValuePair v (_freshVar v v)
        ) forall);
        # 替换 body 中的 forall 变量
        instBody = lib.foldl' (acc: v:
          substLib.substitute v freshBindings.${v} acc
        ) body forall;
        # 替换约束
        instCons = map (c:
          substLib.applyUnifiedSubst
            (substLib.applyUnifiedSubst unifiedSubstLib.emptySubst instBody)
            c
        ) cons;
      in
      { type = instBody; constraints = instCons; subst = unifiedSubstLib.emptySubst; };

  # ══ Lambda 推断 ═══════════════════════════════════════════════════════
  # INV-BIDIR-1: infer Lam generates fresh param type if no annotation
  _inferLam = ctx: expr:
    let
      paramName = expr.param;
      paramTy   = expr.paramTy or null;
      # 如无注释，生成新鲜类型变量
      paramScheme =
        if paramTy != null then monoScheme paramTy
        else monoScheme (_freshVar paramName paramName);
      newCtx = ctxExtend ctx paramName paramScheme;
      bodyR  = infer newCtx expr.body;
      fnTy   = mkTypeDefault (rFn (schemeBody paramScheme) bodyR.type) KStar;
    in
    { type = fnTy; constraints = bodyR.constraints; subst = bodyR.subst; };

  # ══ Application 推断 ══════════════════════════════════════════════════
  # Phase 4.2: 使用约束生成而非 freshVar 占位（INV-BIDIR-1）
  _inferApp = ctx: expr:
    let
      fnR  = infer ctx expr.fn;
      argR = infer ctx expr.arg;
      # 函数类型：fnTy 应该是 argTy → resultTy
      resultFresh = _freshVar "res" expr;
      expectedFnTy = mkTypeDefault (rFn argR.type resultFresh) KStar;
      # 生成约束：fnTy ≡ argTy → resultFresh
      fnEqC = mkEqConstraint (normalize' fnR.type) (normalize' expectedFnTy);
    in
    { type        = resultFresh;
      constraints = fnR.constraints ++ argR.constraints ++ [ fnEqC ];
      subst       = unifiedSubstLib.emptySubst; };

  # ══ Let 推断（Phase 4.2: HM let-generalization）═══════════════════════
  # INV-SCHEME-1: generalize respects free variables in Ctx
  _inferLet = ctx: expr:
    let
      name   = expr.name;
      defR   = infer ctx expr.def;
      # Phase 4.2: let-generalize
      scheme = generalize ctx defR.type defR.constraints;
      newCtx = ctxExtend ctx name scheme;
      bodyR  = infer newCtx expr.body;
    in
    { type        = bodyR.type;
      constraints = bodyR.constraints;
      subst       = unifiedSubstLib.emptySubst; };

  # ══ If 推断 ═══════════════════════════════════════════════════════════
  _inferIf = ctx: expr:
    let
      condR  = infer ctx expr.cond;
      thenR  = infer ctx expr.then_;
      elseR  = infer ctx expr.else_;
      # cond 必须是 Bool
      condBoolC = mkEqConstraint (normalize' condR.type)
        (mkTypeDefault (rPrimitive "Bool") KStar);
      # then/else 必须类型相同
      branchEqC = mkEqConstraint (normalize' thenR.type) (normalize' elseR.type);
    in
    { type = thenR.type;
      constraints = condR.constraints ++ thenR.constraints ++ elseR.constraints
        ++ [ condBoolC branchEqC ];
      subst = unifiedSubstLib.emptySubst; };

  # ══ Literal 推断 ══════════════════════════════════════════════════════
  _inferLiteral = v:
    let ty =
      if builtins.isInt v then mkTypeDefault (rPrimitive "Int") KStar
      else if builtins.isBool v then mkTypeDefault (rPrimitive "Bool") KStar
      else if builtins.isString v then mkTypeDefault (rPrimitive "String") KStar
      else if builtins.isFloat v then mkTypeDefault (rPrimitive "Float") KStar
      else mkTypeDefault (rPrimitive "Unknown") KStar;
    in
    { type = ty; constraints = []; subst = unifiedSubstLib.emptySubst; };

  # ══ Generalization（INV-SCHEME-1）════════════════════════════════════
  # Type: Ctx → Type → [Constraint] → TypeScheme
  # generalize(Γ, T, cs) = ∀(fv(T) \ fv(Γ)).T
  generalize = ctx: ty: constraints:
    let
      tyFreeVars  = freeVars (normalize' ty);
      ctxFreeVars = _ctxFreeVars ctx;
      # INV-SCHEME-1: 只泛化 T 中的自由变量，不包含 Ctx 中的
      toGeneralize = lib.filter (v: !(builtins.elem v ctxFreeVars)) tyFreeVars;
    in
    if toGeneralize == [] then monoScheme ty
    else mkScheme toGeneralize ty constraints;

  # ── Ctx 中所有自由变量（INV-SCHEME-1 所需）──────────────────────────
  _ctxFreeVars = ctx:
    let
      schemes = builtins.attrValues ctx;
      bodyFvs = lib.concatMap (s:
        if isScheme s
        then freeVars (schemeBody s)
        else freeVars s
      ) schemes;
    in
    lib.unique bodyFvs;

  # ══ Expr 构造器（供测试使用）══════════════════════════════════════════
  eVar  = name: { __exprTag = "Var"; name = name; };
  eLam  = param: body: { __exprTag = "Lam"; param = param; body = body; };
  eLamA = param: paramTy: body: { __exprTag = "Lam"; param = param; paramTy = paramTy; body = body; };
  eApp  = fn: arg: { __exprTag = "App"; fn = fn; arg = arg; };
  eLet  = name: def: body: { __exprTag = "Let"; name = name; def = def; body = body; };
  eAnn  = body: ty: { __exprTag = "Ann"; body = body; ty = ty; };
  eIf   = cond: then_: else_: { __exprTag = "If"; cond = cond; then_ = then_; else_ = else_; };
  ePrim = primType: { __exprTag = "Prim"; primType = primType; };
  eLit  = value: value;  # literals are plain values
}
