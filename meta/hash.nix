# meta/hash.nix — Phase 4.3
# Canonical hash：Hash(serialize(NormalForm(t)))
# INV-4: typeEq(a,b) ⟹ typeHash(a) == typeHash(b)
#
# Fix P4.3 (critical):
#   Previous _safeToJSON used builtins.tryEval (builtins.toJSON v).
#   In Nix, builtins.toJSON on a lambda throws an UNCATCHABLE abort in some
#   evaluator versions — tryEval does NOT reliably catch it.
#   Resolution: _safeStr is now the canonical safe primitive, defined in
#   meta/serialize.nix and used here via serialLib.
#   All fallback paths now call serialLib._safeStr or serialLib.serializeType.
{ lib, serialLib }:

let
  inherit (serialLib) serializeType serializeRepr canonicalHash canonicalHashRepr
                      serializeConstraint _safeStr;

in rec {

  # ══ 主 hash 函数（通过 NF）════════════════════════════════════════════════
  # Type: NormalizedType → String
  # 注意：调用者负责先 normalize，hash 不做 normalize（避免循环）
  typeHash = t:
    if builtins.isFunction t then
      # A function value can never be a Type — hash its textual description
      builtins.hashString "sha256" "<fn>"
    else if !builtins.isAttrs t || (t.tag or null) != "Type"
    then builtins.hashString "sha256" (_safeStr t)
    else canonicalHash t;

  # Type: TypeRepr → String（repr 级别 hash）
  reprHash = r: canonicalHashRepr r;

  # ══ Constraint hash（用于去重）══════════════════════════════════════════
  constraintHash = c:
    builtins.hashString "sha256" (serializeConstraint c);

  # ══ TypeScheme hash ══════════════════════════════════════════════════════
  schemeHash = s:
    if builtins.isFunction s then
      builtins.hashString "sha256" "<fn-scheme>"
    else if !builtins.isAttrs s || (s.__schemeTag or null) != "Scheme"
    then builtins.hashString "sha256" (_safeStr s)
    else
      let
        bodyHash  = typeHash s.body;
        forallStr = lib.concatStringsSep "," (lib.sort builtins.lessThan s.forall);
        csHashes  = lib.sort builtins.lessThan (map constraintHash s.constraints);
      in
      builtins.hashString "sha256" "Scheme(${forallStr};${bodyHash};${lib.concatStringsSep "," csHashes})";

  # ══ Hash-consing（Phase 4.2: 结构共享）══════════════════════════════════
  hashConsEq = a: b: typeHash a == typeHash b;

  # ══ Substitution hash（用于 memo key）════════════════════════════════════
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
          # kval is a Kind (pure attrset, no function fields) — _safeStr is safe
          vstr = if tval != null then typeHash tval
                 else if rval != null then typeHash rval
                 else _safeStr kval;
        in
        "${k}=${vstr}"
      ) allKeys;
    in
    builtins.hashString "sha256" "Subst(${lib.concatStringsSep ";" pairStrs})";
}
