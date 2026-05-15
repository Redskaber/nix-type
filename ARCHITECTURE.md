# nix-types Architecture — Phase 4.3 (Fix Round)

## 版本：4.3.0-fix

---

## 核心设计原则

### INV-SER1（新增，Phase 4.3-Fix）：序列化边界不变式

> **`builtins.toJSON` 绝不直接碰触含 Type 对象、Constraint 对象、或任何可能持有函数引用的结构。**

所有序列化必须经由以下规范路径之一：

- `meta/serialize.nix → serializeRepr r` （TypeRepr 序列化）
- `meta/serialize.nix → serializeConstraint c` （Constraint 序列化）
- `meta/serialize.nix → serializePredExpr pe` （PredExpr 序列化）
- `meta/serialize.nix → serializeType t` （完整 Type 序列化）
- `meta/hash.nix → _safeToJSON v` （最后保护层：tryEval + toString 降级）

违反此不变式会导致 `cannot convert a function to JSON` 运行时崩溃。

---

## 模块层次（Layer 0–22）

```
Layer 0:  core/kind.nix          — Kind 系统（KStar/KArrow/KRow/KEffect/KVar）
Layer 1:  meta/serialize.nix     — 规范序列化（← kindLib）  ★ INV-SER1 核心
Layer 2:  core/meta.nix          — MetaType 控制层
Layer 3:  core/type.nix          — TypeIR 宇宙（← serialLib: _mkId 用 serializeRepr）
Layer 4:  repr/all.nix           — TypeRepr 构造器（25+ 变体）
Layer 5:  normalize/substitute.nix — capture-safe 替换
Layer 6:  normalize/rules.nix    — TRS 规则集（11 规则）
Layer 7:  normalize/rewrite.nix  — TRS 主引擎（← serialLib: _reprKey/_constraintKey）★
Layer 8:  meta/hash.nix          — 规范 hash（← serialLib）★ _safeToJSON 保护
Layer 9:  meta/equality.nix      — 类型等价
Layer 10: constraint/ir.nix      — Constraint IR（← serialLib: sort 用 serializeConstraint）★
Layer 11: runtime/instance.nix   — Instance DB
Layer 12: refined/types.nix      — 精化类型
Layer 13: normalize/unified_subst.nix — UnifiedSubst（三前缀 t:/r:/k:）
Layer 14: constraint/unify_row.nix — Row 多态 unification（← serialLib）★
          constraint/unify.nix   — Robinson unification + Mu bisim（Phase 4.3）
Layer 15: module/system.nix      — Module 系统
Layer 16: effect/handlers.nix    — Effect Handlers + continuations
Layer 17: constraint/solver.nix  — Worklist solver（INV-KIND-1）
Layer 18: bidir/check.nix        — 双向类型推断
Layer 19: incremental/graph.nix  — 依赖图（INV-G1–G5）
Layer 20: incremental/memo.nix   — Memo 层（epoch-based）
          incremental/query.nix  — Query DB
Layer 21: match/pattern.nix      — 模式匹配
```

★ = Phase 4.3-Fix 修改的模块

---

## Phase 4.3-Fix：根因与修复

### 问题描述

`nix run .#test` 崩溃，错误：

```
error: cannot convert a function to JSON
at normalize/rewrite.nix:72:29
```

Nix 报错指向 `normalizeWithFuel = fuel: t:` 的定义处，这是因为 Nix 在 `builtins.toJSON` 失败时，**报告被序列化值的定义位置**，而非 `toJSON` 的调用位置。

### 根因分析

多个 `builtins.toJSON` 调用路径在某些测试场景下会碰触函数值：

| 文件                       | 行       | 具体问题                                                                                 |
| -------------------------- | -------- | ---------------------------------------------------------------------------------------- |
| `constraint/unify_row.nix` | 96       | `builtins.toJSON { a = sa; b = sb; }` — `sa`/`sb` 含 Type 对象，深度序列化时可能遇函数值 |
| `constraint/unify_row.nix` | 109–110  | `builtins.toJSON a` / `builtins.toJSON b` — 直接序列化 Type 对象                         |
| `constraint/ir.nix`        | 38       | `lib.sort (a: b: builtins.toJSON a < builtins.toJSON b)` — 序列化 Constraint 对象        |
| `normalize/rewrite.nix`    | 20,24,38 | `_reprKey`/`_constraintKey` fallback；`or` 在插值内                                      |
| `meta/hash.nix`            | 16,29,60 | 非 Type/Scheme 的 fallback path                                                          |
| `tests/test_all.nix`       | 全局     | 无测试隔离 — 任意一个测试的求值错误中断整个套件                                          |

### 修复策略

1. **`constraint/unify_row.nix`**：添加 `serialLib` 依赖；
   - `_spineKey` 函数用 `serializeRepr` 生成行脊的确定性 key
   - `_unifyTypes` 用 `serializeRepr` 替换 `builtins.toJSON`
   - freshVar name 用 `_spineKey sa + "|" + _spineKey sb` 生成

2. **`constraint/ir.nix`**：`mkImpliesConstraint` 排序比较器改用 `serializeConstraint`

3. **`normalize/rewrite.nix`**：
   - 添加 `serializePredExpr` 继承
   - 新增 `_safeToJSON`（tryEval 保护的安全 JSON 化）
   - 所有 fallback 改用 `_safeToJSON`
   - `_constraintKey` 全面改写：消除 `or` 在插值内（INV-NIX-1），改用 `let` 绑定

4. **`meta/hash.nix`**：`typeHash`/`schemeHash` fallback 改用 `_safeToJSON`

5. **`lib/default.nix`**：`unifyRowLib` 导入添加 `serialLib` 参数；导出 `serializePredExpr`

6. **`tests/test_all.nix`**：`mkTestBool`/`mkTest` 用 `builtins.tryEval` 包裹，实现测试隔离

---

## 不变式体系

| 不变式     | 描述                                                               | 状态 |
| ---------- | ------------------------------------------------------------------ | ---- |
| INV-1      | 所有结构 ∈ TypeIR                                                  | ✅   |
| INV-2      | 所有计算 = Rewrite(TypeIR)，fuel 保证终止                          | ✅   |
| INV-3      | 结果 = NormalForm（无可归约子项）                                  | ✅   |
| INV-4      | typeEq(a,b) ⟹ typeHash(a) == typeHash(b)                           | ✅   |
| INV-6      | Constraint ∈ TypeRepr                                              | ✅   |
| INV-8      | Module functor 组合封闭                                            | ✅   |
| INV-K1     | 每个类型参数有确定 kind                                            | ✅   |
| INV-KIND-1 | Kind constraints 真正求解（Phase 4.3）                             | ✅   |
| INV-MU-1   | Mu bisimulation up-to congruence 正确（Phase 4.3）                 | ✅   |
| INV-EFF-10 | Handler continuation 语义正确（Phase 4.3）                         | ✅   |
| INV-SER1   | `builtins.toJSON` 不直接碰触 Type/函数值（**Phase 4.3-Fix 新增**） | ✅   |
| INV-NIX-1  | `or` 不在 `${}` 插值内（**Phase 4.3-Fix 新增**）                   | ✅   |
| INV-TEST-1 | 单个测试错误不中断整个测试套件（**Phase 4.3-Fix 新增**）           | ✅   |

---

## 序列化边界（INV-SER1 执行图）

```
Type 对象
  └──→ serializeRepr(t.repr)          ← meta/serialize.nix
         └──→ _serializeWithEnv       ← 递归，alpha-eq 规范化

Constraint 对象
  └──→ serializeConstraint(c)         ← meta/serialize.nix
         └──→ serializeRepr(c.*.repr) ← 仅访问 .repr，不触碰 kind/meta

PredExpr 对象
  └──→ serializePredExpr(pe)          ← meta/serialize.nix
         └──→ 递归 PredExpr 节点

未知值（fallback）
  └──→ _safeToJSON(v)                 ← meta/hash.nix / normalize/rewrite.nix
         └──→ tryEval(toJSON(v))
               ├── success → JSON 字符串
               └── failure → toString(v)  ← 永不崩溃
```

---

## 测试套件架构（Phase 4.3-Fix）

```
tests/test_all.nix
  mkTestBool name cond           → tryEval cond → pass/fail（不崩溃）
  mkTest name result expected    → tryEval result × tryEval expected
  runGroup name tests            → { passed; total; failed; ok }
  allGroups = [t1..t23]
  totalPassed = foldl' (+ .passed) 0 allGroups
  summary = "Passed: X / Y"
```

**INV-TEST-1**：每个 `mkTestBool`/`mkTest` 调用通过 `builtins.tryEval` 独立求值。
一个测试的运行时错误（如 `assert` 失败、类型错误）标记为 `pass=false`，
不会通过 lazy evaluation 传播到 `totalPassed` 导致整个测试集崩溃。

---

## 文件结构

```
nix-types/
├── core/
│   ├── kind.nix          Layer 0: Kind 系统
│   ├── type.nix          Layer 3: TypeIR
│   └── meta.nix          Layer 2: MetaType
├── repr/all.nix          Layer 4: TypeRepr 构造器
├── normalize/
│   ├── substitute.nix    Layer 5
│   ├── rules.nix         Layer 6
│   ├── rewrite.nix       Layer 7  ★ Fixed
│   └── unified_subst.nix Layer 13
├── meta/
│   ├── serialize.nix     Layer 1  ★ INV-SER1 核心
│   ├── hash.nix          Layer 8  ★ Fixed
│   └── equality.nix      Layer 9
├── constraint/
│   ├── ir.nix            Layer 10 ★ Fixed
│   ├── unify.nix         Layer 14
│   ├── unify_row.nix     Layer 14 ★ Fixed
│   └── solver.nix        Layer 17
├── runtime/instance.nix  Layer 11
├── refined/types.nix     Layer 12
├── module/system.nix     Layer 15
├── effect/handlers.nix   Layer 16
├── bidir/check.nix       Layer 18
├── incremental/
│   ├── graph.nix         Layer 19
│   ├── memo.nix          Layer 20
│   └── query.nix         Layer 20
├── match/pattern.nix     Layer 21
├── lib/default.nix       统一导出  ★ Fixed
├── tests/test_all.nix    测试套件  ★ Fixed
└── flake.nix
```

---

## 变更记录

| 版本    | 主要变更                                                          |
| ------- | ----------------------------------------------------------------- |
| 4.0     | UnifiedSubst 三前缀架构，Phase 分离                               |
| 4.1     | Row 多态 + Effect Handlers                                        |
| 4.2     | Kind 约束 + serialize.nix + HM Scheme 约束                        |
| 4.3     | Mu bisim up-to congruence，Handler continuations，Kind inference  |
| 4.3-Fix | **INV-SER1/NIX-1/TEST-1**：消除所有不安全 `toJSON` 调用；测试隔离 |
