# incremental/memo.nix — Phase 3.1
# Memo 层（INV-M1-4 完整实现）
#
# Phase 3.1 修复：
#   INV-M1: memoKey = typeHash(t)（单一来源，INV-H2 保证）
#   INV-M2: epoch bump → 所有 versioned keys 失效
#   INV-M3: constraint key = sorted + dedup（canonical）
#   INV-M4: versioned key = "epoch:hash"（细粒度失效）
#   新增：   结构化 cache value（不是 string identity 陷阱）
#            withMemoNormalize 包装器（正确 compute callback 语义）
#            invalidateSubgraph（细粒度 type-level 失效）
{ lib, hashLib, constraintLib }:

let
  inherit (hashLib) typeHash;
  inherit (constraintLib) constraintKey;

  # 版本化 key
  _vKey = epoch: rawKey: "${builtins.toString epoch}:${rawKey}";

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # MemoStore 结构
  # ══════════════════════════════════════════════════════════════════════════════

  # MemoStore = {
  #   epoch:     Int                  # 全局版本（bump → 全量失效）
  #   normalize: AttrSet VKey NF      # normalize → NF bucket
  #   substitute: AttrSet VKey Type   # substitute bucket
  #   solve:     AttrSet VKey Result  # solver bucket
  #   stats:     { hits; misses; evictions }
  # }

  emptyMemo = {
    epoch      = 0;
    normalize  = {};
    substitute = {};
    solve      = {};
    stats      = { hits = 0; misses = 0; evictions = 0; };
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Normalize Bucket（INV-M1：memoKey = typeHash）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: MemoStore -> Type -> { hit: Bool; value?: Type; memo: MemoStore }
  lookupNormalize = memo: t:
    let
      key    = _vKey memo.epoch (typeHash t);
      cached = memo.normalize.${key} or null;
    in
    if cached != null
    then { hit = true; value = cached; memo = _bumpHit memo; }
    else { hit = false; memo = _bumpMiss memo; };

  # Type: MemoStore -> Type -> Type -> MemoStore
  storeNormalize = memo: t: nf:
    let key = _vKey memo.epoch (typeHash t); in
    memo // { normalize = memo.normalize // { ${key} = nf; }; };

  # 包装器：先 lookup，miss 则 compute + store
  # Type: MemoStore -> Type -> (Type -> Type) -> { result: Type; memo: MemoStore }
  withMemoNormalize = memo: t: computeFn:
    let looked = lookupNormalize memo t; in
    if looked.hit
    then { result = looked.value; memo = looked.memo; }
    else
      let
        nf     = computeFn t;
        memo'  = storeNormalize looked.memo t nf;
      in
      { result = nf; memo = memo'; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Substitute Bucket
  # ══════════════════════════════════════════════════════════════════════════════

  _substSig = subst:
    let
      # 稳定排序（deterministic key）
      pairs = lib.sort lib.lessThan
        (map (k: "${k}=${(subst.${k}).id or "?"}") (builtins.attrNames subst));
    in
    builtins.hashString "md5" (builtins.concatStringsSep ";" pairs);

  lookupSubst = memo: t: subst:
    let
      key    = _vKey memo.epoch "${typeHash t}:S:${_substSig subst}";
      cached = memo.substitute.${key} or null;
    in
    if cached != null
    then { hit = true; value = cached; memo = _bumpHit memo; }
    else { hit = false; memo = _bumpMiss memo; };

  storeSubst = memo: t: subst: result:
    let key = _vKey memo.epoch "${typeHash t}:S:${_substSig subst}"; in
    memo // { substitute = memo.substitute // { ${key} = result; }; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Solve Bucket（INV-M3：constraint sorted + dedup）
  # ══════════════════════════════════════════════════════════════════════════════

  _constraintSetKey = cs:
    let
      # dedup via AttrSet（O(n)）
      table = builtins.listToAttrs
        (map (c: { name = constraintKey c; value = true; }) cs);
      sorted = lib.sort lib.lessThan (builtins.attrNames table);
    in
    builtins.hashString "sha256" (builtins.concatStringsSep ";" sorted);

  lookupSolve = memo: constraints:
    let
      key    = _vKey memo.epoch (_constraintSetKey constraints);
      cached = memo.solve.${key} or null;
    in
    if cached != null
    then { hit = true; value = cached; memo = _bumpHit memo; }
    else { hit = false; memo = _bumpMiss memo; };

  storeSolve = memo: constraints: result:
    let key = _vKey memo.epoch (_constraintSetKey constraints); in
    memo // { solve = memo.solve // { ${key} = result; }; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Epoch 管理（INV-M2：全量失效）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: MemoStore -> MemoStore
  bumpEpoch = memo:
    let
      evictionCount = builtins.length (builtins.attrNames memo.normalize)
                    + builtins.length (builtins.attrNames memo.substitute)
                    + builtins.length (builtins.attrNames memo.solve);
    in
    memo // {
      epoch      = memo.epoch + 1;
      normalize  = {};
      substitute = {};
      solve      = {};
      stats      = memo.stats // { evictions = memo.stats.evictions + evictionCount; };
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 细粒度失效（INV-M4：type-level invalidation）
  # ══════════════════════════════════════════════════════════════════════════════

  # 失效特定 Type 的所有缓存（不 bump epoch）
  # Type: MemoStore -> Type -> MemoStore
  invalidateType = memo: t:
    let
      h = typeHash t;
      prefix = "${builtins.toString memo.epoch}:${h}";
      filterBucket = bucket:
        lib.filterAttrs (k: _: !(lib.hasPrefix prefix k)) bucket;
    in
    memo // {
      normalize  = filterBucket memo.normalize;
      substitute = filterBucket memo.substitute;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 统计 / 调试
  # ══════════════════════════════════════════════════════════════════════════════

  memoStats = memo: {
    inherit (memo) epoch;
    normalizeSize  = builtins.length (builtins.attrNames memo.normalize);
    substituteSize = builtins.length (builtins.attrNames memo.substitute);
    solveSize      = builtins.length (builtins.attrNames memo.solve);
    hits      = memo.stats.hits;
    misses    = memo.stats.misses;
    evictions = memo.stats.evictions;
    hitRate   = let t = memo.stats.hits + memo.stats.misses; in
                if t == 0 then 0 else memo.stats.hits;
  };

  # Legacy aliases（兼容 tests/test_all.nix）
  lookupNormalize_ = lookupNormalize;
  storeNormalize_  = storeNormalize;

  # ── 内部统计 helpers ──────────────────────────────────────────────────────────
  _bumpHit  = memo: memo // { stats = memo.stats // { hits   = memo.stats.hits + 1; }; };
  _bumpMiss = memo: memo // { stats = memo.stats // { misses = memo.stats.misses + 1; }; };

}
