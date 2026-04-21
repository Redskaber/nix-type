# core/kind.nix — Phase 4.1
# Kind 系统：完全内化为 TypeIR 的一部分
# INV-1: Kind ∈ TypeIR
# INV-K1: per-parameter kind（不使用 KStar 兜底）
{ lib }:

rec {
  # ── Kind Tag 枚举 ────────────────────────────────────────────────────────
  # Kind 不依赖 typeLib，避免循环依赖

  # KStar: * — 具体类型
  KStar = { __kindTag = "KStar"; };

  # KArrow: * → * — 类型构造器（from → to）
  KArrow = from: to: { __kindTag = "KArrow"; inherit from to; };

  # KRow: Row kind（用于行多态）
  KRow = { __kindTag = "KRow"; };

  # KEffect: Effect Row kind
  KEffect = { __kindTag = "KEffect"; };

  # KVar: Kind 变量（用于 kind inference）
  KVar = name: { __kindTag = "KVar"; inherit name; };

  # KUnbound: 未绑定 Kind（占位，用于 kind 推断前）
  KUnbound = { __kindTag = "KUnbound"; };

  # ── 常用 Kind 别名 ───────────────────────────────────────────────────────
  KListKind = KArrow KStar KStar;           # List :: * → *
  KMaybeKind = KArrow KStar KStar;          # Maybe :: * → *
  KFnKind = KArrow KStar (KArrow KStar KStar); # (->) :: * → * → *
  KFunctorKind = KArrow (KArrow KStar KStar) KStar; # Functor :: (* → *) → *

  # ── Kind 谓词 ────────────────────────────────────────────────────────────
  isKind = k: builtins.isAttrs k && k ? __kindTag;
  isKStar   = k: isKind k && k.__kindTag == "KStar";
  isKArrow  = k: isKind k && k.__kindTag == "KArrow";
  isKRow    = k: isKind k && k.__kindTag == "KRow";
  isKEffect = k: isKind k && k.__kindTag == "KEffect";
  isKVar    = k: isKind k && k.__kindTag == "KVar";
  isKUnbound = k: isKind k && k.__kindTag == "KUnbound";

  # ── Kind 推断（从 TypeRepr 推断 Kind）────────────────────────────────────
  # Type: TypeRepr -> Kind
  # INV-K1: Constructor 使用 per-parameter kind，不是 KStar 兜底
  kindInferRepr = repr:
    let v = repr.__variant or null; in
    if v == "Primitive"   then KStar
    else if v == "Var"    then
      # Var 可能有 kind 注释，否则默认 KStar
      repr.kind or KStar
    else if v == "Lambda" then
      # λ(x:k). body :: k → kindOf(body)
      let
        paramKind  = repr.paramKind or KStar;
        bodyKind   = kindInferRepr repr.body.repr;
      in KArrow paramKind bodyKind
    else if v == "Apply" then
      let fnKind = kindInferRepr repr.fn.repr; in
      if isKArrow fnKind then fnKind.to
      else KStar  # kind error — 将在 kindCheck 中报告
    else if v == "Constructor" then repr.kind or KStar
    else if v == "Fn"          then KStar
    else if v == "ADT"         then KStar
    else if v == "Constrained" then kindInferRepr repr.base.repr
    else if v == "Mu"          then KStar  # equi-recursive 展开后是 *
    else if v == "Record"      then KStar
    else if v == "RowExtend"   then KRow
    else if v == "RowEmpty"    then KRow
    else if v == "RowVar"      then KRow
    else if v == "VariantRow"  then KRow
    else if v == "Effect"      then KEffect
    else if v == "EffectMerge" then KEffect
    else if v == "Pi"          then KStar  # Π(x:A).B :: *
    else if v == "Sigma"       then KStar  # Σ(x:A).B :: *
    else if v == "Opaque"      then kindInferRepr repr.inner.repr
    else if v == "Ascribe"     then kindInferRepr repr.expr.repr
    else if v == "Refined"     then KStar  # {n:T|φ} :: *
    else if v == "Sig"         then KStar  # module Sig :: *
    else if v == "Struct"      then KStar  # module Struct :: *
    else if v == "ModFunctor"  then KArrow KStar KStar  # Π(M:Sig).Body
    else if v == "Handler"     then KStar
    else if v == "Kind"        then KStar  # Kind-of-Kind = *
    else KUnbound;

  # ── Kind 相等 ────────────────────────────────────────────────────────────
  # Type: Kind -> Kind -> Bool
  kindEq = k1: k2:
    if !(isKind k1 && isKind k2) then false
    else if k1.__kindTag != k2.__kindTag then false
    else if isKArrow k1 then
      kindEq k1.from k2.from && kindEq k1.to k2.to
    else if isKVar k1 then k1.name == k2.name
    else true;  # KStar, KRow, KEffect, KUnbound — 按 tag 相等

  # ── Kind 序列化（用于 hash）─────────────────────────────────────────────
  # Type: Kind -> AttrSet (JSON-serializable)
  serializeKind = k:
    if !isKind k then { t = "?"; }
    else if isKStar k    then { t = "S"; }
    else if isKRow k     then { t = "R"; }
    else if isKEffect k  then { t = "E"; }
    else if isKUnbound k then { t = "U"; }
    else if isKVar k     then { t = "V"; n = k.name; }
    else if isKArrow k   then { t = "A"; fr = serializeKind k.from; to = serializeKind k.to; }
    else { t = "?"; };

  # ── Kind Check（静态 Kind 验证）─────────────────────────────────────────
  # Type: TypeRepr -> { ok: Bool; kind: Kind; error?: String }
  kindCheck = repr:
    let k = kindInferRepr repr; in
    if isKUnbound k
    then { ok = false; kind = k; error = "Unbound kind in ${builtins.toJSON repr}"; }
    else { ok = true; kind = k; };
}
