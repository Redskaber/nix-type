# incremental/graph.nix — Phase 3.1
# 增量依赖图（BFS worklist，Kahn 修正）
#
# Phase 3.1 关键修复：
#   BUG-1: Kahn 算法 in-degree 方向错误 → 修正为正确 in-degree model
#   BUG-2: topologicalSort newReady logic 错误 → 基于 predecessor 消除
#   BUG-3: BFS queue dedup 未强制 → queueSet 防止重复 BFS expansion
#   BUG-4: stale-clean distinction 缺失 → 添加 stale 状态
#   BUG-5: error provenance 缺失 → errorMeta 记录 cause/originNode
#
# 图结构：
#   Graph = { nodes: AttrSet NodeId NodeEntry; edges: AttrSet NodeId [NodeId]; revEdges: AttrSet NodeId [NodeId] }
#   NodeEntry = { id; data; state; errorMeta? }
#   State = "clean" | "dirty" | "computing" | "stale" | "error"
#
# 不变量：
#   INV-G1: BFS worklist 不重复（queueSet 保证）
#   INV-G2: edges ↔ revEdges 对称（addEdge 维护）
#   INV-G3: batchUpdate = coalesced invalidation（单次 BFS）
#   INV-G4: removeNode 清理 revEdges 优先于 edges（无 dangling）
#   INV-G5: topologicalSort 正确（Kahn，in-degree = 前驱数）
{ lib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # State Machine
  # ══════════════════════════════════════════════════════════════════════════════

  stateClean     = "clean";
  stateDirty     = "dirty";
  stateComputing = "computing";
  stateStale     = "stale";   # Phase 3.1 新增：clean 但可能过时
  stateError     = "error";

  # 合法状态转换
  isValidTransition = from: to:
    (from == stateClean     && (to == stateDirty || to == stateComputing || to == stateStale))
    || (from == stateDirty  && (to == stateComputing || to == stateClean || to == stateError))
    || (from == stateComputing && (to == stateClean || to == stateDirty || to == stateError))
    || (from == stateStale  && (to == stateDirty || to == stateClean))
    || (from == stateError  && to == stateDirty);  # error → retry

  # ══════════════════════════════════════════════════════════════════════════════
  # NodeEntry 构造
  # ══════════════════════════════════════════════════════════════════════════════

  mkNode = id: data: {
    inherit id data;
    state     = stateClean;
    errorMeta = null;
  };

  # Phase 3.1 新增：errorMeta 携带 cause + originNode
  mkErrorNode = id: data: cause:
    { inherit id data;
      state     = stateError;
      errorMeta = { inherit cause; originNode = id; timestamp = 0; };
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 空图
  # ══════════════════════════════════════════════════════════════════════════════

  emptyGraph = {
    nodes    = {};
    edges    = {};   # NodeId → [NodeId]（successors，依赖方向）
    revEdges = {};   # NodeId → [NodeId]（predecessors，反向）
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # 添加节点
  # ══════════════════════════════════════════════════════════════════════════════

  addNode = g: node:
    g // {
      nodes    = g.nodes    // { ${node.id} = node; };
      edges    = g.edges    // { ${node.id} = g.edges.${node.id}    or []; };
      revEdges = g.revEdges // { ${node.id} = g.revEdges.${node.id} or []; };
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 添加边（from → to 表示"to 依赖 from"）
  # ══════════════════════════════════════════════════════════════════════════════

  # addEdge: from 改变会 dirty to（to 是 from 的 dependent）
  addEdge = g: fromId: toId:
    let
      fromEdges = g.edges.${fromId} or [];
      toRevEdges = g.revEdges.${toId} or [];
    in
    g // {
      edges    = g.edges    // { ${fromId} = _addUniq toId fromEdges; };
      revEdges = g.revEdges // { ${toId}   = _addUniq fromId toRevEdges; };
    };

  # 添加边（带环检测）
  addEdgeSafe = g: fromId: toId:
    let hasCycle = _pathExists g toId fromId; in
    if hasCycle
    then { ok = false; error = "Cycle: ${fromId} → ${toId}"; graph = g; }
    else { ok = true;  error = null; graph = addEdge g fromId toId; };

  _addUniq = item: lst:
    if builtins.elem item lst then lst else lst ++ [item];

  # ══════════════════════════════════════════════════════════════════════════════
  # 路径检测（DFS，用于环检测）
  # ══════════════════════════════════════════════════════════════════════════════

  _pathExists = g: from: to:
    _pathDFS g from to {};

  _pathDFS = g: current: target: visited:
    if current == target then true
    else if visited ? ${current} then false
    else
      let
        visited' = visited // { ${current} = true; };
        nexts = g.edges.${current} or [];
      in
      lib.any (n: _pathDFS g n target visited') nexts;

  # ══════════════════════════════════════════════════════════════════════════════
  # 删除节点（INV-G4：revEdges 优先）
  # ══════════════════════════════════════════════════════════════════════════════

  removeNode = g: nodeId:
    let
      # 1. 清理所有指向 nodeId 的 edges（其他节点的 forward edges）
      edges' = builtins.mapAttrs
        (k: succs: builtins.filter (s: s != nodeId) succs)
        (builtins.removeAttrs g.edges [nodeId]);

      # 2. 清理所有从 nodeId 出发的 revEdges（其他节点的 reverse edges）
      predecessors = g.revEdges.${nodeId} or [];
      revEdges' = builtins.mapAttrs
        (k: preds: builtins.filter (p: p != nodeId) preds)
        (builtins.removeAttrs g.revEdges [nodeId]);

      # 3. 删除节点本身
      nodes' = builtins.removeAttrs g.nodes [nodeId];
    in
    g // {
      nodes    = nodes';
      edges    = edges';
      revEdges = revEdges';
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 失效传播（BFS worklist，INV-G1：queueSet 去重）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Graph -> NodeId -> Graph
  propagateInvalidation = g: startId:
    _bfsPropagate g [startId] { ${startId} = true; };

  # BFS 传播（Phase 3.1 修复：queueSet 防止重复）
  _bfsPropagate = g: worklist: visited:
    if worklist == [] then g
    else
      let
        nodeId = builtins.head worklist;
        rest   = builtins.tail worklist;

        # 标记当前节点为 dirty
        g' = if g.nodes ? ${nodeId}
             then g // { nodes = g.nodes // { ${nodeId} = g.nodes.${nodeId} // { state = stateDirty; }; }; }
             else g;

        # 获取 dependents（successor nodes，即依赖 nodeId 的节点）
        dependents = g.edges.${nodeId} or [];

        # Phase 3.1 修复：queueSet = visited ∪ enqueued（去重）
        newWork = builtins.filter (id: !(visited ? ${id})) dependents;
        visited' = lib.foldl' (acc: id: acc // { ${id} = true; }) visited newWork;
        worklist' = rest ++ newWork;
      in
      _bfsPropagate g' worklist' visited';

  # ══════════════════════════════════════════════════════════════════════════════
  # 批量更新（INV-G3：coalesced invalidation）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Graph -> AttrSet NodeId Any -> Graph
  batchUpdate = g: updates:
    let
      nodeIds = builtins.attrNames updates;

      # 1. 更新数据
      g' = lib.foldl'
        (acc: id:
          if acc.nodes ? ${id}
          then acc // { nodes = acc.nodes // { ${id} = acc.nodes.${id} // { data = updates.${id}; }; }; }
          else acc)
        g
        nodeIds;

      # 2. 收集所有受影响的根节点
      roots = nodeIds;

      # 3. 单次 BFS 传播（INV-G3：coalesced）
      initVisited = builtins.listToAttrs (map (id: { name = id; value = true; }) roots);
    in
    _bfsPropagate g' roots initVisited;

  # ══════════════════════════════════════════════════════════════════════════════
  # Topological Sort（Phase 3.1 修复：Kahn 算法，正确 in-degree）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复 BUG-1/BUG-2：
  #   in-degree = 节点的"前驱数"（predecessors count）
  #   Kahn：每次取 in-degree = 0 的节点（即无前驱），从中移除后更新 successors
  #
  # Type: Graph -> { ok: Bool; order: [NodeId]; cycle: [NodeId]? }
  topologicalSort = g:
    let
      allNodes = builtins.attrNames g.nodes;

      # INV-G5：in-degree = 前驱数（revEdges 长度）
      initDegrees = builtins.listToAttrs
        (map (id: {
          name  = id;
          value = builtins.length (g.revEdges.${id} or []);
        }) allNodes);

      # 初始 ready queue：in-degree = 0（稳定排序，deterministic）
      initReady = lib.sort lib.lessThan
        (builtins.filter (id: initDegrees.${id} == 0) allNodes);
    in
    _kahnStep g initDegrees initReady [] (builtins.length allNodes);

  # Kahn 步骤
  _kahnStep = g: degrees: ready: order: remaining:
    if ready == [] then
      if remaining == 0 then { ok = true; order = order; cycle = null; }
      else { ok = false; order = order; cycle = _findCycle g order; }
    else
      let
        nodeId = builtins.head ready;
        rest   = builtins.tail ready;

        # 减少所有 successor 的 in-degree（移除 nodeId 后）
        succs = g.edges.${nodeId} or [];
        degrees' = lib.foldl'
          (acc: s: acc // { ${s} = (acc.${s} or 1) - 1; })
          degrees
          succs;

        # Phase 3.1 修复 BUG-2：新的 ready = successor 中 degree 变为 0 的（sort 保证稳定）
        newReady = lib.sort lib.lessThan
          (builtins.filter (s: degrees'.${s} or 1 == 0) succs);

        order'   = order ++ [nodeId];
        ready'   = rest ++ newReady;
      in
      _kahnStep g degrees' ready' order' (remaining - 1);

  # 找环（从未完成的节点中 DFS 找环）
  _findCycle = g: processed:
    let
      processedSet = builtins.listToAttrs (map (id: { name = id; value = true; }) processed);
      unprocessed  = builtins.filter (id: !(processedSet ? ${id})) (builtins.attrNames g.nodes);
    in
    if unprocessed == [] then []
    else [builtins.head unprocessed];  # 简化：返回一个环成员

  # ══════════════════════════════════════════════════════════════════════════════
  # 查询工具
  # ══════════════════════════════════════════════════════════════════════════════

  dirtyNodes = g:
    builtins.filter (id: (g.nodes.${id}.state or "") == stateDirty)
      (builtins.attrNames g.nodes);

  cleanNodes = g:
    builtins.filter (id: (g.nodes.${id}.state or "") == stateClean)
      (builtins.attrNames g.nodes);

  errorNodes = g:
    builtins.filter (id: (g.nodes.${id}.state or "") == stateError)
      (builtins.attrNames g.nodes);

  # 验证 edges ↔ revEdges 对称性（INV-G2）
  verifySymmetry = g:
    let
      violations = builtins.concatMap
        (fromId:
          builtins.concatMap
            (toId:
              if builtins.elem fromId (g.revEdges.${toId} or [])
              then []
              else ["edge ${fromId}→${toId} missing revEdge"]
            )
            (g.edges.${fromId} or [])
        )
        (builtins.attrNames g.nodes);
    in
    { ok = violations == []; inherit violations; };

  graphStats = g:
    let
      nodeCount = builtins.length (builtins.attrNames g.nodes);
      edgeCount = lib.foldl' (acc: id: acc + builtins.length (g.edges.${id} or []))
                    0 (builtins.attrNames g.nodes);
    in
    { inherit nodeCount edgeCount;
      dirtyCount = builtins.length (dirtyNodes g);
      errorCount = builtins.length (errorNodes g);
    };

}
