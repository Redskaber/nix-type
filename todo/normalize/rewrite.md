这份 `normalize/rewrite.nix` 在 Phase 3 结构上已经接近“可验证 TRS evaluator”，但仍有几个关键语义风险点，会直接影响你标出来的 INV-2 / INV-NF1 / INV-NF2 是否真的成立。

我按“会破坏不变量的程度”来拆。

---

# 1. ❌ 最严重问题：fuel 语义并不保证终止（INV-2 不成立）

你现在的终止条件：

```nix
if fuel <= 0 then t
```

这只能保证**外层递归停止**，但不能保证：

### 问题点 A：子项 step 使用 (fuel - 1)

```nix
step = _normalizeStep (fuel - 1) muFuel eta;
```

这会导致：

- 子树深度递归也消耗 fuel
- 顶层 rewrite 也消耗 fuel
- 但没有“结构深度 vs rewrite 步数”的分离

结果：

> 对于深 AST + 少量 β-reduction loop 的项，fuel 会被“结构遍历”耗尽，而不是“归约过程”耗尽

### 影响

- INV-2（normalize terminates）成立，但变成**trivial termination**
- NF correctness 被削弱（可能中途停在非 normal form）

---

### 建议修正（关键）

引入双 fuel：

```nix
{
  rewriteFuel,
  depthFuel
}
```

- depthFuel：结构递归预算
- rewriteFuel：规则应用预算

---

# 2. ❌ applyOneRule 后没有 canonicalization barrier（破坏 INV-NF1）

当前流程：

```nix
t1 = _normalizeSubterms ...
result = applyOneRule muFuel eta t1;
```

问题：

> applyOneRule 可能引入 β-redex / Mu unfolding / row extension 新结构，但你没有重新 normalize 子结构完整 closure

你现在是：

```
subterms normalize → rule → recurse whole
```

但缺少：

### ❗ “rule result 再次 subterm normalization closure”

---

### 影响

INV-NF1：

> isNormalForm(normalize(t)) = true

不成立原因：

- rule 可能创建新 redex
- 但你 rely on next recursion step，而不是 closure fixpoint

---

### 建议（标准 TRS pipeline）

改成：

```text
normalize = fixpoint(
  normalizeSubterms ∘ applyOneRule ∘ normalizeSubterms
)
```

或更严格：

```text
normalize = fixpoint(
  λt. normalizeSubterms (applyOneRule (normalizeSubterms t))
)
```

但必须保证：

> applyOneRule 输出立即进入 subterm normalization closure

---

# 3. ⚠️ NF 检测是“弱 NF”（与 normalize 不一致）

```nix
isNormalForm = t:
  applyOneRule _defaultMuFuel false t == null;
```

问题：

### ❗ NF 判定忽略 eta / muFuel / context

但 normalizeWith 是：

```nix
applyOneRule muFuel eta t
```

而 NF 用：

```nix
muFuel = _defaultMuFuel
eta = false
```

### 影响

你实际上定义了两个不同系统：

| 系统         | NF定义            |
| ------------ | ----------------- |
| normalize    | parameterized TRS |
| isNormalForm | fixed TRS         |

---

### 结果

INV-NF2（idempotence）风险：

```nix
normalize(normalize(t)) == normalize(t)
```

在不同 config 下**不成立**

---

### 修复方式

NF must be parametric:

```nix
isNormalFormWith = config: t:
  applyOneRule config.muFuel config.eta t == null;
```

---

# 4. ⚠️ Mu recursion 处理缺少 guarded unfolding（潜在 non-termination loop）

你：

```nix
else if v == "Mu" then
  let body' = step t.repr.body; in
  mkTypeWith (rMu t.repr.param body') ...
```

问题：

- 没有 muFuel decrement
- 没有 guarded unfolding check

但你 config 有：

```nix
muFuel
```

却完全没用在 Mu 分支

---

### 影响

- μ-types unfolding 可能绕过 fuel 控制
- 违反 Phase 3 的 equi-recursive safety assumption

---

### 修复建议

```nix
Mu => muFuel - 1 guard
```

---

# 5. ⚠️ Row / Variant 结构存在 eager full traversal + inconsistent depth budget

```nix
map step
lib.mapAttrs (_: step)
```

问题：

- row fields & variants 使用 full recursive step
- 但不是 fuel-aware uniform traversal
- depth budget consumption不对称

---

# 6. ⚠️ eta flag 完全未使用（dead parameter）

```nix
eta = config.eta or false;
```

但：

- Lambda eta-reduction 没实现
- Fn eta equality 没实现
- Pi/Sigma eta 没实现

---

结果：

> η is fake parameter → config space misleading

---

# 7. ⚠️ normalize is not confluent-by-construction (隐含风险)

你依赖：

```nix
applyOneRule
```

但没有 guarantee：

- leftmost / innermost deterministic strategy
- rule priority ordering

因此：

> INV-NF2 幂等性 depends entirely on rulesLib correctness

---

# 总体评价（工程语义）

这个文件的 Phase 3 状态：

### 已正确部分

- ✔ bottom-up rewrite architecture
- ✔ explicit fixpoint iteration
- ✔ structural recursion on AST
- ✔ NF deep check存在

### 关键风险点（必须修）

1. fuel conflation（深度 vs rewrite）
2. rule closure 不完整（NF1 风险）
3. NF definition 不 parametric（NF2 风险）
4. Mu fuel 未使用（soundness bug）
5. eta dead config
6. potential non-confluence hidden in rulesLib

---

# 如果要升级到“真正 Phase 3 stable TRS kernel”

你需要至少三条结构性改造：

### ① split fuel system

```
rewriteFuel
depthFuel
muFuel
```

### ② closure-based normalization

```
step = closure(normalizeSubterms → rule → normalizeSubterms)
```

### ③ parametric NF

```
isNF(config, t) == normalize(config, t) == t
```

---

下一步直接把这一版改成：

> **confluent + fuel-typed + strongly normalizing TRS kernel (Phase 3B)**

那会是一个完全不同等级的系统。
