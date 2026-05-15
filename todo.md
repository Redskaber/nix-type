# todo.md — Phase 4.5 完成状态 + Phase 5.0 规划

---

## Phase 3.3~4.4 遗留风险（全部修复）

| 风险   | 描述                                | 修复                        | 状态   |
| ------ | ----------------------------------- | --------------------------- | ------ |
| RISK-1 | rowVar subst 未注入 solver          | INV-SUB2 guard              | ✅ 4.0 |
| RISK-2 | EffectMerge 不支持 open tail        | open row handling           | ✅ 4.0 |
| RISK-A | canDischarge impl=null soundness    | impl != null guard          | ✅ 4.1 |
| RISK-B | instanceKey toJSON+md5              | NF-hash key                 | ✅ 4.1 |
| RISK-C | worklist solver 无 requeue          | applySubstToConstraints     | ✅ 4.1 |
| RISK-D | QueryDB+Memo 双缓存无同步           | cacheNormalize              | ✅ 4.1 |
| RISK-E | ModFunctor body scope               | qualified naming            | ✅ 4.1 |
| RISK-F | topologicalSort in-degree 方向      | edges/revEdges 分离         | ✅ 4.1 |
| RISK-G | Functor 语义错误（Apply 嵌套）      | λM.f1(f2(M)) lazy subst     | ✅ 4.2 |
| RISK-H | HM let-gen 泄漏 Ctx 变量            | INV-SCHEME-1 generalize     | ✅ 4.2 |
| RISK-I | builtins.toJSON on Type repr        | serializeRepr（Phase 4.3）  | ✅ 4.3 |
| RISK-J | Kind constraints → residual（defer) | solveKindConstraints（4.3） | ✅ 4.3 |
| RISK-K | Mu unify guardSet 过于保守          | up-to congruence（4.3）     | ✅ 4.3 |
| RISK-L | patternVars Ctor branch field miss  | pat.fields or [] guard      | ✅ 4.4 |
| RISK-M | eLamA fresh var round-trip          | direct paramTy path         | ✅ 4.4 |
| RISK-N | contType domain unchecked           | INV-EFF-11 verification     | ✅ 4.4 |
| RISK-O | App result type is always freshVar  | peek fn repr → codomain     | ✅ 4.5 |
| RISK-P | Kind solver single-pass             | fixpoint iteration          | ✅ 4.5 |
| RISK-Q | Record pattern flat (no sub-pats)   | recurse into sub-patterns   | ✅ 4.5 |

---

## Phase 4.5 完成状态

| 编号    | 功能                                            | 文件                 | INV         | 状态 |
| ------- | ----------------------------------------------- | -------------------- | ----------- | ---- |
| P4.5-1  | \_inferApp: concrete Fn → codomain directly     | `bidir/check.nix`    | INV-BIDIR-3 | ✅   |
| P4.5-2  | checkAppResultSolved public verifier            | `bidir/check.nix`    | INV-BIDIR-3 | ✅   |
| P4.5-3  | solveKindConstraintsFixpoint (max 10 iters)     | `core/kind.nix`      | INV-KIND-3  | ✅   |
| P4.5-4  | checkKindAnnotationFixpoint verifier            | `core/kind.nix`      | INV-KIND-3  | ✅   |
| P4.5-5  | inferKindWithAnnotationFixpoint                 | `core/kind.nix`      | INV-KIND-3  | ✅   |
| P4.5-6  | patternVars Record recurses into sub-patterns   | `match/pattern.nix`  | INV-PAT-3   | ✅   |
| P4.5-7  | patternDepth Record properly recurses           | `match/pattern.nix`  | INV-PAT-3   | ✅   |
| P4.5-8  | checkPatternVars public verifier                | `match/pattern.nix`  | INV-PAT-3   | ✅   |
| P4.5-9  | compileMatch Record: field accessor bindings    | `match/pattern.nix`  | INV-PAT-3   | ✅   |
| P4.5-10 | T26: App Result Solved (8 tests)                | `tests/test_all.nix` | INV-BIDIR-3 | ✅   |
| P4.5-11 | T27: Kind Fixpoint (7 tests)                    | `tests/test_all.nix` | INV-KIND-3  | ✅   |
| P4.5-12 | T28: Nested Record Pattern (7 tests)            | `tests/test_all.nix` | INV-PAT-3   | ✅   |
| P4.5-13 | lib/default.nix updated exports + version 4.5.0 | `lib/default.nix`    | —           | ✅   |
| P4.5-14 | flake.nix: invBidir3/invKind3/invPat3 checks    | `flake.nix`          | —           | ✅   |
| P4.5-15 | todo.md + docs updated                          | docs                 | —           | ✅   |

---

## Phase 4.5 测试覆盖

| 组     | 内容                                  | 测试数   | 覆盖 INV              |
| ------ | ------------------------------------- | -------- | --------------------- |
| T1–T15 | TypeIR → Incremental（inherited 4.4） | 106      | INV-1~INV-G4          |
| T16    | Pattern Matching ★+6 (4.4)            | 13       | INV-PAT-1/2           |
| T17    | Row 多态                              | 2        | INV-ROW               |
| T18    | Bidir + TypeScheme                    | 10       | INV-BIDIR-1, SCHEME-1 |
| T19    | Unification                           | 7        | unify                 |
| T20    | 集成测试                              | 6        | all                   |
| T21    | Kind Inference ★+5 (4.4)              | 14       | INV-KIND-1/2          |
| T22    | Handler Continuations                 | 6        | INV-EFF-10            |
| T23    | Mu Bisim up-to congruence             | 6        | INV-MU-1              |
| T24    | Bidir Annotated Lambda (4.4)          | 8        | INV-BIDIR-2           |
| T25    | Handler Cont Type Check (4.4)         | 7        | INV-EFF-11, INV-PAT-1 |
| T26    | Bidir App Result Solved ★ new         | 8        | INV-BIDIR-3           |
| T27    | Kind Fixpoint Solver ★ new            | 7        | INV-KIND-3            |
| T28    | Pattern Nested Record ★ new           | 7        | INV-PAT-3             |
| **Σ**  |                                       | **~187** |                       |

---

## Phase 4.5 已知限制

| 限制                         | 位置                | 描述                                         | 目标 |
| ---------------------------- | ------------------- | -------------------------------------------- | ---- |
| Decision Tree prefix sharing | `match/pattern.nix` | sequential；大型 ADT O(n)                    | 5.x  |
| Bidir App: complex fn types  | `bidir/check.nix`   | Forall/Mu fn types not solved via peek       | 5.0  |
| SMT bridge = string stub     | `refined/types.nix` | 用户提供 oracle                              | 持续 |
| Kind fixpoint max 10 iter    | `core/kind.nix`     | bounded for pure Nix; fine for realistic use | 持续 |

---

## Phase 5.0 规划：Gradual Types + HM 推断

```nix
# 1. Dynamic type（rDynamic 已添加 Phase 4.2）
tDyn = mkTypeDefault rDynamic KStar;

# 2. Consistency relation（gradual subtype）
isConsistent = t1: t2:
  (t1.repr.__variant == "Dynamic") ||
  (t2.repr.__variant == "Dynamic") ||
  typeEq t1 t2;

# 3. HM type inference（全局，全新 pass）
# infer : Ctx → Expr → (Type, [Constraint])
# generalize★ 已在 Phase 4.2 实现
# Phase 5.0: constraint solving + unification loop integrated

# 新增 INV：
# INV-GRAD-1: Dynamic consistent with all types
# INV-GRAD-2: cast insertion explicit at Dynamic boundaries
# INV-HM-1:   infer yields principal type
# INV-HM-2:   generalize respects free variables in Ctx
```

---

## 新增不变量（Phase 4.5）

```
INV-BIDIR-3: App result type solved when fn is concrete
  ∀ ctx, fn, arg:
    fnTy = infer(ctx, fn).type
    fnTy.repr.__variant == "Fn" →
      infer(ctx, eApp(fn, arg)).type = fnTy.repr.to
      infer(ctx, eApp(fn, arg)).resultSolved = true
  Implementation: _inferApp peeks at fn repr; CASE1 uses codomain directly.

INV-KIND-3: kind annotation fixpoint convergence
  ∀ kcs: [KindConstraint]:
    solveKindConstraintsFixpoint(kcs).converged = true
    (if ok, then no further unification possible on residual)
  Termination: bounded at maxIter=10; practical fixpoint in ≤ |KVars|+1 steps.

INV-PAT-3: patternVars completeness for nested Record
  ∀ Record {f₁ = p₁; ...; fₙ = pₙ}:
    patternVars(Record{...}) = ⋃ᵢ patternVars(pᵢ)
  Field names themselves are NOT included (they are accessors, not bindings).
  Implementation: recurse into attrValues of pat.fields.
```

---

## ADR（Phase 4.5）

### ADR-018: INV-BIDIR-3 peek-and-resolve（Phase 4.5）

**决策**: `_inferApp` 对 `fnR.type.repr` 进行模式匹配。  
**Case Fn**: codomain 直接作为 result type，仅生成 `Eq(argTy, domain)` 约束。  
**Case other**: 保持 4.4 行为（freshVar + `Eq(fnTy, argTy → freshVar)`）。  
**理由**: INV-BIDIR-3 要求"当函数类型已知时，结果类型已解析"。Peek 是 O(1)、纯函数式，不引入新依赖。不需要完整约束求解器介入（那会引入循环依赖）。

### ADR-019: INV-KIND-3 bounded fixpoint（Phase 4.5）

**决策**: `solveKindConstraintsFixpoint` 最多迭代 10 次，用 `genList + foldl'` 实现纯 Nix 中的有界循环。  
**理由**: 实际 kind 推断问题（类型构造器嵌套 ≤4 层）在 ≤ |KVars|+1 步内收敛，远低于 10。  
**终止性**: 每次迭代要么绑定 ≥1 KVar（单调减少），要么无新绑定（立即 converged）。

### ADR-020: INV-PAT-3 sub-pattern recursion（Phase 4.5）

**决策**: `patternVars` 的 Record 分支由"返回字段名"改为"递归到 attrValues 的子模式"。  
**向后兼容**: 旧行为（字段名视为绑定）是错误的语义。Phase 4.5 修正为正确的"变量绑定来自 PVar 节点，不来自字段访问器名"。  
**`compileMatch` Record**: 同步更新为从子模式 patternVars 收集绑定，映射到字段访问路径 `__scrutinee.fieldName`。
