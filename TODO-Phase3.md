# TODO-Phase3.md — Phase 3 完成状态 + Phase 4 规划

---

## Phase 3 完成状态

| 特性                           | 状态 | 实现文件                                    | 关键修复                                           |
| ------------------------------ | ---- | ------------------------------------------- | -------------------------------------------------- |
| Pi-types（Dependent Function） | ✅   | `repr/all.nix`, `normalize/rules.nix`       | `rPi`, `rulePiReduction`                           |
| Sigma-types（Dependent Pair）  | ✅   | `repr/all.nix`, `normalize/substitute.nix`  | `rSigma`, capture-safe Pi/Sigma subst              |
| Effect types                   | ✅   | `repr/all.nix`, `core/kind.nix`             | `rEffect`, `KEffect`, `KRow`                       |
| Opaque / Ascribe               | ✅   | `repr/all.nix`                              | `rOpaque`, `rAscribe`（bidirectional 切换）        |
| Bidirectional Type Checking    | ✅   | `bidir/check.nix`                           | check/infer, Pierce/Turner, Ascribe 切换           |
| Open ADT 扩展                  | ✅   | `repr/all.nix`                              | `extendADT`, ordinal 稳定追加                      |
| KRow / KEffect                 | ✅   | `core/kind.nix`                             | Kind 系统扩展，`kindUnify` 完全纯函数              |
| Equality Coherence Law         | ✅   | `meta/equality.nix`                         | structural ⊆ nominal ⊆ hash（INV-EQ2）             |
| muEq 真 bisimulation           | ✅   | `meta/equality.nix`                         | coinductive guard set + fuel（INV-EQ3）            |
| rowVarEq 修复                  | ✅   | `meta/equality.nix`, `constraint/unify.nix` | rigid name equality（INV-EQ4）                     |
| typeHash/nfHash 路径收敛       | ✅   | `meta/hash.nix`                             | typeHash = nfHash∘normalize（INV-H2）              |
| α-canonical 序列化 v3          | ✅   | `meta/serialize.nix`                        | cycle-free, indexed Constructor binder（INV-SER）  |
| normalizeConstraint            | ✅   | `constraint/ir.nix`                         | 幂等统一入口（INV-C4）                             |
| constraintsHash dedup          | ✅   | `constraint/ir.nix`                         | listToAttrs O(n)，集合语义（INV-C2）               |
| constraintKey canonical        | ✅   | `constraint/ir.nix`                         | 不依赖 toJSON 顺序（INV-C1）                       |
| Worklist Solver                | ✅   | `constraint/solver.nix`                     | 精确增量 propagation（INV-SOL1/4/5）               |
| Lambda unify alpha-canonical   | ✅   | `constraint/unify.nix`                      | serializeReprAlphaCanonical 比较（INV-U4）         |
| Pi/Sigma unify                 | ✅   | `constraint/unify.nix`                      | 带 binder 的统一                                   |
| composeSubst 修复              | ✅   | `normalize/substitute.nix`                  | σ₂∘σ₁ 正确顺序                                     |
| freeVarsRepr 完整              | ✅   | `repr/all.nix`                              | 所有 20 变体覆盖（Pi/Sigma/Effect/Ascribe/Opaque） |
| Constructor-partial kind 修复  | ✅   | `normalize/rules.nix`                       | 保留真实 param.kind（INV-K1）                      |
| Pi-reduction 规则              | ✅   | `normalize/rules.nix`                       | Π(x:A).B + arg → B[x↦arg]                          |
| normalize 三系统统一           | ✅   | `normalize/rewrite.nix`                     | 单一 normalize（step+subterms+fixpoint）           |
| Pattern exhaustiveness         | ✅   | `match/pattern.nix`                         | checkExhaustiveness + checkRedundancy              |
| Decision Tree（ordinal O(1)）  | ✅   | `match/pattern.nix`                         | compilePats，Kahn topological sort                 |
| Instance coherence 强化        | ✅   | `runtime/instance.nix`                      | register 强制 coherence check，superclass 传递     |
| Graph BFS worklist             | ✅   | `incremental/graph.nix`                     | INV-G1-5 全保留                                    |
| Memo epoch + NF-hash key       | ✅   | `incremental/memo.nix`                      | INV-M1-4，typeHash 单一 memoKey                    |
| lib/default.nix 18 模块        | ✅   | `lib/default.nix`                           | 正确依赖拓扑序，bidirLib 新增                      |
| verifyInvariants 完整          | ✅   | `lib/default.nix`                           | INV-1~6 + INV-T/K/H/EQ 运行时验证                  |

---

## Phase 3 修复清单（nix-todo 对应）

| todo 编号       | 原问题                                | Phase 3 修复                            | INV      |
| --------------- | ------------------------------------- | --------------------------------------- | -------- |
| equality #1     | INV-3 被 strategy override 破坏       | 单一 NF-hash equality（INV-3 强制）     | INV-3    |
| equality #2     | alphaEq ≈ structuralEq 重复           | 真正 de Bruijn α-equality               | INV-EQ2  |
| equality #3     | nominalEq 非 nominal                  | nominalEq = name + NF-hash              | INV-EQ2  |
| equality #4     | rowVar 走 alphaEq（domain 错误）      | rowVarEq = rigid name identity          | INV-EQ4  |
| equality #5     | muEq = alphaEq alias（退化）          | coinductive bisimulation + guard set    | INV-EQ3  |
| equality #6     | equality lattice 非封闭               | Coherence Law + checkCoherence 验证     | INV-EQ2  |
| hash #1         | typeHash/nfHash 双路径歧义            | typeHash = nfHash∘normalize（唯一路径） | INV-H2   |
| serialize #1    | \_serType 非 canonical（toJSON 依赖） | serializeReprAlphaCanonical v3          | INV-SER3 |
| serialize #2    | Constructor binder 循环风险           | indexed env（不用名字，不循环）         | INV-SER5 |
| constraint ir#1 | \_serType 顺序依赖                    | constraintKey 用 canonical ids          | INV-C1   |
| constraint ir#2 | applySubst 不递归                     | mapTypesInConstraint（完整递归）        | INV-C3   |
| constraint ir#3 | implies 无规范化                      | mkImplies 内 sort premises              | INV-C4   |
| constraint ir#4 | constraintsHash 未去重                | deduplicateConstraints O(n) + sorted    | INV-C2   |
| constraint ir#5 | 缺 normalizeConstraint                | normalizeConstraint 幂等实现            | INV-C4   |
| rules #1        | Constructor-partial kind 假设 KStar   | 使用真实 param.kind + kindInferRepr     | INV-K1   |
| solver #1       | fixpoint 不含 subst 变化              | Worklist + \_substEq（INV-SOL1）        | INV-SOL1 |
| solver #2       | subst 未应用到 constraints            | \_applySubstToConstraint 每轮执行       | INV-SOL4 |
| solver #5       | 精确 worklist 缺失                    | \_partitionAffected（INV-SOL5）         | INV-SOL5 |
| memo #1         | constraint key 非 canonical           | \_constraintSetKey sorted + dedup       | INV-M3   |
| memo #3         | normalize key 非 NF-stable            | typeHash versioned key（INV-M4）        | INV-M4   |

---

## Phase 3.1 规划（短期，当前轮次后）

### P3.1-0：Bidirectional Dependent Types 完善

```nix
# bidir/check.nix 当前简化点：
# _substTypeInType 未完整实现（需 substLib 集成）
# Π(x:A).B 中 body 替换 x 需 capture-safe

# 完善目标：
check(ctx, f, Π(x:A).B) =
  infer(ctx, f) = Π(y:A').B'
  unify(A, A')
  check(ctx, arg, A)
  return B[x↦arg]  # capture-safe
```

### P3.1-1：Mu Unification 完善（equi-recursive soundness）

```nix
# 当前 _unifyMuGuarded：展开时 id 处理简化
# 完善：proper Type 构造 + unfold via substLib.substitute
_muUnfold = mu: substLib.substitute mu.repr.param mu mu.repr.body;
```

### P3.1-2：Effect Handler System

```nix
# Effect = algebraic effect（Koka 风格）
# Handler = Type -> Eff[E]A -> B（消除 effect）
# Row 类型编码：Eff(E, A) where E = VariantRow
rEffHandler = effectRow: handledType: returnType: ...
```

---

## Phase 4 规划

### 优先级矩阵

| 特性                               | 优先级 | 依赖                   | 影响 INV       | 估计工作量 |
| ---------------------------------- | ------ | ---------------------- | -------------- | ---------- |
| Equi-recursive Mu Unification 完善 | P0     | bisimulation soundness | INV-3, INV-EQ3 | 中         |
| Bidirectional Dependent 完善       | P0     | Pi/Sigma bidir         | -              | 中         |
| Liquid Types（SMT interface）      | P1     | Predicate constraint   | INV-6          | 大         |
| Effect Handlers                    | P1     | Effect + VariantRow    | INV-1          | 大         |
| Module System（Sig + Functor）     | P2     | solver + Instance      | -              | 大         |
| Subtyping（coercive）              | P2     | bidir subsumption      | INV-3 ext      | 中         |
| Nix eval 双向集成                  | P3     | bidir check            | -              | 特大       |
| Totality Checking                  | P3     | Pi + Mu fuel analysis  | INV-2          | 特大       |

### P4-0：Liquid Types（Predicate constraint → SMT）

```nix
# Predicate constraint 当前：保留为 residual
# Phase 4：接入 SMT（Nix string-based）
mkRefined = baseType: predFn:
  mkTypeWith (rConstrained baseType [mkPredicate predFn baseType]) KStar defaultMeta;

# 示例：{ n : Int | n > 0 }
tPosInt = mkRefined tInt "gt_zero";

# Solver：predicate discharge via SMT bridge
dischargePredicate = pred: { ok = smtQuery pred.fn pred.arg; };
```

### P4-1：Effect Handlers

```nix
# Handler ADT
mkHandler = effectTag: branches: returnType:
  mkTypeDefault (rADT (map mkHandlerBranch branches) true) KStar;

# handle : Eff(E ++ R, A) -> Handler(E, A, B) -> Eff(R, B)
```

### P4-2：Module System

```nix
# Sig（signature）= record of types + values
# Struct（structure）= implementation of Sig
# Functor = Sig -> Sig（parameterized module）
rSig    = fields: mkRepr "Sig"    { inherit fields; };
rStruct = sig: impl: mkRepr "Struct" { inherit sig impl; };
rFunctor = param: body: mkRepr "Functor" { inherit param body; };
```

---

## 架构风险（Phase 3 → 4）

| 风险                                  | 等级 | 缓解                                             |
| ------------------------------------- | ---- | ------------------------------------------------ |
| Pi types 与 fuel 张力（依赖类型循环） | 高   | type-level computation budget 与 term-level 分离 |
| Mu unification soundness              | 中   | bisimulation fuel + guard set（当前实现）        |
| Effect row 与 Constraint 交互         | 中   | Effect = VariantRow-based（统一在 TypeRepr）     |
| SMT bridge 副作用污染 TypeIR          | 高   | 严格隔离：nix string-based SMT，不带入副作用     |
| Functor 与 Instance 交互              | 中   | Functor application 生成新 InstanceDB（局部化）  |

---

## 当前已知限制（Phase 3）

| 限制                               | 位置                    | Phase 计划修复     |
| ---------------------------------- | ----------------------- | ------------------ |
| bidir `_substTypeInType` 未完整    | `bidir/check.nix`       | 3.1                |
| \_unifyMu 展开时 Type 构造简化     | `constraint/unify.nix`  | 3.1                |
| Predicate constraint 保留 residual | `constraint/solver.nix` | 4                  |
| Effect normalize 委托（未完整）    | `normalize/rules.nix`   | 3.1                |
| Pi bidir 仅支持 param 名一致       | `constraint/unify.nix`  | 3.1                |
| \_applySubstType 仅替换顶层 Var    | `constraint/solver.nix` | 3.1（接 substLib） |
