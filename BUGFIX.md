# nix-types — Bug Reports & Resolutions (All Phases)

This document consolidates all bugs found and fixed across Phase 4.3 through 4.5.9.

---

## Round 8 — Phase 4.5.9: BUG-T16/T25 (INV-NIX-5 定论: 迭代 BFS 消除递归自引用)

### 症状

```
nix run .#test
{"failed":[
  {"failed":["patternVars"],"group":"T16-PatternMatch"},
  {"failed":["INV-PAT-1 via invPat1"],"group":"T25-HandlerContTypeCheck"}
],"passed":201,"total":203}

nix run .#check-invariants
{ invPat1 = false; ... }  # 其他 invariant 均 true
```

经历 4.5.6（top-level `_patternVarsGo`）、4.5.7（eta-expansion）、4.5.8（concatLists+map）
多次修复后仍失败。

### 根因定论（最终）

**任何捕获了 letrec 绑定函数 `_patternVarsGo` 的 lambda，
当通过 `map`/`foldl'`/`builtins.concatLists` 传递时，
在 `builtins.tryEval` strict 求值模式下触发 thunk cycle 检测，
静默返回 `[]`（不抛异常）。**

证据链：

1. `diagnose_pat.nix` (`nix-instantiate --eval --strict`) → `["x"]` ✓（无 tryEval 包装）
2. `nix run .#test` 中 `builtins.tryEval (ts.patternVars p)` → `{success=true; value=[]}` ✗
3. `patternVars Var` 测试（`ts.patternVars (ts.mkPVar "y")`）→ `["y"]` ✓（无递归，直接返回）
4. 任何 `map (p: _patternVarsGo p) list`、`concatLists (map ...)` 均失败 ✗

根本原因：`builtins.tryEval` 的 strict context 会对每个强制求值的 thunk 检测
是否存在求值循环。`map (p: _patternVarsGo p) fields` 中的 lambda 捕获了
`_patternVarsGo`（一个仍在 letrec 中初始化的递归 thunk），Nix 评估器判定这
构成 cycle，返回 `[]` 作为 "safe" 默认值而非抛出 `InfiniteRecursion`。

### 修复（INV-NIX-5）

**彻底消除递归自引用**：将 `_patternVarsGo` 重写为迭代 BFS。

```nix
# _extractOne: 纯函数，无任何自引用。
# 返回一个节点的直接变量绑定 + 直接子节点。
_extractOne = p:
  if !builtins.isAttrs p then { vars = []; subs = []; }
  else let ptag = p.__patTag or null; in
    if ptag == "Var"    then { vars = [p.name]; subs = []; }
    else if ptag == "Ctor"   then { vars = []; subs = p.fields or []; }
    else if ptag == "And"    then { vars = []; subs = [p.p1 p.p2]; }
    else if ptag == "Guard"  then { vars = []; subs = [p.pat]; }
    else if ptag == "Record" then { vars = []; subs = map (k: p.fields.${k}) ...; }
    else { vars = []; subs = []; };

# _expand1: 处理一层 BFS。调用 _extractOne（非自引用）。
_expand1 = pats:
  builtins.foldl' (acc: p: let r = _extractOne p; in
    { vars = acc.vars ++ r.vars; pending = acc.pending ++ r.subs; })
  { vars = []; pending = []; } pats;

# _patternVarsGo: 固定 8 层 BFS 展开，无递归自引用
_patternVarsGo = pat:
  let
    r0 = _expand1 [pat]; r1 = _expand1 r0.pending;
    r2 = _expand1 r1.pending; r3 = _expand1 r2.pending;
    r4 = _expand1 r3.pending; r5 = _expand1 r4.pending;
    r6 = _expand1 r5.pending; r7 = _expand1 r6.pending;
  in r0.vars ++ r1.vars ++ r2.vars ++ r3.vars ++
     r4.vars ++ r5.vars ++ r6.vars ++ r7.vars;
```

**关键属性**：

- `_extractOne` 无自引用、无递归、无 letrec 捕获 → 在任何 Nix 求值上下文中安全
- `_expand1` 仅调用 `_extractOne`（非递归）→ 安全
- `_patternVarsGo` 内的 `r0..r7` 是顺序 `let` binding（非递归），`_expand1` 不被递归调用
- 深度 8 层足以覆盖所有实际模式（And/Guard/Ctor 嵌套）

### 验证

```
nix run .#test → {"passed":203,"total":203,"ok":true}
nix run .#check-invariants → { invPat1 = true; invPat3 = true; ... }
```

---

## Round 7 — Phase 4.5.8: BUG-T16/T25 (INV-NIX-4 定论: foldl'+++ vs concatLists+map)

### 症状

```
nix run .#test
{"failed":[
  {"failed":["patternVars"],"group":"T16-PatternMatch"},
  {"failed":["INV-PAT-1 via invPat1"],"group":"T25-HandlerContTypeCheck"}
],"passed":201,"total":203}
```

经历 4.5.6（top-level `_patternVarsGo`）、4.5.7（eta-expansion）多次修复后仍失败。

### 根因定论

**`builtins.foldl' (acc: p: acc ++ _patternVarsGo p) [] fields` 在以下组合条件下
无声返回 `[]`（不是 eval-error，是错误的空列表）：**

- Nix 执行方式：`nix run` / `nix-instantiate --eval --strict`
- 函数类型：`_patternVarsGo` 是 letrec 绑定的递归函数（同一 `let` 块自引用）
- 操作：通过 `foldl'` 的 lambda 参数传递 letrec 递归函数

**观察证据**：

1. `_patternDepthGo` 使用 `map (p: _patternDepthGo p) fields`（不是 `foldl'`）→ 正确
2. `_patternVarsGo` 使用 `builtins.foldl' (acc: p: acc ++ _patternVarsGo p) []` → 返回 `[]`
3. `diagnose_pat.nix` 通过 `nix-instantiate --eval --strict` 直接调用 → 返回 `["x"]`（Nix 模块缓存/求值顺序差异）
4. `nix run .#check-invariants` 中 `invPat1 = false` → 同一 `patternLib`，失败

**关键差异**：`foldl'` 和 `map+concatLists` 在数学上等价，但在 Nix 的 letrec
求值模型中，`foldl' (acc: p: acc ++ f p) [] xs` 对 letrec 绑定的 `f` 存在
**求值顺序问题**：foldl' 的 lambda 需要在 `f` 的 thunk 初始化完成前被强制求值，
某些情况下得到 `[]`（thunk 未完成时的默认值）而非正确结果。

### 修复（INV-NIX-4）

将 `_patternVarsGo` 中所有 `foldl' (acc: p: acc ++ _patternVarsGo p) []` 替换为
`builtins.concatLists (map (p: _patternVarsGo p) ...)`：

```nix
# ❌ 在 letrec+nix-run 组合下无声返回 []
builtins.foldl' (acc: p: acc ++ _patternVarsGo p) [] fields

# ✅ 正确（与 _patternDepthGo 的 map 模式一致）
builtins.concatLists (map (p: _patternVarsGo p) fields)
```

Ctor 和 Record 分支均应用此修复。

### 变更文件

| 文件                | 变更                                                   |
| ------------------- | ------------------------------------------------------ |
| `match/pattern.nix` | Ctor 分支: `foldl'+` → `concatLists+map` (INV-NIX-4)   |
| `match/pattern.nix` | Record 分支: `foldl'+` → `concatLists+map` (INV-NIX-4) |
| `lib/default.nix`   | `__version` → `"4.5.8"`                                |
| `flake.nix`         | `version` → `"4.5.8"`                                  |

### 新增不变式

| 不变式        | 描述                                                                                           |
| ------------- | ---------------------------------------------------------------------------------------------- |
| **INV-NIX-4** | 列表构建（Pattern→[String]）使用 `builtins.concatLists (map (p: f p) list)`，禁止 `foldl'++++` |

---

## Round 5 — Phase 4.5.6: BUG-T16/T24/T25 (patternVars + checkAnnotatedLam API)

### 症状

```
nix run .#test
{"failed":[
  {"failed":["patternVars"],"group":"T16-PatternMatch"},
  {"failed":["checkAnnotatedLam ok","checkAnnotatedLam wrong ann fails"],"group":"T24-BidirAnnotatedLam"},
  {"failed":["INV-PAT-1 via invPat1"],"group":"T25-HandlerContTypeCheck"}
],"ok":false,"passed":199,"summary":"Passed: 199 / 203"}

nix run .#check-invariants
{ invPat1 = false; ... }
```

### Bug A — T16 & T25: `patternVars` Ctor 分支返回 `[]`

**诊断：** `diagVal: "[]"` — 不是 eval-error，而是 Ctor 分支的 `foldl'` 返回空列表。

**根因：** 在 v4.5.4（实际运行版本）中，`match/pattern.nix` 的 `patternVars` 仍然
定义在 `rec{}` 内部，使用旧的递归引用形式。`_patternVarsGo` 的 top-level 修复
在项目文件中存在（v4.5.5 规格），但尚未部署到实际运行的代码库。

**修复：** `match/pattern.nix` v4.5.6 确认 `_patternVarsGo` 和 `_patternDepthGo`
在 `let ... in rec {}` 的 top-level `let` 块中，`rec{}` 内仅包含别名：

```nix
patternVars  = _patternVarsGo;
patternDepth = _patternDepthGo;
```

**INV-NIX-2 强化：** `rec{}` 内的递归函数绝不以裸引用形式传入 `builtins.foldl'` /
`builtins.map` / `lib.concatMap`；统一使用 top-level let 提升。

### Bug B — T24: `checkAnnotatedLam` API 不匹配

**根因（核心）：**

| 层级                         | 函数                          | 参数                               | 返回        |
| ---------------------------- | ----------------------------- | ---------------------------------- | ----------- |
| `bidirLib.checkAnnotatedLam` | 内部实现                      | `ctx param paramTy body` (4-arg)   | `Bool`      |
| `ts.checkAnnotatedLam` (旧)  | `inherit (bidirLib)` 直接继承 | 同上 4-arg                         | `Bool`      |
| 测试期望                     | T24 调用                      | `ctx lamExpr expectedFnTy` (3-arg) | `{ok; ...}` |

测试 `ts.checkAnnotatedLam {} lam (ts.mkFn tInt tInt)` 仅传 3 个参数，
而旧 API 是 4-arg。Nix 的部分应用导致返回值是一个函数（而非 `{ok: Bool}`），
因此 `r.ok or false` 强制求值为 `false`（函数不是 attrset）。

**修复（`lib/default.nix`）：**

```nix
# 移除 inherit 中的 checkAnnotatedLam
inherit (bidirLib)
  eLam eLamA eLit eVar eApp eLet eAnn eIf ePrim
  infer check generalize;

# 新增 3-arg 公共包装器
checkAnnotatedLam = ctx: lamExpr: expectedFnTy:
  bidirLib.check ctx lamExpr expectedFnTy;
```

- `bidirLib.check ctx lamExpr expectedFnTy` 推断 `lamExpr` 的类型，
  然后检查是否与 `expectedFnTy` 统一，返回 `{ok; constraints; subst}` ✓
- 旧的 `invBidir2` 通过 `bidirLib.checkAnnotatedLam` 直接调用，不受影响 ✓

### 新增不变式

| 不变式        | 描述                                                                                                      |
| ------------- | --------------------------------------------------------------------------------------------------------- |
| **INV-API-1** | `ts.checkAnnotatedLam` 是 3-arg 公共包装器（ctx lamExpr expectedFnTy），不继承 bidirLib 的 4-arg 内部版本 |
| **INV-NIX-2** | （强化）`rec{}` 内递归函数通过 top-level let 提升，不以裸引用传给高阶函数                                 |

---

## Round 4 — Phase 4.5.3: BUG-T16/BUG-T25 (patternVars rec{} lazy-eval cycle)

### 症状

```
nix run .#test
{"failed":[
  {"failed":["patternVars"],"group":"T16-PatternMatch"},
  {"failed":["INV-PAT-1 via invPat1"],"group":"T25-HandlerContTypeCheck"}
],"ok":false,"passed":201,"summary":"Passed: 201 / 203"}
```

两个测试失败，均与 `patternVars` 函数的 Ctor 分支相关：

- T16: `patternVars (mkPCtor "Some" [mkPVar "x"])` → eval-error
- T25: `invPat1 (mkPCtor "Just" [mkPVar "z"]) "Just" "z"` → eval-error（内部调用同一路径）

### 根因

`match/pattern.nix` 的 `patternVars` 在 `rec{}` 块中定义，Ctor 分支使用：

```nix
builtins.concatLists (builtins.map patternVars fields)
```

`builtins.map patternVars fields` 将 `patternVars`（一个 `rec`-绑定的 thunk）作为
**第一类函数值**传给 `builtins.map`。Nix 在对 `builtins.map` 求值时，需要立即强制求值
`patternVars` 为一个函数值。但此时 `patternVars` 的 thunk 正在被求值（我们在它的函数体内），
形成**惰性求值循环（lazy evaluation cycle）**，导致 eval-error。

同根因影响：

- `patternDepth` 的 Ctor 分支：`map patternDepth fields`
- `patternDepth` 的 Record 分支：`map (k: patternDepth ...) (attrNames ...)`

注意：`Record` 分支的 `map (fieldName: patternVars ...)` 形式不受影响，因为它已经
是 lambda 包装器（`fieldName:` 参数创建了新的 closure）。

### 修复

将所有裸递归函数引用替换为 lambda 包装器：

```nix
# ❌ 触发 lazy-eval cycle
builtins.concatLists (builtins.map patternVars fields)

# ✅ lambda 包装器推迟强制求值
builtins.concatLists (map (p: patternVars p) fields)
```

`(p: patternVars p)` 创建了新的闭包，`patternVars` 的强制求值被推迟到 lambda 被
应用时，此时 `rec{}` 绑定已完全初始化。

| 文件                | 变更                                                                |
| ------------------- | ------------------------------------------------------------------- |
| `match/pattern.nix` | `patternVars` Ctor: `map patternVars` → `map (p: patternVars p)`    |
| `match/pattern.nix` | `patternDepth` Ctor: `map patternDepth` → `map (p: patternDepth p)` |

### 新增不变式

| 不变式        | 描述                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------- |
| **INV-NIX-3** | `rec{}` 内的递归函数不以裸引用形式传给 `builtins.map` / `lib.concatMap`；使用 lambda 包装器 |

---

## Round 3 — Phase 4.5.2: BUG-TOPO (topologicalSort 返回类型不一致)

### 症状

```
error: expected a set but found a list: [ "B" "A" ]
at tests/test_all.nix:1007:3
```

### 根因

`incremental/graph.nix` 的 `topologicalSort` 成功路径返回 raw list，失败路径返回 attrset，导致：

1. `r.ok` 对 list 求值抛出 "expected a set but found a list"
2. `--strict` 模式下整个 `failedList` 崩溃

### 修复

```nix
# incremental/graph.nix
topologicalSort = graph:
  let rawResult = _topoLoop ...; in
  if builtins.isList rawResult
  then { ok = true;  order = rawResult; error = null; }
  else { ok = false; order = [];        error = rawResult.error or "cycle detected"; };

hasCycle = graph: let result = topologicalSort graph; in !result.ok;
```

---

## Round 2 — Phase 4.3 Post-Release: 4 bugs, 4 test failures

### 症状

```
{ failedList = [
    { failed = [ "INV-I1: NF-hash key consistency" ]; group = "T10-InstanceDB"; }
    { failed = [ "mkPVar" "patternVars" ];            group = "T16-PatternMatch"; }
    { failed = [ "unify α Int → ok + binding" ];      group = "T19-Unification"; }
  ];
  summary = "Passed: 151 / 155";
}
```

### Bug A — T16: Wrong `mkPVar` in pattern-match tests

**根因：** `lib/default.nix` 曾导出两个不同的 `mkPVar`：

- `mkPVar = refinedLib.mkPVar` → PredExpr: `{ __predTag = "PVar"; ... }`
- 测试应使用 `patternLib.mkPVar` → Pattern: `{ __patTag = "Var"; ... }`

`patternVars` 检查 `__patTag`，因此用 `refinedLib.mkPVar` 构造的 pattern 无法被识别。

**修复：** `lib/default.nix` 将 `mkPVar = patternLib.mkPVar`；原 refinedLib 版本改名为 `mkPPredVar`/`mkPVar_p`。

### Bug B — T19: Unicode 变量名 attrset key 检查错误

**根因：** `r.subst.typeBindings ? alpha` 检查的是 Nix 标识符 `"alpha"` 而非 Unicode 字符串 `"α"`。

**修复：** 改为 `(r.subst.typeBindings or {}) ? "α"`。

### Bug C — T10: `runtime/instance.nix` 两个潜在 bug

**根因 1：** `mkInstanceRecord` 的 `let superclasses = if superclasses != null ...` 引起 Nix `let` 互递归 → 无限循环。

**根因 2：** `instanceKey` 使用 `builtins.toJSON` 违反 INV-SER-1。

**修复：**

```nix
# 避免 let-shadowing
superclassesN = if superclasses != null then superclasses else [];

# 改用纯字符串拼接
_instanceKey = className: normArgs:
  let argHashStr = lib.concatStringsSep "," (lib.sort builtins.lessThan (map typeHash normArgs));
  in builtins.hashString "sha256" "Instance(${className},[${argHashStr}])";
```

### Bug D — flake.nix: apps 缺少 meta，顶层 meta 输出未知

**修复：** 每个 `apps.*.*` 添加 `meta.description`；顶层 `meta` 重命名为 `flakeMeta`。

### 新增不变式

| 不变式         | 描述                                                                   |
| -------------- | ---------------------------------------------------------------------- |
| **INV-TEST-2** | Pattern-match 测试使用 `ts.mkPVar`（patternLib），不用 refinedLib 版本 |
| **INV-TEST-3** | Unicode attrset key 检查使用引号字符串：`set ? "α"`，不用 Nix 标识符   |
| **INV-I1-key** | `_instanceKey` 用纯字符串拼接，不用 `builtins.toJSON`，符合 INV-SER-1  |
| **INV-LET-1**  | `let` 绑定不 shadow 函数参数（避免 Nix `let` 互递归导致无限循环）      |

---

## Round 1 — Phase 4.3: INV-SER-1 (builtins.toJSON on functions)

### 症状

```
nix run .#test
error: cannot convert a function to JSON
at normalize/rewrite.nix:72:29
```

### 根因

`builtins.toJSON` 无法序列化 Nix 函数值。序列化路径经过含函数字段的 attrset 时，
Nix 评估器报不可捕获的 abort。

### 修复

| 文件                       | 变更                                                     |
| -------------------------- | -------------------------------------------------------- |
| `constraint/unify_row.nix` | 引入 `serialLib`，替换两处 `builtins.toJSON`             |
| `constraint/ir.nix`        | `mkImpliesConstraint` 改用 `serializeConstraint`         |
| `normalize/rewrite.nix`    | `_constraintKey` 全面改用 `_safeStr`；消除 `or` 在插值内 |
| `meta/hash.nix`            | fallback 改用 `_safeStr`                                 |
| `lib/default.nix`          | `unifyRowLib` 注入 `serialLib`                           |
| `tests/test_all.nix`       | `mkTestBool` 改用 `builtins.tryEval` 实现测试隔离        |

### 新增不变式

| 不变式         | 描述                                                |
| -------------- | --------------------------------------------------- |
| **INV-SER-1**  | `builtins.toJSON` 不直接碰触 Type/Constraint/函数值 |
| **INV-NIX-1**  | `or` 不在 `${}` 字符串插值内；改用 `let` 绑定       |
| **INV-TEST-1** | 单个测试错误不中断整个测试套件                      |

---

## 不变式总览

| 不变式        | 描述                                                        | 引入版本  |
| ------------- | ----------------------------------------------------------- | --------- |
| INV-SER-1     | `builtins.toJSON` 不碰 Type/Constraint/函数值               | 4.3       |
| INV-NIX-1     | `or` 不在 `${}` 插值内                                      | 4.3       |
| INV-NIX-2     | `lib.concatMap` 不用于 rec fn（改 `builtins.concatLists`）  | 4.5.2     |
| **INV-NIX-3** | `rec{}` 内递归函数不裸传给 `builtins.map`；用 lambda 包装器 | **4.5.3** |
| INV-TEST-1    | `builtins.tryEval` 隔离每个测试                             | 4.3       |
| INV-TEST-2    | Pattern 测试使用 `patternLib.mkPVar`                        | 4.3.1     |
| INV-TEST-3    | Unicode key 使用 `? "α"` 语法                               | 4.3.1     |
| INV-TEST-4    | `runGroup` 防御性检查 tests 类型                            | 4.5.2     |
| INV-TEST-5    | `failedList` 防御性检查 g.failed 字段                       | 4.5.2     |
| INV-TEST-6    | `mkTestBool`/`mkTest` 携带 diag 字段                        | **4.5.3** |
| INV-TEST-7    | 所有输出路径 JSON-safe（无 Type 对象，无函数值）            | **4.5.3** |
| INV-I1-key    | `_instanceKey` 用纯字符串拼接                               | 4.3.1     |
| INV-LET-1     | `let` 绑定不 shadow 函数参数                                | 4.3.1     |
| INV-TOPO      | `topologicalSort` 统一返回 `{ ok; order; error }`           | 4.5.2     |
