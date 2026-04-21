整体来看，这一版 `constraint/ir.nix` 已经进入“可用于 Phase 3 上层推导”的形态，但仍存在几处**结构性不一致 + 语义泄漏点**，会直接影响 INV-C1~C4 的严格成立。

下面按问题严重度分层审计。

---

# 1. 🚨 关键正确性问题（会破坏 INV-C1 / C2 / C4）

## 1.1 `_sortConstraints` 与 `constraintKey` 不一致风险

```nix
_sortConstraints = cs:
  builtins.sort (a: b: constraintKey a < constraintKey b) cs;
```

但：

```nix
constraintsHash = cs:
  let
    dedup  = deduplicateConstraints cs;
    keys   = builtins.sort (a: b: a < b) (map constraintKey dedup);
```

### 问题

这里存在**两种排序语义**：

- `_sortConstraints`: 用 `constraintKey`
- `constraintsHash`: 用 string 直接排序

这在理论上破坏：

- INV-C2（集合语义一致性）
- INV-C4（normalize 幂等性依赖 canonical order）

### 后果

同一 constraint set：

```text
normalize → merge → hash
```

可能产生：

- sort order mismatch
- hash instability（尤其 Class args）

### 修复建议（唯一标准化）

统一为：

```nix
sortByKey = cs: builtins.sort (a: b: constraintKey a < constraintKey b) cs;
```

然后：

- `_sortConstraints`
- `constraintsHash`
- `mkImplies`

全部复用同一个函数

---

## 1.2 `Implies` key 拼接存在字符串污染 bug

```nix
"Imp:[${builtins.concatStringsSep ";""  premKeys}]→${conclKey}"
```

### 问题

这里明显有 syntax/logic defect：

- `";""  premKeys` → 多余字符串断裂
- 造成 key 非 deterministic（取决于 eval parser behavior）

### 更严重问题

即便修复 syntax：

```nix
premKeys = builtins.sort (a: b: a < b)
```

你在 hash key 中使用：

- sorted string
- but premises themselves are already canonical objects

👉 这属于 **double canonicalization mismatch**

### 建议

统一：

```nix
Imp:${builtins.concatStringsSep "|" premKeys}->${conclKey}
```

避免 `;` / `→` 混淆 encoding layer

---

## 1.3 `normalizeConstraint` 中 Implies conclusion 逻辑错误

```nix
normConclusion = mapTypesInConstraint f (c.conclusion or c);
```

### 问题

这里 fallback：

```nix
c.conclusion or c
```

意味着：

> 如果 conclusion 不存在，用整个 constraint 代替 conclusion

这是**类型错误 + semantic collapse**

### 后果

- Implies 可能自引用
- 或变成 recursion folding bug

### 修复

必须强约束：

```nix
assert c ? conclusion;
```

或者：

```nix
normConclusion = normalizeConstraint c.conclusion;
```

---

# 2. ⚠️ 结构性问题（影响 Phase 3 可扩展性）

## 2.1 `_mkC` 没有 invariant tagging

```nix
_mkC = tag: fields: { __constraintTag = tag; } // fields;
```

### 问题

没有：

- version stamp
- normalization stamp
- canonical id hook

### 后果

Phase 4（incremental / memo）会无法 diff constraint shape

### 建议增强

```nix
{
  __constraintTag = tag;
  __constraintVersion = 3;
}
```

---

## 2.2 `constraintKey` fallback 用 JSON hash（危险）

```nix
else "?c:${builtins.hashString "md5" (builtins.toJSON c)}";
```

### 问题

这违反 Phase 3 核心目标：

- “no toJSON dependency”

但这里**仍然使用 toJSON**

### 后果

- order dependent
- attrSet order leak
- row types / mu types 会不稳定

### 建议

必须改为：

- structural fallback hash
- 或 explicit error（更安全）

推荐：

```nix
else throw "Unsupported constraint form in key"
```

---

## 2.3 `deduplicateConstraints` O(n) 实际是 O(n log n)

```nix
listToAttrs (map ...)
```

### 问题

依赖 attrSet merge semantics：

- key collision resolution
- attrSet construction cost

### 更重要问题

dedup 依赖 `constraintKey` string equality

→ 如果 key 逻辑变动，会 silently corrupt set

### 建议

Phase 3 应该升级为：

- stable hash map abstraction
- 或 explicit fold-based set

---

# 3. 🟡 语义一致性问题（INV-C3/C4边界）

## 3.1 `mapTypesInConstraint` vs `normalizeConstraint` 双系统

当前存在两套 transformation：

- normalizeConstraint（structure-level）
- mapTypesInConstraint（type-level）

### 问题

没有 composition law：

```text
normalize ∘ subst != subst ∘ normalize
```

### 风险

- constraint rewriting pipeline 非幂等
- solver stage ordering sensitive

### 建议

引入统一入口：

```nix
normalizeConstraint ∘ mapTypesInConstraint f
```

并 enforce ordering invariant：

> ALWAYS substitute before normalize

---

## 3.2 Class graph recursion不 tail-safe

```nix
lib.any (isSuperclassOf graph super) supers;
```

### 问题

- exponential recursion risk
- no visited set

### 风险

Phase 3 typeclass depth 深时 stack blowup

---

# 4. 🟢 设计亮点（这一版是合理的）

这些是结构正确的部分：

### ✔ Equality canonicalization（很好）

```nix
idA <= idB
```

→ 保证 symmetric equality

---

### ✔ Implies sorting

premises sorted before construction

→ good IR invariant

---

### ✔ Constraint IR tag system

```nix
__constraintTag
```

→ clean algebraic encoding

---

### ✔ Separation of concerns

- IR
- normalization
- substitution stub
- class graph

→ architecture正确

---

# 5. 总体结论

这一模块目前处于：

> 🟠 Phase 3 early-stable（但未达 strict canonical correctness）

核心风险集中在：

### ❗ 必修复三点

1. `_sortConstraints` 与 hash ordering 不一致
2. `toJSON` fallback（违反 Phase 3 canonical principle）
3. `Implies conclusion fallback bug`

---

# 如果继续推进 Phase 3

下一步应该做的是：

### A. 引入统一 canonical pipeline

```
Constraint
  → normalizeConstraint
  → mapTypesInConstraint
  → deduplicate
  → key
  → hash
```

### B. 消灭所有 implicit serialization

- 禁止 toJSON
- 禁止 attrSet order dependency

### C. 引入 constraint algebra law tests

- commutativity (Eq)
- idempotence (normalize)
- associativity (merge)

---

如果你下一步是 Phase 3 → Phase 4（incremental solver），建议优先修：

> constraintKey + normalizeConstraint ordering consistency

否则 memo layer 会出现不可解释 cache miss。
