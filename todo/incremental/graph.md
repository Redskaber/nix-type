整体结构是合理的：你已经把 Graph IR 做成了“状态机 + worklist BFS + 双向边索引 + batch propagation”的组合体，且关键不变量（G1–G5）是清晰的。

下面是按“语义正确性 / Nix 实现风险 / 复杂度隐患”三个层面的精确审查。

---

# 1. 关键正确性问题（需要优先修）

## 1.1 `dirtyNodes` 存在逻辑 bug（高风险）

```nix
builtins.filter
  (id: (graph.nodes.${id} or {}).state or "" == NodeState.dirty)
```

### 问题

`or "" == NodeState.dirty` 的绑定优先级是错误的：

实际解析为：

```
(state or "") == NodeState.dirty
```

但你写法在 Nix 中容易被误读为：

```
(state or ("" == NodeState.dirty))
```

这是典型 precedence trap（虽然 Nix 里 `or` 优先级较低，但这里可读性风险仍然很高）。

### 建议修正（语义更稳）

```nix
builtins.filter
  (id:
    let n = graph.nodes.${id} or null;
    in n != null && n.state == NodeState.dirty
  )
  (builtins.attrNames graph.nodes);
```

---

## 1.2 `_kahnBFS` 入度初始化逻辑错误（严重）

```nix
inDegree = lib.foldl'
  (acc: id: acc // { ${id} = builtins.length (graph.edges.${id} or []); })
```

### 问题本质

你把：

```
inDegree = out-degree
```

但 Kahn 算法需要：

```
in-degree = 被多少节点依赖（revEdges）
```

### 正确应为：

```nix
inDegree = lib.foldl'
  (acc: id:
    acc // { ${id} = builtins.length (graph.revEdges.${id} or []); })
  {}
  nodes;
```

否则拓扑排序是**语义错误的 DAG 计算器**。

---

## 1.3 `_kahnBFS` newReady 计算是错误的（连锁 bug）

```nix
newReady = builtins.filter (id: inDegree'.${id} or 0 == 0) rdeps;
```

### 问题

你只检查 `rdeps`，但：

- in-degree 变化传播应该基于 **所有 nodes**
- 当前实现只检查局部邻接

### 后果

拓扑排序会“卡住”或漏节点。

### 正确策略（标准 Kahn）

维护一个 global candidate set：

```nix
newReady =
  builtins.filter (id: (inDegree'.${id} or 0) == 0)
    (builtins.attrNames graph.nodes);
```

或者更高效：

- 使用 queue + decrement trigger（推荐）

---

## 1.4 `addNode` edges 初始化语义不一致（隐性 bug）

```nix
edges = graph.edges // { ${nodeId} = graph.edges.${nodeId} or []; };
```

### 问题

你创建 node 时：

- edges = []
- revEdges = []

但如果 node 已存在 graph.edges，但 node 不存在 graph.nodes：

→ 会造成 **graph structure divergence**

### 建议

强制 single source of truth：

```nix
edges = graph.edges // { ${nodeId} = graph.edges.${nodeId} or []; };
revEdges = graph.revEdges // { ${nodeId} = graph.revEdges.${nodeId} or []; };
```

OK，但应补：

```nix
nodes = graph.nodes // { ${nodeId} = node; };
```

并保证 nodeId 在 edges/revEdges 一致初始化。

---

# 2. 状态机设计评估

## 当前设计：

```
clean → dirty → computing → clean
               ↘ error
error → dirty
```

### 评价

这是一个典型 incremental computation DAG runtime FSM。

### 问题点

#### 2.1 missing recovery semantics

`error → dirty` 允许重试，但：

- 没有 “error provenance”
- 没有 error invalidation propagation

建议至少保留：

```nix
errorMeta = { cause; timestamp; originNode; }
```

否则 debug 成本会上升。

---

#### 2.2 missing “stale-clean” distinction

当前：

- clean = valid
- dirty = invalid

但 incremental graph 通常需要：

```
clean-stale vs clean-valid
```

否则：

- batchUpdate 后 propagation 语义模糊
- caching invalidation 不精确

---

# 3. BFS propagation（INV-G1）分析

## 正确点

- 非递归 worklist ✔
- visited set ✔
- reverse dependency propagation ✔

---

## 3.1 subtle performance issue

```nix
newWork = builtins.filter (id: !(visited' ? ${id})) rdeps;
```

### 问题

这是 O(n²) 潜在结构（attrSet membership check in loop）

### 建议优化

使用 set-style structure：

```nix
visited' = visited // { ${nodeId} = true; };
```

OK，但更关键是：

- worklist 可能重复 append
- 无 priority / dedup queue

建议引入：

```
queueSet = visited ∪ enqueued
```

---

# 4. batchUpdate 语义分析（INV-G3）

## 当前设计：

```
update nodes → collect roots → single BFS propagation
```

### 正确性：✔

这是正确的 “coalesced invalidation model”。

---

## 风险点

### 4.1 data update vs dependency update 混合

你：

```nix
node // { data = ... }
```

但没有：

- edge recomputation
- structural change detection

### 后果

如果 data 改变影响 dependencies：

→ graph 可能不一致（stale edges）

---

# 5. removeNode 顺序（INV-G4）

这一点是正确的：

```
revEdges cleanup → edges cleanup → nodes removal
```

✔ 没问题

但建议：

- add invariant comment：

```
INV-G4: no dangling edge references allowed post-removal
```

---

# 6. 结构级评价（整体）

## 优点

- clear FSM
- correct BFS design (conceptually)
- dual adjacency representation (good for incremental systems)
- batch propagation design is sound
- no recursion (good for Nix evaluation safety)

---

## 核心问题总结（必须修）

1. ❌ Kahn algorithm uses wrong degree direction
2. ❌ topologicalSort newReady logic incorrect
3. ⚠ dirtyNodes precedence/robustness issue
4. ⚠ potential edge/data divergence in batchUpdate
5. ⚠ BFS queue deduplication not enforced

---

# 7. 总体判断

这个 module 已经达到：

> “incremental graph runtime prototype（Phase 3 early alpha）”

但还没有达到：

> “correct incremental evaluation engine”

主要阻塞点不是设计，而是：

- graph algorithms correctness（topo sort + degree model）

---

如果你下一步要做优化，优先级建议是：

1. 修 Kahn in-degree model（最高优先级）
2. 修 topoSort correctness
3. 引入 stable queue set（避免重复 BFS expansion）
4. 再考虑 caching / memo layer integration

---

把这个 graph 升级成：

> “lazy incremental evaluator core（类似 Adapton / Salsa model）”

那一层会直接进入“可复用增量编译/类型系统 runtime”。
