# incremental/query.nix — Phase 4.2
# QueryDB（Salsa-style，双缓存统一入口，RISK-D 修复）
# INV-QK1: QueryKey 确定性
# INV-QK2: 精确失效 BFS
# INV-QK5: 循环检测 DFS
# INV-QK-SCHEMA: key 格式验证
{ lib, hashLib }:

let inherit (hashLib) typeHash; in

rec {

  # ══ QueryKey 构造（INV-QK1 + INV-QK-SCHEMA）══════════════════════════
  # 所有 key 必须通过 mkQueryKey 构造
  # Type: String → [String] → QueryKey
  mkQueryKey = tag: inputs:
    let
      sortedInputs = lib.sort builtins.lessThan inputs;
    in
    "${tag}:${lib.concatStringsSep "," sortedInputs}";

  # INV-QK-SCHEMA: 验证 key 格式
  _validateKey = key:
    builtins.isString key &&
    builtins.stringLength key > 0 &&
    lib.hasInfix ":" key;

  # ══ QueryDB 结构 ═══════════════════════════════════════════════════════
  # { cache: {key → {value; deps: [key]; valid: Bool}};
  #   deps:  {key → [key]};    key 的依赖
  #   rdeps: {key → [key]};    依赖 key 的 keys }
  emptyDB = { cache = {}; deps = {}; rdeps = {}; };

  # ══ storeResult（INV-QK-SCHEMA 验证）═════════════════════════════════
  # Type: DB → QueryKey → Any → [QueryKey] → DB
  storeResult = db: key: value: deps:
    assert _validateKey key;
    let
      # 更新 rdeps：对每个 dep，记录 key 依赖它
      newRdeps = lib.foldl' (acc: dep:
        acc // { ${dep} = lib.unique ((acc.${dep} or []) ++ [ key ]); }
      ) db.rdeps deps;
      newDeps = db.deps // { ${key} = deps; };
      newCache = db.cache // { ${key} = { value = value; deps = deps; valid = true; }; };
    in
    db // { cache = newCache; deps = newDeps; rdeps = newRdeps; };

  lookupResult = db: key:
    let entry = db.cache.${key} or null; in
    if entry == null then null
    else if !(entry.valid or false) then null
    else entry.value;

  # ══ BFS 失效（INV-QK2 精确失效）══════════════════════════════════════
  invalidateKey = db: key:
    _bfsInvalidate db [ key ] [ key ];

  _bfsInvalidate = db: queue: visited:
    if queue == [] then db
    else
      let
        current   = builtins.head queue;
        rest      = builtins.tail queue;
        # 失效 current
        newDB     = _markInvalid db current;
        # INV-QK2: 找到依赖 current 的所有 keys（rdeps）
        rdeps     = db.rdeps.${current} or [];
        newRdeps  = lib.filter (k: !(builtins.elem k visited)) rdeps;
      in
      _bfsInvalidate newDB (rest ++ newRdeps) (visited ++ newRdeps);

  _markInvalid = db: key:
    if !(db.cache ? ${key}) then db
    else db // {
      cache = db.cache // { ${key} = db.cache.${key} // { valid = false; }; };
    };

  # ══ RISK-D 修复: cacheNormalize（双缓存统一入口）══════════════════════
  # 同时写 QueryDB + Memo，保证一致性
  # Type: DB → Memo → String → Type → [QueryKey] → { db; memo }
  cacheNormalize = db: memo: typeId: nf: deps:
    let
      key    = mkQueryKey "norm" [ typeId ];
      newDB  = storeResult db key nf deps;
      newMemo = memo // { normalize = memo.normalize // { ${typeId} = nf; }; };
    in
    { db = newDB; memo = newMemo; };

  # RISK-D 修复: bumpEpochDB（两层同步清空）
  # Type: { queryDB; memo } → { queryDB; memo }
  bumpEpochDB = state:
    let
      # 失效所有 QueryDB entries
      newDB = state.queryDB // {
        cache = builtins.mapAttrs (k: v: v // { valid = false; }) state.queryDB.cache;
      };
      # 清空 Memo
      newMemo = { normalize = {}; substitute = {}; solve = {}; epoch = (state.memo.epoch or 0) + 1; };
    in
    { queryDB = newDB; memo = newMemo; };

  # ══ INV-QK5: 循环检测 ══════════════════════════════════════════════════
  hasDependencyCycle = db: key:
    _dfsCycle db key [ key ];

  _dfsCycle = db: current: visited:
    let deps = db.deps.${current} or []; in
    builtins.any (dep:
      builtins.elem dep visited || _dfsCycle db dep (visited ++ [ dep ])
    ) deps;

  # ══ 查询统计 ══════════════════════════════════════════════════════════
  cacheStats = db:
    let
      entries    = builtins.attrValues db.cache;
      valid      = lib.filter (e: e.valid or false) entries;
      invalid    = lib.filter (e: !(e.valid or false)) entries;
    in
    { total = builtins.length entries;
      valid = builtins.length valid;
      invalid = builtins.length invalid; };
}
