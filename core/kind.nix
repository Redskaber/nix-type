# core/kind.nix — Phase 4.2
# Kind 系统：完全内化为 Type（自举），Kind-of-Kind = Kind
# INV-K1: 每个类型参数都有确定的 kind
{ lib }:

rec {
  # ══ Kind Repr 标记（不依赖 typeLib，避免循环）══════════════════════════

  # KindRepr 直接使用 attrset，不包裹在 Type 中（bootstrap 阶段）
  KStar   = { __kindTag = "Star";   };
  KRow    = { __kindTag = "Row";    };
  KEffect = { __kindTag = "Effect"; };
  KUnbound = { __kindTag = "Unbound"; name = "?"; };

  # KArrow: Kind → Kind（类型构造器 kind）
  KArrow = from: to: { __kindTag = "Arrow"; from = from; to = to; };

  # KVar: kind 变量（Phase 4.2: kind-level inference）
  KVar = name: { __kindTag = "Var"; name = name; };

  # ══ Kind 谓词 ══════════════════════════════════════════════════════════
  isKind    = k: builtins.isAttrs k && k ? __kindTag;
  isStar    = k: isKind k && k.__kindTag == "Star";
  isKArrow  = k: isKind k && k.__kindTag == "Arrow";
  isKRow    = k: isKind k && k.__kindTag == "Row";
  isKEffect = k: isKind k && k.__kindTag == "Effect";
  isKVar    = k: isKind k && k.__kindTag == "Var";
  isKUnbound = k: isKind k && k.__kindTag == "Unbound";

  # ══ Kind 序列化（canonical，用于 hash）════════════════════════════════
  serializeKind = k:
    if !isKind k then "?"
    else if isStar k    then "*"
    else if isKRow k    then "Row"
    else if isKEffect k then "Effect"
    else if isKVar k    then "(KVar ${k.name})"
    else if isKUnbound k then "Unbound"
    else if isKArrow k  then "(${serializeKind k.from} → ${serializeKind k.to})"
    else "?";

  # ══ Kind Equality ══════════════════════════════════════════════════════
  kindEq = a: b:
    if !isKind a || !isKind b then false
    else if a.__kindTag != b.__kindTag then false
    else if isStar a then true
    else if isKRow a then true
    else if isKEffect a then true
    else if isKVar a then a.name == b.name
    else if isKUnbound a then true
    else if isKArrow a then (kindEq a.from b.from) && (kindEq a.to b.to)
    else false;

  # ══ Kind Arity（类型构造器参数数量）══════════════════════════════════
  kindArity = k:
    if isKArrow k then 1 + kindArity k.to
    else 0;

  # ══ Kind Application（应用后的结果 kind）══════════════════════════════
  # Type: Kind → Kind → Kind | null
  applyKind = fnKind: argKind:
    if isKArrow fnKind then
      if kindEq fnKind.from argKind then fnKind.to
      else null  # kind mismatch
    else null;

  # ══ Kind Substitution（Phase 4.2: kind-level unification support）══════
  # Type: AttrSet(name → Kind) → Kind → Kind
  applyKindSubst = ksubst: k:
    if !isKind k then k
    else if isKVar k then
      let bound = ksubst.${k.name} or null; in
      if bound != null then bound else k
    else if isKArrow k then
      KArrow (applyKindSubst ksubst k.from) (applyKindSubst ksubst k.to)
    else k;

  # ══ Kind Unification（phase 4.2: HM kind inference）══════════════════
  # Type: Kind → Kind → { ok: Bool; subst: AttrSet } | { ok: false; error }
  unifyKind = a: b:
    if kindEq a b then { ok = true; subst = {}; }
    else if isKVar a then
      { ok = true; subst = { ${a.name} = b; }; }
    else if isKVar b then
      { ok = true; subst = { ${b.name} = a; }; }
    else if isKArrow a && isKArrow b then
      let r1 = unifyKind a.from b.from; in
      if !r1.ok then r1
      else
        let
          a2 = applyKindSubst r1.subst a.to;
          b2 = applyKindSubst r1.subst b.to;
          r2 = unifyKind a2 b2;
        in
        if !r2.ok then r2
        else { ok = true; subst = r1.subst // r2.subst; }
    else { ok = false; error = "kind mismatch: ${serializeKind a} vs ${serializeKind b}"; };

  # ══ Built-in Type Kind Annotations ════════════════════════════════════
  # defaultKinds: 内建类型的 kind
  defaultKinds = {
    "Int"    = KStar;
    "Bool"   = KStar;
    "String" = KStar;
    "Float"  = KStar;
    "Unit"   = KStar;
    "List"   = KArrow KStar KStar;
    "Maybe"  = KArrow KStar KStar;
    "Either" = KArrow KStar (KArrow KStar KStar);
    "Map"    = KArrow KStar (KArrow KStar KStar);
    "IO"     = KArrow KStar KStar;
  };
}
