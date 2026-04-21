# incremental/query.nix — Phase 4.1
# QueryKey 增量管道（Salsa-style）
# 修复 RISK-D：双缓存一致性（QueryDB + Memo 统一入口）
# INV-QK1: QueryKey 确定性（所有 key 通过 mkQueryKey 构造）
# INV-QK2: 精确失效（BFS，仅失效依赖此 key 的查询）
# INV-QK3: storeResult 原子（数据 + deps 同时存储）
# INV-QK4: invalidateKey 传播完整（BFS visited set）
# INV-QK5: 循环检测（DFS cycle detection）
# Phase 4.1 新增：
#   - QueryKey schema validation（防止手写 key 冲突）
#   - cacheNormalize 统一入口（同步两层缓存）
#   - bumpEpochDB 同步两层缓存（保证一致性）
{ lib, hashLib }:

let
  # ── QueryKey 合法 tag 集合（INV-QK-SCHEMA）───────────────────────────────
  _validTags = [ "norm" "hash" "eq" "solve" "check" "kind" "sub" "inst" "row" "infer" ];

  # ── QueryKey 构造器（INV-QK1：所有 key 必须通过此函数构造）──────────────
  # Type: String -> [String] -> String
  mkQueryKey = tag: inputs:
    let
      validTag = builtins.elem tag _validTags;
    in
    if !validTag then
      builtins.throw "Invalid QueryKey tag: ${tag}. Must be one of: ${builtins.toJSON _validTags}"
    else
      "${tag}:${builtins.concatStringsSep "," inputs}";

  # ── 预定义 key 构造器（INV-QK1 保证格式） ────────────────────────────────
  qkNormalize  = typeId:       mkQueryKey "norm"  [ typeId ];
  qkHash       = typeId:       mkQueryKey "hash"  [ typeId ];
  qkEq         = id1: id2:     mkQueryKey "eq"    (lib.sort (a: b: a < b) [ id1 id2 ]);
  qkSolve      = constraintIds: mkQueryKey "solve" constraintIds;
  qkCheck      = typeId:       mkQueryKey "check" [ typeId ];
  qkKind       = typeId:       mkQueryKey "kind"  [ typeId ];
  qkSubst      = varId: typeId: mkQueryKey "sub"  [ varId typeId ];
  qkInst       = className: argHashes: mkQueryKey "inst" ([ className ] ++ argHashes);
  qkRow        = rowId:        mkQueryKey "row"   [ rowId ];
  qkInfer      = exprId:       mkQueryKey "infer" [ exprId ];

  # ── QueryKey schema validation（INV-QK-SCHEMA）───────────────────────────
  validateQueryKey = key:
    lib.any (tag: lib.hasPrefix "${tag}:" key) _validTags;

  # ── QueryDB 结构 ──────────────────────────────────────────────────────────
  # { results  : AttrSet(key -> { value; valid; deps: [key] })
  # , revDeps  : AttrSet(key -> [key])  -- 反向依赖（被谁依赖）
  # , epoch    : Int
  # }
  emptyQueryDB = {
    results = {};
    revDeps = {};
    epoch   = 0;
  };

  # ── storeResult（INV-QK3：原子存储 value + deps）─────────────────────────
  # Type: DB -> String -> Any -> [String] -> DB
  storeResult = db: key: value: deps:
    let
      # 验证 key 格式（INV-QK-SCHEMA）
      valid = validateQueryKey key;
      entry = { inherit value deps; valid = true; epoch = db.epoch; };

      # 更新反向依赖图（deps 中每个 key 反向指向当前 key）
      newRevDeps = lib.foldl'
        (acc: depKey:
          let
            existing = acc.${depKey} or [];
          in
          acc // { ${depKey} = if builtins.elem key existing then existing
                               else existing ++ [ key ]; })
        db.revDeps
        deps;
    in
    if !valid then
      builtins.throw "storeResult: invalid QueryKey format: ${key}"
    else
      db // {
        results = db.results // { ${key} = entry; };
        revDeps = newRevDeps;
      };

  # ── lookupResult（缓存命中检查）──────────────────────────────────────────
  # Type: DB -> String -> { found: Bool; value?: Any }
  lookupResult = db: key:
    let entry = db.results.${key} or null; in
    if entry == null then { found = false; }
    else if !entry.valid then { found = false; }
    else { found = true; value = entry.value; };

  # ── invalidateKey（BFS 传播，INV-QK2/4）──────────────────────────────────
  # Type: DB -> String -> DB
  invalidateKey = db: key:
    let
      # BFS invalidation
      go = visited: worklist: db':
        if worklist == [] then db'
        else
          let
            cur      = builtins.head worklist;
            restWork = builtins.tail worklist;
          in
          if visited ? ${cur} then go visited restWork db'
          else
            let
              visited'  = visited // { ${cur} = true; };
              # 标记当前 key 为 invalid
              entry     = db'.results.${cur} or null;
              db''      = if entry == null then db'
                          else db' // {
                            results = db'.results // {
                              ${cur} = entry // { valid = false; };
                            };
                          };
              # 将依赖 cur 的 keys 加入 worklist
              rdeps     = db'.revDeps.${cur} or [];
              newWork   = lib.filter (k: !(visited' ? ${k})) rdeps;
            in
            go visited' (restWork ++ newWork) db'';
    in go {} [ key ] db;

  # ── detectCycle（DFS cycle detection，INV-QK5）───────────────────────────
  # Type: DB -> String -> Bool
  detectCycle = db: startKey:
    let
      go = visiting: visited: key:
        if visited ? ${key} then false     # 已完成访问，无环
        else if visiting ? ${key} then true  # 正在访问，发现环！
        else
          let
            visiting' = visiting // { ${key} = true; };
            deps      = (db.results.${key} or { deps = []; }).deps;
          in
          lib.any (go visiting' visited) deps;
    in go {} {} startKey;

  # ── bumpEpochDB（INV-QK4：全量失效退化模式，同步两层缓存）──────────────
  # Phase 4.1 修复 RISK-D：bumpEpochDB 同步 QueryDB + Memo 层
  # Type: { queryDB: DB; memo: MemoState } -> { queryDB: DB; memo: MemoState }
  bumpEpochDB = state:
    let
      db  = state.queryDB or emptyQueryDB;
      mem = state.memo or {};
      # 将所有 results 标记为 invalid
      invalidated = builtins.listToAttrs (map (k: {
        name  = k;
        value = db.results.${k} // { valid = false; };
      }) (builtins.attrNames db.results));
      newDB = db // { results = invalidated; epoch = db.epoch + 1; };
      # 同步 Memo：清空（epoch bump = 全量失效）
      newMemo = {};
    in
    { queryDB = newDB; memo = newMemo; };

  # ── Phase 4.1: 统一缓存入口（修复 RISK-D）────────────────────────────────
  # normalize 结果同时写入 QueryDB 和 Memo（保证一致性）
  # Type: DB -> MemoState -> String -> Any -> [String] -> { queryDB; memo }
  cacheNormalize = db: memo: typeId: nfValue: deps:
    let
      qKey    = qkNormalize typeId;
      newDB   = storeResult db qKey nfValue deps;
      # 同时写入 Memo（epoch-keyed）
      newMemo = memo // { ${typeId} = nfValue; };
    in
    { queryDB = newDB; memo = newMemo; };

  # hash 结果同时写入两层缓存
  cacheHash = db: memo: typeId: hashValue: deps:
    let
      qKey    = qkHash typeId;
      newDB   = storeResult db qKey hashValue deps;
      newMemo = memo // { ${typeId + ":hash"} = hashValue; };
    in
    { queryDB = newDB; memo = newMemo; };

  # ── DB 元信息 ─────────────────────────────────────────────────────────────
  queryDBSize = db: builtins.length (builtins.attrNames (db.results or {}));

  validEntryCount = db:
    builtins.length (lib.filter
      (k: (db.results.${k}).valid or false)
      (builtins.attrNames (db.results or {})));

  invalidEntryCount = db:
    queryDBSize db - validEntryCount db;

in {
  # Key constructors
  inherit mkQueryKey validateQueryKey
          qkNormalize qkHash qkEq qkSolve qkCheck
          qkKind qkSubst qkInst qkRow qkInfer;

  # DB operations
  inherit emptyQueryDB storeResult lookupResult
          invalidateKey detectCycle bumpEpochDB;

  # Phase 4.1: unified cache
  inherit cacheNormalize cacheHash;

  # Utilities
  inherit queryDBSize validEntryCount invalidEntryCount;
}
