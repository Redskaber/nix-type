# incremental/graph.nix — Phase 4.1
# 增量依赖图（Dependency Graph）
# INV-G1: BFS propagation 正确（in-degree 方向修正）
# INV-G2: FSM 状态清晰（clean-valid / clean-stale / dirty / computing / error）
# INV-G3: batchUpdate 语义正确（coalesced invalidation）
# INV-G4: removeNode 无 dangling edge
{ lib }:

rec {
  # ── Node FSM 状态 ─────────────────────────────────────────────────────────
  # Phase 4.1 修复 INV-G2：区分 clean-valid 和 clean-stale
  STATE_CLEAN_VALID  = "clean-valid";   # 已计算 + 仍有效
  STATE_CLEAN_STALE  = "clean-stale";   # 已计算 + 可能过时（deps 变化）
  STATE_DIRTY        = "dirty";          # 需要重算
  STATE_COMPUTING    = "computing";      # 正在计算
  STATE_ERROR        = "error";          # 计算出错

  # ── Graph 结构 ────────────────────────────────────────────────────────────
  # { nodes   : AttrSet(nodeId -> Node)
  # , edges   : AttrSet(nodeId -> [nodeId])      -- 正向依赖（from → to）
  # , revEdges: AttrSet(nodeId -> [nodeId])      -- 反向依赖（to ← from）
  # }
  # Node = { state; data; errorMeta? }
  # errorMeta = { cause; timestamp; originNode }

  emptyGraph = { nodes = {}; edges = {}; revEdges = {}; };

  # ── Node 操作 ─────────────────────────────────────────────────────────────

  addNode = graph: nodeId: data:
    let node = { state = STATE_DIRTY; data = data; errorMeta = null; }; in
    graph // { nodes = graph.nodes // { ${nodeId} = node; }; };

  updateNode = graph: nodeId: data:
    let existing = graph.nodes.${nodeId} or null; in
    if existing == null
    then addNode graph nodeId data
    else
      let node' = existing // { data = data; state = STATE_DIRTY; }; in
      graph // { nodes = graph.nodes // { ${nodeId} = node'; }; };

  # INV-G4: removeNode 先清理 edges，再删 node（无 dangling edge）
  removeNode = graph: nodeId:
    let
      # 清理指向 nodeId 的反向边（其他 node 的 edges 中移除 nodeId）
      affectedSources = graph.revEdges.${nodeId} or [];
      newEdges = lib.foldl'
        (acc: src:
          let
            oldTargets = acc.${src} or [];
            newTargets = lib.filter (t: t != nodeId) oldTargets;
          in acc // { ${src} = newTargets; })
        graph.edges
        affectedSources;

      # 清理 nodeId 的 revEdges 条目
      targets  = graph.edges.${nodeId} or [];
      newRevEdges = lib.foldl'
        (acc: tgt:
          let
            oldSources = acc.${tgt} or [];
            newSources = lib.filter (s: s != nodeId) oldSources;
          in acc // { ${tgt} = newSources; })
        (builtins.removeAttrs graph.revEdges [ nodeId ])
        targets;

      # 移除 node 本身
      newNodes = builtins.removeAttrs graph.nodes [ nodeId ];
      # 移除 nodeId 在 edges 中的条目
      finalEdges = builtins.removeAttrs newEdges [ nodeId ];
    in
    graph // { nodes = newNodes; edges = finalEdges; revEdges = newRevEdges; };

  # ── Edge 操作 ─────────────────────────────────────────────────────────────

  addEdge = graph: fromId: toId:
    let
      oldEdges    = graph.edges.${fromId} or [];
      newEdges    = if builtins.elem toId oldEdges then oldEdges
                    else oldEdges ++ [ toId ];
      oldRevEdges = graph.revEdges.${toId} or [];
      newRevEdges = if builtins.elem fromId oldRevEdges then oldRevEdges
                    else oldRevEdges ++ [ fromId ];
    in
    graph // {
      edges    = graph.edges    // { ${fromId} = newEdges; };
      revEdges = graph.revEdges // { ${toId}   = newRevEdges; };
    };

  # ── State transitions ──────────────────────────────────────────────────────

  markDirty = graph: nodeId:
    let node = graph.nodes.${nodeId} or null; in
    if node == null then graph
    else
      graph // { nodes = graph.nodes // { ${nodeId} = node // { state = STATE_DIRTY; }; }; };

  markComputing = graph: nodeId:
    let node = graph.nodes.${nodeId} or null; in
    if node == null then graph
    else
      graph // { nodes = graph.nodes // { ${nodeId} = node // { state = STATE_COMPUTING; }; }; };

  markClean = graph: nodeId: result:
    let node = graph.nodes.${nodeId} or null; in
    if node == null then graph
    else
      graph // {
        nodes = graph.nodes // {
          ${nodeId} = node // { state = STATE_CLEAN_VALID; data = result; errorMeta = null; };
        };
      };

  markError = graph: nodeId: cause:
    let
      node = graph.nodes.${nodeId} or null;
      errorMeta = { inherit cause; originNode = nodeId; timestamp = 0; };
    in
    if node == null then graph
    else
      graph // {
        nodes = graph.nodes // {
          ${nodeId} = node // { state = STATE_ERROR; errorMeta = errorMeta; };
        };
      };

  # Phase 4.1 INV-G2: clean-stale transition
  markStale = graph: nodeId:
    let node = graph.nodes.${nodeId} or null; in
    if node == null then graph
    else if node.state == STATE_CLEAN_VALID then
      graph // {
        nodes = graph.nodes // {
          ${nodeId} = node // { state = STATE_CLEAN_STALE; };
        };
      }
    else graph;  # 已经是 dirty/stale/computing/error，不需要 stale 标记

  # ── BFS invalidation 传播（INV-G1 修复：正确 in-degree 方向）────────────
  # 当 nodeId 的数据变化时，依赖它的节点（revEdges）需要被标记为 dirty
  # INV-G1: 使用 revEdges（反向依赖）而不是 edges
  propagateDirty = graph: nodeId:
    let
      go = visited: worklist: g:
        if worklist == [] then g
        else
          let
            cur      = builtins.head worklist;
            restWork = builtins.tail worklist;
          in
          if visited ? ${cur} then go visited restWork g
          else
            let
              visited' = visited // { ${cur} = true; };
              g'       = markDirty g cur;
              # revEdges[cur] = 依赖 cur 的节点（它们需要重算）
              rdeps    = g'.revEdges.${cur} or [];
              # dedup queue（INV-G1 修复：避免重复 BFS expansion）
              newWork  = lib.filter (id: !(visited' ? ${id})) rdeps;
            in
            go visited' (restWork ++ newWork) g';
    in
    go {} [ nodeId ] graph;

  # ── batchUpdate（INV-G3：coalesced invalidation）─────────────────────────
  # 批量更新多个 nodes，单次 BFS 传播
  batchUpdate = graph: updates:
    let
      # Step 1: 更新所有 nodes 的数据
      g1 = lib.foldl'
        (acc: upd: updateNode acc upd.nodeId upd.data)
        graph updates;

      # Step 2: 收集所有 root dirty nodes
      roots = map (upd: upd.nodeId) updates;

      # Step 3: 单次 BFS propagation（从所有 roots 出发）
      # 注意：先 dedup roots
      uniqueRoots = lib.foldl'
        (acc: r: if builtins.elem r acc then acc else acc ++ [ r ])
        [] roots;

      go = visited: worklist: g:
        if worklist == [] then g
        else
          let
            cur      = builtins.head worklist;
            restWork = builtins.tail worklist;
          in
          if visited ? ${cur} then go visited restWork g
          else
            let
              visited' = visited // { ${cur} = true; };
              g'       = markDirty g cur;
              rdeps    = g'.revEdges.${cur} or [];
              newWork  = lib.filter (id: !(visited' ? ${id})) rdeps;
            in go visited' (restWork ++ newWork) g';
    in
    go {} uniqueRoots g1;

  # ── 拓扑排序（Kahn 算法，INV-G1 正确语义）────────────────────────────────
  # edges[A]=[B] 语义：A 依赖 B（B 先处理）
  # in-degree(A) = len(edges[A])：A 等待多少依赖完成
  topologicalSort = graph:
    let
      nodeIds = builtins.attrNames graph.nodes;

      # in-degree = 该节点依赖的节点数量（edges 正向，A→B 表示 A 依赖 B）
      # edges[A]=[B] → in-degree(A)=1，A 等待 B 先完成
      # 起始：in-degree=0（无依赖）的节点先出队
      inDegrees = builtins.listToAttrs (map (id: {
        name  = id;
        value = builtins.length (graph.edges.${id} or []);
      }) nodeIds);

      go = order: remaining: degrees:
        if remaining == [] then { ok = true; order = order; }
        else
          let
            # 找所有 in-degree = 0 的节点
            zeros = lib.filter (id: degrees.${id} or 0 == 0) remaining;
          in
          if zeros == [] then
            { ok = false; order = order; error = "Cycle detected in dependency graph"; }
          else
            let
              # 选择第一个（稳定排序）
              next       = builtins.head (lib.sort (a: b: a < b) zeros);
              remaining' = lib.filter (id: id != next) remaining;
              # 处理 next 后，所有依赖 next 的节点（revEdges[next]）等待少了一个
              # 即: 对 revEdges[next] 中每个节点，其 in-degree 减 1
              dependents = graph.revEdges.${next} or [];
              degrees'   = lib.foldl'
                (acc: dep: acc // { ${dep} = (acc.${dep} or 1) - 1; })
                degrees dependents;
            in go (order ++ [ next ]) remaining' degrees';
    in go [] nodeIds inDegrees;

  # ── dirtyNodes（需要重算的节点列表）─────────────────────────────────────
  dirtyNodes = graph:
    lib.filter
      (id:
        let s = (graph.nodes.${id} or {}).state or ""; in
        s == STATE_DIRTY || s == STATE_CLEAN_STALE)
      (builtins.attrNames graph.nodes);
}
