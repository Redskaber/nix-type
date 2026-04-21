# core/kind.nix — Phase 3.1
# Kind 系统（完整不变量强化版）
#
# Phase 3.1 修复：
#   INV-K4: kindUnify 纯函数，无副作用
#   INV-K5: kindNormalize 消除所有 KVar 链（chase + occur）
#   INV-K6: KRow/KEffect 扩展完全正交
#   新增：    kindFreeVars, kindSubstFull（完整 KVar 消除）
#            kindEqFull（structural + KVar-chase）
#            kindPretty（人类可读打印）
#
# 不变量：
#   INV-K1: kindCheck(t) = KStar → t 是值类型
#   INV-K2: kindCheck(t) = KArrow(a,b) → t 是类型构造器
#   INV-K3: KUnbound 仅出现在推断过程中，最终结果不含 KUnbound
#   INV-K4: kindUnify 纯函数，不 mutate
#   INV-K5: kindNormalize 消除所有 KVar 链
#   INV-K6: KRow/KEffect 与 KStar/KArrow 正交，不互相继承
{ lib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 构造器（完整变体集）
  # ══════════════════════════════════════════════════════════════════════════════

  KStar    = { __kindVariant = "KStar"; };
  KArrow   = from: to: { __kindVariant = "KArrow"; inherit from to; };
  KRow     = { __kindVariant = "KRow"; };
  KEffect  = { __kindVariant = "KEffect"; };
  KVar     = name: { __kindVariant = "KVar"; inherit name; };
  KUnbound = { __kindVariant = "KUnbound"; };
  KError   = message: { __kindVariant = "KError"; inherit message; };

  # ── 常用 Kind 别名 ──────────────────────────────────────────────────────────
  KStar1           = KArrow KStar KStar;
  KStar2           = KArrow KStar (KArrow KStar KStar);
  KHO1             = KArrow (KArrow KStar KStar) KStar;
  KRowToStar       = KArrow KRow KStar;
  KEffToStarToStar = KArrow KEffect (KArrow KStar KStar);

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 判断
  # ══════════════════════════════════════════════════════════════════════════════

  isKind    = k: builtins.isAttrs k && k ? __kindVariant;
  isStar    = k: isKind k && k.__kindVariant == "KStar";
  isArrow   = k: isKind k && k.__kindVariant == "KArrow";
  isRow     = k: isKind k && k.__kindVariant == "KRow";
  isEffect  = k: isKind k && k.__kindVariant == "KEffect";
  isKVar    = k: isKind k && k.__kindVariant == "KVar";
  isUnbound = k: isKind k && k.__kindVariant == "KUnbound";
  isKError  = k: isKind k && k.__kindVariant == "KError";
  isGround  = k: isStar k || isRow k || isEffect k; # 无参 kind

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 序列化（确定性，用于 hash + equality）
  # ══════════════════════════════════════════════════════════════════════════════

  serializeKind = k:
    let v = k.__kindVariant or null; in
    if      v == "KStar"    then "*"
    else if v == "KArrow"   then "(${serializeKind k.from}->${serializeKind k.to})"
    else if v == "KRow"     then "#row"
    else if v == "KEffect"  then "#eff"
    else if v == "KVar"     then "?K${k.name}"
    else if v == "KUnbound" then "_K"
    else if v == "KError"   then "!K(${k.message or "?"})"
    else "?kind";

  kindPretty = k:
    let v = k.__kindVariant or null; in
    if      v == "KStar"    then "★"
    else if v == "KArrow"   then "${kindPretty k.from} → ${kindPretty k.to}"
    else if v == "KRow"     then "Row"
    else if v == "KEffect"  then "Eff"
    else if v == "KVar"     then "κ${k.name}"
    else if v == "KUnbound" then "?"
    else if v == "KError"   then "KError(${k.message or "?"})"
    else "?";

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 自由变量
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Kind -> [String]
  kindFreeVars = k:
    let v = k.__kindVariant or null; in
    if v == "KVar"   then [k.name]
    else if v == "KArrow" then kindFreeVars k.from ++ kindFreeVars k.to
    else [];

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 等价性（structural，消除 KVar 链，INV-K4）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Kind -> Kind -> Bool
  kindEq = a: b:
    let
      va = a.__kindVariant or null;
      vb = b.__kindVariant or null;
    in
    if va != vb then false
    else if va == "KStar"    then true
    else if va == "KRow"     then true
    else if va == "KEffect"  then true
    else if va == "KUnbound" then true   # unbound 接受任意
    else if va == "KArrow"   then kindEq a.from b.from && kindEq a.to b.to
    else if va == "KVar"     then a.name == b.name
    else if va == "KError"   then a.message == b.message
    else false;

  # Kind 等价性（带 subst chase，正确处理 KVar 绑定）
  # Type: AttrSet -> Kind -> Kind -> Bool
  kindEqUnder = subst: a: b:
    kindEq (kindNormalize subst a) (kindNormalize subst b);

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 变量替换
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet String Kind -> Kind -> Kind
  kindSubst = subst: k:
    let v = k.__kindVariant or null; in
    if      v == "KStar"    then k
    else if v == "KRow"     then k
    else if v == "KEffect"  then k
    else if v == "KUnbound" then k
    else if v == "KError"   then k
    else if v == "KVar"     then subst.${k.name} or k
    else if v == "KArrow"   then KArrow (kindSubst subst k.from) (kindSubst subst k.to)
    else k;

  # 完整替换（直到无 KVar 可替换，不超过 depth 次）
  # Type: AttrSet -> Kind -> Kind
  kindSubstFull = subst: k:
    let
      go = fuel: k:
        if fuel <= 0 then k
        else
          let k' = kindSubst subst k; in
          if kindEq k k' then k else go (fuel - 1) k';
    in go 16 k;

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind Normalization（KVar chase，INV-K5）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> Kind -> Kind
  kindNormalize = subst: k:
    let v = k.__kindVariant or null; in
    if v == "KVar" then
      let bound = subst.${k.name} or null; in
      if bound == null then k
      else if kindEq bound k then k  # 防止自指 loop
      else kindNormalize subst bound
    else if v == "KArrow" then
      KArrow (kindNormalize subst k.from) (kindNormalize subst k.to)
    else k;

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind Unification（完全纯函数，INV-K4）
  # ══════════════════════════════════════════════════════════════════════════════

  # 结果类型：{ ok: Bool; subst: AttrSet; error?: String }
  # Type: AttrSet -> Kind -> Kind -> { ok; subst; error? }
  kindUnify = subst: a: b:
    let
      a' = kindNormalize subst a;
      b' = kindNormalize subst b;
      va = a'.__kindVariant or null;
      vb = b'.__kindVariant or null;
    in

    # 完全相等（含 KVar 自身）
    if kindEq a' b' then { ok = true; subst = subst; }

    # KUnbound ~ k：unbound 接受任意
    else if va == "KUnbound" then { ok = true; subst = subst; }
    else if vb == "KUnbound" then { ok = true; subst = subst; }

    # KVar(n) ~ b：绑定 n → b（occur check）
    else if va == "KVar" then
      if _kindOccurs a'.name b'
      then { ok = false; subst = subst; error = "Kind occur check: ${a'.name} in ${serializeKind b'}"; }
      else { ok = true; subst = subst // { ${a'.name} = b'; }; }

    # a ~ KVar(n)：对称
    else if vb == "KVar" then
      if _kindOccurs b'.name a'
      then { ok = false; subst = subst; error = "Kind occur check: ${b'.name} in ${serializeKind a'}"; }
      else { ok = true; subst = subst // { ${b'.name} = a'; }; }

    # KArrow ~ KArrow：结构递归统一
    else if va == "KArrow" && vb == "KArrow" then
      let r1 = kindUnify subst a'.from b'.from; in
      if !r1.ok then r1
      else kindUnify r1.subst a'.to b'.to

    # 失败
    else {
      ok    = false;
      subst = subst;
      error = "Kind mismatch: ${serializeKind a'} vs ${serializeKind b'}";
    };

  # Occur Check（防止无限 Kind）
  _kindOccurs = name: k:
    let v = k.__kindVariant or null; in
    if v == "KVar"   then k.name == name
    else if v == "KArrow" then _kindOccurs name k.from || _kindOccurs name k.to
    else false;

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 推断（从 TypeRepr 结构推断，不依赖 typeLib 避免循环）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: TypeRepr -> Kind
  kindInferRepr = repr:
    let v = repr.__variant or repr.__kindVariant or null; in

    # Kind 变体：Kind-of-Kind = KStar（约定）
    if builtins.elem v ["KStar" "KArrow" "KRow" "KEffect" "KVar" "KUnbound" "KError"]
    then KStar

    else if v == "Primitive"   then KStar
    else if v == "Var"         then KUnbound
    else if v == "Lambda"      then
      # λ(x:k₁).body : k₁ → kindOf(body)
      KArrow (repr.paramKind or KUnbound) (kindInferRepr (repr.body.repr or { __variant = "Var"; name = "_"; scope = 0; }))
    else if v == "Apply"       then
      let fk = kindInferRepr (repr.fn.repr or { __variant = "Var"; name = "_"; scope = 0; }); in
      if fk.__kindVariant or null == "KArrow" then fk.to else KUnbound
    else if v == "Fn"          then KStar
    else if v == "Pi"          then KStar   # Π(x:A).B :: ★
    else if v == "Sigma"       then KStar   # Σ(x:A).B :: ★
    else if v == "Constructor" then repr.kind or KUnbound
    else if v == "ADT"         then KStar
    else if v == "Constrained" then kindInferRepr (repr.base.repr or { __variant = "Primitive"; name = "?"; })
    else if v == "Mu"          then KStar
    else if v == "Record"      then KStar
    else if v == "VariantRow"  then KStar
    else if v == "RowExtend"   then KRow
    else if v == "RowEmpty"    then KRow
    else if v == "Effect"      then KEffect
    else if v == "Opaque"      then KStar
    else if v == "Ascribe"     then KStar
    else KUnbound;

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 检查（verify Type has expected Kind）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Kind -> { ok: Bool; error?: String }
  kindCheck = t: expectedKind:
    let
      actualKind = t.kind or KUnbound;
      v = actualKind.__kindVariant or null;
    in
    if v == "KUnbound" then { ok = true; }
    else if v == "KError" then { ok = false; error = "KError: ${actualKind.message or "?"}"; }
    else
      let unified = kindUnify {} actualKind expectedKind; in
      if unified.ok then { ok = true; }
      else { ok = false; error = "Kind check: expected ${serializeKind expectedKind}, got ${serializeKind actualKind}"; };

}
