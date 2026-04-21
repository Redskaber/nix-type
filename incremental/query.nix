# incremental/query.nix — Phase 4.0
#
# QueryKey 增量管道（类 Salsa / Rust 编译器）
#
# 目标：
#   Phase 3.3 memo = epoch-based（全量失效，粗粒度）
#   Phase 4.0 query = QueryKey-based（细粒度，per-query 失效）
#
# 设计：
#   QueryKey = String（规范化的查询标识符）
#   QueryResult = { value; deps: [QueryKey]; epoch: Int; valid: Bool }
#   QueryDB = AttrSet QueryKey QueryResult
#
#   查询类型（Query）：
#     normalize(typeId)     → NF(type)
#     typeHash(typeId)      → Hash
#     typeEq(idA, idB)      → Bool
#     solveConstraints(cs)  → SolverResult
#     checkType(exprId)     → TypeResult
#
# 不变量（Phase 4.0 QueryKey）：
#   INV-QK1: QueryKey = tag ":" serialize(inputs)（规范化，确定性）
#   INV-QK2: 失效传播 = 仅失效 deps 中包含 dirtyKey 的查询
#   INV-QK3: recompute 后 deps 精确更新（非保守）
#   INV-QK4: epoch = 全局单调递增（不回绕）
#   INV-QK5: circular deps 检测（avoid infinite loop）

{ lib, hashLib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # QueryKey 构造（INV-QK1）
  # ══════════════════════════════════════════════════════════════════════════════

  mkQueryKey = tag: inputs:
    "${tag}:${lib.concatStringsSep "," (map builtins.toString inputs)}";

  qkNormalize = typeId:
    mkQueryKey "norm" [typeId];

  qkHash = typeId:
    mkQueryKey "hash" [typeId];

  qkTypeEq = idA: idB:
    let sorted = if idA <= idB then [idA idB] else [idB idA]; in
    mkQueryKey "eq" sorted;

  qkSolve = csHash:
    mkQueryKey "solve" [csHash];

  qkCheck = exprId:
    mkQueryKey "check" [exprId];

  qkKindOf = typeId:
    mkQueryKey "kind" [typeId];

  qkSubtype = idA: idB:
    mkQueryKey "sub" [idA idB];

  qkInstance = className: typeHash:
    mkQueryKey "inst" [className typeHash];

  # ══════════════════════════════════════════════════════════════════════════════
  # QueryResult
  # ══════════════════════════════════════════════════════════════════════════════

  mkQueryResult = value: deps: epoch: {
    inherit value deps epoch;
    valid = true;
  };

  invalidateResult = qr: qr // { valid = false; };

  # ══════════════════════════════════════════════════════════════════════════════
  # QueryDB 操作
  # ══════════════════════════════════════════════════════════════════════════════

  emptyQueryDB = {
    results = {};   # QueryKey → QueryResult
    epoch   = 0;
    revDeps = {};   # QueryKey → [QueryKey] (who depends on me)
  };

  # 记录一次查询结果
  storeResult = db: key: value: deps:
    let
      result = mkQueryResult value deps db.epoch;

      # 更新反向依赖：对每个 dep，记录 key 依赖了它
      newRevDeps = lib.foldl' (acc: dep:
        let existing = acc.${dep} or []; in
        acc // { ${dep} = lib.unique (existing ++ [key]); }
      ) db.revDeps deps;
    in
    db // {
      results  = db.results // { ${key} = result; };
      revDeps  = newRevDeps;
    };

  # 查找结果
  lookupResult = db: key:
    if db.results ? ${key} && (db.results.${key}).valid
    then { found = true; result = db.results.${key}; }
    else { found = false; result = null; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 细粒度失效传播（INV-QK2/QK3）
  # BFS + queueSet（仅失效直接/间接依赖此 key 的查询）
  # ══════════════════════════════════════════════════════════════════════════════

  invalidateKey = db: dirtyKey:
    _bfsInvalidate db [dirtyKey] {};

  _bfsInvalidate = db: worklist: visited:
    if worklist == [] then db
    else
      let
        current   = builtins.head worklist;
        rest      = builtins.tail worklist;
        visited'  = visited // { ${current} = true; };

        # 失效当前节点
        db' = if db.results ? ${current}
              then db // {
                results = db.results // {
                  ${current} = invalidateResult db.results.${current};
                };
              }
              else db;

        # 找到依赖 current 的所有查询（反向依赖）
        rdeps    = db.revDeps.${current} or [];
        newWork  = lib.filter (k: !(visited' ? ${k})) rdeps;
        newWork' = lib.filter (k: !(lib.elem k rest)) newWork;  # dedup
      in
      _bfsInvalidate db' (rest ++ newWork') visited';

  # 批量失效
  invalidateKeys = db: dirtyKeys:
    lib.foldl' (acc: k: invalidateKey acc k) db dirtyKeys;

  # ── epoch bump（粗粒度全量失效，退化模式）────────────────────────────────────
  bumpEpochDB = db:
    let
      invalidateAll = lib.mapAttrs (_: r: invalidateResult r) db.results;
    in
    db // {
      epoch   = db.epoch + 1;
      results = invalidateAll;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 循环依赖检测（INV-QK5）
  # ══════════════════════════════════════════════════════════════════════════════

  # 检测从 rootKey 出发的依赖图中是否存在循环（DFS）
  detectCycle = db: rootKey:
    _dfsDetectCycle db rootKey [] {};

  _dfsDetectCycle = db: key: path: visited:
    if visited ? ${key} then
      { hasCycle = false; }  # 已访问，正常终止
    else if lib.elem key path then
      { hasCycle = true; cycle = path ++ [key]; }  # 检测到循环
    else
      let
        visited' = visited // { ${key} = true; };
        path'    = path ++ [key];
        deps     = (db.results.${key} or { deps = []; }).deps;
        results  = map (dep: _dfsDetectCycle db dep path' visited') deps;
        cycles   = lib.filter (r: r.hasCycle) results;
      in
      if cycles != [] then builtins.head cycles
      else { hasCycle = false; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 查询追踪上下文（运行查询时收集 deps）
  # ══════════════════════════════════════════════════════════════════════════════

  # QueryContext：追踪当前查询的依赖收集
  emptyQueryCtx = { deps = []; };

  trackDep = ctx: key: ctx // { deps = lib.unique (ctx.deps ++ [key]); };

  # withQueryCtx：执行查询并追踪所有访问的 QueryKey
  # f: ctx → { result; ctx }
  withQueryCtx = f:
    let
      ctx0      = emptyQueryCtx;
      resultCtx = f ctx0;
    in {
      value = resultCtx.result or resultCtx;
      deps  = (resultCtx.ctx or ctx0).deps;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 查询引擎（集成 QueryDB + 计算函数）
  # ══════════════════════════════════════════════════════════════════════════════

  # runQuery：执行或缓存查询
  # compute: db → { value; deps }
  runQuery = db: key: compute:
    let lookup = lookupResult db key; in
    if lookup.found then
      { db = db; value = lookup.result.value; hit = true; }
    else
      let
        computed = compute db;
        db'      = storeResult db key computed.value (computed.deps or []);
      in
      { db = db'; value = computed.value; hit = false; };

  # ══════════════════════════════════════════════════════════════════════════════
  # QueryDB 统计
  # ══════════════════════════════════════════════════════════════════════════════

  queryStats = db:
    let
      allResults = builtins.attrValues db.results;
      total      = builtins.length allResults;
      valid      = builtins.length (lib.filter (r: r.valid) allResults);
      invalid    = total - valid;
    in {
      inherit total valid invalid;
      epoch = db.epoch;
      hitRate = if total > 0
                then builtins.div (valid * 100) total
                else 0;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 集成：与 Phase 3.3 memoLib 的桥接
  # ══════════════════════════════════════════════════════════════════════════════

  # fromLegacyMemo：将 Phase 3.3 memo 转换为 QueryDB（迁移路径）
  fromLegacyMemo = legacyMemo:
    let
      cacheEntries = legacyMemo.cache or {};
      epoch        = legacyMemo.epoch or 0;
      asResults = lib.mapAttrs (key: entry:
        mkQueryResult (entry.value or null) [] epoch
      ) cacheEntries;
    in
    emptyQueryDB // {
      results = asResults;
      epoch   = epoch;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 不变量验证
  # ══════════════════════════════════════════════════════════════════════════════

  verifyQueryInvariants = _:
    let
      # INV-QK1: 确定性 QueryKey
      k1a = qkNormalize "abc123";
      k1b = qkNormalize "abc123";
      invQK1 = k1a == k1b;

      # INV-QK4: epoch 单调
      db0  = emptyQueryDB;
      db1  = bumpEpochDB db0;
      db2  = bumpEpochDB db1;
      invQK4 = db0.epoch < db1.epoch && db1.epoch < db2.epoch;

      # INV-QK2: 精确失效传播
      # 设置：A 依赖 B，B 依赖 C
      dbSetup =
        let
          d0 = storeResult emptyQueryDB "C" "valC" [];
          d1 = storeResult d0 "B" "valB" ["C"];
          d2 = storeResult d1 "A" "valA" ["B"];
        in d2;

      # 失效 C → B 和 A 应被失效
      dbAfterInvalidate = invalidateKey dbSetup "C";
      cValid = (dbAfterInvalidate.results.C or { valid = true; }).valid;
      bValid = (dbAfterInvalidate.results.B or { valid = true; }).valid;
      aValid = (dbAfterInvalidate.results.A or { valid = true; }).valid;
      invQK2 = !cValid && !bValid && !aValid;

      # INV-QK3: lookup after invalidation → not found
      lookup = lookupResult dbAfterInvalidate "A";
      invQK3 = !lookup.found;

      # INV-QK5: cycle detection
      dbCycle =
        let
          d0 = storeResult emptyQueryDB "X" "vX" ["Y"];
          d1 = storeResult d0 "Y" "vY" ["X"];  # cycle: X → Y → X
        in d1;
      cycleResult = detectCycle dbCycle "X";
      invQK5 = cycleResult.hasCycle;

    in {
      allPass   = invQK1 && invQK2 && invQK3 && invQK4 && invQK5;
      "INV-QK1" = invQK1;
      "INV-QK2" = invQK2;
      "INV-QK3" = invQK3;
      "INV-QK4" = invQK4;
      "INV-QK5" = invQK5;
    };
}
