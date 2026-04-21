# meta/hash.nix — Phase 3
# Canonical Hash 实现（INV-4 强化）
#
# Phase 3 核心修复（来自 nix-todo/meta/hash.md）：
#   1. typeHash / nfHash 语义收敛（INV-H2/H3 边界统一）
#   2. 消除 typeHash vs nfHash 双路径歧义
#   3. memoKey 单一路径：nfHash ∘ normalize
#   4. combineHashes — canonical 哈希组合（sorted）
#   5. verifyHashConsistency — 运行时不变量验证
#
# 统一规范（Phase 3）：
#   typeHash(t)  = nfHash(normalize(t))   — 对外唯一接口
#   nfHash(nf)   = H(serializeAlpha(nf.repr))  — 内部，仅在 normalize 之后调用
#   memoKey(t)   = typeHash(t)             — 单一来源
#
# 不变量：
#   INV-H1: typeEq(a,b) ⟹ typeHash(a) == typeHash(b)
#   INV-H2: typeHash = nfHash ∘ normalize（唯一收敛路径）
#   INV-H3: memoKey = typeHash（不是 raw repr hash）
#   INV-H4: combineHashes 是 canonical（sorted，与顺序无关）
{ lib, serialLib, normalizeLib, typeLib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 核心 Hash 函数
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3 规范：nfHash = H(serializeAlpha(repr))
  # 前提：repr 必须已经是 NF（不做 normalize）
  # 内部使用，不对外直接暴露作为 memo key
  # Type: Type -> String
  nfHash = t:
    assert typeLib.isType t;
    builtins.hashString "sha256"
      (serialLib.serializeReprAlphaCanonical t.repr);

  # Phase 3 规范：typeHash = nfHash ∘ normalize（唯一对外接口）
  # 无论 t 是否已经是 NF，都先 normalize
  # INV-H2：typeHash = nfHash ∘ normalize（强制）
  # Type: Type -> String
  typeHash = t:
    assert typeLib.isType t;
    let nf = normalizeLib.normalize t; in
    nfHash nf;

  # ── memoKey（INV-H3：单一来源，只用 typeHash）────────────────────────────
  # Type: Type -> String
  memoKey = t: typeHash t;

  # ── 带 namespace 的 memoKey ──────────────────────────────────────────────
  # Type: String -> Type -> String
  memoKeyNS = namespace: t: "${namespace}:${typeHash t}";

  # ══════════════════════════════════════════════════════════════════════════════
  # Hash 组合（canonical，INV-H4）
  # ══════════════════════════════════════════════════════════════════════════════

  # 组合多个 hash：sorted 后拼接再 hash（顺序无关，canonical）
  # Type: [String] -> String
  combineHashes = hashes:
    let sorted = builtins.sort (a: b: a < b) hashes; in
    builtins.hashString "sha256"
      (builtins.concatStringsSep ":" sorted);

  # 组合两个 hash（常用简化版）
  # Type: String -> String -> String
  combineTwo = h1: h2:
    combineHashes [h1 h2];

  # ══════════════════════════════════════════════════════════════════════════════
  # Hash-Consing（结构共享）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: HashConsTable -> Type -> { type: Type; table: HashConsTable }
  hashCons = table: t:
    let h = typeHash t; in
    let existing = table.${h} or null; in
    if existing != null
    then { type = existing; table = table; }
    else
      let t' = t // { id = h; }; in
      { type = t'; table = table // { ${h} = t'; }; };

  emptyHashConsTable = {};

  # ══════════════════════════════════════════════════════════════════════════════
  # Hash 缓存（避免重复 normalize）
  # ══════════════════════════════════════════════════════════════════════════════

  # 两层缓存：raw hash → NF hash
  # 避免：同一 Type 在不同阶段进入 memo 时 hash key 不一致（Phase 2 bug）
  # Phase 3 修复：只用 typeHash 作为唯一 key，消除 nfHash 作为 raw key 的歧义

  # Type: HashMemo -> Type -> { hash: String; memo: HashMemo }
  typeHashCached = memo: t:
    let
      # key 统一：typeHash（normalize 后）
      key = typeHash t;
      cached = memo.cache.${key} or null;
    in
    if cached != null
    then { hash = cached; memo = memo; }
    else
      { hash = key; memo = memo // { cache = memo.cache // { ${key} = key; }; }; };

  emptyHashMemo = { cache = {}; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 不变量验证
  # ══════════════════════════════════════════════════════════════════════════════

  # INV-H1/H2 验证：typeEq(a,b) ⟺ typeHash(a) == typeHash(b)
  # Type: Type -> Type -> { consistent: Bool; status: String }
  verifyHashConsistency = a: b:
    let
      ha = typeHash a;
      hb = typeHash b;
      hashEq = ha == hb;
      # NF equality（通过 serializeAlpha 比较）
      nfA = normalizeLib.normalize a;
      nfB = normalizeLib.normalize b;
      nfEqual = serialLib.serializeReprAlphaCanonical nfA.repr
              == serialLib.serializeReprAlphaCanonical nfB.repr;
    in
    if hashEq && nfEqual then
      { consistent = true;  status = "consistent-equal";     details = "hash=${ha}"; }
    else if !hashEq && !nfEqual then
      { consistent = true;  status = "consistent-different"; details = "${ha} vs ${hb}"; }
    else if hashEq && !nfEqual then
      { consistent = false; status = "hash-collision";
        details = "COLLISION: same hash ${ha} but different NF"; }
    else
      { consistent = false; status = "hash-inconsistency";
        details = "INCONSISTENCY: different hash but same NF: ${ha} vs ${hb}"; };

  # ── 系统级 INV 检查 ────────────────────────────────────────────────────────
  # Type: [Type] -> { ok: Bool; violations: [String] }
  verifyHashInvariants = types:
    let
      # 检查 typeHash = nfHash ∘ normalize 对每个类型
      violations = lib.concatMap (t:
        let
          h1 = typeHash t;
          nf = normalizeLib.normalize t;
          h2 = nfHash nf;
        in
        if h1 == h2 then []
        else ["INV-H2 violation: typeHash(${builtins.substring 0 8 t.id}) != nfHash(normalize(t))"]
      ) types;
    in
    { ok = builtins.length violations == 0; inherit violations; };

}
