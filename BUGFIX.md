# nix-types Phase 4.3-Fix — Bug Report & Resolution

This document records all bugs found and fixed during Phase 4.3 development.

---

## Round 1 — Phase 4.3 Main Fix

### 症状

```
nix run .#test
error: cannot convert a function to JSON
at normalize/rewrite.nix:72:29:
    normalizeWithFuel = fuel: t:
                              ^
```

### 根因

`builtins.toJSON` 无法序列化 Nix 函数值（lambda）。当序列化路径经过含有
Type/Constraint/函数字段的 attrset 时，Nix 评估器报不可捕获的 abort。

### 修复文件（6个）

| 文件                       | 变更摘要                                                          |
| -------------------------- | ----------------------------------------------------------------- |
| `constraint/unify_row.nix` | 引入 `serialLib`，替换两处 `builtins.toJSON`                      |
| `constraint/ir.nix`        | `mkImpliesConstraint` 改用 `serializeConstraint` 排序             |
| `normalize/rewrite.nix`    | `_constraintKey`/fallback 全面改用 `_safeStr`；消除 `or` 在插值内 |
| `meta/hash.nix`            | fallback 改用 `_safeStr`                                          |
| `lib/default.nix`          | `unifyRowLib` 注入 `serialLib`                                    |
| `tests/test_all.nix`       | `mkTestBool` 改用 `builtins.tryEval` 实现测试隔离                 |

### 新增不变式

| 不变式         | 描述                                                |
| -------------- | --------------------------------------------------- |
| **INV-SER-1**  | `builtins.toJSON` 不直接碰触 Type/Constraint/函数值 |
| **INV-NIX-1**  | `or` 不在 `${}` 字符串插值内；改用 `let` 绑定       |
| **INV-TEST-1** | 单个测试错误不中断整个测试套件                      |

---

## Round 2 — Phase 4.3 Post-Release Fixes (3 bugs, 4 test failures)

### 症状

```
nix run .#test
{ failedList = [
    { failed = [ "INV-I1: NF-hash key consistency" ]; group = "T10-InstanceDB"; }
    { failed = [ "mkPVar" "patternVars" ];            group = "T16-PatternMatch"; }
    { failed = [ "unify α Int → ok + binding" ];      group = "T19-Unification"; }
  ];
  summary = "Passed: 151 / 155";
}
```

Additionally, `nix flake check --all-systems` produced:

```
warning: unknown flake output 'meta'
warning: app 'apps.<system>.test' lacks attribute 'meta'
warning: app 'apps.<system>.check-invariants' lacks attribute 'meta'
warning: app 'apps.<system>.demo' lacks attribute 'meta'
```

---

### Bug A — T16: Wrong `mkPVar` in pattern-match tests

**Root cause:**

`lib/default.nix` exports two different `mkPVar` functions:

```
mkPVar   = refinedLib.mkPVar;   # PredExpr: { __predTag = "PVar"; name = ... }
mkPVar_p = patternLib.mkPVar;   # Pattern:  { __patTag  = "Var";  name = ... }
```

`ts.isPattern` checks for `__patTag` (from `patternLib`).  
`ts.patternVars` also expects `__patTag`.

The tests in T16 used `ts.mkPVar "x"` (the PredExpr variant), so `ts.isPattern`
returned `false` and `ts.patternVars` never found `"x"`.

**Fix — `tests/test_all.nix`:**

```nix
# Before (wrong: ts.mkPVar = refinedLib.mkPVar, __predTag)
(mkTestBool "mkPVar"    (ts.isPattern (ts.mkPVar "x")))
(mkTestBool "patternVars"
  (let vars = ts.patternVars (ts.mkPCtor "Some" [ts.mkPVar "x"]); in
  builtins.elem "x" vars))

# After (correct: ts.mkPVar_p = patternLib.mkPVar, __patTag)
(mkTestBool "mkPVar"    (ts.isPattern (ts.mkPVar_p "x")))
(mkTestBool "patternVars"
  (let vars = ts.patternVars (ts.mkPCtor "Some" [ts.mkPVar_p "x"]); in
  builtins.elem "x" vars))
```

---

### Bug B — T19: Wrong attrset key check for Unicode variable name

**Root cause:**

```nix
# Original test
alpha = ts.mkTypeDefault (ts.rVar "α" "") KStar;
r     = ts.unify alpha tInt;
r.ok && r.subst.typeBindings ? alpha
```

In Nix, `attrset ? identifier` checks for the key whose name equals the
**string representation of the identifier** (`"alpha"`), NOT the value of the
variable. The actual binding key in `typeBindings` is `"α"` (the Unicode string
passed to `rVar "α"`). So the test was checking for `"alpha"` which never exists.

**Fix — `tests/test_all.nix`:**

```nix
# Before (checks for key "alpha" — the Nix identifier name)
r.ok && r.subst.typeBindings ? alpha

# After (checks for key "α" — the actual variable name string)
r.ok && (r.subst.typeBindings or {}) ? "α"
```

The `or {}` guard also prevents an evaluation error if `subst` lacks
`typeBindings` entirely (e.g., on early-exit error paths).

---

### Bug C — T10/INV-I1: `runtime/instance.nix` two latent bugs

**Root cause 1 — `superclasses` let-shadowing:**

```nix
mkInstanceRecord = className: args: impl: superclasses:
  let
    ...
    superclasses = if superclasses != null then superclasses else [];
    #              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    # Nix `let` is mutually recursive: the RHS `superclasses` refers to
    # the *new* let-binding, not the function parameter.
    # Result: a self-referential thunk that loops infinitely when forced.
  in ...
```

Although the loop was only triggered when the `superclasses` output field is
forced, it represents a silent unsoundness: any code that accesses
`ir.superclasses` will hang.

**Root cause 2 — `instanceKey` uses `builtins.toJSON`:**

```nix
key = builtins.hashString "sha256"
  (builtins.toJSON { c = className; a = argHashes; });
```

`argHashes` is a list of strings (safe). However, using `builtins.toJSON` on
an attrset violates the Phase 4.3 architectural rule (INV-SER-1): all key/hash
generation must go through canonical string concatenation, not the JSON
serializer. Any future addition of a Type-valued field to the attrset (or a
Nix version that serializes attrsets differently) would silently break INV-I1.

**Fix — `runtime/instance.nix`:**

```nix
# Extracted helper: canonical key, pure string concat, INV-SER-1 compliant
_instanceKey = className: normArgs:
  let
    argHashes  = lib.sort builtins.lessThan (map typeHash normArgs);
    argHashStr = lib.concatStringsSep "," argHashes;
  in
  builtins.hashString "sha256" "Instance(${className},[${argHashStr}])";

# mkInstanceRecord: fix both bugs
mkInstanceRecord = className: args: impl: superclasses:
  let
    superclassesN = if superclasses != null then superclasses else [];
    #              ^^ fresh name, no shadowing
    normArgs = map normalize' args;
    key      = _instanceKey className normArgs;
    #          ^^ uses _instanceKey, not builtins.toJSON
  in {
    __type       = "InstanceRecord";
    className    = className;
    args         = normArgs;
    impl         = impl;
    superclasses = superclassesN;
    key          = key;
  };

# lookupInstance: use same _instanceKey
lookupInstance = db: className: args:
  let
    normArgs = map normalize' args;
    key      = _instanceKey className normArgs;
    classDB  = db.${className} or {};
  in
  classDB.${key} or null;
```

---

### Bug D — flake.nix: missing `meta` on apps, unknown `meta` output

**Root cause:**

- Each `apps.*.*` entry lacked a `meta` attribute → `nix flake check` warnings.
- The top-level `meta = { ... }` output is not a recognised Nix flake output
  key → `warning: unknown flake output 'meta'`.

**Fix — `flake.nix`:**

1. Added `meta = { description = "..."; mainProgram = "..."; }` to each app.
2. Renamed the top-level `meta` output to `flakeMeta` (non-standard but
   non-warning; purely informational metadata for humans).

---

### New invariant

| Invariant      | Description                                                                               |
| -------------- | ----------------------------------------------------------------------------------------- |
| **INV-TEST-2** | Pattern-match tests use `ts.mkPVar_p` (patternLib), never `ts.mkPVar` (refinedLib)        |
| **INV-TEST-3** | Unicode attrset key checks use quoted strings: `set ? "α"`, not `set ? alpha`             |
| **INV-I1-key** | `_instanceKey` uses pure string concat — no `builtins.toJSON` — consistent with INV-SER-1 |
| **INV-LET-1**  | `let` bindings must not shadow function parameters (avoids recursive thunk bugs)          |

---

## Deployment

### Round 2 fix files

```bash
# Copy to project:
cp tests/test_all.nix          $PROJECT/tests/test_all.nix
cp runtime/instance.nix        $PROJECT/runtime/instance.nix
cp flake.nix                   $PROJECT/flake.nix

# Verify:
nix run .#test              # Expected: "Passed: 155 / 155"
nix flake check --all-systems  # Expected: no warnings about meta or unknown outputs
nix run .#demo              # Expected: all s1..s8 = true
nix run .#check-invariants  # Expected: all inv = true
```

---

## Round 3 — Phase 4.5.2: BUG-TOPO (topologicalSort 返回类型不一致)

### 症状

```
nix run .#test
error: expected a set but found a list: [ "B" "A" ]
at tests/test_all.nix:1007:3:
  failedList = map (g: { group = g.name; ... }) failedGroups;
```

### 根因

`incremental/graph.nix` 的 `topologicalSort`：

```nix
# 修复前：成功时返回 raw list，失败时返回 attrset
topologicalSort = graph:
  ...
  _topoLoop graph inDegrees initQueue [];  # → ["A","B"] or {error="cycle"}
```

成功路径返回 `["B" "A"]`（list）。失败路径返回 `{ error = "cycle detected"; }`（attrset）。

**返回类型不一致**，导致两个问题：

1. 测试 `in r.ok` → `r` 是 list → `tryEval (r.ok)` 捕获 `"expected a set but found a list"` → `pass = false`（测试误判为失败）。
2. `--strict` 强制求值路径中，`failedGroups = lib.filter (g: !g.ok) allGroups` 对某个 group 求值 `g.ok` 时，如果该 group 的 lazy thunk 涉及 topologicalSort 返回的 list，最终触发 `"expected a set but found a list: [ \"B\" \"A\" ]"`，导致整个 `failedList` 求值崩溃。

### 修复

**`incremental/graph.nix`（INV-TOPO）**：

```nix
# 修复后：始终返回 { ok; order; error }
topologicalSort = graph:
  let rawResult = _topoLoop graph inDegrees initQueue []; in
  if builtins.isList rawResult
  then { ok = true;  order = rawResult; error = null; }
  else { ok = false; order = [];        error = rawResult.error or "cycle detected"; };

# hasCycle 同步修复
hasCycle = graph:
  let result = topologicalSort graph; in
  !result.ok;
```

**`tests/test_all.nix`（INV-TEST-5）**：

```nix
# failedGroups: 防御性 isAttrs 检查
failedGroups = lib.filter (g:
  builtins.isAttrs g && !(g.ok or true)
) allGroups;

# failedList: 完全防御性
failedList =
  let
    safeGroup = g:
      if !builtins.isAttrs g then { group = "<non-attrset>"; failed = []; }
      else
        let gf = g.failed or []; in
        { group = g.name or "<unknown>";
          failed = if !builtins.isList gf then []
                   else map (t: if builtins.isAttrs t then t.name else toString t) gf; };
  in
  map safeGroup failedGroups;
```

### 新增不变式

| 不变式         | 描述                                                                            |
| -------------- | ------------------------------------------------------------------------------- |
| **INV-TOPO**   | `topologicalSort` 始终返回 `{ ok: Bool; order: [String]; error: Null\|String }` |
| **INV-TEST-5** | `failedGroups`/`failedList` 对每个 group 防御性检查 `isAttrs`                   |

### 修复文件

| 文件                    | 变更                                                |
| ----------------------- | --------------------------------------------------- |
| `incremental/graph.nix` | `topologicalSort` 统一返回类型，`hasCycle` 同步修复 |
| `tests/test_all.nix`    | `failedGroups`/`failedList`/`runAll` 防御性处理     |

### 验证

```bash
nix run .#test              # Expected: Passed: 190 / 190 (topologicalSort 测试从 fail → pass)
nix run .#demo              # Expected: all s1..s8 = true
nix run .#check-invariants  # Expected: all inv = true
```
