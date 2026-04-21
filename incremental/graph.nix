# incremental/graph.nix — Phase 3
# 依赖图（增量失效 + BFS Worklist + 状态机）
#
# Phase 3 保留 Phase 2 修复 + 新增：
#   INV-G1: visited state 单源 BFS（worklist，非递归）
#   INV-G2: dirty state 有效 transition guard（_validTransitions）
#   INV-G3: batchUpdate = union roots → single propagation
#   INV-G4: removeNode 顺序：先清 revEdges，再清 edges
#   INV-G5: 节点 kind 分类（type / constraint / normalize / bidir）
#
# 节点状态机：
#   clean → dirty → computing → clean
#                ↘ error（终态）
{ lib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 节点状态（有限状态机）
  # ══════════════════════════════════════════════════════════════════════════════

  NodeState = {
    clean     = "clean";
    dirty     = "dirty";
    computing = "computing";
    error     = "error";
  };

  # 有效转换（INV-G2）
  _validTransitions = {
    clean     = ["dirty"];
    dirty     = ["computing" "clean"];  # computing（开始求值），clean（外部设置）
    computing = ["clean" "error"];
    error     = ["dirty"];              # 可重试
  };

  # Type: String -> String -> Bool
  isValidTransition = from: to:
    builtins.elem to (_validTransitions.${from} or []);

  # ══════════════════════════════════════════════════════════════════════════════
  # Graph 结构
  # ══════════════════════════════════════════════════════════════════════════════

  # Graph = {
  #   nodes: AttrSet NodeId Node;
  #   edges: AttrSet NodeId [NodeId];      # NodeId → [依赖的 NodeId]
  #   revEdges: AttrSet NodeId [NodeId];   # NodeId → [被依赖的 NodeId]（反向）
  # }
  # Node = { id: String; kind: String; state: NodeState; data: any; label?: String }

  emptyGraph = {
    nodes    = {};
    edges    = {};
    revEdges = {};
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # 节点操作
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Graph -> String -> String -> any -> Graph
  addNode = graph: nodeId: kind: data:
    let node = { id = nodeId; inherit kind data; state = NodeState.clean; label = nodeId; }; in
    graph // {
      nodes    = graph.nodes    // { ${nodeId} = node; };
      edges    = graph.edges    // { ${nodeId} = graph.edges.${nodeId} or []; };
      revEdges = graph.revEdges // { ${nodeId} = graph.revEdges.${nodeId} or []; };
    };

  # Type: Graph -> String -> Graph（INV-G4：先清 revEdges，再清 edges）
  removeNode = graph: nodeId:
    let
      deps    = graph.edges.${nodeId} or [];
      rdeps   = graph.revEdges.${nodeId} or [];
      # 先：从所有 dep 的 revEdges 中移除 nodeId
      graph1 = lib.foldl'
        (g: dep:
          g // { revEdges = g.revEdges // { ${dep} = builtins.filter (x: x != nodeId) (g.revEdges.${dep} or []); }; })
        graph
        deps;
      # 再：从所有 rdep 的 edges 中移除 nodeId
      graph2 = lib.foldl'
        (g: rdep:
          g // { edges = g.edges // { ${rdep} = builtins.filter (x: x != nodeId) (g.edges.${rdep} or []); }; })
        graph1
        rdeps;
    in
    graph2 // {
      nodes    = builtins.removeAttrs graph2.nodes    [nodeId];
      edges    = builtins.removeAttrs graph2.edges    [nodeId];
      revEdges = builtins.removeAttrs graph2.revEdges [nodeId];
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 边操作
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Graph -> String -> String -> Graph（from 依赖 to）
  addEdge = graph: fromId: toId:
    let
      # 更新正向边
      curEdges = graph.edges.${fromId} or [];
      newEdges = if builtins.elem toId curEdges then curEdges else curEdges ++ [toId];
      # 更新反向边
      curRev   = graph.revEdges.${toId} or [];
      newRev   = if builtins.elem fromId curRev then curRev else curRev ++ [fromId];
    in
    graph // {
      edges    = graph.edges    // { ${fromId} = newEdges; };
      revEdges = graph.revEdges // { ${toId}   = newRev; };
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 节点状态更新（transition guard，INV-G2）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Graph -> String -> String -> Graph
  setNodeState = graph: nodeId: newState:
    let node = graph.nodes.${nodeId} or null; in
    if node == null then graph  # 节点不存在，跳过
    else
      let from = node.state or NodeState.clean; in
      if !isValidTransition from newState
      then graph  # 无效转换，跳过（INV-G2 guard）
      else
        graph // {
          nodes = graph.nodes // { ${nodeId} = node // { state = newState; }; };
        };

  # ══════════════════════════════════════════════════════════════════════════════
  # BFS 失效传播（INV-G1：单源 BFS，worklist 非递归）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Graph -> [String] -> Graph
  # 将 roots 及其所有传递依赖者标记为 dirty
  propagateDirty = graph: roots:
    _propagateBFS graph roots {};

  # Type: Graph -> [String] -> VisitedSet -> Graph
  _propagateBFS = graph: worklist: visited:
    if worklist == [] then graph
    else
      let
        nodeId = builtins.head worklist;
        rest   = builtins.tail worklist;
      in
      if visited ? ${nodeId}
      then _propagateBFS graph rest visited  # 已访问，跳过
      else
        let
          visited' = visited // { ${nodeId} = true; };
          graph'   = setNodeState graph nodeId NodeState.dirty;
          # 将所有反向依赖加入 worklist（被依赖者需要重新计算）
          rdeps    = graph.revEdges.${nodeId} or [];
          # 只加入尚未访问的
          newWork  = builtins.filter (id: !(visited' ? ${id})) rdeps;
        in
        _propagateBFS graph' (rest ++ newWork) visited';

  # ══════════════════════════════════════════════════════════════════════════════
  # 批量更新（INV-G3：union roots → single propagation）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Graph -> [{nodeId, kind, data}] -> Graph
  batchUpdate = graph: updates:
    let
      # 1. 更新节点数据
      graph1 = lib.foldl'
        (g: upd:
          let node = g.nodes.${upd.nodeId} or null; in
          if node == null
          then addNode g upd.nodeId (upd.kind or "type") (upd.data or null)
          else g // { nodes = g.nodes // { ${upd.nodeId} = node // { data = upd.data or node.data; }; }; })
        graph
        updates;
      # 2. 收集所有变更节点为 dirty roots
      roots = map (upd: upd.nodeId) updates;
      # 3. 单次 BFS 传播（INV-G3）
      graph2 = propagateDirty graph1 roots;
    in
    graph2;

  # ══════════════════════════════════════════════════════════════════════════════
  # 查询
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Graph -> String -> Node?
  getNode = graph: nodeId: graph.nodes.${nodeId} or null;

  # Type: Graph -> String -> [NodeId]（直接依赖）
  getDeps = graph: nodeId: graph.edges.${nodeId} or [];

  # Type: Graph -> String -> [NodeId]（直接被依赖）
  getRevDeps = graph: nodeId: graph.revEdges.${nodeId} or [];

  # Type: Graph -> String -> NodeState
  getState = graph: nodeId:
    let node = graph.nodes.${nodeId} or null; in
    if node == null then NodeState.error
    else node.state or NodeState.clean;

  # Type: Graph -> [NodeId]（所有 dirty 节点）
  dirtyNodes = graph:
    builtins.filter
      (id: (graph.nodes.${id} or {}).state or "" == NodeState.dirty)
      (builtins.attrNames graph.nodes);

  # ══════════════════════════════════════════════════════════════════════════════
  # 拓扑排序（重新计算顺序）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Graph -> [NodeId]（Kahn's algorithm，BFS）
  topologicalSort = graph:
    let
      nodes = builtins.attrNames graph.nodes;
      # 入度计算
      inDegree = lib.foldl'
        (acc: id: acc // { ${id} = builtins.length (graph.edges.${id} or []); })
        {}
        nodes;
      # 初始 worklist：入度 = 0
      initial = builtins.filter (id: inDegree.${id} or 0 == 0) nodes;
    in
    _kahnBFS graph initial inDegree [];

  _kahnBFS = graph: worklist: inDegree: sorted:
    if worklist == [] then sorted
    else
      let
        nodeId   = builtins.head worklist;
        rest     = builtins.tail worklist;
        sorted'  = sorted ++ [nodeId];
        # 减少所有反向依赖的入度
        rdeps    = graph.revEdges.${nodeId} or [];
        inDegree' = lib.foldl'
          (acc: rdep: acc // { ${rdep} = (acc.${rdep} or 1) - 1; })
          inDegree
          rdeps;
        # 新增入度 = 0 的节点
        newReady = builtins.filter (id: inDegree'.${id} or 0 == 0) rdeps;
      in
      _kahnBFS graph (rest ++ newReady) inDegree' sorted';

  # ══════════════════════════════════════════════════════════════════════════════
  # 调试
  # ══════════════════════════════════════════════════════════════════════════════

  showGraph = graph:
    let
      nodes  = builtins.attrNames graph.nodes;
      dirty  = dirtyNodes graph;
      nEdges = lib.foldl' (acc: id: acc + builtins.length (graph.edges.${id} or [])) 0 nodes;
    in
    "Graph: ${toString (builtins.length nodes)} nodes, ${toString nEdges} edges, ${toString (builtins.length dirty)} dirty";

}
