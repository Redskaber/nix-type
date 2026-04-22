# meta/hash.nix — Phase 4.2
# Canonical hash：Hash(serialize(NormalForm(t)))
# INV-4: typeEq(a,b) ⟹ typeHash(a) == typeHash(b)
{ lib, serialLib }:

let
  inherit (serialLib) serializeType serializeRepr canonicalHash canonicalHashRepr;

in rec {

  # ══ 主 hash 函数（通过 NF）════════════════════════════════════════════
  # Type: NormalizedType → String
  # 注意：调用者负责先 normalize，hash 不做 normalize（避免循环）
  typeHash = t:
    if !builtins.isAttrs t || (t.tag or null) != "Type"
    then builtins.hashString "sha256" (builtins.toJSON t)
    else canonicalHash t;

  # Type: TypeRepr → String（repr 级别 hash）
  reprHash = r: canonicalHashRepr r;

  # ══ Constraint hash（用于去重）════════════════════════════════════════
  constraintHash = c:
    builtins.hashString "sha256" (serialLib.serializeConstraint c);

  # ══ TypeScheme hash ════════════════════════════════════════════════════
  schemeHash = s:
    if !builtins.isAttrs s || (s.__schemeTag or null) != "Scheme"
    then builtins.hashString "sha256" (builtins.toJSON s)
    else
      let
        bodyHash = typeHash s.body;
        forallStr = lib.concatStringsSep "," (lib.sort builtins.lessThan s.forall);
        csHashes  = lib.sort builtins.lessThan (map constraintHash s.constraints);
      in
      builtins.hashString "sha256" "Scheme(${forallStr};${bodyHash};${lib.concatStringsSep "," csHashes})";

  # ══ Hash-consing（Phase 4.2: 结构共享）═══════════════════════════════
  # 使用 hash 作为 key，避免重复构造相同类型
  # 在纯 Nix 中，hash-consing 通过 lazy evaluation 自动实现
  # 此函数用于显式检查两个类型是否结构共享

  # Type: Type → Type → Bool
  hashConsEq = a: b: typeHash a == typeHash b;

  # ══ Substitution hash（用于 memo key）════════════════════════════════
  substHash = subst:
    let
      typeKeys = builtins.attrNames (subst.typeBindings or {});
      rowKeys  = builtins.attrNames (subst.rowBindings or {});
      kindKeys = builtins.attrNames (subst.kindBindings or {});
      allKeys  = lib.sort builtins.lessThan (typeKeys ++ rowKeys ++ kindKeys);
      pairStrs = map (k:
        let
          tval = (subst.typeBindings or {}).${k} or null;
          rval = (subst.rowBindings or {}).${k} or null;
          kval = (subst.kindBindings or {}).${k} or null;
          vstr = if tval != null then typeHash tval
                 else if rval != null then typeHash rval
                 else builtins.toJSON kval;
        in
        "${k}=${vstr}"
      ) allKeys;
    in
    builtins.hashString "sha256" "Subst(${lib.concatStringsSep ";" pairStrs})";
}
