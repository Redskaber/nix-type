整体结构是可运行的 TRS rule layer，但 Phase 3 在语义一致性上仍有几个关键问题，主要集中在 **kind 安全性、row/record canonicalization、以及 Mu/Effect 的归约边界**。

下面按“实质风险点”拆解。

---

# 1. ❗ ruleConstructorPartial：kind 推断是“局部正确，但全局不稳定”

你这里的修复方向是对的：

> 从 KStar 改为 per-parameter kind（INV-K1）

但当前实现仍有两个隐患：

## 问题 A：resultKind 参与 fold 的顺序不匹配语义

```nix
newKind = lib.foldr
  (p: acc: KArrow (p.kind or KStar) acc)
  resultKind
  remainParams;
```

### 风险

- `remainParams` 是“未应用参数”
- 但 `resultKind = kindInferRepr body'.repr` 可能依赖**已应用参数后的 body**
- 这会导致：
  - kind 构造“尾部依赖前缀”
  - 但实际 arrow 构造是“前缀 → 后缀”

👉 结果：**kind 可能在部分应用时不稳定（尤其 higher-kinded constructor）**

## 建议修正（语义对齐）

应该拆成：

- applied prefix kind context
- remaining arrow chain independent of body inference

更稳定形式：

```nix
newKind =
  lib.foldr
    (p: acc: KArrow p.kind acc)
    (kindLib.KPartial resultKind)  # 或 KUnbound hole
    remainParams;
```

或更严格：

> resultKind 不参与 partial constructor kind construction（只用于 full application）

---

# 2. ❗ rulePiReduction：缺少 dependency hygiene（变量 capture 风险）

```nix
body' = substitute pi.param arg pi.body;
```

## 问题

这是 naive substitution，没有显式 alpha-renaming。

### 风险场景

如果：

- `pi.body` 中存在 shadowed binder
- arg 含 free var collision

会破坏 dependent typing coherence。

## 建议

必须保证：

> Π-elim 使用 capture-avoiding substitution

也就是：

```nix
body' = substLib.substituteSafe pi.param arg pi.body;
```

或至少：

- rename binder before substitution if needed

---

# 3. ❗ ruleConstructorUnfold vs Partial：语义不对称

```nix
Apply(Constructor(...), args) → body[params↦args]
```

## 问题

你要求：

```nix
builtins.length r.args == builtins.length r.fn.repr.params
```

这意味着：

- **只有 full saturation 才 unfold**
- partial application 走 constructor partial

### 风险

这会导致：

> constructor 不支持 staged reduction（η-like behavior broken）

在 dependent constructor 体系里，通常需要：

- partial = closure
- full = reduction
- but also **reduction should be monotonic (no branch split)**

---

## 建议（更一致模型）

建议统一：

- Constructor always becomes closure
- full application triggers reduction via same rule path

否则：

- partial / full 两套 semantics 会 drift

---

# 4. ❗ ruleMuUnfold：one-step unfold 语义有“重复替换风险”

```nix
unfolded = substitute muRepr.param mu muRepr.body;
```

## 问题

这里把 `mu` 直接塞回 body：

```text
μp. b[p := μp.b]
```

但你没有：

- guard recursion depth
- or memoized unfolding

### 风险

- infinite normalization loop
- or exponential duplication

---

## 建议（标准 TRS 控制）

必须至少一个：

- fuel-based unfold (你已有，但只在 rule level)
- or structural guarded unfolding:

```nix
if isContractive(muRepr.body) then unfold else stop
```

---

# 5. ❗ ruleRowNormalize：Record canonicalization是“表面排序”

```nix
labels = builtins.attrNames t.repr.fields;
sorted = builtins.sort (a: b: a < b) labels;
```

## 问题

Nix attrset 本身是 unordered，但：

> mkTypeWith (rRecord t.repr.fields ...) 并没有重新排序 fields

### 风险

- normalization step “返回同一 repr”
- 但 canonical form 未真正 enforce

---

## 建议

必须保证：

> Row normalization happens at serialization boundary OR structural rebuild

否则 INV-R1 不成立（row equality non-deterministic）

---

# 6. ❗ ruleEffectNormalize：当前是 no-op（逻辑缺失）

```nix
if v == "Effect" then null
```

## 问题

你在 Phase 3 spec 中声明：

> Effect row canonicalization required

但实际实现：

- 未排序
- 未 flatten
- 未 deduplicate

## 结果

Effect system 在 equality 层是不可靠的

---

## 建议（最小修复）

Effect 应该：

- reduce to row form
- reuse ruleRowNormalize logic

---

# 7. ⚠️ ruleEtaReduction：实现目前不 sound

```nix
args == [ (mkTypeDefault (rVar t.repr.param "") t.kind) ]
```

## 问题

这是 syntactic equality on generated term

### 风险

- eta reduction false negative / false positive
- breaks referential transparency assumption

---

## 建议

必须改成：

- structural match
- free variable check via substitution model
- NOT constructed placeholder equality

---

# 8. applyOneRule：正确但偏“linear priority chain”

当前：

```nix
r1 -> r2 -> r3 ...
```

## 问题

这是：

> first-match-wins deterministic TRS

但 Phase 3 目标更像：

> confluent rewrite system + normalization strategy separation

### 风险

- rule priority artificially encodes semantics
- reduces confluence guarantees

---

## 建议（结构性改进）

建议未来拆为：

- constraint rules
- beta/pi rules
- structural rules
- normalization rules

再做 staged dispatch，而不是 flat chain。

---

# 总体评价

这份 Phase 3 rewrite 已经具备：

- ✔ dependent Pi elimination
- ✔ constructor partial/full split
- ✔ row canonicalization基础结构
- ✔ mu unfolding control
- ✔ constraint merging semantics

但当前主要风险集中在：

### 三个核心不变量尚未完全成立

1. INV-K1（kind stability in partial application）
2. INV-R1（row canonical form actually structural）
3. INV-MU（mu unfolding termination discipline）

---

如果你下一步要推进 Phase 3 收敛，我建议优先顺序是：

1. unify constructor semantics（partial/full collapse）
2. repair Pi/Σ substitution capture safety
3. strengthen row/effect canonicalization to structural normalization
4. add mu contractiveness guard or normalization budget

---

把这一套 rule system 重构成一个：

> confluent, stratified, fuel-bounded normalization engine（Phase 3.1 clean model）

会比现在这版更接近“语义可证明稳定”的 TRS。
