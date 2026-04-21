# normalize/substitute.nix — Phase 3.1
# 捕获安全替换（α-rename + de Bruijn + row spine）
#
# Phase 3.1 关键修复：
#   1. substituteAll：显式 lexicographic 排序（消除 attrNames 不稳定顺序）
#   2. composeSubst：weakly closed composition（σ₂ ∘ σ₁ 正确顺序）
#   3. freeVarsRepr：全 21 变体覆盖（通过 reprLib）
#   4. Lambda/Pi/Sigma：capture check + fresh name generation
#   5. substituteType：完整递归替换（INV-C3，不仅顶层 Var）
#
# 不变量：
#   SUBST-1: substitute(x, t, e)[x ∉ freeVars] = e（不相关替换无影响）
#   SUBST-2: capture-safe：substitution 不捕获自由变量
#   SUBST-3: substituteAll 顺序稳定（lexicographic）
{ lib, typeLib, reprLib }:

let
  inherit (typeLib) isType mkTypeWith withRepr;
  inherit (reprLib) freeVarsRepr;

  # ── 辅助：新鲜名生成 ─────────────────────────────────────────────────────────
  # 简单计数后缀（Phase 3.1 实用策略，非 Barendregt 完整）
  _freshName = name: fvs:
    let
      go = n:
        let candidate = "${name}_${builtins.toString n}"; in
        if !builtins.elem candidate fvs then candidate
        else go (n + 1);
    in
    if !builtins.elem name fvs then name else go 0;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 核心替换（capture-safe，INV-SUBST-2）
  # ══════════════════════════════════════════════════════════════════════════════

  # substitute varName replacementType typeExpr → typeExpr[varName ↦ replacementType]
  # Type: String -> Type -> Type -> Type
  substitute = varName: replacement: t:
    assert isType t;
    let
      fvReplacement = freeVarsRepr replacement.repr;
    in
    _subst varName replacement fvReplacement t;

  _subst = varName: replacement: fvRepl: t:
    let
      repr = t.repr;
      v    = repr.__variant or null;
      goT  = _subst varName replacement fvRepl;  # recurse
    in

    if v == "Var" then
      if repr.name or "_" == varName then replacement else t

    else if v == "Primitive" then t

    else if v == "Lambda" then
      let param = repr.param or "_"; in
      if param == varName then t  # 绑定 shadow：不替换 body
      else if builtins.elem param fvRepl then
        # capture 风险：alpha-rename param
        let
          allFv = fvRepl ++ freeVarsRepr repr;
          fresh = _freshName param allFv;
          freshT = _subst param
            (mkTypeWith { __variant = "Var"; name = fresh; scope = 0; } t.kind t.meta)
            [fresh]  # fvRepl for inner rename (safe: no capture)
            (repr.body or t);
          renamedRepr = repr // { param = fresh; body = freshT; };
          newBody = goT (repr.body or t);
        in
        # rename first, then substitute
        withRepr t (renamedRepr // { body = goT freshT; })
      else
        withRepr t (repr // { body = goT (repr.body or t); })

    else if v == "Pi" then
      let param = repr.param or "_"; in
      let newDomain = goT (repr.domain or t); in
      if param == varName then withRepr t (repr // { domain = newDomain; })
      else if builtins.elem param fvRepl then
        let
          allFv = fvRepl ++ freeVarsRepr repr;
          fresh = _freshName param allFv;
          renamedBody = _subst param
            (mkTypeWith { __variant = "Var"; name = fresh; scope = 0; } t.kind t.meta)
            []
            (repr.body or t);
          newBody = goT renamedBody;
        in
        withRepr t (repr // { param = fresh; domain = newDomain; body = newBody; })
      else
        withRepr t (repr // { domain = newDomain; body = goT (repr.body or t); })

    else if v == "Sigma" then
      let param = repr.param or "_"; in
      let newDomain = goT (repr.domain or t); in
      if param == varName then withRepr t (repr // { domain = newDomain; })
      else if builtins.elem param fvRepl then
        let
          allFv = fvRepl ++ freeVarsRepr repr;
          fresh = _freshName param allFv;
          renamedBody = _subst param
            (mkTypeWith { __variant = "Var"; name = fresh; scope = 0; } t.kind t.meta)
            []
            (repr.body or t);
          newBody = goT renamedBody;
        in
        withRepr t (repr // { param = fresh; domain = newDomain; body = newBody; })
      else
        withRepr t (repr // { domain = newDomain; body = goT (repr.body or t); })

    else if v == "Mu" then
      let var = repr.var or "_"; in
      if var == varName then t  # 绑定 shadow
      else withRepr t (repr // { body = goT (repr.body or t); })

    else if v == "Apply" then
      withRepr t (repr // {
        fn   = goT (repr.fn or t);
        args = map goT (repr.args or []);
      })

    else if v == "Fn" then
      withRepr t (repr // {
        from = goT (repr.from or t);
        to   = goT (repr.to or t);
      })

    else if v == "Constructor" then
      let
        paramNames = map (p: p.name or "_") (repr.params or []);
      in
      if builtins.elem varName paramNames then
        # varName is shadowed by Constructor param
        t
      else
        withRepr t (repr // {
          body = if repr ? body then goT repr.body else null;
        })

    else if v == "ADT" then
      withRepr t (repr // {
        variants = map (var:
          var // { fields = map goT (var.fields or []); }
        ) (repr.variants or []);
      })

    else if v == "Constrained" then
      withRepr t (repr // {
        base        = goT (repr.base or t);
        constraints = _substConstraints varName replacement fvRepl (repr.constraints or []);
      })

    else if v == "Record" then
      withRepr t (repr // {
        fields = builtins.mapAttrs (_: goT) (repr.fields or {});
      })

    else if v == "VariantRow" then
      withRepr t (repr // {
        variants = builtins.mapAttrs (_: goT) (repr.variants or {});
        tail = if repr ? tail then goT repr.tail else null;
      })

    else if v == "RowExtend" then
      withRepr t (repr // {
        fieldType = goT (repr.fieldType or t);
        rest      = goT (repr.rest or t);
      })

    else if v == "Effect" then
      withRepr t (repr // {
        effectRow = goT (repr.effectRow or t);
      })

    else if v == "Ascribe" then
      withRepr t (repr // {
        inner = goT (repr.inner or t);
        ty    = goT (repr.ty or t);
      })

    else t;  # Primitive, RowEmpty, Opaque：无 Var，返回原样

  # ── 约束内替换（INV-C3：完整递归）────────────────────────────────────────────
  _substConstraints = varName: replacement: fvRepl: cs:
    map (c:
      let tag = c.__constraintTag or null; in
      if tag == "Class"     then c // { args = map (_subst varName replacement fvRepl) (c.args or []); }
      else if tag == "Equality" then c // {
        a = _subst varName replacement fvRepl (c.a or c);
        b = _subst varName replacement fvRepl (c.b or c);
      }
      else if tag == "Predicate" then c // {
        arg = _subst varName replacement fvRepl (c.arg or c);
      }
      else c
    ) cs;

  # ══════════════════════════════════════════════════════════════════════════════
  # substituteAll（多变量替换，Phase 3.1：显式稳定排序）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：attrNames 排序不稳定 → 显式 lexicographic 排序
  # Type: AttrSet String Type -> Type -> Type
  substituteAll = subst: t:
    let
      # 稳定排序（INV-SUBST-3）
      vars = lib.sort (a: b: a < b) (builtins.attrNames subst);
    in
    lib.foldl' (acc: varName: substitute varName subst.${varName} acc) t vars;

  # ══════════════════════════════════════════════════════════════════════════════
  # composeSubst（σ₂ ∘ σ₁，正确语义）
  # ══════════════════════════════════════════════════════════════════════════════

  # σ₂ ∘ σ₁：先应用 σ₁，再应用 σ₂
  # 等价于：compose(σ₁, σ₂)(x) = σ₂(σ₁(x))
  # Type: AttrSet -> AttrSet -> AttrSet
  composeSubst = sigma1: sigma2:
    let
      # σ₁ 的值 apply σ₂
      applied = builtins.mapAttrs (_: t: substituteAll sigma2 t) sigma1;
      # σ₂ 中不被 σ₁ 覆盖的额外绑定
      extra = lib.filterAttrs (k: _: !(sigma1 ? ${k})) sigma2;
    in
    applied // extra;

  # 恒等替换
  idSubst = {};

  # 单点替换
  singleSubst = name: t: { ${name} = t; };

  # ══════════════════════════════════════════════════════════════════════════════
  # de Bruijn 序列化辅助（α-equivalence 检查）
  # ══════════════════════════════════════════════════════════════════════════════

  # 将 Type 转换为 de Bruijn 形式（用于 α-equality 比较）
  # Type: Type -> Type（in-place repr transformation）
  deBruijnify = t: _deBruijn {} 0 t;

  _deBruijn = env: depth: t:
    let
      repr = t.repr;
      v    = repr.__variant or null;
      go   = _deBruijn env depth;
    in
    if v == "Var" then
      let
        name = repr.name or "_";
        idx  = env.${name} or null;
      in
      if idx != null
      then withRepr t (repr // { name = "db${builtins.toString (depth - idx - 1)}"; scope = depth - idx - 1; })
      else t  # 自由变量：保留

    else if v == "Lambda" then
      let
        param  = repr.param or "_";
        newEnv = env // { ${param} = depth; };
        newBody = _deBruijn newEnv (depth + 1) (repr.body or t);
      in
      withRepr t (repr // { param = "db${builtins.toString depth}"; body = newBody; })

    else if v == "Pi" || v == "Sigma" then
      let
        param   = repr.param or "_";
        newEnv  = env // { ${param} = depth; };
        newDom  = go (repr.domain or t);
        newBody = _deBruijn newEnv (depth + 1) (repr.body or t);
      in
      withRepr t (repr // { param = "db${builtins.toString depth}"; domain = newDom; body = newBody; })

    else if v == "Mu" then
      let
        var    = repr.var or "_";
        newEnv = env // { ${var} = depth; };
        newBody = _deBruijn newEnv (depth + 1) (repr.body or t);
      in
      withRepr t (repr // { var = "db${builtins.toString depth}"; body = newBody; })

    else if v == "Apply" then
      withRepr t (repr // { fn = go (repr.fn or t); args = map go (repr.args or []); })

    else if v == "Fn" then
      withRepr t (repr // { from = go (repr.from or t); to = go (repr.to or t); })

    else t;

}
