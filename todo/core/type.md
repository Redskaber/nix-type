整体结构是自洽的，但这里存在几个**关键语义风险点 + Phase 3 不变量潜在破坏面**，主要集中在 identity、lens 更新语义、以及 meta/phase 漂移。

下面按优先级拆。

---

## 1. 🔴 INV-T2：stableId 与 repr 不一致风险（最关键）

### 当前问题

```nix
withRepr = t: repr:
  _mkType (stableId repr) repr t.kind t.meta;
```

问题在于：

- stableId 只依赖 `repr`
- 但 `meta` 没参与 hash
- 但 meta 可能影响 equality / normalization / constraints

### 结果

同一 repr + 不同 meta：

```text
t1 = (repr, metaA)
t2 = (repr, metaB)
```

➡️ **id 冲突（INV-T2 被语义破坏）**

因为：

> id = H(serialize(repr))
> 不包含 meta

但 Type equality 在 Phase 3 是：

> typeEq 走 meta 策略（INV-T3）

### 后果

- hash-eq ≠ semantic-eq
- memoization cache 命中错误
- constraint solver 可能 collapse 不同 policy 类型

### 建议修复（两种选一）

#### 方案 A（推荐）：meta-stratified hash

```nix
stableId = repr: meta:
  hashString "sha256" (_serialize repr + serializeMeta meta);
```

#### 方案 B（保守）：只 hash repr，但禁止 meta 影响 identity

需要强约束：

> INV-M1: meta must be non-identity-affecting

当前系统明显**不满足这个条件**，所以不推荐。

---

## 2. 🔴 withKind 违反 lens 语义（结构不一致）

```nix
withKind = t: kind:
  let safeKind = ...
  in t // { kind = ... };
```

### 问题

- ❌ 不更新 id
- ❌ 不更新 stable identity
- ❌ 不更新 phase consistency（隐含）

但 mkType 系统认为：

> Type identity = id + repr + kind + meta

现在：

```text
withKind breaks identity coherence
```

### 影响

- typeEq(t, withKind(t,k)) ≠ true（但直觉上应该 true）
- cache inconsistency
- solver sees phantom mutation

### 修复策略

#### Option 1（严格一致性）

```nix
withKind = t: kind:
  _mkType t.id t.repr (normalizeKind kind) t.meta;
```

#### Option 2（弱 lens语义）

明确写 invariant：

> withKind does NOT preserve identity

但这会污染 equality system，不推荐。

---

## 3. 🟠 phase 字段存在“隐式漂移”

```nix
phase = safeMeta.phase or 3;
```

### 问题

phase 来源：

- meta.phase
- fallback = 3

但：

- mkBootstrapType → defaultMeta
- defaultMeta.phase 未保证存在

### 风险

- bootstrap type phase 不稳定
- cross-phase serialization bug

### 建议

强制：

```nix
phase = meta.phase;
```

并在 meta 层保证 defaultMeta.phase = 3（或明确 bootstrap phase = 0）

---

## 4. 🟡 isTypeStrict 语义过强但不一致

```nix
isKind t.kind
isMeta t.meta
```

问题：

- isType 允许 weak validity
- isTypeStrict 进入 strong validity

但：

> \_mkType 允许 KUnbound fallback

导致：

```text
isTypeStrict(t) can be false for valid constructed Type
```

这不是错误，但：

➡️ 会导致 debug / solver split behavior

建议明确分层：

- isType (structural)
- isTypeWellFormed (semantic)
- isTypeStrict (canonical)

现在命名混淆。

---

## 5. 🟢 正确设计点（结构是好的）

以下是系统中做对的部分：

### ✔ stableId 放在 core/type 层是正确的

避免散落 hash 逻辑。

### ✔ KUnbound 替代 null（INV-T1）

这是正确的 totality modeling。

### ✔ repr/meta/kind 三分结构清晰

这是 Phase 3 的核心抽象，设计是成立的。

### ✔ validateType 明确 violations model

很好，适合 solver debug pipeline。

---

## 结论（关键修复顺序）

必须优先修：

### P0（语义正确性）

1. stableId 不包含 meta（或明确 meta invariant）
2. withKind 不更新 identity（或改为 full reconstruction）

### P1（系统一致性）

3. phase 来源规范化
4. isTypeStrict 分层语义

---

如果你下一步要推进 Phase 3 solver / memo / constraint IR，这个文件里的 **identity coherence（stableId + lens）问题会直接放大成全局 cache corruption**。
