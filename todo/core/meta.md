整体结构是清晰的：你在这一层把 **语义策略（equality / kind / effect / row / mu）集中成 Meta 控制面**，这是正确的抽象位置。不过 Phase 3 里有几处关键点存在“形式上看似一致，但语义上不闭合”的问题，主要集中在 **equality coherence 实际未被强制执行** 和 **policy 之间存在隐式冲突域**。

下面按“实质问题”拆解。

---

# 1. Equality Coherence Law：当前是“声明”，不是“约束”

你写了：

> structural ⊆ nominal ⊆ hash

但实现层面：

```nix
EqStrategy = {
  structural = "structural";
  nominal    = "nominal";
  referential = "referential";
};
```

以及：

```nix
hashStrategy = HashStrategy.normalized;
```

### 问题本质

你没有在任何地方实现：

- structuralEq / nominalEq / hashEq 的 **单一 reduction pipeline**
- 或 enforce partial order 的 runtime check

目前 coherence law 是 **注释级不变量（doc invariant）**，不是 system invariant。

### 结果

在以下组合中会出现不可控 divergence：

- `nominal + custom normalization depth`
- `structural but non-normalizing repr in hashStrategy`
- `referential + constraints`

### 关键缺口

你缺一个：

> canonical equality dispatcher

建议结构（核心不是实现，而是分层）：

```
eq(a,b) :=
  normalizeToNF(a) == normalizeToNF(b)
```

所有 strategy 只影响：

```
normalization depth / unfolding / opacity
```

而不是 equality semantics 本身。

---

# 2. referential equality 与 hashStrategy 冲突未消解

```nix
opaqueMeta = defaultMeta // {
  eqStrategy = EqStrategy.referential;
};
```

但：

```nix
hashStrategy = HashStrategy.normalized;
```

### 问题

referential equality implies:

- identity-based equality
- 不依赖 NF

但 hash 仍然是 normalized NF hash

### 语义冲突：

| layer        | semantics          |
| ------------ | ------------------ |
| eqStrategy   | pointer / identity |
| hashStrategy | structural NF      |

这会导致：

> eq(a,b)=true 但 hash(a) ≠ hash(b)

直接破坏 INV-4（hash consistency）

### 必须补的约束

你需要显式：

```
if eqStrategy == referential → hashStrategy must == repr OR identity-hash
```

否则系统是“不一致类型系统”。

---

# 3. MuPolicy：coinductive + fuel = 混合语义不闭合

```nix
MuPolicy = {
  fuel = 8;
  coinductive = true;
  guardEnabled = true;
};
```

### 问题本质

你同时启用了：

- bounded unfolding（fuel）
- coinductive bisimulation（guard set）

这两者是两种不同 semantics：

| mode        | semantics               |
| ----------- | ----------------------- |
| fuel        | syntactic approximation |
| coinductive | greatest fixed point    |

### 冲突点

如果：

```
coinductive == true
```

那么：

```
fuel 应该失效或仅用于 termination fallback
```

但你当前没有定义 priority。

### 结果风险

会出现：

- 某些 mu type 在不同路径下 equality 不稳定
- 非 confluence bisimulation result

---

# 4. RowPolicy：rigid rowVarEq 的语义是“半 unification”，但未说明 solver binding

```nix
rowVarEq = "rigid";
```

### 问题

rigid variable equality 实际意味着：

- row variables are **constants in equality domain**
- not unification variables

但你 solver（前面 Phase 3 solver）是：

> worklist + substitution-based

### 缺口

没有说明：

- rowVar 是否参与 substitution closure
- 是否参与 solver propagation

### 风险

会产生：

- row polymorphism 不 complete unification
- pattern mismatch false negatives

---

# 5. EffectPolicy：encoding = row 但缺 effect lattice semantics

```nix
EffectPolicy = {
  encoding = "row";
};
```

### 问题

你定义了 encoding，但没有定义：

- effect join
- effect subtyping relation
- effect normalization rule

目前 Effect 是：

> syntactic row type alias

而不是：

> semantic effect system

### 结果

effect system 目前是：

- type-level annotation system
- not effect inference system

---

# 6. BidirPolicy：subsumption = strict 与 row polymorphism 是张力关系

```nix
subsumption = "strict";
```

但：

- row types inherently require structural subtyping
- effect rows also require extensible subtyping

### 冲突

strict subsumption implies:

```
A <: B only if A == B
```

但 row system requires:

```
{a,b} <: {a}
```

### 当前设计矛盾

你同时启用了：

- row polymorphism
- strict subsumption

这是不可同时成立的。

---

# 7. validateMeta：目前只是 lint，不是 coherence checker

```nix
validateMeta = m:
```

现在它只检查：

- warning级不一致
- 不检查 system invariant violation

### 缺失：

应有：

- eqStrategy ↔ hashStrategy compatibility check
- muPolicy coherence check
- rowPolicy + subsumption consistency check

---

# 总体评价（实质）

这一层现在是：

> “策略集合（policy bag） + 弱约束 lint”

而不是：

> “语义一致性控制层（semantic coherence kernel）”

---

# 建议的最关键修复（优先级排序）

## P0（必须修）

1. 引入 canonical equality pipeline（唯一 eq semantics）
2. hashStrategy 必须依赖 eqStrategy 约束
3. rowVarEq 与 substitution semantics 对齐

## P1（结构性修复）

4. muPolicy 明确：
   - coinductive vs fuel precedence

5. effectPolicy 补 lattice semantics（至少 join + subeffect）

## P2（系统一致性）

6. bidirPolicy 必须与 row subtyping 对齐
7. validateMeta 升级为 invariant checker（不是 lint）

---

# 一句话总结

当前设计的问题不是“策略太少”，而是：

> 你已经有多个完整语义系统（row / mu / effect / equality），但缺少一个统一的 semantic coherence kernel 来约束它们的组合空间。

如果需要，可以下一步直接帮你把这一层重构成：

> single semantic spine + orthogonal policy injection model

这样 Phase 3 会从“配置系统”变成“可证明一致的 type semantics core”。
