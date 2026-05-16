# testlib/default.nix
# 测试框架新增能力：
#   mkTestBool  - 布尔断言（带错误上下文，INV-TEST-1）
#   mkTestEq    - 等值断言（actual vs expected，带类型信息）
#   mkTestEval  - 求值断言（验证不抛异常）
#   mkTestError - 负面测试（验证 cond 为 false 或 eval-error）
#   mkTestExpr  - 带诊断表达式的测试（捕获中间值）
#   testGroup   - 组级聚合（INV-TEST-4：防御性检查）
#   runGroups   - JSON-safe 摘要输出
#   diagnoseAll - 详细诊断输出（含失败详情和实际值）
#   failedList  - 精确失败列表（INV-TEST-5）
#
# 不变式：
#   INV-TEST-1: builtins.tryEval 隔离每个测试，单失败不中断整个套件
#   INV-TEST-4: tb.testGroup 防御性检查 tests 参数类型
#   INV-TEST-5: failedList 防御性检查 g.failed 字段
#   INV-TEST-6: tb.mkTestBool/mkTest 均携带 diag 字段供调试
#   INV-TEST-7: 诊断输出 JSON-safe（无 Type 对象，无函数值）


{ lib ? (import <nixpkgs> {}).lib }:
let
  # ════════════════════════════════════════════════════════════════════
  # 诊断辅助函数（Diagnostic Helpers）
  # ════════════════════════════════════════════════════════════════════

  # JSON-safe 值展示：将任意 Nix 值转为可展示字符串
  # INV-TEST-7: 不直接 toJSON Type/函数对象
  safeShow = v:
    let t = builtins.typeOf v; in
    if t == "bool"   then if v then "true" else "false"
    else if t == "int"    then builtins.toString v
    else if t == "float"  then builtins.toString v
    else if t == "string" then "\"${v}\""
    else if t == "null"   then "null"
    else if t == "list"   then
      let
        len = builtins.length v;
        preview = if len == 0 then "[]"
                  else if len <= 4
                    then "[ ${lib.concatStringsSep ", " (map safeShow v)} ]"
                  else "[ ${safeShow (builtins.head v)}, ... (${builtins.toString len} items) ]";
      in preview
    else if t == "set"    then
      let
        keys = builtins.attrNames v;
        patTag  = if v ? __patTag  then v.__patTag  else "?";
        kindTag = if v ? __kindTag then v.__kindTag else "?";
        typeTag = if v ? __type    then v.__type    else "?";
        varTag  = if v ? __variant then v.__variant else "?";
        dtTag   = if v ? __dtTag   then v.__dtTag   else "?";
      in
      if builtins.elem "__patTag"  keys then "<Pattern:${patTag}>"
      else if builtins.elem "__kindTag" keys then "<Kind:${kindTag}>"
      else if builtins.elem "__type"    keys then "<Type:${typeTag}>"
      else if builtins.elem "__variant" keys then "<Repr:${varTag}>"
      else if builtins.elem "__dtTag"   keys then "<DT:${dtTag}>"
      else if builtins.elem "__armTag"  keys then "<Arm>"
      else if builtins.length keys == 0 then "{}"
      else if builtins.length keys <= 4
        then "{ ${lib.concatStringsSep ", " (map (k: "${k}") keys)} }"
      else "{ ${lib.concatStringsSep ", " (lib.take 4 keys)}, ... }"
    else if t == "lambda" then "<function>"
    else "<${t}>";

  # ════════════════════════════════════════════════════════════════════
  # 核心测试原语（Core Test Primitives）
  # ════════════════════════════════════════════════════════════════════

  # mkTestBool name cond
  # 布尔断言：cond 应求值为 true
  # INV-TEST-1: tryEval 隔离
  # INV-TEST-6: diag 字段携带调试信息
  mkTestBool = name: cond:
    let
      r = builtins.tryEval cond;
    in {
      inherit name;
      result   = if r.success then r.value else false;
      expected = true;
      pass     = r.success && r.value == true;
      diag = {
        kind     = "bool";
        evalOk   = r.success;
        actual   = if r.success then safeShow r.value else "<eval-error>";
        expected = "true";
        hint     = if !r.success then "eval-error: check for abort/assert/type-error"
                   else if r.value != true then "condition evaluated to ${safeShow r.value}"
                   else "ok";
      };
    };

  # mkTestEq name result expected
  # 等值断言：result == expected sw
  mkTestEq = name: result: expected:
    let
      r = builtins.tryEval result;
      e = builtins.tryEval expected;
      ok = r.success && e.success && r.value == e.value;
    in {
      inherit name;
      result   = if r.success then r.value else "<eval-error>";
      expected = if e.success then e.value else "<eval-error>";
      pass     = ok;
      diag = {
        kind     = "eq";
        evalOk   = r.success && e.success;
        actual   = if r.success then safeShow r.value else "<eval-error>";
        expected = if e.success then safeShow e.value else "<eval-error>";
        hint =
          if !r.success then "result eval-error"
          else if !e.success then "expected eval-error"
          else if r.value != e.value then "mismatch: got ${safeShow r.value}, want ${safeShow e.value}"
          else "ok";
      };
    };

  # mkTestEval name expr
  # 求值测试：expr 不应抛出求值错误
  mkTestEval = name: expr:
    let r = builtins.tryEval expr; in {
      inherit name;
      result   = r.success;
      expected = true;
      pass     = r.success;
      diag = {
        kind   = "eval";
        evalOk = r.success;
        actual = if r.success then safeShow r.value else "<eval-error>";
        hint   = if r.success then "ok" else "eval-error: expression threw an exception";
      };
    };

  # mkTestError name cond
  # 负面测试：cond 应为 false 或 eval-error（验证错误路径）
  mkTestError = name: cond:
    let r = builtins.tryEval cond; in {
      inherit name;
      result   = !(r.success && r.value == true);
      expected = true;
      pass     = !(r.success && r.value == true);
      diag = {
        kind   = "neg";
        evalOk = r.success;
        actual = if r.success then safeShow r.value else "<eval-error>";
        hint   = if !r.success then "ok (eval-error as expected)"
                 else if r.value != true then "ok (false as expected)"
                 else "FAIL: expected false/error but got true";
      };
    };

  # mkTestWith name cond diagExpr
  # 带诊断表达式的布尔测试：diagExpr 在 cond 失败时用于额外诊断
  mkTestWith = name: cond: diagExpr:
    let
      r = builtins.tryEval cond;
      d = builtins.tryEval diagExpr;
    in {
      inherit name;
      result   = if r.success then r.value else false;
      expected = true;
      pass     = r.success && r.value == true;
      diag = {
        kind     = "bool+diag";
        evalOk   = r.success;
        actual   = if r.success then safeShow r.value else "<eval-error>";
        expected = "true";
        diagVal  = if d.success then safeShow d.value else "<diag-eval-error>";
        hint     = if !r.success then "eval-error"
                   else if r.value != true then "false; diag=${if d.success then safeShow d.value else "err"}"
                   else "ok";
      };
    };

  # ════════════════════════════════════════════════════════════════════
  # 组级聚合（Group Aggregation）
  # ════════════════════════════════════════════════════════════════════

  # INV-TEST-4: 防御性 testGroup
  testGroup = name: tests:
    if !(builtins.isList tests) then {
      inherit name;
      passed = 0; total = 0;
      failed = [];
      ok     = false;
      error  = "runGroup: tests not a list (got ${builtins.typeOf tests})";
    } else
    let
      safeTests = map (t:
        if builtins.isAttrs t && t ? pass && t ? name then t
        else {
          name     = "<invalid-test>";
          pass     = false;
          result   = false;
          expected = true;
          diag     = { kind = "invalid"; hint = "test value is not an attrset"; };
        }
      ) tests;
      passed = lib.length (lib.filter (t: t.pass) safeTests);
      total  = lib.length safeTests;
      failed = lib.filter (t: !t.pass) safeTests;
    in {
      inherit name passed total failed;
      ok         = passed == total;
      failedNames = map (t: t.name) failed;
    };

  # ════════════════════════════════════════════════════════════════════
  # JSON-safe group summary（INV-TEST-7）
  # ════════════════════════════════════════════════════════════════════
  runGroups = testGroups:
    map (g: {
    name        = g.name;
    passed      = g.passed;
    total       = g.total;
    ok          = g.ok;
    failedNames =
      let gf = g.failed or []; in
      if !builtins.isList gf then []
      else map (t:
        if builtins.isAttrs t then (t.name or "<unnamed>")
        else builtins.toString t
      ) gf;
  }) testGroups;

  failedGroups= testGroups: lib.filter (g: builtins.isAttrs g && !(g.ok or true)) testGroups;

  # ════════════════════════════════════════════════════════════════════
  # INV-TEST-5 防御性
  # ════════════════════════════════════════════════════════════════════
  failedList = failedGroups:
    let
      safeGroup = g:
        if !builtins.isAttrs g then { group = "<non-attrset>"; failed = []; }
        else
          let
            gf    = g.failed or [];
            names =
              if !builtins.isList gf then []
              else map (t:
                if builtins.isAttrs t then (t.name or "<unnamed>")
                else builtins.toString t
              ) gf;
          in
          { group = g.name or "<unknown>"; failed = names; };
    in
    map safeGroup failedGroups;

  # ════════════════════════════════════════════════════════════════════
  # 详细诊断输出(包含失败测试(hint, actual, expected)（INV-TEST-6/7）
  # ════════════════════════════════════════════════════════════════════
  diagnoseAll = failedGroups:
    let
      diagTest = t:
        if !builtins.isAttrs t then { name = "<invalid>"; pass = false; hint = "not an attrset"; }
        else {
          name = t.name or "<unnamed>";
          pass = t.pass or false;
          hint = (t.diag or {}).hint or "no diag";
          actual   = (t.diag or {}).actual or "?";
          expected = (t.diag or {}).expected or "?";
          diagVal  = (t.diag or {}).diagVal or null;
        };
      diagGroup = g:
        if !builtins.isAttrs g then { group = "<invalid>"; ok = false; tests = []; }
        else {
          group   = g.name or "<unnamed>";
          ok      = g.ok or false;
          passed  = g.passed or 0;
          total   = g.total or 0;
          # 只输出失败测试的诊断（INV-TEST-7: JSON-safe）
          failed  =
            let gf = g.failed or []; in
            if !builtins.isList gf then []
            else map diagTest gf;
        };
    in
    map diagGroup failedGroups;
in
{
  inherit
  # ════════════════════════════════════════════════════════════════════
  # 诊断辅助函数（Diagnostic Helpers）
  # ════════════════════════════════════════════════════════════════════
  safeShow
  # ════════════════════════════════════════════════════════════════════
  # 核心测试原语（Core Test Primitives）
  # ════════════════════════════════════════════════════════════════════
  mkTestBool
  mkTestEq
  mkTestEval
  mkTestError
  mkTestWith
  # ════════════════════════════════════════════════════════════════════
  # 组级聚合（Group Aggregation）
  # ════════════════════════════════════════════════════════════════════
  testGroup
  # ════════════════════════════════════════════════════════════════════
  # JSON-safe group summary（INV-TEST-7）
  # ════════════════════════════════════════════════════════════════════
  runGroups
  failedGroups
  # ════════════════════════════════════════════════════════════════════
  # INV-TEST-5 防御性
  # ════════════════════════════════════════════════════════════════════
  failedList
  # ════════════════════════════════════════════════════════════════════
  # 详细诊断输出(包含失败测试(hint, actual, expected)（INV-TEST-6/7）
  # ════════════════════════════════════════════════════════════════════
  diagnoseAll
  ;
}
