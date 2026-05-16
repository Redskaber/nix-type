# meta/equality.nix — Phase 4.2
# TypeEq via NormalForm：typeEq(a,b) ⟺ serialize(NF(a)) == serialize(NF(b))
# INV-3: 所有比较 = NormalForm Equality
{ lib, hashLib, serialLib }:

let
  inherit (hashLib) typeHash;
  inherit (serialLib) serializeConstraint serializeRepr;


  # ══ 主比较函数（NF-hash equality）════════════════════════════════════
  # Type: Type → Type → Bool
  # 注意：调用者需保证 a, b 均已 normalize（或使用 typeEqN）
  typeEq = a: b:
    if !builtins.isAttrs a || !builtins.isAttrs b then a == b
    else if (a.tag or null) != "Type" || (b.tag or null) != "Type" then false
    else typeHash a == typeHash b;

  # Type: NormalizeLib → Type → Type → Bool
  # 内部先 normalize 再比较（完整版）
  typeEqN = normalizeLib: a: b:
    let
      na = normalizeLib.normalize' a;
      nb = normalizeLib.normalize' b;
    in
    typeEq na nb;

  # ══ Kind Equality ══════════════════════════════════════════════════════
  # 直接委托给 kindLib
  kindEq = a: b:
    if !builtins.isAttrs a || !builtins.isAttrs b then false
    else (a.__kindTag or null) == (b.__kindTag or null) &&
      (if (a.__kindTag or null) == "Arrow"
       then kindEq a.from b.from && kindEq a.to b.to
       else if (a.__kindTag or null) == "Var"
       then a.name == b.name
       else true);

  # ══ Constraint Equality ════════════════════════════════════════════════
  # Type: Constraint → Constraint → Bool
  constraintEq = a: b:
    serializeConstraint a == serializeConstraint b;

  # ══ TypeScheme Equality ════════════════════════════════════════════════
  # Type: TypeScheme → TypeScheme → Bool
  schemeEq = a: b:
    hashLib.schemeHash a == hashLib.schemeHash b;

  # ══ Subtype（结构近似，非完整 subtype）════════════════════════════════
  # 用于 bidir checking 的快速 subsumption
  # 真正的 subtype 需要约束求解
  # Type: Type → Type → Bool
  isSubtype = a: b:
    let
      av = a.repr.__variant or null;
      bv = b.repr.__variant or null;
    in
    if typeEq a b then true
    else if bv == "Dynamic" then true  # Phase 5.0 gradual types
    else if bv == "Forall" then
      # 实例化 b 中的 forall 变量（近似）
      true  # 延迟到 Phase 5.0 完整实现
    else false;

  # ══ Α-等价（变量名不影响）════════════════════════════════════════════
  # 因为 serialize 已经做了 de Bruijn 转换，typeEq 已蕴含 α-等价
  alphaEq = typeEq;
in
{
  inherit
  # ══ 主比较函数（NF-hash equality）════════════════════════════════════
  typeEq
  typeEqN
  # ══ Kind Equality ══════════════════════════════════════════════════════
  kindEq
  # ══ Constraint Equality ════════════════════════════════════════════════
  constraintEq
  # ══ TypeScheme Equality ════════════════════════════════════════════════
  schemeEq
  # ══ Subtype（结构近似，非完整 subtype）════════════════════════════════
  isSubtype
  # ══ Α-等价（变量名不影响）════════════════════════════════════════════
  alphaEq
  ;
}
