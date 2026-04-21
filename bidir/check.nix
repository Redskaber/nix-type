# bidir/check.nix — Phase 3.2
# 双向类型检查（Pierce/Turner，完整 substLib 集成）
#
# Phase 3.2 新增：
#   P3.2-1: _substTypeInType 完整递归（substLib 集成，不仅顶层 Var）
#            依赖 substLib.substitute / substituteAll
#
# Phase 3.1 继承：
#   check:   Γ ⊢ e ⇐ T（checking mode，向下传递类型期望）
#   infer:   Γ ⊢ e ⇒ T（synthesis mode，向上生成类型）
#   子类型：Fn contravariance，Pi/Sigma 带 binder，Record/ADT
#
# 语法项（Term IR）：
#   Var(x)         — 变量引用
#   Lam(x, body)   — lambda 抽象
#   App(fn, arg)   — 应用
#   Ascribe(e, T)  — 类型标注（e : T）
#   Lit(v, T)      — 字面量（已知类型）
#   Match(e, branches) — 模式匹配（分支类型检查）
#   Pi(x, A, body) — 依赖函数项（term-level，π-type intro）
#   Sigma(x, A, b) — 依赖对（existential intro）
#
# 类型检查不变量：
#   check(Γ, e, T) → ok iff e 有类型 T（在上下文 Γ 中）
#   infer(Γ, e)    → { ok; type } iff e 有唯一可推断类型
{ lib, typeLib, normalizeLib, constraintLib, unifyLib, reprLib, substLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith withRepr;
  inherit (normalizeLib) normalize;
  inherit (constraintLib) mkClass mkEquality;
  inherit (unifyLib) unify;
  inherit (reprLib)
    rVar rFn rLambda rApply rPi rSigma rADT rRecord rMu rConstrained;
  inherit (substLib) substitute substituteAll;

  # ── Term IR 构造器 ─────────────────────────────────────────────────────────────

  mkTerm = tag: attrs:
    { __termTag = tag; } // attrs;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Term IR 构造器（公共 API）
  # ══════════════════════════════════════════════════════════════════════════════

  tVar     = name:            mkTerm "Var"     { inherit name; };
  tLam     = param: body:     mkTerm "Lam"     { inherit param body; };
  tApp     = fn: arg:         mkTerm "App"     { inherit fn arg; };
  tAscribe = expr: ty:        mkTerm "Ascribe" { inherit expr ty; };
  tLit     = value: ty:       mkTerm "Lit"     { inherit value ty; };
  tMatch   = expr: branches:  mkTerm "Match"   { inherit expr branches; };
  tPi      = param: dom: body: mkTerm "PiTerm" { inherit param dom body; };
  tSigma   = param: dom: body: mkTerm "SigmaTerm" { inherit param dom body; };
  tLet     = name: def: body: mkTerm "Let"    { inherit name def body; };

  # Branch: { pat: Pattern; body: Term }
  mkBranch = pat: body: { inherit pat body; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 上下文（Γ：变量名 → Type）
  # ══════════════════════════════════════════════════════════════════════════════

  emptyCtx  = {};
  ctxBind   = ctx: name: ty: ctx // { ${name} = ty; };
  ctxLookup = ctx: name: ctx.${name} or null;

  # ══════════════════════════════════════════════════════════════════════════════
  # 类型检查主入口
  # ══════════════════════════════════════════════════════════════════════════════

  # check：Γ ⊢ e ⇐ T
  # Type: Ctx -> Term -> Type -> { ok; error?; constraints: [Constraint] }
  check = ctx: expr: ty:
    let
      tag = expr.__termTag or null;
      tyN = normalize ty;
    in

    # Lam ⇐ Fn(A,B)：引入参数
    if tag == "Lam" then
      let
        fnRepr = tyN.repr;
        fnV    = fnRepr.__variant or null;
      in
      if fnV == "Fn" then
        let
          ctx' = ctxBind ctx (expr.param or "_") (fnRepr.from or ty);
          r    = check ctx' (expr.body or expr) (fnRepr.to or ty);
        in
        r

      else if fnV == "Pi" then
        # Lam ⇐ Pi(x:A).B：引入 x:A，check body ⇐ B
        let
          ctx' = ctxBind ctx (expr.param or "_") (fnRepr.domain or ty);
          # Phase 3.2 修复：_substTypeInType 完整替换
          body_ty = _substTypeInType
            (fnRepr.param or "_")
            (mkTypeDefault (rVar (expr.param or "_") "bidir") ty.kind)
            (fnRepr.body or ty);
          r = check ctx' (expr.body or expr) body_ty;
        in
        r

      else
        _inferAndMatch ctx expr ty

    # Ascribe ⇐ T：内部 check infer 一致性
    else if tag == "Ascribe" then
      let
        r = check ctx (expr.expr or expr) (expr.ty or ty);
      in
      if !r.ok then r
      else
        let
          ur = unify {} (expr.ty or ty) ty;
        in
        if ur.ok
        then { ok = true; constraints = r.constraints or []; }
        else { ok = false; error = "Ascribe type mismatch: ${ur.error or "?"}"; constraints = []; }

    # Match ⇐ T：各分支 check ⇐ T
    else if tag == "Match" then
      _checkMatch ctx expr ty

    # Lit ⇐ T：类型一致性
    else if tag == "Lit" then
      let
        litTy = expr.ty or ty;
        ur    = unify {} litTy ty;
      in
      if ur.ok
      then { ok = true; constraints = []; }
      else { ok = false; error = "Lit type mismatch"; constraints = []; }

    # Let ⇐ T：局部定义
    else if tag == "Let" then
      let
        defResult = infer ctx (expr.def or expr);
      in
      if !defResult.ok
      then { ok = false; error = "Let def: ${defResult.error or "?"}"; constraints = []; }
      else
        let ctx' = ctxBind ctx (expr.name or "_") defResult.type; in
        check ctx' (expr.body or expr) ty

    # 其他情况：先推断类型，再和目标类型做 subsumption
    else _inferAndMatch ctx expr ty;

  # infer：Γ ⊢ e ⇒ T（synthesis）
  # Type: Ctx -> Term -> { ok; type?; error?; constraints: [Constraint] }
  infer = ctx: expr:
    let tag = expr.__termTag or null; in

    # Var：上下文查找
    if tag == "Var" then
      let ty = ctxLookup ctx (expr.name or ""); in
      if ty == null
      then { ok = false; error = "Unbound variable: ${expr.name or "?"}"; constraints = []; }
      else { ok = true; type = ty; constraints = []; }

    # Ascribe(e, T)：check e ⇐ T，推断结果 = T
    else if tag == "Ascribe" then
      let
        annotTy = expr.ty or null;
        r       = if annotTy != null then check ctx (expr.expr or expr) annotTy
                  else { ok = false; error = "Ascribe: missing type"; constraints = []; };
      in
      if !r.ok then r
      else { ok = true; type = annotTy; constraints = r.constraints or []; }

    # App(fn, arg)：infer fn，得 Fn(A,B)，check arg ⇐ A，推断 B
    else if tag == "App" then
      let rFn' = infer ctx (expr.fn or expr); in
      if !rFn'.ok then rFn'
      else
        let
          fnTy  = normalize (rFn'.type or (mkTypeDefault (rVar "_fn" "app") null));
          fnRepr = fnTy.repr;
          fnV    = fnRepr.__variant or null;
        in
        if fnV == "Fn" then
          let
            argTy   = fnRepr.from or fnTy;
            retTy   = fnRepr.to or fnTy;
            rArg    = check ctx (expr.arg or expr) argTy;
          in
          if !rArg.ok then rArg
          else { ok = true; type = retTy; constraints = (rFn'.constraints or []) ++ (rArg.constraints or []); }

        else if fnV == "Pi" then
          # App ⇒ Pi(x:A).B：check arg ⇐ A，推断 B[x↦arg]
          let
            domTy  = fnRepr.domain or fnTy;
            bodyTy = fnRepr.body   or fnTy;
            param  = fnRepr.param  or "_";
            rArg   = check ctx (expr.arg or expr) domTy;
          in
          if !rArg.ok then rArg
          else
            # Phase 3.2：_substTypeInType 完整替换
            let
              argInferred = infer ctx (expr.arg or expr);
              actualArg   = if argInferred.ok then argInferred.type or domTy else domTy;
              retTy       = _substTypeInType param actualArg bodyTy;
            in
            { ok = true; type = retTy; constraints = (rFn'.constraints or []) ++ (rArg.constraints or []); }

        else if fnV == "Lambda" then
          # 函数式应用：β-reduce（App(λx.B, arg) → B[x↦arg]）
          let
            param  = fnRepr.param or "_";
            body   = fnRepr.body or fnTy;
            rArg   = infer ctx (expr.arg or expr);
          in
          if !rArg.ok then rArg
          else
            let
              argTy = rArg.type or (mkTypeDefault (rVar "_arg" "app") null);
              # Phase 3.2：完整 _substTypeInType
              retTy = _substTypeInType param argTy body;
            in
            { ok = true; type = retTy; constraints = (rFn'.constraints or []) ++ (rArg.constraints or []); }

        else if fnV == "Constrained" then
          # Constrained fn：float constraints, infer base
          let
            baseTy  = fnRepr.base or fnTy;
            baseFn  = mkTypeDefault (baseTy.repr) baseTy.kind;
            cs      = fnRepr.constraints or [];
            synth   = infer ctx (tApp (tAscribe (expr.fn or expr) baseFn) (expr.arg or expr));
          in
          if !synth.ok then synth
          else { ok = true; type = synth.type; constraints = cs ++ (synth.constraints or []); }

        else
          # FIXME: Undefined name => `or`
          { ok = false; error = "Cannot apply non-function type: ${fnV or "?"}"; constraints = []; }

    # Lit：已知类型
    else if tag == "Lit" then
      { ok = true; type = expr.ty or (mkTypeDefault { __variant = "Primitive"; name = "?"; } null);
        constraints = []; }

    # Let：定义后推断 body
    else if tag == "Let" then
      let defResult = infer ctx (expr.def or expr); in
      if !defResult.ok then defResult
      else
        let ctx' = ctxBind ctx (expr.name or "_") defResult.type; in
        infer ctx' (expr.body or expr)

    # Match：推断 scrutinee，检查分支
    else if tag == "Match" then
      _inferMatch ctx expr

    # 无法推断（checking-mode only）
    else
      # FIXME: Undefined name => `or`
      { ok = false; error = "Cannot infer type for ${tag or "?"}"; constraints = []; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 辅助：infer + subsumption（用于 check 的 catch-all）
  # ══════════════════════════════════════════════════════════════════════════════

  _inferAndMatch = ctx: expr: expectedTy:
    let result = infer ctx expr; in
    if !result.ok then result
    else
      let
        inferredTy = normalize (result.type or expectedTy);
        expectedNF = normalize expectedTy;
        ur         = unify {} inferredTy expectedNF;
      in
      if ur.ok
      then { ok = true; constraints = result.constraints or []; }
      else { ok = false;
             error = "Type mismatch: inferred ${inferredTy.id or "?"} vs expected ${expectedNF.id or "?"}";
             constraints = []; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Phase 3.2：_substTypeInType（完整递归，substLib 集成）
  #
  # 语义：将 Type 中的 term-variable（来自 Pi/Sigma binding）替换为实际类型
  # 这与 normalize/substitute.nix 中的 substitute 不同：
  #   - substitute：Type 层面的变量替换（type-level Var）
  #   - _substTypeInType：在 Type 的 dependent position 中替换 term 变量
  #
  # Phase 3.1 限制：只替换顶层 Var（incomplete）
  # Phase 3.2 修复：调用 substLib.substitute 做完整的 capture-safe 递归替换
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: String -> Type -> Type -> Type
  # 将 ty 中出现的类型变量 varName 替换为 replacement
  _substTypeInType = varName: replacement: ty:
    substitute varName replacement ty;

  # 批量替换（用于 Pi/Sigma 多参数）
  # Type: AttrSet String Type -> Type -> Type
  _substTypeInTypeAll = substMap: ty:
    substituteAll substMap ty;

  # ══════════════════════════════════════════════════════════════════════════════
  # Match 类型检查
  # ══════════════════════════════════════════════════════════════════════════════

  _checkMatch = ctx: expr: expectedTy:
    let
      branches = expr.branches or [];
      scrutExpr = expr.expr or expr;
      scrutResult = infer ctx scrutExpr;
    in
    if !scrutResult.ok
    then { ok = false; error = "Match scrutinee: ${scrutResult.error or "?"}"; constraints = []; }
    else
      let
        scrutTy = scrutResult.type or (mkTypeDefault { __variant = "Primitive"; name = "?"; } null);
        branchResults = map (_checkBranch ctx scrutTy expectedTy) branches;
        failures = builtins.filter (r: !r.ok) branchResults;
      in
      if failures != []
      then builtins.head failures
      else
        { ok = true;
          constraints = builtins.concatMap (r: r.constraints or []) branchResults; };

  _inferMatch = ctx: expr:
    let
      branches    = expr.branches or [];
      scrutExpr   = expr.expr or expr;
      scrutResult = infer ctx scrutExpr;
    in
    if !scrutResult.ok
    then scrutResult
    else if branches == []
    then { ok = false; error = "Match: no branches"; constraints = []; }
    else
      # 推断第一个分支的类型，其余分支 check
      let
        firstBranch = builtins.head branches;
        firstResult = _inferBranch ctx (scrutResult.type or null) firstBranch;
      in
      if !firstResult.ok then firstResult
      else
        let
          restBranches = builtins.tail branches;
          restResults  = map (_checkBranch ctx (scrutResult.type or null) (firstResult.type or null)) restBranches;
          failures     = builtins.filter (r: !r.ok) restResults;
        in
        if failures != []
        then builtins.head failures
        else
          { ok = true;
            type = firstResult.type;
            constraints =
              (firstResult.constraints or [])
              ++ builtins.concatMap (r: r.constraints or []) restResults; };

  # 检查单个 branch（check mode）
  _checkBranch = ctx: scrutTy: expectedTy: branch:
    let
      pat      = branch.pat or {};
      bodyExpr = branch.body or branch;
      # 从 pattern 中绑定变量（简化：只处理 Var 和 Ctor patterns）
      ctx'     = _bindPatternVars ctx scrutTy pat;
    in
    # FIXME: Undefined name => `or`
    check ctx' bodyExpr (expectedTy or (mkTypeDefault { __variant = "Primitive"; name = "?"; } null));

  # 推断单个 branch（infer mode）
  _inferBranch = ctx: scrutTy: branch:
    let
      pat      = branch.pat or {};
      bodyExpr = branch.body or branch;
      ctx'     = _bindPatternVars ctx scrutTy pat;
    in
    infer ctx' bodyExpr;

  # 从 Pattern 绑定变量到 context（简化版）
  _bindPatternVars = ctx: scrutTy: pat:
    let tag = pat.__patTag or null; in
    if tag == "Var"
    # FIXME: Undefined name => `or`
    then ctxBind ctx (pat.name or "_") (scrutTy or (mkTypeDefault { __variant = "Primitive"; name = "?"; } null))
    else if tag == "Ctor"
    then
      let
        fields = pat.fields or [];
        # 尝试从 scrutTy 的 ADT variants 中找 Ctor 字段类型
        ctorFields = _findCtorFields scrutTy (pat.name or "");
      in
      lib.foldl'
        (ctx': pair:
          let
            subPat = pair.a;
            subTy  = pair.b;
          in
          _bindPatternVars ctx' subTy subPat)
        ctx
        (_zipLists fields ctorFields)
    else ctx;

  # 从 ADT type 中找 constructor 的字段类型列表
  _findCtorFields = ty: ctorName:
    let
      tyN    = normalize ty;
      repr   = tyN.repr;
      v      = repr.__variant or null;
    in
    if v == "ADT" then
      let
        variants = repr.variants or [];
        matched  = builtins.filter (var: var.name or "" == ctorName) variants;
      in
      if matched == [] then []
      else (builtins.head matched).fields or []
    else [];

  # zipLists 辅助
  _zipLists = xs: ys:
    lib.imap0 (i: x: { a = x; b = builtins.elemAt ys i; }) xs;

  # ══════════════════════════════════════════════════════════════════════════════
  # 子类型检查（结构性 subsumption）
  # ══════════════════════════════════════════════════════════════════════════════

  # 简化子类型：Fn contravariance + 递归比较
  # Type: Type -> Type -> Bool
  isSubtype = sub: sup:
    let
      subN = normalize sub;
      supN = normalize sup;
      vs   = subN.repr.__variant or null;
      vp   = supN.repr.__variant or null;
    in
    # 相同类型
    if subN.id == supN.id then true
    # Fn contravariance: sub ≤ sup iff sup.from ≤ sub.from && sub.to ≤ sup.to
    else if vs == "Fn" && vp == "Fn" then
      isSubtype (supN.repr.from or supN) (subN.repr.from or subN)
      && isSubtype (subN.repr.to or subN) (supN.repr.to or supN)
    # Constrained: subtype if base subtypes
    else if vs == "Constrained" then
      isSubtype (subN.repr.base or subN) supN
    else false;

}
