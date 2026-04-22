# incremental/graph.nix — Phase 4.2
# 依赖图（INV-G1~4 全修复）
# INV-G1: BFS propagation 正确方向（edges[A]=[B] → A 依赖 B）
# INV-G2: clean-stale FSM 状态区分
# INV-G3: 无自环
# INV-G4: removeNode 无 dangling edge
{ lib }:

rec {

  # ══ 图结构 ════════════════════════════════════════════════════════════
  # { nodes: {id → NodeState}; edges: {id → [id]}; revEdges: {id → [id]} }
  # NodeState: "clean" | "stale" | "computing"
  # edges[A]=[B] → A 依赖 B（B 先处理，B 是 A 的 prerequisite）
  # revEdges[B]=[A,...] → A 依赖 B（B 变化时，需要失效 A）

  emptyGraph = { nodes = {}; edges = {}; revEdges = {}; };

  # ══ 节点操作 ══════════════════════════════════════════════════════════

  # Type: Graph → String → Graph
  addNode = graph: nodeId:
    if graph.nodes ? ${nodeId} then graph
    else graph // {
      nodes    = graph.nodes    // { ${nodeId} = "clean"; };
      edges    = graph.edges    // { ${nodeId} = []; };
      revEdges = graph.revEdges // { ${nodeId} = []; };
    };

  # Type: Graph → String → Graph
  # INV-G4: removeNode 清除所有相关 edges
  removeNode = graph: nodeId:
    if !(graph.nodes ? ${nodeId}) then graph
    else
      let
        # 找到所有依赖 nodeId 的节点（revEdges[nodeId]）
        dependents = graph.revEdges.${nodeId} or [];
        # 从这些节点的 edges 中移除 nodeId
        newEdges = builtins.mapAttrs (n: deps:
          lib.filter (d: d != nodeId) deps
        ) (builtins.removeAttrs graph.edges [ nodeId ]);
        # 找到 nodeId 依赖的节点（edges[nodeId]）
        dependencies = graph.edges.${nodeId} or [];
        # 从这些节点的 revEdges 中移除 nodeId
        newRevEdges = builtins.mapAttrs (n: revDeps:
          lib.filter (d: d != nodeId) revDeps
        ) (builtins.removeAttrs graph.revEdges [ nodeId ]);
      in {
        nodes    = builtins.removeAttrs graph.nodes [ nodeId ];
        edges    = newEdges;
        revEdges = newRevEdges;
      };

  # ══ 边操作 ════════════════════════════════════════════════════════════

  # Type: Graph → String(from) → String(to) → Graph
  # addEdge A B: A 依赖 B
  # INV-G3: 不添加自环
  addEdge = graph: fromId: toId:
    if fromId == toId then graph  # INV-G3: no self-loops
    else
      let
        g1 = if graph.nodes ? ${fromId} then graph else addNode graph fromId;
        g2 = if g1.nodes ? ${toId} then g1 else addNode g1 toId;
        currentEdges    = g2.edges.${fromId} or [];
        currentRevEdges = g2.revEdges.${toId} or [];
      in
      if builtins.elem toId currentEdges then g2  # already exists
      else g2 // {
        edges    = g2.edges    // { ${fromId} = currentEdges ++ [ toId ]; };
        revEdges = g2.revEdges // { ${toId} = currentRevEdges ++ [ fromId ]; };
      };

  removeEdge = graph: fromId: toId:
    graph // {
      edges    = graph.edges    // { ${fromId} = lib.filter (d: d != toId) (graph.edges.${fromId} or []); };
      revEdges = graph.revEdges // { ${toId} = lib.filter (d: d != fromId) (graph.revEdges.${toId} or []); };
    };

  # ══ 节点状态操作（INV-G2: clean/stale FSM）═══════════════════════════
  # clean  → stale  (invalidate)
  # stale  → clean  (recompute)
  # computing → clean (finish)

  markStale = graph: nodeId:
    if !(graph.nodes ? ${nodeId}) then graph
    else graph // { nodes = graph.nodes // { ${nodeId} = "stale"; }; };

  markClean = graph: nodeId:
    if !(graph.nodes ? ${nodeId}) then graph
    else graph // { nodes = graph.nodes // { ${nodeId} = "clean"; }; };

  nodeState = graph: nodeId: graph.nodes.${nodeId} or "unknown";
  isClean = graph: nodeId: nodeState graph nodeId == "clean";
  isStale = graph: nodeId: nodeState graph nodeId == "stale";

  # ══ INV-G1: BFS 失效传播（正确方向）════════════════════════════════
  # change(node) → 失效所有依赖 node 的节点（revEdges）
  # BFS from changed node, following revEdges

  # Type: Graph → String → Graph
  invalidateNode = graph: nodeId:
    _bfsInvalidate graph [ nodeId ] [ nodeId ];

  _bfsInvalidate = graph: queue: visited:
    if queue == [] then graph
    else
      let
        current  = builtins.head queue;
        rest     = builtins.tail queue;
        # INV-G1: 失效 current 的 dependents（revEdges[current]）
        deps     = graph.revEdges.${current} or [];
        newDeps  = lib.filter (d: !(builtins.elem d visited)) deps;
        newGraph = lib.foldl' markStale graph ([ current ] ++ newDeps);
      in
      _bfsInvalidate newGraph (rest ++ newDeps) (visited ++ newDeps);

  # ══ 拓扑排序（INV-G5: 正确语义）══════════════════════════════════════
  # edges[A]=[B] → A 依赖 B → B 先处理
  # in-degree(A) = |edges[A]|（A 的依赖数量，即 A 需要等待的节点数）

  # Type: Graph → [String] | { error: "cycle" }
  topologicalSort = graph:
    let
      nodes = builtins.attrNames graph.nodes;
      # INV-G5 修复: in-degree = 依赖数量（自身 edges 的长度）
      inDegrees = builtins.listToAttrs (map (n:
        lib.nameValuePair n (builtins.length (graph.edges.${n} or []))
      ) nodes);
      # 初始队列：in-degree = 0 的节点（无依赖，可以立即处理）
      initQueue = lib.filter (n: inDegrees.${n} == 0) nodes;
    in
    _topoLoop graph inDegrees initQueue [];

  _topoLoop = graph: degrees: queue: result:
    if queue == [] then
      if builtins.length result == builtins.length (builtins.attrNames graph.nodes)
      then result
      else { error = "cycle detected"; }
    else
      let
        current  = builtins.head queue;
        rest     = builtins.tail queue;
        newResult = result ++ [ current ];
        # INV-G5: 使用 revEdges[current] 减少依赖 current 的节点的 in-degree
        dependents = graph.revEdges.${current} or [];
        updatedDegrees = lib.foldl' (acc: dep:
          let
            newDeg = (acc.${dep} or 0) - 1;
          in
          acc // { ${dep} = newDeg; }
        ) degrees dependents;
        newQueue = rest ++ lib.filter (n:
          (updatedDegrees.${n} or 0) == 0 && !(builtins.elem n newResult)
        ) dependents;
      in
      _topoLoop graph updatedDegrees newQueue newResult;

  # ══ 循环检测（DFS，INV-QK5）══════════════════════════════════════════
  hasCycle = graph:
    let topo = topologicalSort graph; in
    builtins.isAttrs topo && topo ? error;

  # ══ 可达性（BFS）════════════════════════════════════════════════════
  reachable = graph: fromId:
    _bfsReachable graph [ fromId ] [ fromId ];

  _bfsReachable = graph: queue: visited:
    if queue == [] then visited
    else
      let
        current = builtins.head queue;
        rest    = builtins.tail queue;
        deps    = graph.edges.${current} or [];
        newDeps = lib.filter (d: !(builtins.elem d visited)) deps;
      in
      _bfsReachable graph (rest ++ newDeps) (visited ++ newDeps);
}
