# ARCHITECTURE.md — Phase 3

# Nix Type System 架构文档

---

## 总体架构（Phase 3）

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Nix Type System（Phase 3）                      │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    TypeIR（统一宇宙）                        │   │
│  │  Type = { tag; id; kind; repr; meta; phase }                 │   │
│  │  Kind = KStar | KArrow | KRow | KEffect | KVar | KUnbound    │   │
│  │  Meta = { eqStrategy; muPolicy; rowPolicy; bidirPolicy; ... }│   │
│  └──────────────────────────────────────────────────────────────┘   │
│           │                  │                  │                   │
│    ┌──────▼──────┐   ┌───────▼──────┐   ┌───────▼──────┐            │
│    │  TypeRepr   │   │   Normalize  │   │  Constraint  │            │
│    │(20 variants)│   │  (TRS, fuel) │   │  IR (INV-6)  │            │
│    │  Pi/Sigma   │   │  11 rules    │   │  Worklist    │            │
│    │  Effect     │   │  Unified     │   │  Solver      │            │
│    └──────┬──────┘   └──────┬───────┘   └──────┬───────┘            │
│           │                 │                  │                    │
│    ┌──────▼──────────────────▼───────────────────▼──────┐           │
│    │              Meta Layer                            │           │
│    │  serialize(α-canonical v3) → hash(NF) → equality   │           │
│    │  Coherence Law: structural ⊆ nominal ⊆ hash        │           │
│    │  muEq: bisimulation + guard set                    │           │
│    │  rowVarEq: rigid name identity                     │           │
│    └────────────────────────────────────────────────────┘           │
│           │                                    │                    │
│    ┌──────▼──────┐                    ┌────────▼────────┐           │
│    │  Incremental│                    │  Bidirectional  │           │
│    │  Graph(BFS) │                    │  Type Checking  │           │
│    │  Memo(epoch)│                    │  check / infer  │           │
│    └─────────────┘                    └─────────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 模块依赖图（严格拓扑序）

```
kindLib ─────────────────────────────────────────────────────────────┐
metaLib ─────────────────────────────────────────────────────────────┤
reprLib ─────────────────────────────────────────────────────────────┤
serialLib ───────────────────────────────────────────────────────────┤
                                                                     │
typeLib ← {kindLib, metaLib, serialLib} ─────────────────────────────┤
substLib ← {typeLib, reprLib} ───────────────────────────────────────┤
rulesLib ← {reprLib, substLib, kindLib, typeLib} ────────────────────┤
normalizeLib ← {typeLib, reprLib, rulesLib, substLib, kindLib} ──────┤
hashLib ← {serialLib, normalizeLib, typeLib} ────────────────────────┤
eqLib ← {typeLib, normalizeLib, serialLib, metaLib} ─────────────────┤
constraintLib ← {lib} ───────────────────────────────────────────────┤
unifyLib ← {reprLib, typeLib, serialLib} ────────────────────────────┤
solverLib ← {constraintLib, unifyLib} ───────────────────────────────┤
graphLib ← {lib} ────────────────────────────────────────────────────┤
memoLib ← {hashLib} ─────────────────────────────────────────────────┤
matchLib ← {typeLib, reprLib} ───────────────────────────────────────┤
instanceLib ← {typeLib, hashLib, constraintLib, normalizeLib} ───────┤
bidirLib ← {typeLib, normalizeLib, constraintLib, unifyLib, reprLib} ┘
```

---

## 核心数据流

### 1. 类型构造 → 规范化 → 缓存

```
User构造 TypeRepr
    │
    ▼
mkTypeWith(repr, kind, meta)
    │ stableId = H(serializeAlpha(repr))  ← INV-T2
    │
    ▼
normalize(t)  ← fuel-bounded TRS
    │ 11 rules: constraint-float/merge, β, π, constructor, mu, row, effect
    │
    ▼
nfHash(nf) = H(serializeAlpha(nf.repr))  ← INV-H2
    │
    ▼
memoKey = typeHash = nfHash∘normalize  ← INV-H3（单一来源）
```

### 2. Equality（Coherence Law）

```
typeEq(a, b)
    │
    ├─ fast path: a.id == b.id → true
    │
    ├─ nominal check（若 strategy = nominal）
    │   ADT name / Constructor name 相同？
    │
    └─ NF-hash equality（所有路径最终到此，INV-3）
        normalize(a) → nfHash → == nfHash(normalize(b))

Coherence Law（INV-EQ2）：
    structural ⊆ nominal ⊆ hashEq
    （不允许反向）
```

### 3. Bidirectional Type Checking

```
Term
 │
 ├─ check(ctx, term, typ) → CheckResult
 │   - λx.e + Fn(A,B)  → check body with x:A
 │   - λx.e + Pi(x:A,B)→ check body with x:A, B[x↦x]
 │   - otherwise         → infer(term) + subtype check
 │
 └─ infer(ctx, term) → InferResult
     - TVar   → ctx.lookup
     - TAscribe → check + return annot type（mode switch）
     - TApp   → infer fn + check arg
     - TLam   → fresh type vars + check body
```

### 4. Constraint Solving（Worklist）

```
[Constraint]
    │
    ▼ dedup + normalize
[Constraint]  ──→  Worklist
                      │
                  ┌───▼──────────────────────────────┐
                  │ Process head:                    │
                  │   Equality → unify → new subst   │
                  │   Class    → discharge / residual│
                  │   Implies  → discharge premises  │
                  │                                  │
                  │ INV-SOL4: apply subst to rest    │
                  │ INV-SOL5: requeue affected       │
                  └──────────────────────┬───────────┘
                                         │ fuel--
                                         ▼
                                    (repeat until empty)
                                         │
                                    { subst; residual }
```

---

## Kind 系统（Phase 3 完整）

```
KindRepr =
  KStar         # * — 具体类型
| KArrow k₁ k₂  # k₁ → k₂ — 类型构造器
| KRow          # Row kind（Record/VariantRow spine）
| KEffect       # Effect kind（algebraic effects）
| KVar name     # 推断过程变量
| KUnbound      # 待推断占位符
| KError msg    # kind 检查错误

# 别名
KStar1        = KArrow KStar KStar           # Functor, Maybe
KStar2        = KArrow KStar KStar1          # Either, Pair
KRowToStar    = KArrow KRow  KStar           # Record 构造器
KEffToStarStar = KArrow KEffect KStar1       # Eff

# 三位一体
kind(Kind) = KStar    # Kind 本身是 KStar 的元素（自指 by convention）
kind(Type) = kind     # 每个 Type 有 Kind
```

---

## Equality 体系（Phase 3 Coherence Law）

```
                    ┌─────────────────────────────────┐
                    │        Equality Universe        │
                    │                                 │
                    │  hashEq（最宽松）               │
                    │    ⊇ nominalEq（name + struct） │
                    │       ⊇ structuralEq（最精确）  │
                    │                                 │
                    │  muEq = bisimulation（equi-rec）│
                    │  rowEq: rowVar = rigid identity │
                    └─────────────────────────────────┘

Coherence Law（INV-EQ2，Phase 3 强制）：
  structuralEq(a,b) → nominalEq(a,b) → hashEq(a,b)
  违反 → 系统不一致（checkCoherence 运行时验证）
```

---

## Incremental 引擎

```
Graph（依赖图）：
  nodes: type | constraint | normalize | bidir
  edges: from → deps（正向）
  revEdges: to → rdeps（反向，传播用）

  状态机：clean → dirty → computing → clean
                                    ↘ error

  propagateDirty(roots) → BFS（单源，INV-G1）
  batchUpdate(updates)  → union roots → single BFS（INV-G3）
  removeNode(id)        → 先清 revEdges，再清 edges（INV-G4）

Memo（缓存层）：
  memoKey = typeHash（NF-based，INV-H3）
  versioned key = "epoch:hash"（INV-M4）
  epoch bump → 全量失效
  invalidateType(t) → 细粒度失效（按 hash prefix）

  分桶：normalize / substitute / solve（独立）
  统计：hits / misses / evictions / epoch
```

---

## Phase 4 架构预规划

### Liquid Types（Phase 4，SMT bridge）

```
Predicate constraint → SMT query（Nix string-based bridge）
TypeRepr 增加：
  Refined { base; predicate }  # { n: Int | n > 0 }

Solver 增加：
  dischargePredicate → smtBridge.check(pred)
  smtBridge = pure Nix（生成 SMT-LIB string，调用外部 nix derivation）
```

### Module System（Phase 4）

```
Sig     { fields: AttrSet (Type | Sig) }   # signature
Struct  { sig; impl }                       # structure（满足 sig）
Functor { paramSig; body }                  # Sig → Sig

Functor application → 生成新 InstanceDB（局部化，避免污染全局）
```

---

## 版本演化（Phase 0 → 3）

| Phase     | 核心增量                                                   |
| --------- | ---------------------------------------------------------- |
| 0         | TypeIR 原型，基础 normalize，单文件                        |
| 1         | KUnbound, Meta, solver fixpoint, Graph visited set         |
| 2         | de Bruijn, Mu/HKT/Row, Instance DB, memo NF-hash fix       |
| 3         | Pi/Sigma, Effect, Bidir, Open ADT, Coherence Law, Worklist |
| 4（计划） | Liquid Types, Effect Handlers, Module System               |
| 5（计划） | Nix eval 集成, Totality, Full dependent types              |
