# normalize/rewrite.nix — Phase 4.5.4
# TRS 主引擎（fuel-based，保证终止）
# INV-2:  所有计算 = Rewrite(TypeIR)，fuel 保证终止
# INV-3:  结果 = NormalForm（无可归约子项）
#
# Fix P4.3: _reprKey 改用 serialLib.serializeRepr 而非 builtins.toJSON t.repr
#           避免 repr 内嵌 Type 对象（rLambda.body 等）触发 toJSON 失败
# Fix P4.3b: 废除 _safeToJSON（基于 builtins.tryEval，在部分 Nix 版本无法拦截
#            builtins.toJSON-on-function 的 uncatchable abort）。
#            改用 serialLib._safeStr（isFunction 守卫，必定安全）。
# Fix P4.3c: _constraintKey/predExpr fallback 改用 serializePredExpr + _safeStr
#            确保所有 key 生成路径对函数值安全
# Fix P4.5.4: Updated constraint tag patterns to short form
#   "Equality"  → "Eq"    (also handles legacy "Equality" for compat)
#   "RowEquality" → "RowEq" (also handles legacy "RowEquality" for compat)
{ lib, typeLib, reprLib, kindLib, substLib, rulesLib, serialLib }:

let
  inherit (typeLib) isType mkTypeWith;
  inherit (rulesLib) applyFirstRule allRules;
  inherit (serialLib) serializeRepr serializePredExpr _safeStr;

  # ── repr-only key（P4.3 Fix: serializeRepr — never builtins.toJSON）────
  _reprKey = t:
    if builtins.isFunction t then "<fn>"
    else if builtins.isAttrs t && t ? repr
    then serializeRepr t.repr
    else if builtins.isAttrs t && t ? __variant
    then serializeRepr t
    else _safeStr t;

  # ── 约束结构 key（仅依赖 repr，不触碰 kind/meta/函数字段）────────────────
  _constraintKey = c:
    if builtins.isFunction c then "<fn>"
    else if !builtins.isAttrs c then _safeStr c
    else
      let
        tag = if c ? __constraintTag then c.__constraintTag else "unknown";
      in
      # Phase 4.5.4: short tags, with legacy compat
      if tag == "Eq" || tag == "Equality" then
        let
          lk = _reprKey (if c ? lhs then c.lhs else {});
          rk = _reprKey (if c ? rhs then c.rhs else {});
        in "Eq:${lk}:${rk}"
      else if tag == "Class" then
        let
          cls     = if c ? className then c.className else "?";
          argKeys = lib.concatStringsSep "," (map _reprKey (if c ? args then c.args else []));
        in "Class:${cls}:[${argKeys}]"
      else if tag == "RowEq" || tag == "RowEquality" then
        let
          lk = _reprKey (if c ? lhsRow then c.lhsRow else {});
          rk = _reprKey (if c ? rhsRow then c.rhsRow else {});
        in "RowEq:${lk}:${rk}"
      else if tag == "Refined" then
        let
          subj    = _reprKey (if c ? subject then c.subject else {});
          pvar    = if c ? predVar then c.predVar else "?";
          pexpr   = if c ? predExpr then c.predExpr else { __predTag = "PTrue"; };
          predStr = builtins.hashString "sha256" (serializePredExpr pexpr);
        in "Ref:${subj}:${pvar}:${predStr}"
      else if tag == "Predicate" then
        let
          pname = if c ? predName then c.predName else "?";
          subj  = _reprKey (if c ? subject then c.subject else {});
        in "Pred:${pname}:${subj}"
      else if tag == "Implies" then
        let
          premKeys = lib.concatStringsSep "," (map _constraintKey (if c ? premises then c.premises else []));
          concKey  = _constraintKey (if c ? conclusion then c.conclusion else {});
        in "Impl:[${premKeys}]->${concKey}"
      else if tag == "Scheme" then
        let
          sch       = if c ? scheme then c.scheme else {};
          schemeStr =
            if builtins.isAttrs sch && sch ? forall
            then
              let
                fl   = lib.concatStringsSep "," (if sch ? forall then sch.forall else []);
                body = _reprKey (if sch ? body then sch.body else {});
              in "forall=[${fl}]:${body}"
            else "opaque";
          tyKey = _reprKey (if c ? ty then c.ty else {});
        in "Scheme:${schemeStr}:${tyKey}"
      else if tag == "Kind" then
        let
          tvar = if c ? typeVar then c.typeVar else "?";
          ks   =
            let k = if c ? expectedKind then c.expectedKind else {}; in
            if builtins.isAttrs k && k ? __kindTag then k.__kindTag else "?";
        in "Kind:${tvar}:${ks}"
      else if tag == "Instance" then
        let
          cls     = if c ? className then c.className else "?";
          argKeys = lib.concatStringsSep "," (map _reprKey (if c ? types then c.types else []));
        in "Instance:${cls}:[${argKeys}]"
      else if tag == "Sub" then
        let
          sk = _reprKey (if c ? sub then c.sub else {});
          pk = _reprKey (if c ? sup then c.sup else {});
        in "Sub:${sk}:${pk}"
      else if tag == "HasField" then
        let
          f  = if c ? field then c.field else "?";
          ft = _reprKey (if c ? fieldType then c.fieldType else {});
          rt = _reprKey (if c ? recType then c.recType else {});
        in "HasField:${f}:${ft}:${rt}"
      else
        let attrHash = builtins.hashString "sha256" (lib.concatStringsSep "," (builtins.attrNames c)); in
        "${tag}:${attrHash}";


  DEFAULT_FUEL = 1000;
  DEEP_FUEL    = 3000;

  normalizeWithFuel = fuel: t:
    if fuel <= 0 then t
    else if !isType t then t
    else
      let t1 = _normalizeChildren (fuel - 1) t; in
      let r  = applyFirstRule t1; in
      if r == null then t1
      else normalizeWithFuel (fuel - 1) r.result;

  _normalizeChildren = fuel: t:
    if !isType t || fuel <= 0 then t
    else
      let
        v   = t.repr.__variant or null;
        go  = normalizeWithFuel (fuel - 1);
        goR = f: mkTypeWith f t.kind t.meta;
      in
      if v == "Lambda" then
        goR { __variant = "Lambda"; param = t.repr.param; body = go t.repr.body; }
      else if v == "Apply" then
        goR { __variant = "Apply"; fn = go t.repr.fn; args = map go (t.repr.args or []); }
      else if v == "Fn" then
        goR { __variant = "Fn"; from = go t.repr.from; to = go t.repr.to; }
      else if v == "Constrained" then
        goR { __variant = "Constrained"; base = go t.repr.base; constraints = t.repr.constraints; }
      else if v == "Mu" then
        goR { __variant = "Mu"; var = t.repr.var; body = go t.repr.body; }
      else if v == "Record" then
        goR { __variant = "Record"; fields = builtins.mapAttrs (_: f: go f) t.repr.fields; }
      else if v == "RowExtend" then
        goR { __variant = "RowExtend"; label = t.repr.label; ty = go t.repr.ty; tail = go t.repr.tail; }
      else if v == "VariantRow" then
        let tailVal = t.repr.tail or null; in
        goR { __variant = "VariantRow";
              variants = builtins.mapAttrs (_: vt: go vt) t.repr.variants;
              tail = if tailVal != null then go tailVal else null; }
      else if v == "Effect" then
        goR { __variant = "Effect"; effectRow = go t.repr.effectRow; resultType = go t.repr.resultType; }
      else if v == "EffectMerge" then
        goR { __variant = "EffectMerge"; e1 = go t.repr.e1; e2 = go t.repr.e2; }
      else if v == "Refined" then
        goR { __variant = "Refined"; base = go t.repr.base; predVar = t.repr.predVar; predExpr = t.repr.predExpr; }
      else if v == "Sig" then
        goR { __variant = "Sig"; fields = builtins.mapAttrs (_: f: go f) t.repr.fields; }
      else if v == "Struct" then
        goR { __variant = "Struct"; sig = go t.repr.sig;
              impls = builtins.mapAttrs (_: i: go i) t.repr.impls; }
      else if v == "ModFunctor" then
        goR { __variant = "ModFunctor"; param = t.repr.param;
              paramSig = go t.repr.paramSig; body = go t.repr.body; }
      else if v == "Forall" then
        goR { __variant = "Forall"; vars = t.repr.vars; body = go t.repr.body; }
      else if v == "ForAll" then
        goR { __variant = "ForAll"; name = t.repr.name; kind = t.repr.kind; body = go t.repr.body; }
      else if v == "Pi" then
        goR { __variant = "Pi"; param = t.repr.param;
              paramType = go t.repr.paramType; body = go t.repr.body; }
      else if v == "Sigma" then
        goR { __variant = "Sigma"; param = t.repr.param;
              paramType = go t.repr.paramType; body = go t.repr.body; }
      else t;

  normalize'    = normalizeWithFuel DEFAULT_FUEL;
  normalizeDeep = normalizeWithFuel DEEP_FUEL;

  isNormalForm = t:
    if !isType t then true
    else applyFirstRule t == null;

  normalizeConstraint = c:
    if !builtins.isAttrs c then c
    else
      let tag = c.__constraintTag or null; in
      # Phase 4.5.4: short tags + legacy compat
      if tag == "Eq" || tag == "Equality" then
        let
          lhsN = normalize' c.lhs;
          rhsN = normalize' c.rhs;
          lhsH = builtins.hashString "sha256" (_reprKey lhsN);
          rhsH = builtins.hashString "sha256" (_reprKey rhsN);
        in
        if lhsH <= rhsH then c // { lhs = lhsN; rhs = rhsN; }
        else c // { lhs = rhsN; rhs = lhsN; }
      else if tag == "Class" then
        c // { args = map normalize' c.args; }
      else if tag == "RowEq" || tag == "RowEquality" then
        c // { lhsRow = normalize' c.lhsRow; rhsRow = normalize' c.rhsRow; }
      else if tag == "Refined" then
        c // { subject = normalize' c.subject; }
      else c;

  deduplicateConstraints = cs:
    let
      withKeys = map (c: { k = _constraintKey c; v = c; }) cs;
      uniq = lib.foldl' (acc: x:
        if builtins.elem x.k acc.seen
        then acc
        else { seen = acc.seen ++ [ x.k ]; result = acc.result ++ [ x.v ]; }
      ) { seen = []; result = []; } withKeys;
    in
    uniq.result;
in
{
  inherit
  DEFAULT_FUEL
  DEEP_FUEL
  normalizeWithFuel
  _normalizeChildren
  normalize'
  normalizeDeep
  isNormalForm
  normalizeConstraint
  deduplicateConstraints
  ;
}
