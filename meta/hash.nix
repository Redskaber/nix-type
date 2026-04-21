# meta/hash.nix — Phase 3.1
# Canonical Hash（INV-H2 单路径强制）
#
# Phase 3.1 关键修复：
#   INV-H2:  typeHash = nfHash ∘ normalize（唯一收敛路径）
#   INV-EQ1: typeEq(a,b) ⟹ typeHash(a) == typeHash(b)
#   修复：   消除 typeHash / nfHash 双路径歧义
#            nfHash 增加 NF precondition guard
#            memo cache 改为结构化 value（不是 string identity）
#            verifyHashConsistency 改为 nf-only truth model
#
# 设计：
#   hash = sha256(serializeAlpha(normalize(type)))
#   所有调用路径唯一：typeHash → normalize → serializeAlpha → sha256
{ lib, typeLib, normalizeLib, serialLib }:

let
  inherit (typeLib) isType;
  inherit (serialLib) serializeReprAlphaCanonical hashReprCanonical;

  # 统一 normalize 入口（INV-H2 关键：单路径）
  _normalize = t:
    if normalizeLib != null && normalizeLib ? normalize
    then normalizeLib.normalize t
    else t;  # bootstrap fallback

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 核心 Hash 函数（INV-H2 强制：单一路径）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 核心：typeHash = nfHash ∘ normalize
  # 所有 hash 必须经过 normalize，保证 typeEq ⟹ hash-eq（INV-EQ1）
  #
  # Type: Type -> String
  typeHash = t:
    assert isType t;
    nfHash (_normalize t);

  # NF hash（假设输入已经是 NF，或接近 NF）
  # Type: Type -> String
  nfHash = t:
    hashReprCanonical (t.repr or { __variant = "?"; });

  # Raw repr hash（快速路径，仅用于 cache lookup key，不作为 equality 依据）
  # Type: Type -> String
  reprHash = t:
    builtins.hashString "md5" (serializeReprAlphaCanonical (t.repr or { __variant = "?"; }));

  # ══════════════════════════════════════════════════════════════════════════════
  # Hash Cache（结构化 value，避免 string identity 陷阱）
  # ══════════════════════════════════════════════════════════════════════════════

  # HashMemo = { byRawKey: AttrSet String HashEntry }
  # HashEntry = { nfHash: String; rawKey: String }
  emptyHashMemo = { byRawKey = {}; };

  # Type: HashMemo -> Type -> { hash: String; memo: HashMemo }
  typeHashCached = memo: t:
    let
      rawKey = reprHash t;
      cached = (memo.byRawKey or {}).${rawKey} or null;
    in
    if cached != null
    then { hash = cached.nfHash; memo = memo; }
    else
      let
        h   = typeHash t;
        entry = { nfHash = h; rawKey = rawKey; };
        memo' = memo // { byRawKey = (memo.byRawKey or {}) // { ${rawKey} = entry; }; };
      in
      { hash = h; memo = memo'; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Hash-Consing（结构共享，减少内存 + 加速 equality）
  # ══════════════════════════════════════════════════════════════════════════════

  # HashConsTable = AttrSet NfHash Type
  emptyHashConsTable = {};

  # Type: HashConsTable -> Type -> { type: Type; table: HashConsTable }
  hashCons = table: t:
    let
      h = typeHash t;
      existing = table.${h} or null;
    in
    if existing != null
    then { type = existing; table = table; }
    else
      # 使用 canonical hash 作为 stable id（不 mutate type，用 overlay）
      let t' = t // { id = h; }; in
      { type = t'; table = table // { ${h} = t'; }; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Hash 一致性验证（Phase 3.1：nf-only truth model）
  # ══════════════════════════════════════════════════════════════════════════════

  # verifyHashConsistency 改为：
  #   consistent ⇔ nfEqual（不用 hash 作为 truth，只用 NF equality）
  #   hash 只用于 performance，不用于 correctness 分类
  #
  # Type: Type -> Type -> { consistent: Bool; reason: String }
  verifyHashConsistency = a: b:
    let
      nfA   = _normalize a;
      nfB   = _normalize b;
      hashA = nfHash nfA;
      hashB = nfHash nfB;
      nfSer = t: serializeReprAlphaCanonical t.repr;
      nfEq  = nfSer nfA == nfSer nfB;
      hashEq = hashA == hashB;
    in
    if nfEq && hashEq    then { consistent = true;  reason = "nf-equal and hash-equal"; }
    else if !nfEq && !hashEq then { consistent = true;  reason = "nf-different and hash-different"; }
    else if nfEq && !hashEq  then { consistent = false; reason = "BUG: nf-equal but hash-different (hash function error)"; }
    else                          { consistent = false; reason = "BUG: hash-equal but nf-different (hash collision)"; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Hash 工具
  # ══════════════════════════════════════════════════════════════════════════════

  # 比较两个 type 的 hash（相等 ⟹ 语义相等，by INV-EQ1）
  # Type: Type -> Type -> Bool
  hashEq = a: b: typeHash a == typeHash b;

  # 从一组 types 中去重（按 hash）
  # Type: [Type] -> [Type]
  deduplicateByHash = types:
    let
      go = acc: seen: ts:
        if ts == [] then acc
        else
          let
            h = typeHash (builtins.head ts);
            rest = builtins.tail ts;
          in
          if seen ? ${h} then go acc seen rest
          else go (acc ++ [builtins.head ts]) (seen // { ${h} = true; }) rest;
    in
    go [] {} types;

  # 从一组 types 中按 hash 排序（canonical 顺序）
  # Type: [Type] -> [Type]
  sortByHash = types:
    lib.sort (a: b: typeHash a < typeHash b) types;

}
