整体结构已经接近“统一语义等价核”，但当前实现仍有几处**会破坏 INV-3 / INV-EQ1 / coinduction soundness** 的隐性问题。这些不是风格问题，而是会导致等价关系不再是良定义关系（尤其是传递性与一致性）。

下面按严重程度拆。

---

# 1. ❌ INV-3 被“策略分支”弱化（仍未完全消除）

### 问题点

```nix
strategyA = metaA.eqStrategy or "structural";
strategyB = metaB.eqStrategy or "structural";

nominalFail =
  (strategyA == "nominal" || strategyB == "nominal")
  && _nominalCheck a b == false;
```

### 结构问题

你当前设计仍然存在：

- equality path 依赖 **pairwise meta.strategy**
- 但 INV-3 要求的是：

> equality must be normalization-invariant, not policy-influenced

### 结果问题

这会导致：

- `typeEq(a,b)` 可能 false
- 但 `typeHash(a) == typeHash(b)` true（或反之在 future normalization tweak 下）

→ **INV-EQ1 被破坏（强等价 ⇒ hash 等价）**

---

### ✔ 修复方向（关键）

策略不能影响“是否比较”，只能影响：

> normalization depth / unfolding policy

必须改为：

```nix
nfEq = _nfHashEq (normalizeWithMeta metaA a)
                 (normalizeWithMeta metaB b);
```

而不是 early reject。

---

# 2. ❌ alphaEq 与 structuralEq 仍然冗余但更严重：语义分裂

```nix
alphaEq = ...serializeReprAlphaCanonical...
structuralEq = _nfHashEq
```

问题不是重复，而是：

> 你现在存在两个 canonicalization pipeline

- alpha pipeline（serializeReprAlphaCanonical）
- normalization pipeline (normalize → repr → serialize)

### 风险

如果：

- normalizeLib 和 serializeLib 不是完全同构函数
- 或 rewrite rules change ordering

则：

> alphaEq ≠ structuralEq（即使 INV-3 claim says they converge）

---

### ✔ 修复原则

必须强制：

```
serializeReprAlphaCanonical(normalize(x)) == normalize(serializeReprAlphaCanonical(x))
```

否则 INV-3 只是“假设成立”。

---

# 3. ❌ nominalEq 实际不是 nominal equality（语义混合）

```nix
nominalEq = a: b:
  _nominalCheck a b && _nfHashEq a b;
```

### 关键问题

你把 nominal equality 定义成：

> name equality AND structural equality

但 nominal equality 在类型系统里通常是：

| 系统       | 定义               |
| ---------- | ------------------ |
| nominal    | name identity only |
| structural | shape equality     |

你现在是：

> nominal = intersection(naming, structural)

这导致：

### 破坏点

- ADT rename-safe property 丢失
- API evolution 不再稳定
- coercion semantics 会变得不可预测

---

### ✔ 正确设计（建议）

拆成三层：

```nix
nameEq
structuralEq
nominalEq = nameEq
```

然后：

```
compatEq = nameEq && structuralEq   # 仅用于 migration check
```

---

# 4. ❌ rowVarEq 已经正确，但与 typeEq 不一致

你这里是正确的：

```nix
ra.rowVar == rb.rowVar
```

但问题是：

> rowEq 是独立系统，不参与 typeEq pipeline

### 风险

- typeEq(a,b) true
- rowEq(a,b) false

→ equality 非 substitution-stable

---

### ✔ 建议

必须 enforce：

```
if repr contains Row => typeEq MUST delegate to rowEq first-class
```

否则违反 substitution congruence：

> INV-EQ stability under context

---

# 5. ❌ muEq coinductive guard set 有 aliasing bug

```nix
guardKey = "${idA}:${idB}";
```

### 问题

这是**ordered pair encoding**，导致：

```
(a,b) != (b,a)
```

但 mu equality 必须 symmetric relation：

> coinductive bisimulation must be symmetric by construction

---

### 后果

- 可能出现：
  - a ~ b true
  - b ~ a false（guard asymmetry under different traversal paths）

---

### ✔ 修复

必须 canonicalize pair:

```nix
guardKey =
  if idA < idB then "${idA}:${idB}"
  else "${idB}:${idA}";
```

否则 muEq 不是 equivalence relation。

---

# 6. ❌ INV-EQ1（hash consistency）仍然“假命题级别依赖”

```nix
typeEq ⟹ typeHash equality
```

但你实际是：

- typeEq = nfHashEq + strategy gating
- hash = serializeReprAlphaCanonical(normalize)

### 问题本质

你没有证明：

```
normalize(a) == normalize(b) ⇒ hash(a) == hash(b)
```

但你在设计中默认它成立。

---

# 7. ⚠ 结构层级虽然 clean，但 coherence check 太弱

```nix
if sEq then nEq else true
```

这不是 partial order check，而是：

> implication check only in one direction

你真正想要的是：

```
structural ⊆ nominal ⊆ hash
```

但你没有验证：

- transitivity of implication closure

---

# 总体评价

当前系统状态：

### ✔ 已正确部分

- μ-equality coinductive skeleton（正确方向）
- rowVar rigid separation（非常关键正确）
- NF-based canonical equality（主干正确）
- de Bruijn α equality 思路正确

### ❌ 关键结构性问题（必须修）

1. equality strategy 仍然影响 decision path（破 INV-3）
2. nominalEq 定义语义错误（混合 equality domain）
3. muEq guard set 非 symmetric（破 coinductive bisimulation）
4. alpha/structural dual pipeline 未收敛证明
5. INV-EQ1 属于“未证明约束”，不是 invariant

---

# 如果下一步要收敛（建议路线）

你现在系统已经到“语义收敛前夜”，建议做三件事：

### 1. collapse equality to single kernel

```
Eq(a,b) := hash(normalize(a)) == hash(normalize(b))
```

所有其他 equality 变成：

- diagnostic
- lint
- proof-check layer

---

### 2. muEq 变成 coinductive _proof checker_，不是 decision procedure

---

### 3. row / nominal / alpha 全部变成 projection views

---

下一步目标是“INV-3 真正可证明”，把这一整套改成：

> **single-kernel equality + derivation lattice（proof-relevant equality system）**

会比现在稳定一个数量级。
