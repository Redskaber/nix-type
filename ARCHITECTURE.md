# ARCHITECTURE.md — Phase 3.2

# Nix Type System 架构文档

---

## 总体架构（Phase 3.2）

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                       Nix Type System（Phase 3.2）                           │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐   │
│  │                      TypeIR（统一宇宙）                               │   │
│  │  Type = { tag; id; kind; repr; meta; phase }                          │   │
│  │  Kind = KStar | KArrow | KRow | KEffect | KVar | KUnbound             │   │
│  │  Meta = { eqStrategy; muPolicy; rowPolicy; bidirPolicy; ... }         │   │
│  └───────────────────────────────────────────────────────────────────────┘   │
│         │                    │                    │                          │
│  ┌──────▼──────┐   ┌─────────▼──────┐   ┌─────────▼───────┐                 │
│  │  TypeRepr   │   │   Normalize    │   │  Constraint     │                 │
│  │ (21 变体)   │   │ (TRS, 3-fuel)  │   │  IR (INV-6)     │                 │
│  │ Pi/Sigma    │   │ ruleRowCanon ✅ │   │  Worklist       │                 │
│  │ Effect      │   │ ruleEffNorm  ✅ │   │  Solver         │                 │
│  │ Opaque      │   │ bisimMu      ✅ │   │  _typeMentions  │                 │
│  └──────┬──────┘   └─────────┬──────┘   └─────────┬───────┘                 │
│         │                    │                    │                          │
│  ┌──────▼────────────────────▼────────────────────▼──────┐                  │
│  │                    Meta Layer                         │                  │
│  │  serialize(α-canonical v3) → hash(NF) → equality      │                  │
│  │  Coherence: structural ⊆ nominal ⊆ hash               │                  │
│  │  muEq: bisimulation + guard set ✅                     │                  │
│  │  rowVarEq: rigid name identity                        │                  │
│  └───────────────────────────────────────────────────────┘                  │
│         │                                    │                              │
│  ┌──────▼────────┐   ┌──────────┐   ┌────────▼────────┐                     │
│  │  Incremental  │   │ Instance │   │  Bidirectional  │                     │
│  │  Graph(BFS)   │   │ DB       │   │  Type Checking  │                     │
│  │  Memo(epoch)  │   │ specif.✅│   │  substLib ✅    │                     │
│  └───────────────┘   └──────────┘   └─────────────────┘                     │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 模块依赖图（严格拓扑序，Phase 3.2）

```
kindLib ──────────────────────────────────────────────────────────────┐
serialLib ────────────────────────────────────────────────────────────┤
metaLib ──────────────────────────────────────────────────────────────┤
                                                                      ▼
typeLib ← (kindLib, metaLib, serialLib)                          [typeLib]
reprLib ← (lib)
substLib ← (typeLib, reprLib)                     ← Phase 3.2: bidir 使用
rulesLib ← (typeLib, reprLib, substLib, kindLib)  ← Phase 3.2: ruleRowCanonical
normalizeLib ← (typeLib, reprLib, rulesLib)
hashLib ← (typeLib, normalizeLib, serialLib)
equalityLib ← (typeLib, hashLib, normalizeLib, serialLib)
constraintLib ← (typeLib, hashLib)
unifyLib ← (constraintLib, substLib, serialLib, hashLib)  ← Phase 3.2: bisimMu
instanceLib ← (constraintLib, hashLib, normalizeLib)      ← Phase 3.2: specificity
solverLib ← (constraintLib, unifyLib, instanceLib)        ← Phase 3.2: _typeMentions
bidirLib ← (normalizeLib, constraintLib, unifyLib, reprLib, substLib) ← Phase 3.2
graphLib ← (lib)
memoLib ← (hashLib, constraintLib)
matchLib ← (typeLib, reprLib)
```

---

## Phase 3.2 关键变化

### 1. `_unifyMu` — 真正的 bisimulation

**旧实现（Phase 3.1）**：alpha-canonical 序列化比较（保守近似）

```
serA == serB  →  ok  |  fail
```

**新实现（Phase 3.2）**：guard set + coinductive unfolding

```
unifyMu(guard, a, b, fuel):
  key = min(a.id,b.id) + ":" + max(a.id,b.id)    # symmetric guard key
  if key ∈ guard → ok (coinductive hypothesis)
  if fuel = 0 → fallback alpha-canonical
  guard' = guard ∪ {key}
  unfoldA = substitute(a.var, a, a.body)
  unfoldB = substitute(b.var, b, b.body)
  unifyCore(guard', unfoldA, unfoldB, fuel-1)
```

**覆盖的新情况**：

- `μ(lst.Nil|Cons(Int,lst))` ≡ `μ(list.Nil|Cons(Int,list))`（不同 binder 名）
- 互相递归类型（guard 防止无限展开）
- partial unfolding（fuel 控制深度）

### 2. `ruleRowCanonical` — 完整 spine sort

**旧实现（Phase 3.1）**：no-op（`{ changed = false; type = t; }`）

**新实现（Phase 3.2）**：

```
unspine: RowExtend → [(label, fieldType)] × tail
sort: by label (lexicographic)
rebuild: foldr RowExtend tail sortedFields
```

**关键不变量**（INV-ROW）：

```
typeHash(normalize({ b:Bool | a:Int })) == typeHash(normalize({ a:Int | b:Bool }))
```

### 3. Specificity-based Instance Selection

**旧实现（Phase 3.1）**：lexicographic key 顺序（不稳定语义）

**新实现（Phase 3.2）**：

```
specificity(inst) = |{arg : arg.repr.__variant ≠ "Var"}|

resolve(db, class, args):
  candidates = [e ∈ byClass[class] | args matches e.normArgs]
  best = argmax_{e ∈ candidates} e.specificity  # tie: min key
  return best.impl
```

**示例**：

```
Eq a   → specificity = 0  (泛化)
Eq Int → specificity = 1  (具体，优先)
```

### 4. `_substTypeInType` — substLib 集成

**旧实现（Phase 3.1）**：手写顶层 Var 替换（不完整）

**新实现（Phase 3.2）**：

```nix
_substTypeInType = varName: replacement: ty:
  substitute varName replacement ty;  # substLib.substitute：完整 capture-safe
```

**影响**：dependent type checking（Pi/Sigma application）中 `B[x↦arg]` 完全正确。

### 5. `_applySubstTypeFull` — 完整深层替换

**旧实现（Phase 3.1）**：`_applySubstType` 仅顶层 Var

```
Var → lookup; else → t (pass through)
```

**新实现（Phase 3.2）**：全 21 TypeRepr 变体深层遍历

```
Var    → follow chain
Lambda → body
Pi     → domain + body
Apply  → fn + args
Fn     → from + to
Mu     → body
...（全 21 变体）
```

### 6. `_typeMentions` — freeVarsRepr 全变体

**旧实现（Phase 3.1）**：只检查顶层 Var

```
_typeMentions vars t = t.repr.__variant == "Var" && elem t.repr.name vars
```

**新实现（Phase 3.2）**：`_reprMentions` 递归所有 TypeRepr 变体

```
Lambda → check body (respecting binder)
Pi     → check domain + body (respecting binder)
Apply  → check fn + all args
ADT    → check all variant fields
Record → check all field types
...（全 21 变体）
```

---

## TypeRepr 变体全集（21 个，Phase 3.2）

```
Primitive  { name }                    # 原子类型（Int, Bool, ...）
Var        { name; scope }             # 类型变量
Lambda     { param; body }             # 类型级 λ
Apply      { fn; args }                # 类型级应用
Fn         { from; to }                # 函数类型（语法糖）
Pi         { param; domain; body }     # 依赖函数类型
Sigma      { param; domain; body }     # 依赖对类型
Mu         { var; body }               # 等递归类型（bisimulation）
Constructor{ name; kind; params; body }# 泛型 ADT 构造器
ADT        { variants; closed }        # ADT（closed/open）
Record     { fields; rowVar? }         # Record 类型
VariantRow { variants; tail? }         # Variant row（Effect 使用）
RowExtend  { label; fieldType; rest }  # Row 扩展（canonical = sorted）
RowEmpty   {}                          # 空 Row
Effect     { effectTag; effectRow }    # Effect 类型
Constrained{ base; constraints }       # 约束类型（INV-6）
Opaque     { inner; tag }              # 不透明类型（module sealing）
Ascribe    { inner; ty }               # 类型标注
VarDB      { index }                   # de Bruijn 变量（序列化内部）
```

---

## Constraint IR（Phase 3.2）

```
Constraint =
  Class     { name: String; args: [Type] }         # 类型类约束
| Equality  { a: Type; b: Type }                   # 相等约束（id-ordered）
| Predicate { fn: String; arg: Type }              # 谓词（Liquid Types，Phase 4）
| Implies   { premises: [Constraint]; conclusion }  # 蕴含（sorted premises）

Pipeline（INV-C4）:
  raw → mapTypesInConstraint(subst) → normalizeConstraint → key → hash
```

---

## Normalize Pipeline（Phase 3.2）

```
normalize(t):
  normalize'(defaultFuel, t)

normalize'(fuel, t):
  if !hasDepth(fuel) → t
  else _normalizeStep(fuel, t)

_normalizeStep(fuel, t):
  t' = _normalizeSubterms(fuel.depth-1, t)   # innermost: subterms first
  r  = applyRules(fuel, t')
  if !r.changed → t'                          # NF: no rule applied
  else _normalizeStep(fuel.beta-1, r.type)    # repeat with reduced fuel

applyRules（优先级顺序）:
  1. ruleBetaReduce       # Apply(Lambda, arg) → β-reduce
  2. rulePiReduce         # Apply(Pi, arg) → dependent β-reduce
  3. ruleConstructorFull  # Constructor full application
  4. ruleConstructorPartial # Constructor partial kind fix
  5. ruleConstrainedFloat # Constrained float out
  6. ruleRowCanonical ✅  # RowExtend spine sort（Phase 3.2）
  7. ruleRecordCanonical  # Record field clean
  8. ruleEffectNormalize ✅ # Effect VariantRow sort（Phase 3.2）
  9. ruleMuUnfold         # μ(α).T → T[α↦μ(α).T]（muFuel）
  10. ruleFnDesugar       # Fn → Lambda（默认关闭）
```

---

## Instance Resolution 算法（Phase 3.2）

```
resolveWithFallback(db, classGraph, className, args):
  normArgs = map normalize args

  # Stage 1: Primitive（内建，最高优先）
  if isPrimitive(className, normArgs) →
    return { found=true; impl=primitiveImpl; source="primitive" }

  # Stage 2: Exact match（hash-based key）
  key = instanceKey(className, normArgs)
  if db.instances[key] exists →
    return { found=true; impl=entry.impl; source="db-exact" }

  # Stage 3: Specificity-based（Phase 3.2 新增）
  candidates = [e ∈ db.byClass[className] | argsMatch(normArgs, e.normArgs)]
  if candidates ≠ [] →
    best = argmax_{c ∈ candidates} c.specificity  # tie: min key
    return { found=true; impl=best.impl; source="db-specificity-N" }

  # Stage 4: Superclass resolution
  for subClass ∈ getAllSubs(classGraph, className):
    result = resolveWithFallback(db, classGraph, subClass, normArgs)
    if result.found && result.impl ≠ null →
      return result // { source = "via-superclass(subClass)" }

  return { found=false }

argsMatch(callArgs, instArgs):
  ∀i: instArgs[i] is Var          # 泛化 match
     OR typeHash(callArgs[i]) == typeHash(instArgs[i])  # exact match
     OR same Constructor name     # structural match
```

---

## Bisimulation Unification 算法（Phase 3.2）

```
unifyMu(guard, binders, subst, a, b, fuel):

  # Symmetric guard key（canonical pair）
  key = if a.id ≤ b.id then "${a.id}:${b.id}" else "${b.id}:${a.id}"

  if key ∈ guard:
    return { ok=true, subst }    # coinductive hypothesis

  if fuel ≤ 0:
    # Fallback: alpha-canonical comparison
    if serializeAlpha(a.repr) == serializeAlpha(b.repr):
      return { ok=true, subst }
    else:
      return { ok=false, error="Mu: fuel exhausted" }

  guard' = guard ∪ {key}
  unfoldA = substitute(a.var, a, a.body)   # μ(α).T → T[α↦μ(α).T]
  unfoldB = substitute(b.var, b, b.body)

  # 若 unfold 后仍是 Mu → 递归 unifyMu（减少 fuel）
  # 若 unfold 后非 Mu → 转入 unifyCore（正常结构比较）
  return unifyMuBodies(guard', binders, subst, unfoldA, unfoldB, fuel-1)

Soundness note:
  guard set 保证对任意有限深度的 mu-type 对，算法终止
  coinductive hypothesis 对 equi-recursive semantics 是 sound 的
  fuel 防止无限展开（degenerates to alpha-canonical at limit）
```

---

## Row Canonical Form（Phase 3.2）

```
Canonical form of RowExtend chain:
  { l₁:T₁ | { l₂:T₂ | ... | tail } }  →  sorted by label (lexicographic)

Algorithm:
  unspine({ l:T | rest }) = { fields = [(l,T)] ++ unspine(rest).fields
                             ; tail  = unspine(rest).tail }
  unspine(tail)           = { fields = []; tail = tail }

  canonical(row) =
    let (fields, tail) = unspine(row)
        sorted = sortBy label fields
    in foldr (λ(l,T). { l:T | _ }) tail sorted

Idempotency (INV-ROW):
  canonical(canonical(row)) = canonical(row)
  typeHash(canonical(row_ab)) = typeHash(canonical(row_ba))  # for same field set
```

---

## 不变量总表（Phase 3.2）

| 不变量   | 描述                                              | 验证位置                | Phase 3.2 状态 |
| -------- | ------------------------------------------------- | ----------------------- | -------------- |
| INV-1    | 所有结构 ∈ TypeIR                                 | `lib/default.nix`       | ✅             |
| INV-2    | normalize 终止（split fuel）                      | `normalize/rewrite.nix` | ✅             |
| INV-3    | typeEq = NF-hash（单一路径）                      | `meta/equality.nix`     | ✅             |
| INV-4    | cache key = NF-hash                               | `meta/hash.nix`         | ✅             |
| INV-5    | 依赖追踪 = Graph Edge                             | `incremental/graph.nix` | ✅             |
| INV-6    | Constraint ∈ TypeRepr                             | `constraint/ir.nix`     | ✅             |
| INV-MU   | muEq = bisimulation（guard set）                  | `constraint/unify.nix`  | ✅ **新**      |
| INV-ROW  | ruleRowCanonical 幂等                             | `normalize/rules.nix`   | ✅ **新**      |
| INV-SPEC | specificity-based selection                       | `runtime/instance.nix`  | ✅ **新**      |
| INV-I2   | overlap = partial unification                     | `runtime/instance.nix`  | ✅ **新**      |
| INV-SOL4 | \_applySubstTypeFull（深层替换）                  | `constraint/solver.nix` | ✅ **强化**    |
| INV-SOL5 | \_typeMentions 全变体                             | `constraint/solver.nix` | ✅ **强化**    |
| INV-DEP  | \_substTypeInType = substLib（完整 capture-safe） | `bidir/check.nix`       | ✅ **新**      |
