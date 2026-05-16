# todo.md — Phase 4.5.9 完成状态 + Phase 5.0 规划

---

## Phase 3.3~4.5.3 遗留风险（全部修复）

| 风险   | 描述                                 | 修复                         | 状态         |
| ------ | ------------------------------------ | ---------------------------- | ------------ |
| RISK-1 | rowVar subst 未注入 solver           | INV-SUB2 guard               | ✅ 4.0       |
| RISK-2 | EffectMerge 不支持 open tail         | open row handling            | ✅ 4.0       |
| RISK-A | canDischarge impl=null soundness     | impl != null guard           | ✅ 4.1       |
| RISK-B | instanceKey toJSON+md5               | NF-hash key (\_instanceKey)  | ✅ 4.1       |
| RISK-C | worklist solver 无 requeue           | applySubstToConstraints      | ✅ 4.1       |
| RISK-D | QueryDB+Memo 双缓存无同步            | cacheNormalize               | ✅ 4.1       |
| RISK-E | ModFunctor body scope                | qualified naming             | ✅ 4.1       |
| RISK-F | topologicalSort in-degree 方向       | edges/revEdges 分离          | ✅ 4.1       |
| RISK-G | Functor 语义错误（Apply 嵌套）       | λM.f1(f2(M)) lazy subst      | ✅ 4.2       |
| RISK-H | HM let-gen 泄漏 Ctx 变量             | INV-SCHEME-1 generalize      | ✅ 4.2       |
| RISK-I | builtins.toJSON on Type repr         | serializeRepr（INV-SER-1）   | ✅ 4.3       |
| RISK-J | Kind constraints → residual          | solveKindConstraints         | ✅ 4.3       |
| RISK-K | Mu unify guardSet 过于保守           | up-to congruence             | ✅ 4.3       |
| RISK-L | patternVars Ctor branch field miss   | pat.fields or [] guard       | ✅ 4.4       |
| RISK-M | eLamA fresh var round-trip           | direct paramTy path          | ✅ 4.4       |
| RISK-N | contType domain unchecked            | INV-EFF-11 verification      | ✅ 4.4       |
| RISK-O | App result type is always freshVar   | peek fn repr → codomain      | ✅ 4.5       |
| RISK-P | Kind solver single-pass              | fixpoint iteration           | ✅ 4.5       |
| RISK-Q | Record pattern flat (no sub-pats)    | recurse into sub-patterns    | ✅ 4.5       |
| RISK-R | lib.concatMap lazy cycle on rec fn   | builtins.concatLists/map     | ✅ 4.5.2     |
| RISK-S | topologicalSort list/attrset duality | unified return { ok; order } | ✅ 4.5.2     |
| RISK-T | mkHandlerWithCont missing fields     | contDomainOk + inv_eff_11    | ✅ 4.5.2     |
| RISK-U | patternVars rec{} lazy-eval cycle    | lambda wrapper (p: f p)      | ✅ **4.5.3** |
| RISK-V | test framework lacks diagnostics     | mkTestWith + diagnoseAll     | ✅ **4.5.3** |
| RISK-W | foldl'+++ in letrec ctx → silent []  | concatLists+map (INV-NIX-4)  | ✅ **4.5.9** |

---

## Phase 4.5.9 完成状态

| 编号     | 功能                                                 | 文件                | INV       | 状态 |
| -------- | ---------------------------------------------------- | ------------------- | --------- | ---- |
| P4.5.9-1 | patternVars Ctor: foldl'+→concatLists+map            | `match/pattern.nix` | INV-NIX-4 | ✅   |
| P4.5.9-2 | patternVars Record: foldl'+→concatLists+map          | `match/pattern.nix` | INV-NIX-4 | ✅   |
| P4.5.9-3 | patternVars/patternDepth: eta-expand rec{} exports   | `match/pattern.nix` | INV-NIX-3 | ✅   |
| P4.5.9-4 | patternVarsSet/isLinear: direct \_patternVarsGo call | `match/pattern.nix` | INV-NIX-3 | ✅   |
| P4.5.9-5 | version bump 4.5.9                                   | `flake.nix`, `lib/` | —         | ✅   |
| P4.5.9-6 | BUGFIX.md: Round 7 entry                             | `BUGFIX.md`         | —         | ✅   |
| P4.5.9-7 | todo.md: RISK-W + 4.5.9 status                       | `todo.md`           | —         | ✅   |

---

## Phase 4.5.3 完成状态

| 编号      | 功能                                          | 文件                 | INV        | 状态 |
| --------- | --------------------------------------------- | -------------------- | ---------- | ---- |
| P4.5.3-1  | patternVars Ctor: lambda wrapper fix          | `match/pattern.nix`  | INV-NIX-3  | ✅   |
| P4.5.3-2  | patternDepth Ctor/Record: lambda wrapper fix  | `match/pattern.nix`  | INV-NIX-3  | ✅   |
| P4.5.3-3  | mkTestBool/mkTest: diag field (INV-TEST-6)    | `tests/test_all.nix` | INV-TEST-6 | ✅   |
| P4.5.3-4  | mkTestWith: bool+diag combined                | `tests/test_all.nix` | INV-TEST-6 | ✅   |
| P4.5.3-5  | mkTestEval / mkTestError primitives           | `tests/test_all.nix` | INV-TEST-1 | ✅   |
| P4.5.3-6  | diagnoseAll: per-failure diagnostics output   | `tests/test_all.nix` | INV-TEST-7 | ✅   |
| P4.5.3-7  | \_safeShow: JSON-safe value display helper    | `tests/test_all.nix` | INV-TEST-7 | ✅   |
| P4.5.3-8  | T16/T25: use mkTestWith for patternVars tests | `tests/test_all.nix` | INV-TEST-6 | ✅   |
| P4.5.3-9  | flake.nix: nix run .#diagnose app             | `flake.nix`          | —          | ✅   |
| P4.5.3-10 | flake.nix: version 4.5.3                      | `flake.nix`          | —          | ✅   |
| P4.5.3-11 | BUGFIX.md: Round 4 entry                      | `BUGFIX.md`          | —          | ✅   |
| P4.5.3-12 | todo.md updated to 4.5.3                      | `todo.md`            | —          | ✅   |

---

## Phase 4.5.2 完成状态

| 编号      | 功能                                     | 文件                    | INV        | 状态 |
| --------- | ---------------------------------------- | ----------------------- | ---------- | ---- |
| P4.5.2-1  | patternVars: builtins.concatLists fix    | `match/pattern.nix`     | INV-NIX-2  | ✅   |
| P4.5.2-2  | mkHandlerWithCont: contDomainOk field    | `effect/handlers.nix`   | INV-EFF-11 | ✅   |
| P4.5.2-3  | checkHandlerContWellFormed: inv_eff_11   | `effect/handlers.nix`   | INV-EFF-11 | ✅   |
| P4.5.2-4  | topologicalSort unified return type      | `incremental/graph.nix` | INV-TOPO   | ✅   |
| P4.5.2-5  | failedGroups/failedList defensive checks | `tests/test_all.nix`    | INV-TEST-5 | ✅   |
| P4.5.2-6  | solve call BUG-T9 fix                    | `tests/test_all.nix`    | INV-TEST   | ✅   |
| P4.5.2-7  | README.md updated to 4.5.2               | `README.md`             | —          | ✅   |
| P4.5.2-8  | ARCHITECTURE.md updated to 4.5.2         | `ARCHITECTURE.md`       | —          | ✅   |
| P4.5.2-9  | BUGFIX.md consolidated (all rounds)      | `BUGFIX.md`             | —          | ✅   |
| P4.5.2-10 | todo.md updated                          | `todo.md`               | —          | ✅   |

---

## Phase 4.5 完成状态

| 编号    | 功能                                                      | 文件                 | INV         | 状态 |
| ------- | --------------------------------------------------------- | -------------------- | ----------- | ---- |
| P4.5-1  | \_inferApp: concrete Fn → codomain directly               | `bidir/check.nix`    | INV-BIDIR-3 | ✅   |
| P4.5-2  | checkAppResultSolved public verifier                      | `bidir/check.nix`    | INV-BIDIR-3 | ✅   |
| P4.5-3  | solveKindConstraintsFixpoint (max 10 iters)               | `core/kind.nix`      | INV-KIND-3  | ✅   |
| P4.5-4  | checkKindAnnotationFixpoint verifier                      | `core/kind.nix`      | INV-KIND-3  | ✅   |
| P4.5-5  | inferKindWithAnnotationFixpoint                           | `core/kind.nix`      | INV-KIND-3  | ✅   |
| P4.5-6  | patternVars Record recurses into sub-patterns             | `match/pattern.nix`  | INV-PAT-3   | ✅   |
| P4.5-7  | patternDepth Record properly recurses                     | `match/pattern.nix`  | INV-PAT-3   | ✅   |
| P4.5-8  | checkPatternVars public verifier                          | `match/pattern.nix`  | INV-PAT-3   | ✅   |
| P4.5-9  | compileMatch Record: field accessor bindings              | `match/pattern.nix`  | INV-PAT-3   | ✅   |
| P4.5-10 | T26: App Result Solved (8 tests)                          | `tests/test_all.nix` | INV-BIDIR-3 | ✅   |
| P4.5-11 | T27: Kind Fixpoint Solver (7 tests)                       | `tests/test_all.nix` | INV-KIND-3  | ✅   |
| P4.5-12 | T28: Pattern Nested Record (7 tests)                      | `tests/test_all.nix` | INV-PAT-3   | ✅   |
| P4.5-13 | lib/default.nix: updated exports + version 4.5.0          | `lib/default.nix`    | —           | ✅   |
| P4.5-14 | flake.nix: invBidir3/invKind3/invPat3 checks              | `flake.nix`          | —           | ✅   |
| P4.5-15 | patternVars BFS fix (INV-NIX-5): iterative \_extractOne×8 | `match/pattern.nix`  | INV-PAT-1/3 | ✅   |

---

## 测试覆盖（Phase 4.5.3）

| 组     | 内容                                | 测试数  | 覆盖 INV                  |
| ------ | ----------------------------------- | ------- | ------------------------- |
| T1–T8  | TypeIR, Kind, Repr, Normalize       | 53      | INV-1~6, INV-KIND-1       |
| T9–T15 | Solver, InstanceDB, Refined, Module | 52      | INV-SOL, INV-I1, INV-MOD  |
|        | Effect, QueryDB, Graph              |         | INV-EFF, INV-G1~4         |
| T16    | Pattern Matching                    | 13      | INV-PAT-1/2               |
| T17    | Row 多态                            | 2       | INV-ROW                   |
| T18    | Bidir + TypeScheme                  | 10      | INV-BIDIR-1, INV-SCHEME-1 |
| T19    | Unification                         | 7       | unify, Mu bisim           |
| T20    | Integration                         | 6       | all                       |
| T21    | Kind Inference                      | 14      | INV-KIND-1/2              |
| T22    | Handler Continuations               | 6       | INV-EFF-10                |
| T23    | Mu Bisim Congruence                 | 6       | INV-MU-1                  |
| T24    | Bidir Annotated Lambda              | 8       | INV-BIDIR-2               |
| T25    | Handler Cont Type Check             | 7       | INV-EFF-11, INV-PAT-1     |
| T26    | Bidir App Result Solved             | 8       | INV-BIDIR-3               |
| T27    | Kind Fixpoint Solver                | 7       | INV-KIND-3                |
| T28    | Pattern Nested Record               | 7       | INV-PAT-3                 |
| **Σ**  |                                     | **203** | **目标: 203/203 ✅**      |

---

## 已知限制（Phase 4.5.3）

| 限制                         | 位置                | 描述                                         | 目标 |
| ---------------------------- | ------------------- | -------------------------------------------- | ---- |
| Decision Tree prefix sharing | `match/pattern.nix` | Sequential; 大型 ADT O(n)                    | 5.x  |
| Bidir: complex fn types      | `bidir/check.nix`   | Forall/Mu fn types not resolved via peek     | 5.0  |
| SMT bridge = string stub     | `refined/types.nix` | 用户提供 oracle; 无真实 SMTLIB2 连接         | 持续 |
| Kind fixpoint max 10 iter    | `core/kind.nix`     | Bounded for pure Nix; fine for realistic use | 持续 |

---

## Phase 5.0 规划：Gradual Types + Full HM

```
新增不变量:
  INV-GRAD-1: Dynamic consistent with all types
  INV-GRAD-2: cast insertion explicit at Dynamic boundaries
  INV-HM-1:   infer yields principal type
  INV-HM-2:   generalize respects free variables in Ctx

实现计划:
  1. isConsistent: t1 t2 → Bool (rDynamic already in repr/all.nix)
  2. Cast insertion pass: Expr → ExprWithCasts
  3. HM constraint solving integration loop
  4. Decision Tree: prefix sharing (Maranget 2008 algorithm)
  5. SMT bridge: real SMTLIB2 backend
```

---

## 新增不变量（Phase 4.5.3）

```
INV-NIX-3: lambda wrapper for rec{}-scope self-referential functions
  ∀ rec-scope function f used as arg to builtins.map / similar:
    Use (x: f x) NOT bare f
  Reason: bare reference forces f's thunk while f is being defined,
  creating a lazy-eval cycle that results in eval-error.
  Applies to: patternVars, patternDepth, and any future rec-defined
  functions that are passed as higher-order arguments.

INV-TEST-6: test primitives carry diag fields
  ∀ t from mkTestBool/mkTest/mkTestWith:
    t.diag is an attrset with fields: kind, evalOk, actual, expected, hint
  Purpose: enables diagnoseAll output to surface failure reasons.

INV-TEST-7: all output paths are JSON-safe
  ∀ path in runAll, failedList, diagnoseAll:
    no Type objects, no function values, no unforced thunks
  Impl: _safeShow converts any Nix value to String for display.
```

```
INV-BIDIR-3: App result type solved when fn is concrete
  ∀ ctx, fn, arg:
    fnTy = infer(ctx, fn).type
    fnTy.repr.__variant == "Fn" →
      infer(ctx, eApp(fn, arg)).type = fnTy.repr.to
      infer(ctx, eApp(fn, arg)).resultSolved = true
  Impl: _inferApp peeks at fn repr; CASE1 uses codomain directly.

INV-KIND-3: kind annotation fixpoint convergence
  ∀ kcs: [KindConstraint]:
    solveKindConstraintsFixpoint(kcs).converged = true
    (if ok, then no further unification possible on residual)
  Termination: bounded at maxIter=10; practical fixpoint in ≤ |KVars|+1 steps.

INV-PAT-3: patternVars completeness for nested Record
  ∀ Record {f₁ = p₁; ...; fₙ = pₙ}:
    patternVars(Record{...}) = ⋃ᵢ patternVars(pᵢ)
  Field names are NOT included (they are accessors, not bindings).

INV-NIX-2: builtins.concatLists safety for rec-scope functions
  ∀ rec-scope self-referential functions f used with map/concatMap:
    Use builtins.concatLists (builtins.map f xs)
    NOT lib.concatMap f xs
  Reason: lib.concatMap triggers lazy cycle on rec-scope self-refs in some Nix versions.

INV-TOPO: topologicalSort unified return type
  ∀ graph:
    topologicalSort(graph) = { ok: Bool; order: [String]; error: String|null }
  Never returns a raw list or non-attrset.
```
