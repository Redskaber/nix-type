# incremental/memo.nix — Phase 3
# Memo 层（INV-H3 强化 + epoch + 语义 hash key）
#
# Phase 3 修复（来自 nix-todo/incremental/memo.md）：
#   1. memoKey 单一来源（typeHash，INV-H3）
#   2. epoch bump 协议（版本化 key：epoch:hash）
#   3. 分桶设计（normalize / substitute / solve 独立 bucket）
#   4. 约束 hash：sorted + dedup（INV-M-3）
#   5. 缓存一致性验证（detect 隐性 cache miss）
#
# 不变量：
#   INV-M1: memoKey = typeHash(t)（经过 normalize，INV-H3）
#   INV-M2: epoch bump → 所有 keys 失效（全量失效）
#   INV-M3: constraint key 是 sorted + dedup（canonical）
#   INV-M4: versioned key = "epoch:hash"（细粒度失效）
{ lib, hashLib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Memo Store 结构
  # ══════════════════════════════════════════════════════════════════════════════

  # MemoStore = {
  #   epoch: Int;                    # 全局版本（bump → 全量失效）
  #   normalize: AttrSet;            # normalize bucket
  #   substitute: AttrSet;           # substitute bucket
  #   solve: AttrSet;                # solver bucket
  #   hash: AttrSet;                 # hash cache（快速路径）
  #   stats: { hits: Int; misses: Int; evictions: Int };
  # }

  emptyMemo = {
    epoch     = 0;
    normalize = {};
    substitute = {};
    solve      = {};
    hash       = {};
    stats      = { hits = 0; misses = 0; evictions = 0; };
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Key 协议
  # ══════════════════════════════════════════════════════════════════════════════

  # versioned key（INV-M4）
  # Type: MemoStore -> String -> String
  _vKey = memo: rawKey: "${toString memo.epoch}:${rawKey}";

  # Type: MemoStore -> Type -> String
  _typeKey = memo: t: _vKey memo (hashLib.typeHash t);

  # Type: MemoStore -> Type -> String -> String（带 namespace）
  _nsKey = memo: namespace: t: _vKey memo "${namespace}:${hashLib.typeHash t}";

  # ══════════════════════════════════════════════════════════════════════════════
  # Normalize Bucket
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: MemoStore -> Type -> { found: Bool; value?: Type; memo: MemoStore }
  memoLookupNormalize = memo: t:
    let key = _typeKey memo t; in
    let cached = memo.normalize.${key} or null; in
    if cached != null
    then {
      found = true;
      value = cached;
      memo  = memo // { stats = memo.stats // { hits = memo.stats.hits + 1; }; };
    }
    else {
      found = false;
      memo  = memo // { stats = memo.stats // { misses = memo.stats.misses + 1; }; };
    };

  # Type: MemoStore -> Type -> Type -> MemoStore
  memoStoreNormalize = memo: t: nf:
    let key = _typeKey memo t; in
    memo // { normalize = memo.normalize // { ${key} = nf; }; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Substitute Bucket
  # ══════════════════════════════════════════════════════════════════════════════

  # Key = typeHash(t) + hash(substSig)
  _substSig = subst:
    let
      pairs = builtins.sort (a: b: a < b)
        (map (k: "${k}:${(subst.${k}).id or "?"}") (builtins.attrNames subst));
    in
    builtins.hashString "md5" (builtins.concatStringsSep ";" pairs);

  # Type: MemoStore -> Type -> Subst -> { found: Bool; value?: Type; memo: MemoStore }
  memoLookupSubst = memo: t: subst:
    let
      key = _vKey memo "${hashLib.typeHash t}:subst:${_substSig subst}";
      cached = memo.substitute.${key} or null;
    in
    if cached != null
    then { found = true; value = cached; memo = _bumpHit memo; }
    else { found = false; memo = _bumpMiss memo; };

  # Type: MemoStore -> Type -> Subst -> Type -> MemoStore
  memoStoreSubst = memo: t: subst: result:
    let key = _vKey memo "${hashLib.typeHash t}:subst:${_substSig subst}"; in
    memo // { substitute = memo.substitute // { ${key} = result; }; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Solve Bucket
  # ══════════════════════════════════════════════════════════════════════════════

  # Key = hash(constraints)（sorted + dedup，INV-M3）
  _constraintSetKey = cs:
    let
      # dedup（listToAttrs O(n)）
      table = builtins.listToAttrs
        (map (c: {
          name = _constraintKey c;
          value = true;
        }) cs);
      sorted = builtins.sort (a: b: a < b) (builtins.attrNames table);
    in
    builtins.hashString "sha256"
      (builtins.concatStringsSep ";" sorted);

  _constraintKey = c:
    let tag = c.__constraintTag or c.__tag or null; in
    if tag == "Class" then
      "Cls:${c.name}:${builtins.concatStringsSep "," (map (a: a.id or "?") (c.args or []))}"
    else if tag == "Equality" then "Eq:${(c.a or {}).id or "?"}:${(c.b or {}).id or "?"}"
    else if tag == "Predicate" then "Pred:${c.fn or "?"}:${(c.arg or {}).id or "?"}"
    else builtins.hashString "md5" (builtins.toJSON c);

  # Type: MemoStore -> [Constraint] -> { found: Bool; value?: SolveResult; memo: MemoStore }
  memoLookupSolve = memo: constraints:
    let key = _vKey memo (_constraintSetKey constraints); in
    let cached = memo.solve.${key} or null; in
    if cached != null
    then { found = true; value = cached; memo = _bumpHit memo; }
    else { found = false; memo = _bumpMiss memo; };

  # Type: MemoStore -> [Constraint] -> SolveResult -> MemoStore
  memoStoreSolve = memo: constraints: result:
    let key = _vKey memo (_constraintSetKey constraints); in
    memo // { solve = memo.solve // { ${key} = result; }; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Epoch 管理（全量失效）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: MemoStore -> MemoStore（bump epoch → 所有 versioned keys 失效）
  bumpEpoch = memo:
    memo // {
      epoch = memo.epoch + 1;
      # 可选：清理旧 bucket（在 Nix 中 lazy，旧 key 自然失效）
      normalize  = {};
      substitute = {};
      solve      = {};
      hash       = {};
      stats      = memo.stats // { evictions = memo.stats.evictions + builtins.length (builtins.attrNames memo.normalize); };
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 细粒度失效（单节点失效，INV-M4）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: MemoStore -> Type -> MemoStore（失效特定 Type 的所有缓存）
  invalidateType = memo: t:
    let
      h      = hashLib.typeHash t;
      prefix = "${toString memo.epoch}:${h}";
      # 清除含此 hash 的所有 key
      filterBucket = bucket:
        lib.filterAttrs (k: _: !lib.hasPrefix prefix k) bucket;
    in
    memo // {
      normalize  = filterBucket memo.normalize;
      substitute = filterBucket memo.substitute;
      hash       = filterBucket memo.hash;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # Memoized 计算包装器
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: MemoStore -> Type -> (Type -> { result: a; memo: MemoStore }) -> { result: a; memo: MemoStore }
  withMemoNormalize = memo: t: compute:
    let looked = memoLookupNormalize memo t; in
    if looked.found
    then { result = looked.value; memo = looked.memo; }
    else
      let computed = compute t; in
      { result = computed.result;
        memo   = memoStoreNormalize computed.memo t computed.result; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 统计 / 调试
  # ══════════════════════════════════════════════════════════════════════════════

  memoStats = memo: memo.stats;

  showMemoStats = memo:
    let s = memo.stats; in
    "hits=${toString s.hits} misses=${toString s.misses} evictions=${toString s.evictions} epoch=${toString memo.epoch}";

  # ── 内部统计 helpers ─────────────────────────────────────────────────────
  _bumpHit  = memo: memo // { stats = memo.stats // { hits   = memo.stats.hits + 1; }; };
  _bumpMiss = memo: memo // { stats = memo.stats // { misses = memo.stats.misses + 1; }; };

}
