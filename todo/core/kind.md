整体设计是“可用但有几个关键语义断点”，主要问题集中在 **Kind 层一致性定义、unify 语义、以及 normalize / inference 的闭环不完整**。按严重程度拆。

---

## 1. 关键不一致：`KUnbound` 被过度“宽容化”（破坏 INV-K3/INV-K4 交界）

### 当前行为

- `kindEq`：

```nix
else if va == "KUnbound" then true
```

- `kindUnify`：

```nix
else if va == "KUnbound" then { ok = true; subst = subst; }
```

### 问题

这等价于：

> KUnbound ≡ wildcard kind

但你同时声明：

> INV-K3: KUnbound 仅出现在推断过程中，最终结果不含 KUnbound

这两个是冲突的。

### 后果

- unify 会“吞掉约束”
- kindEq 变成非对称逻辑（KUnbound == anything）
- inference 无法收敛到 KStar/KArrow 等正规形式

### 建议修正（核心）

把 KUnbound 分成两个概念：

```nix
KUnbound   # meta-variable (unified later)
KHole      # truly unknown placeholder
```

或者至少：

- `KUnbound ≠ wildcard`
- unify 时必须生成 substitution，而不是直接 accept

---

## 2. unify 设计问题：没有“occurs substitution propagation”

当前：

```nix
{ ok = true; subst = subst // { name = b'; }; }
```

### 问题

你没有做：

- substitution closure
- transitive propagation into existing bindings

例如：

```
α := β
β := KStar
```

你不会自动得到：

```
α := KStar
```

### 影响

- normalize 依赖隐式 chase（目前是 partial）
- kindEq / kindUnify 不一致
- INV-K5（KVar 链消除）无法保证 global correctness

---

## 3. `kindNormalize` 是“局部 chase”，不是 closure

```nix
if bound != null && !kindEq bound k
then kindNormalize subst bound
```

### 问题

只 chase 单链，没有：

- path compression
- substitution expansion inside whole subst environment

### 正确模型应该是：

- DSU-style path compression
- 或 full substitution closure pass

否则：

```
a -> b -> c -> KStar
```

会在不同调用路径产生不同结果（非 canonical）

---

## 4. `kindEq` 对 KArrow 是 OK，但缺 canonical normalization 前置条件

```nix
else if va == "KArrow" then kindEq a.from b.from && kindEq a.to b.to
```

### 问题

没有保证：

- a/from/b/from 已 normalize

你依赖 caller，但：

- kindEq 被直接用在 unify 前
- unify 又依赖 kindEq

→ potential semantic circularity

---

## 5. `kindInferRepr` 有结构性不完备

### 关键问题点

#### (1) Lambda case 直接丢信息

```nix
KArrow KUnbound (kindInferRepr repr.body.repr)
```

问题：

- 参数 kind 被丢失
- 不做 binder kind environment

→ 这是 _System Fω 风格 kind inference 断裂点_

---

#### (2) Apply case 过弱

```nix
if fk.__kindVariant == "KArrow"
then fk.to
else KUnbound
```

问题：

- 没有 unify function kind argument
- 没有 partial application handling

---

## 6. INV-K4（pure unify）是正确的，但实现仍“隐式依赖 mutation-like pattern”

```nix
subst // { ${a'.name} = b'; }
```

在 Nix 语义里是 immutable，但：

- 逻辑上没有 “composition normalization step”
- 仍然是 _shallow overwrite model_

建议引入：

```nix
composeSubst : σ → σ → σ
normalizeSubst : σ → σ
```

否则 unify 是“非标准 Robinson variant”。

---

## 7. Row / Effect kind 是 placeholder，但未绑定语义域

```nix
KRow
KEffect
```

当前：

- kindEq 直接 true
- unify 直接 accept

这意味着：

> Row 和 Effect 是 atomic kinds

但你又定义：

> Row Polymorphism + Effect System

这在 Phase 3 目标上是不够的。

建议至少预留：

- `KRowVar`
- `KEffectVar`
- 或 row constraint system

否则后面 constraint solver 会崩在 kind layer。

---

## 8. 最严重的架构问题：kind system 和 type system 解耦不彻底

```nix
kindInferRepr = repr:
  ...
  KUnbound
```

问题：

- type inference 没有 feeding kind constraints back
- kind system 是“post hoc guesser”，不是 constraint participant

结果：

> kind system 是 annotation checker，不是 inference engine

---

## 总体评价（工程视角）

### 优点

- KArrow / KStar / KRow / KEffect 结构清晰
- unify 是纯函数（设计正确方向）
- serializeKind deterministic（很好）

### 核心问题（优先级排序）

1. ❌ KUnbound 语义错误（会破坏整个 inference consistency）
2. ❌ substitution 没 closure（导致非 canonical）
3. ❌ normalize 不是 DSU / fixpoint
4. ❌ kindInferRepr 不支持真正 higher-order kind inference
5. ⚠ Row/Effect 被过早 atomic 化

---

## 如果要修到 Phase-3 稳定版本，最小补丁是：

- 拆 KUnbound → MetaVar / Hole
- unify 改为 full substitution composition
- normalize 改 path compression
- kindInferRepr 加 environment passing
- Row/Effect 至少引入 Var 版本

---

如果你下一步是接 solver / constraint IR，这个 kind 层现在是“能跑，但不保证 global confluence”。
