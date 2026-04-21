# TODO-Phase4.md — Phase 4.0 完成状态 + Phase 5.0 规划

---

## Phase 3.3 遗留风险修复（Phase 4.0 首要任务）

| 风险编号 | 问题描述                                              | 修复位置                          | 状态 |
| -------- | ----------------------------------------------------- | --------------------------------- | ---- |
| RISK-1   | rowVar subst 未注入 solver pipeline                   | `constraint/solver_p40.nix`       | ✅   |
| RISK-2   | EffectMerge 不支持 open effect row（RowVar tail）     | `normalize/rules_p40.nix`         | ✅   |
| RISK-3   | Decision Tree 无 prefix sharing（P3.3 遗留）          | `match/pattern_p33.nix`           | 🔵 延至 4.x |

---

## Phase 4.0 完成状态

| 编号    | 功能                                                   | 文件                              | INV                  | 状态 |
| ------- | ------------------------------------------------------ | --------------------------------- | -------------------- | ---- |
| P4.0-1  | UnifiedSubst（type+row+kind 统一替换系统）             | `normalize/unified_subst.nix`     | INV-US1~5            | ✅   |
| P4.0-2  | Refined Types（PredExpr IR + staticEval + smtBridge）  | `refined/types.nix`               | INV-SMT-1~4          | ✅   |
| P4.0-3  | Module System（Sig/Struct/ModFunctor/sealing）          | `module/system.nix`               | INV-MOD-1~5          | ✅   |
| P4.0-4  | Effect Handlers（checkHandler/handleAll/subtractEffect）| `effect/handlers.nix`             | INV-EFF-4~7          | ✅   |
| P4.0-5  | rules_p40（EffectMerge open + ruleRefined + ruleSig）  | `normalize/rules_p40.nix`         | INV-EFF-6, INV-MOD-4 | ✅   |
| P4.0-6  | solver_p40（UnifiedSubst + RowEquality + smtResidual） | `constraint/solver_p40.nix`       | INV-SOL-P40-1~3      | ✅   |
| P4.0-7  | QueryKey DB（Salsa-style BFS invalidation）            | `incremental/query.nix`           | INV-QK1~5            | ✅   |
| P4.0-8  | lib/default.nix Phase 4.0 export（p40 namespace）     | `lib/default.nix`                 | —                    | ✅   |
| P4.0-9  | Phase 4.0 专项测试（T17-T21，35 tests）               | `tests/test_phase40.nix`          | all P4.0 INV         | ✅   |
| P4.0-10 | README.md + ARCHITECTURE.md + TODO-Phase4.md 更新     | 文档                              | —                    | ✅   |
| P4.0-11 | Phase 4.0 综合演示                                    | `examples/phase40_demo.nix`       | —                    | ✅   |

---

## Phase 4.0 测试覆盖

| 测试组  | 组名                    | 测试数 | 覆盖 INV                         |
| ------- | ----------------------- | ------ | -------------------------------- |
| T1-T16  | Phase 3.3 全量          | 99     | 所有 Phase 3.x INV               |
| T17     | UnifiedSubst            | 5      | INV-US1~4                        |
| T18     | Refined Types           | 6      | INV-SMT-1~4                      |
| T19     | Module System           | 5      | INV-MOD-1~5                      |
| T20     | Effect Handlers         | 5      | INV-EFF-4~7                      |
| T21     | QueryKey Incremental    | 7      | INV-QK1~5                        |
| **合计** |                        | **127** |                                 |

---

## Phase 4.0 已知限制（Phase 4.x 目标）

| 限制                                        | 位置                         | 描述                                          | 目标 Phase |
| ------------------------------------------- | ---------------------------- | --------------------------------------------- | ---------- |
| SMT bridge = string only                    | `refined/types.nix`          | 用户需自行调用外部 SMT solver                 | 4.1        |
| Refined subtype 非自动化                    | `refined/types.nix`          | obligation 生成后需用户 invoke smtBridge       | 4.1        |
| Functor transitive composition              | `module/system.nix`          | applyFunctor 仅单次；无 F∘G 组合              | 4.2        |
| Functor coherence check（global InstanceDB）| `module/system.nix`          | localInstances 未整合到 global 一致性检查     | 4.2        |
| Effect Handler continuations                | `effect/handlers.nix`        | 当前仅 type-level；无 continuation passing    | 4.3        |
| Mu bisimulation up-to congruence            | `constraint/unify.nix`       | guard set 近似；真正 up-to 需 congruence closure | 4.3     |
| Decision Tree prefix sharing                | `match/pattern_p33.nix`      | sequential-first；大型 ADT 可能 O(n)          | 4.x        |
| QueryKey + Memo dual-cache consistency      | `lib/default.nix`            | 两层缓存需一致性协议（文档化约定）            | —          |

---

## Phase 4.1 规划：Refined Type Automation

```nix
# 目标：自动化 Refined subtype 检查
# { n : Int | n > 0 } <: { n : Int | n >= 0 }
# → 自动生成 SMT obligation 并求解

# 新增 API：
checkRefinedSubtype = sub: sup: smtSolverFn:
  let
    obl = refinedSubtypeObligation sub sup;
    smtResult = smtSolverFn obl.smtScript;  # 用户提供
  in
  if obl.trivial then { ok = true; trivial = true; }
  else if smtResult == "unsat" then { ok = true; trivial = false; }
  else { ok = false; counterexample = smtResult; };

# 不变量：
# INV-SMT-5: checkRefinedSubtype sound（smtSolver 正确时）
# INV-SMT-6: trivial cases never sent to SMT
```

---

## Phase 4.2 规划：Module System 完善

```nix
# 目标：Functor 组合 + 全局一致性

# 1. Functor composition
composeFunctors = f1: f2:
  let
    p = "M_compose_${builtins.toString (builtins.hashString "md5" f1.repr.param)}";
    body' = applyFunctor f2 (mkTypeDefault (rVar p "compose") KStar);
  in
  mkModFunctor p f1.repr.paramTy body'.result;

# 2. Global InstanceDB coherence
mergeLocalInstances = global: local:
  # Check coherence before merge（INV-MOD-2 upgrade）
  let conflicts = findConflicts global local; in
  if conflicts != [] then { ok = false; conflicts; }
  else { ok = true; db = global // local; };

# 不变量：
# INV-MOD-6: composeFunctors type-correct（kind-checked）
# INV-MOD-7: mergeLocalInstances coherent
```

---

## Phase 4.3 规划：Effect Handler Continuations

```nix
# 目标：delimited control / continuation passing
# handle : Eff(E ++ R, A) → Handler(E, A, B) → Eff(R, B)

# 1. Continuation type
rCont = resultTy: effTy: {
  __variant = "Cont";
  result = resultTy;
  eff    = effTy;
};

# 2. Handler with continuation passing
mkHandlerWithCont = effectTag: branches: returnType:
  let
    contBranches = map (b:
      b // { hasResume = true; resumeType = rCont b.body effTy; }
    ) branches;
  in
  mkHandler effectTag contBranches returnType;

# 3. deep vs shallow handlers
mkShallowHandler = effectTag: branches: returnType:
  (mkHandler effectTag branches returnType) // { shallow = true; };

# 不变量：
# INV-EFF-8: deep handler = handle all occurrences
# INV-EFF-9: shallow handler = handle first occurrence only
```

---

## Phase 5.0 规划：Gradual Types + HM Inference

```nix
# 目标：将 Hindley-Milner type inference 与 constraint solver 统一

# 1. Gradual type（Dynamic）
rDynamic = { __variant = "Dynamic"; };
tDyn = mkTypeDefault rDynamic KStar;

# 2. Consistency（gradual subtype）
# T ~ S if either is Dynamic, or structural equal
isConsistent = t1: t2:
  if t1.repr.__variant == "Dynamic" || t2.repr.__variant == "Dynamic"
  then true
  else typeEq t1 t2;

# 3. HM 推断（unify-based）
# infer : Ctx → Expr → (Type, Constraints)
# solve : Constraints → Subst
# generalize : Ctx → Type → TypeScheme

# 不变量：
# INV-GRAD-1: Dynamic consistent with all types
# INV-GRAD-2: cast insertion = explicit coercion at Dynamic boundaries
# INV-HM-1: infer + solve = principal type（most general）
# INV-HM-2: generalize respects free variables in context
```

---

## 架构反思（Phase 4.0 内部挑刺）

### ❗ 风险 1：QueryDB 与 Memo 双缓存一致性未强制

**现状**：
- `memoLib`（Phase 3.3）：epoch bucket，normalize/subst/solve 专属
- `queryLib`（Phase 4.0）：dep-tracked QueryDB，通用 key-value

**问题**：同一个 normalize 结果可能在两个 cache 中不同步：
```
memoLib.storeNormalize → memo bucket（epoch-keyed）
queryLib.storeResult   → QueryDB（dep-keyed）
# 两者都在使用，但没有 sync protocol
```

**修复方向（Phase 4.1）**：
```nix
# 统一 cache 入口
cacheNormalize = memo: queryDB: typeId: nf: deps:
  let
    memo'   = memoLib.storeNormalize memo type nf;
    qKey    = queryLib.qkNormalize typeId;
    queryDB' = queryLib.storeResult queryDB qKey nf deps;
  in
  { memo = memo'; queryDB = queryDB'; };
```

### ❗ 风险 2：refinedSubtypeObligation 未集成 solver

**现状**：`refinedSubtypeObligation` 返回 smtScript（string）。
**问题**：solver_p40 处理 Refined constraint 时只做 staticEval，无自动 SMT discharge。
**影响**：`{ n : Int | n > 0 } <: { n : Int | n >= 0 }` 类型检查无法自动完成。

**修复方向（Phase 4.1）**：引入 `smtOracle` 接口（用户提供，纯函数）。

### ⚠️ 风险 3：ModFunctor body 的 type subst scope

**现状**：`applyFunctor` 使用 `singleTypeBinding param arg`，直接替换 body 中的 `param`。
**问题**：若 body 包含同名 free type variable（如 `M.T`），替换可能不准确。
**修复方向**：引入 qualified naming（`param.field` → `r.impl.${field}`）。

### ⚠️ 风险 4：QueryKey 无 schema validation

**现状**：storeResult 接受任意 String key，无结构验证。
**风险**：手写 key 可能与 qkNormalize/qkHash 等构造的 key 冲突或格式不一致。
**修复方向**：
```nix
# 所有 key 必须通过 mkQueryKey 构造
# storeResult 校验 key 格式（startsWith known tag）
validateQueryKey = key:
  lib.any (tag: lib.hasPrefix "${tag}:" key)
    ["norm" "hash" "eq" "solve" "check" "kind" "sub" "inst"];
```
