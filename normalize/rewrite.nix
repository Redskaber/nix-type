# normalize/rewrite.nix — Phase 3.1
# TRS 主引擎（统一 normalize，split fuel，confluence-by-construction）
#
# Phase 3.1 关键修复：
#   1. split fuel：betaFuel / depthFuel / muFuel 独立（INV-NF）
#   2. 单一 normalize 入口（消除三系统并存，INV-H2 依赖）
#   3. closure-based normalization：subterms → rule → subterms（fixpoint）
#   4. NF deep check 参数化（INV-NF2）
#   5. step 策略：innermost（先 subterms，再 top-level rule）
#
# 不变量：
#   INV-NF1: normalize(t) ∈ NormalForm（rule closure 完整）
#   INV-NF2: normalize(normalize(t)) = normalize(t)（幂等性）
#   INV-H2:  typeHash = nfHash ∘ normalize（调用此入口）
{ lib, typeLib, reprLib, rulesLib }:

let
  inherit (typeLib) isType withRepr;
  inherit (rulesLib)
    applyRules defaultFuel
    consumeDepth consumeBeta consumeMu
    hasBeta hasDepth hasMu
    isNF;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 主入口（INV-H2 依赖的唯一 normalize 路径）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Type
  normalize = t:
    normalize' defaultFuel t;

  # 带 custom fuel
  # Type: Fuel -> Type -> Type
  normalize' = fuel: t:
    assert isType t;
    if !hasDepth fuel then t  # 强制终止
    else _normalizeStep fuel t;

  # ══════════════════════════════════════════════════════════════════════════════
  # Innermost normalization step（closure-based）
  # ══════════════════════════════════════════════════════════════════════════════

  # Step 1: normalize subterms（innermost strategy）
  # Step 2: apply top-level rules
  # Step 3: if changed, repeat（fixpoint）
  _normalizeStep = fuel: t:
    let
      # Step 1: normalize all subterms
      t' = _normalizeSubterms (consumeDepth fuel) t;
      # Step 2: apply top-level rule
      r  = applyRules fuel t';
    in
    if !r.changed
    then t'   # NF: no rule applied
    else
      # changed: recurse with reduced fuel
      let fuel' = consumeBeta (consumeDepth fuel); in
      if !hasBeta fuel' || !hasDepth fuel'
      then r.type  # fuel exhausted: return best effort
      else _normalizeStep fuel' r.type;

  # ══════════════════════════════════════════════════════════════════════════════
  # Subterm normalization（by variant，fuel-aware）
  # ══════════════════════════════════════════════════════════════════════════════

  _normalizeSubterms = fuel: t:
    if !hasDepth fuel then t
    else
      let
        repr = t.repr;
        v    = repr.__variant or null;
        goT  = normalize' fuel;
        goTl = map goT;
      in

      if v == "Primitive" || v == "Var" || v == "RowEmpty" || v == "Opaque"
      then t  # leaf: no subterms

      else if v == "Lambda" then
        withRepr t (repr // { body = goT (repr.body or t); })

      else if v == "Pi" || v == "Sigma" then
        withRepr t (repr // {
          domain = goT (repr.domain or t);
          body   = goT (repr.body or t);
        })

      else if v == "Apply" then
        withRepr t (repr // {
          fn   = goT (repr.fn or t);
          args = goTl (repr.args or []);
        })

      else if v == "Fn" then
        withRepr t (repr // {
          from = goT (repr.from or t);
          to   = goT (repr.to or t);
        })

      else if v == "Constructor" then
        withRepr t (repr // {
          body = if repr ? body then goT repr.body else null;
        })

      else if v == "ADT" then
        withRepr t (repr // {
          variants = map (var:
            var // { fields = goTl (var.fields or []); }
          ) (repr.variants or []);
        })

      else if v == "Constrained" then
        withRepr t (repr // {
          base = goT (repr.base or t);
          # constraints 内部 Type 也需要 normalize
          constraints = map (_normalizeConstraint fuel) (repr.constraints or []);
        })

      else if v == "Mu" then
        # Mu body：depthFuel 控制，不展开（展开由 rulesLib.ruleMuUnfold 处理）
        withRepr t (repr // { body = goT (repr.body or t); })

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

      else t;  # unknown: no subterms

  # Constraint 内部 Type normalize
  _normalizeConstraint = fuel: c:
    let
      goT = normalize' fuel;
      tag = c.__constraintTag or null;
    in
    if tag == "Class"     then c // { args = map goT (c.args or []); }
    else if tag == "Equality" then c // { a = goT (c.a or c); b = goT (c.b or c); }
    else if tag == "Predicate" then c // { arg = if c ? arg then goT c.arg else null; }
    else c;

  # ══════════════════════════════════════════════════════════════════════════════
  # normalize 不动点验证（调试/测试用）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Bool（INV-NF2 验证）
  isNormalForm = t:
    let t' = normalize t; in
    t'.id == t.id || isNF t;

  # ══════════════════════════════════════════════════════════════════════════════
  # 便捷入口
  # ══════════════════════════════════════════════════════════════════════════════

  # normalize 并返回 NF repr 序列化（用于 hash）
  normalizeAndSerialize = serialLib: t:
    let nf = normalize t; in
    serialLib.serializeReprAlphaCanonical nf.repr;

}
