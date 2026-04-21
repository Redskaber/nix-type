整体结构是可工作的“pattern matrix → decision tree”雏形，但在 Phase 3 语义一致性和正确性上存在几类**关键问题**，主要集中在：matrix 约束、变量列绑定语义、ADT 分组一致性、以及 exhaustiveness/redundancy 逻辑偏乐观近似。

下面按模块拆解。

---

# 1. Pattern IR：语义基本正确，但缺少“类型约束边界”

### ✔ 正确点

- `PCtor / PRecord / PVariant / PGuard` 的表达能力是完整的
- `_mkPat` tag 设计清晰
- ordinal dispatch 思路是合理的（ADT compilation）

### ⚠ 问题

#### (1) `pLit` 缺少 equality strategy

```nix
pLit = value: typ: _mkPat "PLit" { inherit value typ; };
```

问题：

- 没有 canonical equality（Phase 3 通常要求 repr-level equality）
- value 可能是非规范化结构（list/record/function）

👉 后果：

- decision tree 无法保证 determinism matching

---

#### (2) `PGuard` 没进入 compilation semantics

```nix
pGuard = pat: guardFn:
```

问题：

- compilePats 完全忽略 guard
- DT 没有 guard node

👉 实际结果：

- guard pattern 等价于“被丢弃的 AST metadata”

---

# 2. Decision Tree IR：结构正确，但不完整

### ✔ 优点

- DTSwitch / DTLeaf / DTFail / DTBind 分层合理
- ordinal dispatch 已考虑

### ⚠ 关键缺失

#### (1) DTBind 未被编译器使用

```nix
dtBind = name: tree: ...
```

但：

- `_compileVarCol` 直接写入 bindings attrset
- 没有 DTBind 节点生成

👉 结果：

- binding semantics 被“flatten”，失去 scope structure

---

#### (2) DT 不是 compositional IR

目前：

- binding / switch / leaf 混合 flatten
- 无 uniform evaluation model

👉 后果：

- 后续 optimization（merge switch / pruning）不可做

---

# 3. compilePats：核心算法存在结构性 bug

## ⚠ (1) matrix encoding 是不正确的

```nix
{ pats = [pa.pat]; action = pa.action; bindings = {}; }
```

问题：

- matrix 本应是 `[PatternRow]`
- 当前只有 1-column matrix
- 多 column matching 根本无法形成

👉 实际：compile 退化为 unary pattern match

---

## ⚠ (2) column head 处理是危险的 partiality

```nix
let firstCol = builtins.head accessPaths;
```

问题：

- accessPaths 可能为空 / 不一致长度
- matrix row pats 可能为空

👉 缺少 invariant：

```
INV-MATRIX-1: 所有 row.pats length == accessPaths length
```

当前未 enforce

---

## ⚠ (3) pattern tag 判断过弱

```nix
builtins.elem "PWild" headTags || builtins.elem "PVar"
```

问题：

- 忽略 PGuard / POr / PVariant
- guard pattern 被当作普通列处理

👉 直接导致：

- 非确定 dispatch

---

# 4. Var column 编译：binding 语义有 bug

```nix
bindings = row.bindings // { ${p.name} = firstCol.access; };
```

### ⚠ 问题 1：access 未 resolve value

- 存的是 `"root"` string path
- 不是真正 AST access path

### ⚠ 问题 2：binding override unsafe

- 若同名 var 重复绑定 → silent overwrite

👉 违反：

```
INV-B1: binding must be unique or shadowed explicitly
```

---

# 5. Constructor compilation：核心结构问题

## ⚠ (1) groupByOrdinal 使用 string key

```nix
ord = toString (p.ordinal or 0);
```

问题：

- ordinal 本应是 Int
- string key 导致 ordering ambiguity

---

## ⚠ (2) wildcard rows handling incorrect

```nix
p.__patternTag == "PWild" || PVar
```

问题：

- wildcard row still enters ctor grouping
- should be fallback, not branch participant

👉 当前实现会：

- duplicate evaluation subtree

---

## ⚠ (3) \_expandCtorRows 不一致

```nix
fPats = if p.__patternTag == "PCtor" then p.fields else [];
```

问题：

- p.fields 不是 normalized pattern list（缺 mkFieldPat guarantee）

---

# 6. Exhaustiveness check：过度近似

## ADT case：

```nix
covered = _coveredCtors pats;
missing = filter (n: !covered ? ${n})
```

### ⚠ 问题 1：覆盖判断错误

```nix
covered ? ${n}
```

- attribute set membership check incorrect
- should be `builtins.hasAttr`

---

### ⚠ 问题 2：忽略 nested patterns

- POr / PGuard / PVariant 未参与 coverage
- wildcard collapses semantics too aggressively

👉 结果：

- false positives in exhaustiveness

---

### ⚠ 问题 3：row types / variant ignored

```nix
else = wildcard check only
```

👉 Phase 3 应该至少区分：

- record open
- variant open
- unknown type

---

# 7. Redundancy check：逻辑过弱 + false negatives

## 当前逻辑：

```nix
prev.__patternTag == "PWild"
|| PVar
|| same ctorName
```

### ⚠ 问题 1：没有 specificity ordering

例：

```
Ctor A(x)
Ctor A(_)
```

当前不会识别 redundancy（但实际上第二个可能 redundant）

---

### ⚠ 问题 2：未考虑 POr flattening

- POr 会绕过覆盖逻辑
- guard pattern 完全忽略

---

### ⚠ 问题 3：顺序依赖过强

- redundancy = prefix-based
- 不是真正 coverage-based analysis

---

# 8. 最大结构问题（总结）

## ❗ 核心设计缺陷

### ① Matrix abstraction不完整

当前：

```
List Pattern per row (flat)
```

应为：

```
Matrix[ row: Vector Pattern ]
```

否则 column reasoning 不成立

---

### ② DT 和 Pattern IR 解耦不完全

- bindings 被 inline map
- 没有 IR-level binding node propagation

---

### ③ exhaustiveness 是 heuristic，不是 logical solver

- 没有 type-driven pattern semantics
- 没有 row/variant openness reasoning

---

### ④ guard / or / variant 是“语法存在”，不是 semantic participant

---

# 9. 如果要修（Phase 3 正确方向）

只列关键修复点：

### 必修 1

- 引入 `PatternMatrix = { rows, cols invariant }`

### 必修 2

- DTBind 必须进入 tree IR（不能 flatten）

### 必修 3

- exhaustiveness 改为 type-directed lattice reasoning（ADT / Row / Variant separate domain)

### 必修 4

- redundancy = coverage inclusion test（not prefix test）

---

# 结论

当前实现属于：

> **“working prototype-level decision tree compiler”**

但不是 Phase 3 语义完整版本。

核心问题不在实现细节，而在：

- matrix 结构不满足 multi-column invariant
- exhaustiveness / redundancy 仍是 heuristic scan
- DT IR 未闭合（binding flattening 是关键设计退化点）

---

如果你下一步要做 Phase 3 收敛，我建议优先补三件事：

1. matrix invariant（这是根问题）
2. DTBind 语义恢复（scope model）
3. ADT exhaustiveness type-driven solver

可以再往 Phase 4（优化 + coverage lattice）走。
