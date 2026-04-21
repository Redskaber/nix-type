整体结构是合理的：你已经把 instance resolution 分成了 **primitive / DB / superclass fallback** 三段，这是 Phase 3 里比较标准的分层方式。但这份实现里有几处关键语义问题，会直接影响 coherence 与 resolution 正确性。

---

## 1. ❗ `_resolveViaSuper` 是“判定存在”，但不是“解析”

```nix
if found
then { found = true; impl = null; source = "via-superclass"; }
```

### 问题

- 这里只返回 `found = true`，但 `impl = null`
- 这会导致：
  - `resolveWithFallback` 认为命中
  - 但实际无法使用 instance implementation
  - constraint solver 会“假成功”

### 本质 bug

> superclass path 只是 existence check，不是 resolution

### 修正方向

应该返回“具体 sub-class instance 的 impl”，例如：

- 找到第一个有效 sub instance
- 或做 deterministic selection（hash/minimal key）

---

## 2. ❗ superclass 查询方向大概率是反的

```nix
builtins.filter
  (sub: isSuperclassOf classGraph className sub)
```

语义上你在问：

> sub 是否是 className 的子类？

但函数名：

```nix
isSuperclassOf graph a b
```

通常语义是：

> a 是 b 的 superclass

如果如此，那么你现在写的是：

> className ⊇ sub ?

还是：

> sub <: className ?

### 风险

- 一旦方向错，superclass resolution 会：
  - 漏掉合法 instance
  - 或错误继承过多 instance（严重 coherence break）

---

## 3. ❗ coherence check 只覆盖“完全相同 key”，不覆盖 overlap

```nix
if db ? ${key}
```

这是 **exact match coherence**，但 Phase 3 标注：

> INV-I2：overlap instance detection

目前缺失：

### 缺失能力

- overlapping:
  - `Eq a`
  - `Eq Int`

- 或 partially unifiable args

### 当前系统只能抓：

- 完全相同 normalized args

👉 这不是 full coherence，只是 hash collision check

---

## 4. ⚠️ `_instanceKey` 依赖 normalize + typeHash，但缺 canonical guarantee

```nix
normArgs = map normalize args;
argIds   = map typeHash normArgs;
```

风险点：

- `normalize` 是否 canonicalized？（不保证 alpha-equivalence stable）
- `typeHash` 是否 INV-H2/H3 unified？（你之前系统提到过 split risk）

### 典型 failure mode

- α-equivalent type → 不同 hash → duplicate instance not detected

---

## 5. ⚠️ `_resolvePrimitive` 是 hardcoded dispatch，不参与 DB coherence

```nix
if builtins.elem className supported
then { found = true; impl = null; }
```

问题：

- primitive instance **不可扩展**
- 不参与 coherence system
- 不参与 superclass graph

### consequence

- DB + primitive + super 不在同一 resolution lattice
- 会导致“隐式优先级不透明”

---

## 6. ❗ `canDischarge` 忽略 impl，导致 unsound success

```nix
(resolveWithFallback ...).found
```

问题：

- 只检查 found
- 不验证 `impl != null`

但你系统里：

- superclass path 可能 `impl = null`

👉 会导致：

> constraint 被错误 discharge（soundness bug）

---

## 7. ⚠️ `resolveWithFallback` 优先级隐含强序，但 primitive 是 opaque

```nix
prim → db → super
```

问题不是顺序，而是：

- primitive bypass DB coherence
- super bypasses impl existence

这会导致：

> resolution lattice 不是单调的

---

## 8. minor：debug / listInstances 不稳定

```nix
map (key: "${e.className}[${key}] ...")
```

- attrNames order in nix is not guaranteed stable
- list output is non-deterministic

---

# 总体评价

你这个 Phase 3 instance system 已经具备：

- ✔ hash-based keying
- ✔ DB + fallback architecture
- ✔ superclass integration（雏形）
- ✔ primitive short-circuit

但目前问题集中在：

### 关键风险（优先级排序）

1. **superclass resolution 返回 null impl（soundness bug）**
2. **coherence 只做 exact match（不是真 INV-I2）**
3. **canDischarge 忽略 impl validity**
4. **superclass direction ambiguity（可能逻辑反转）**
5. **primitive system 与 DB 不统一 lattice**

---

# 如果要推进 Phase 3 完整性（建议）

最关键的三步：

### ① unify resolution return type

所有 path 必须返回：

```nix
{ found; impl; source; witnessPath? }
```

不能有 `impl = null` 的“假成功”。

---

### ② superclass resolution must _select instance_, not just detect

改为：

- return actual instance entry
- or deterministic best-match

---

### ③ coherence should become overlap check, not key equality

需要：

- unification-based overlap detection（至少 structural unify args）

---

如果你愿意，可以下一步把 **classGraph + isSuperclassOf + instance resolution** 合起来重构成一个“单一 lattice resolver”，那才是 Phase 3 真正收敛点。
