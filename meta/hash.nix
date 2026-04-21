# meta/hash.nix — Phase 4.1
# canonical hash：INV-4 核心实现
# typeEq(a,b) ⟹ typeHash(a) == typeHash(b)
{ lib, typeLib, normalizeLib, serialLib }:

let
  inherit (normalizeLib) normalize';
  inherit (serialLib) serializeRepr canonicalHash;

in rec {
  # ── 规范化 hash（INV-4）──────────────────────────────────────────────────
  # Type: Type -> String
  # hash = H(serialize(normalize(t)))
  typeHash = t:
    assert typeLib.isType t;
    let nf = normalize' t; in
    canonicalHash nf.repr;

  # ── TypeRepr 直接 hash（不经过 normalize，仅用于内部）───────────────────
  reprHash = repr:
    canonicalHash repr;

  # ── hash 一致性验证（调试用）─────────────────────────────────────────────
  # Type: Type -> Type -> Bool
  # 验证 INV-4: typeEq(a,b) ⟹ typeHash(a) == typeHash(b)
  verifyHashConsistency = equalityFn: a: b:
    if equalityFn a b
    then typeHash a == typeHash b
    else true;  # 不相等时无约束

  # ── instance key 生成（用于 constraint solver）────────────────────────────
  # Type: String -> [Type] -> String
  # INV-4 保证：相同 className + 规范化等价 args → 相同 key
  instanceKey = className: args:
    let
      normalizedArgs = map normalize' args;
      argHashes      = map (a: canonicalHash a.repr) normalizedArgs;
      keyData        = { c = className; a = argHashes; };
    in
    builtins.hashString "sha256" (builtins.toJSON keyData);
}
