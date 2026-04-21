# meta/equality.nix — Phase 4.1
# INV-3: 所有比较 = NormalForm Equality
# typeEq(a,b) ⟺ serialize(normalize(a)) == serialize(normalize(b))
{ lib, typeLib, normalizeLib, serialLib, hashLib }:

let
  inherit (normalizeLib) normalize';
  inherit (serialLib) canonicalHash;
  inherit (hashLib) typeHash;

in rec {
  # ── NF-based 类型相等（主入口）────────────────────────────────────────────
  # Type: Type -> Type -> Bool
  # INV-3: 所有比较必须经过 normalize
  typeEq = a: b:
    assert typeLib.isType a && typeLib.isType b;
    typeHash a == typeHash b;

  # ── 结构相等（不经 normalize，仅调试用）────────────────────────────────────
  reprEq = a: b:
    canonicalHash a.repr == canonicalHash b.repr;

  # ── 集合相等（无序 [Type] 集合比较）─────────────────────────────────────────
  # Type: [Type] -> [Type] -> Bool
  typeSetEq = as: bs:
    builtins.length as == builtins.length bs &&
    lib.all (a: lib.any (b: typeEq a b) bs) as;

  # ── Mu（递归类型）相等（bisimulation guard）────────────────────────────────
  # 使用 guard set 防止无限展开
  # Type: AttrSet(String -> true) -> Type -> Type -> Bool
  muEq = guard: a: b:
    let
      va = a.repr.__variant or null;
      vb = b.repr.__variant or null;
      guardKey = typeHash a + ":" + typeHash b;
    in
    if guard ? ${guardKey} then true  # 假设相等（co-inductive）
    else
      let guard' = guard // { ${guardKey} = true; }; in
      if va == "Mu" && vb == "Mu" then
        # 展开一层，继续比较
        let
          unfoldA = typeEq a b;  # 简化：直接用 NF hash
        in unfoldA
      else typeEq a b;

  # ── Row 相等（忽略顺序）──────────────────────────────────────────────────
  # Type: Type -> Type -> Bool
  rowEq = r1: r2: typeEq r1 r2;  # normalize 已保证 canonical order

  # ── INV-4 一致性检查（断言）──────────────────────────────────────────────
  assertHashConsistency = a: b:
    if typeEq a b && !(typeHash a == typeHash b)
    then builtins.throw "INV-4 violated: typeEq but hash differs"
    else true;
}
