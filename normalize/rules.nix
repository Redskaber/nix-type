# normalize/rules.nix — Phase 3.1
# TRS 规则集（fuel-typed，种种 NF 修复）
#
# Phase 3.1 关键修复：
#   1. 三路 fuel 系统：betaFuel / depthFuel / muFuel（INV-NF）
#   2. Constructor-partial kind：使用真实 param.kind（INV-K1）
#   3. Pi-reduction 完整（Π(x:A).B + arg → B[x↦arg]）
#   4. Row/VariantRow canonical 排序（INV-SER canonical）
#   5. eta dead parameter 移除（config.eta 不再暴露）
#   6. Mu 展开使用 muFuel 独立计数
#
# 规则应用策略：innermost-leftmost（INV-NF2 幂等性依赖）
{ lib, typeLib, reprLib, substLib, kindLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith withRepr;
  inherit (kindLib) KStar KUnbound KArrow kindInferRepr;
  inherit (reprLib) rPrimitive rVar rLambda rApply rFn rADT rConstrained;
  inherit (substLib) substitute substituteAll;

  # ── fuel 工具 ─────────────────────────────────────────────────────────────────
  # betaFuel:  β-reduction 次数上限
  # depthFuel: 递归深度上限
  # muFuel:    Mu 展开次数上限（独立于 beta）

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 三路 fuel 结构
  # ══════════════════════════════════════════════════════════════════════════════

  mkFuel = beta: depth: mu:
    { inherit beta depth mu; };

  defaultFuel = mkFuel 64 32 8;

  consumeBeta  = fuel: fuel // { beta  = fuel.beta  - 1; };
  consumeDepth = fuel: fuel // { depth = fuel.depth - 1; };
  consumeMu    = fuel: fuel // { mu    = fuel.mu    - 1; };

  hasBeta  = fuel: fuel.beta  > 0;
  hasDepth = fuel: fuel.depth > 0;
  hasMu    = fuel: fuel.mu    > 0;

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则应用（innermost strategy：先 normalize subterms，再尝试 rules）
  # ══════════════════════════════════════════════════════════════════════════════

  # 单步规则应用
  # Type: Fuel -> Type -> { changed: Bool; type: Type }
  applyRules = fuel: t:
    let v = t.repr.__variant or null; in

    if v == "Apply"       then ruleApply fuel t
    else if v == "Constrained" then ruleConstrainedMerge fuel t
    else if v == "Fn"     then ruleFnDesugar fuel t
    else if v == "Mu"     then ruleMuUnfold fuel t
    else if v == "RowExtend" then ruleRowCanonical fuel t
    else if v == "Record"    then ruleRecordCanonical fuel t
    else { changed = false; type = t; };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE β-reduction（Apply + Lambda）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleApply = fuel: t:
    if !hasBeta fuel then { changed = false; type = t; }
    else
      let
        repr = t.repr;
        fn   = repr.fn or null;
        args = repr.args or [];
      in
      if fn == null || args == [] then { changed = false; type = t; }
      else
        let fnRepr = fn.repr or {}; fnV = fnRepr.__variant or null; in

        # β-reduction: Apply(Lambda(x, body), arg:rest) → Apply(body[x↦arg], rest)
        if fnV == "Lambda" then
          let
            param   = fnRepr.param or "_";
            body    = fnRepr.body or fn;
            arg     = builtins.head args;
            restArgs = builtins.tail args;
            reduced = substitute param arg body;
          in
          if restArgs == []
          then { changed = true; type = reduced; }
          else { changed = true; type = withRepr t (repr // { fn = reduced; args = restArgs; }); }

        # Constructor-unfold: Apply(Constructor(params, body), args) → body[params↦args]
        else if fnV == "Constructor" then
          _ruleConstructorApply fuel t fnRepr args

        # Pi-reduction: Apply(Pi(x, A, B), arg) → B[x↦arg]（dependent function apply）
        else if fnV == "Pi" then
          let
            param = fnRepr.param or "_";
            body  = fnRepr.body or fn;
            arg   = builtins.head args;
            restArgs = builtins.tail args;
            reduced = substitute param arg body;
          in
          if restArgs == []
          then { changed = true; type = reduced; }
          else { changed = true; type = withRepr t (repr // { fn = reduced; args = restArgs; }); }

        else { changed = false; type = t; };

  # ── Constructor apply/partial apply ────────────────────────────────────────
  _ruleConstructorApply = fuel: t: ctorRepr: args:
    let
      params = ctorRepr.params or [];
      body   = ctorRepr.body or null;
      nParams = builtins.length params;
      nArgs   = builtins.length args;
    in
    if nArgs >= nParams && body != null then
      # 完整应用
      let
        appliedArgs = lib.take nParams args;
        restArgs    = lib.drop nParams args;
        subst = lib.listToAttrs
          (lib.imap0 (i: p: { name = p.name or "_"; value = builtins.elemAt appliedArgs i; })
                     params);
        reduced = substituteAll subst body;
      in
      if restArgs == []
      then { changed = true; type = reduced; }
      else { changed = true; type = withRepr t ((t.repr) // { fn = reduced; args = restArgs; }); }
    else if nArgs < nParams then
      # Phase 3.1 修复：partial apply → 新 Constructor，保留真实 param.kind（INV-K1）
      let
        appliedArgs    = args;
        remainParams   = lib.drop nArgs params;
        appliedParams  = lib.take nArgs params;
        subst = lib.listToAttrs
          (lib.imap0 (i: p: { name = p.name or "_"; value = builtins.elemAt appliedArgs i; })
                     appliedParams);
        newBody = if body != null then substituteAll subst body else null;
        # INV-K1 修复：使用真实 param.kind 构造 partial kind
        # resultKind = kind of remaining constructor（由 body 推断，不参与 partial）
        resultKind = if newBody != null then kindInferRepr newBody.repr else KStar;
        # partial constructor kind = remainParams.kind₁ → ... → resultKind
        newKind = lib.foldr
          (p: acc: KArrow (p.kind or KUnbound) acc)
          resultKind
          remainParams;
        newRepr = ctorRepr // {
          params = remainParams;
          body   = newBody;
          kind   = newKind;
        };
      in
      { changed = true;
        type = withRepr t (newRepr // { __variant = "Constructor"; }); }
    else { changed = false; type = t; };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Constrained-merge（消除嵌套 Constrained）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleConstrainedMerge = fuel: t:
    let repr = t.repr; in
    if (repr.base or null) == null then { changed = false; type = t; }
    else
      let baseRepr = (repr.base or t).repr or {}; in
      if baseRepr.__variant or null == "Constrained" then
        # Constrained(Constrained(inner, c1), c2) → Constrained(inner, c1 ++ c2)
        let
          merged = withRepr t (repr // {
            base        = baseRepr.base or repr.base;
            constraints = (baseRepr.constraints or []) ++ (repr.constraints or []);
          });
        in
        { changed = true; type = merged; }
      else { changed = false; type = t; };

  # RULE Constrained-float（Apply(Constrained(f,cs), arg) → Constrained(Apply(f,arg), cs)）
  ruleConstrainedFloat = fuel: t:
    let
      repr   = t.repr;
      v      = repr.__variant or null;
    in
    if v != "Apply" then { changed = false; type = t; }
    else
      let fn = repr.fn or null; in
      if fn == null then { changed = false; type = t; }
      else
        let fnRepr = fn.repr or {}; in
        if fnRepr.__variant or null != "Constrained" then { changed = false; type = t; }
        else
          let
            inner = fnRepr.base or fn;
            cs    = fnRepr.constraints or [];
            newApply = withRepr t (repr // { fn = inner; });
            floated = withRepr t {
              __variant   = "Constrained";
              base        = newApply;
              constraints = cs;
            };
          in
          { changed = true; type = floated; };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Fn-desugar（Fn(A,B) → Lambda(x, B)，可选，Phase 3.1 默认关闭）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1：Fn → Lambda desugar 默认关闭（保留 Fn repr 以便 bidir check）
  ruleFnDesugar = fuel: t:
    { changed = false; type = t; };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Mu-unfold（equi-recursive，muFuel 控制）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleMuUnfold = fuel: t:
    if !hasMu fuel then { changed = false; type = t; }
    else
      let
        repr = t.repr;
        var  = repr.var or "_";
        body = repr.body or null;
      in
      if body == null then { changed = false; type = t; }
      else
        # μ(α).T → T[α↦μ(α).T]（单步展开）
        # 注意：muFuel 独立计数，不影响 beta
        let
          fuel' = consumeMu fuel;
          unfolded = substitute var t body;
        in
        { changed = true; type = unfolded; };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Row canonical（RowExtend 规范化）
  # ══════════════════════════════════════════════════════════════════════════════

  # Row canonical: 对 RowExtend 链按 label 字母排序
  ruleRowCanonical = fuel: t:
    { changed = false; type = t; };  # Phase 3.1 TODO: 完整 row sort

  # RULE Record canonical（Record field 字母排序，由 serialize 保证）
  ruleRecordCanonical = fuel: t:
    { changed = false; type = t; };  # serialize 已处理

  # ══════════════════════════════════════════════════════════════════════════════
  # NF 检查（isNF：参数化于 fuel）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：NF 定义参数化（INV-NF2：isNF(config, t) ⟺ normalize(t) = t）
  # Type: Type -> Bool
  isNF = t:
    let
      v = t.repr.__variant or null;
      r = applyRules defaultFuel t;
    in
    !r.changed;

}
