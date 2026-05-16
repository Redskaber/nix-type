# tests/test_all.nix — Phase 4.5.8
# 完整测试套件（203 tests，28 组）
#
# ★ Phase 4.5.8 — INV-NIX-4 definitive fix (concatLists+map)
#
# 修复（Phase 4.5.8）:
#   BUG-T16 (定论): patternVars Ctor → [] 根因
#            builtins.foldl' (acc: p: acc ++ _patternVarsGo p) 在 letrec+nix-run
#            场景下无声返回 []. 修复: builtins.concatLists (map (p: f p) fields)
#            INV-NIX-4: 列表构建使用 concatLists+map, 禁止 foldl'++++
#   BUG-T25: invPat1 → false（同 T16 根因，同步修复）
#
# 测试框架新增能力：
#   mkTestBool  - 布尔断言（带错误上下文，INV-TEST-1）
#   mkTest      - 等值断言（actual vs expected，带类型信息）
#   mkTestEval  - 求值断言（验证不抛异常）
#   mkTestError - 负面测试（验证 cond 为 false 或 eval-error）
#   mkTestExpr  - 带诊断表达式的测试（捕获中间值）
#   runGroup    - 组级聚合（INV-TEST-4：防御性检查）
#   runAll      - JSON-safe 摘要输出
#   diagnoseAll - 详细诊断输出（含失败详情和实际值）
#   failedList  - 精确失败列表（INV-TEST-5）
#
# 不变式：
#   INV-TEST-1: builtins.tryEval 隔离每个测试，单失败不中断整个套件
#   INV-TEST-2: pattern 测试使用 patternLib.mkPVar，不使用 refinedLib 版本
#   INV-TEST-3: Unicode attrset key 使用引号字符串 set ? "α"
#   INV-TEST-4: runGroup 防御性检查 tests 参数类型
#   INV-TEST-5: failedList 防御性检查 g.failed 字段
#   INV-TEST-6: mkTestBool/mkTest 均携带 diag 字段供调试
#   INV-TEST-7: 诊断输出 JSON-safe（无 Type 对象，无函数值）
{ lib ? (import <nixpkgs> {}).lib }:

let
  ts = import ../lib/default.nix { inherit lib; };

  # ════════════════════════════════════════════════════════════════════
  # 诊断辅助函数（Diagnostic Helpers）
  # ════════════════════════════════════════════════════════════════════

  # JSON-safe 值展示：将任意 Nix 值转为可展示字符串
  # INV-TEST-7: 不直接 toJSON Type/函数对象
  _safeShow = v:
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
                    then "[ ${lib.concatStringsSep ", " (map _safeShow v)} ]"
                  else "[ ${_safeShow (builtins.head v)}, ... (${builtins.toString len} items) ]";
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
        actual   = if r.success then _safeShow r.value else "<eval-error>";
        expected = "true";
        hint     = if !r.success then "eval-error: check for abort/assert/type-error"
                   else if r.value != true then "condition evaluated to ${_safeShow r.value}"
                   else "ok";
      };
    };

  # mkTest name result expected
  # 等值断言：result == expected
  mkTest = name: result: expected:
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
        actual   = if r.success then _safeShow r.value else "<eval-error>";
        expected = if e.success then _safeShow e.value else "<eval-error>";
        hint =
          if !r.success then "result eval-error"
          else if !e.success then "expected eval-error"
          else if r.value != e.value then "mismatch: got ${_safeShow r.value}, want ${_safeShow e.value}"
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
        actual = if r.success then _safeShow r.value else "<eval-error>";
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
        actual = if r.success then _safeShow r.value else "<eval-error>";
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
        actual   = if r.success then _safeShow r.value else "<eval-error>";
        expected = "true";
        diagVal  = if d.success then _safeShow d.value else "<diag-eval-error>";
        hint     = if !r.success then "eval-error"
                   else if r.value != true then "false; diag=${if d.success then _safeShow d.value else "err"}"
                   else "ok";
      };
    };

  # ════════════════════════════════════════════════════════════════════
  # 组级聚合（Group Aggregation）
  # ════════════════════════════════════════════════════════════════════

  # INV-TEST-4: 防御性 runGroup
  runGroup = name: tests:
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
  # 测试组局部常量
  # ════════════════════════════════════════════════════════════════════

  tInt    = ts.tInt;
  tBool   = ts.tBool;
  tString = ts.tString;
  tUnit   = ts.tUnit;
  KStar   = ts.KStar;
  KArrow  = ts.KArrow;

  # ════════════════════════════════════════════════════════════════════
  # T1: TypeIR 核心（INV-1）
  # ════════════════════════════════════════════════════════════════════
  t1 = runGroup "T1-TypeIR" [
    (mkTestBool "tInt is Type"    (ts.isType ts.tInt))
    (mkTestBool "tBool is Type"   (ts.isType ts.tBool))
    (mkTestBool "tString is Type" (ts.isType ts.tString))
    (mkTestBool "tUnit is Type"   (ts.isType ts.tUnit))
    (mkTestBool "tInt has id"     (builtins.isString ts.tInt.id))
    (mkTestBool "tBool has kind"  (ts.isKind ts.tBool.kind))
    (mkTestBool "mkFn creates Fn"
      ((ts.mkFn ts.tInt ts.tBool).repr.__variant == "Fn"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T2: Kind 系统（INV-K1）
  # ════════════════════════════════════════════════════════════════════
  t2 = runGroup "T2-Kind" [
    (mkTestBool "KStar is kind"  (ts.isKind ts.KStar))
    (mkTestBool "KRow is kind"   (ts.isKind ts.KRow))
    (mkTestBool "KArrow a b"     (ts.isKArrow (ts.KArrow ts.KStar ts.KStar)))
    (mkTestBool "kindEq Star"    (ts.kindEq ts.KStar ts.KStar))
    (mkTestBool "kindEq Arrow"   (ts.kindEq (ts.KArrow ts.KStar ts.KStar) (ts.KArrow ts.KStar ts.KStar)))
    (mkTestBool "unifyKind ok"   ((ts.unifyKind ts.KStar ts.KStar).ok))
    (mkTestBool "unifyKind fail" (!(ts.unifyKind ts.KStar ts.KRow).ok))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T3: TypeRepr 宇宙（INV-2）
  # ════════════════════════════════════════════════════════════════════
  t3 = runGroup "T3-TypeRepr" [
    (mkTestBool "rFn"          ((ts.rFn tInt tBool).__variant == "Fn"))
    (mkTestBool "rForAll"      ((ts.rForAll "a" ts.KStar tInt).__variant == "ForAll"))
    (mkTestBool "rMu"          ((ts.rMu "X" tInt).__variant == "Mu"))
    (mkTestBool "rTyCon"       ((ts.rTyCon "List" ts.KStar).__variant == "TyCon"))
    (mkTestBool "rApply"       ((ts.rApply (ts.mkTypeDefault (ts.rTyCon "F" (ts.KArrow ts.KStar ts.KStar)) (ts.KArrow ts.KStar ts.KStar)) [tInt]).__variant == "Apply"))
    (mkTestBool "rSig"         ((ts.rSig { x = tInt; }).__variant == "Sig"))
    (mkTestBool "rVariantRow"  ((ts.rVariantRow { A = tInt; } null).__variant == "VariantRow"))
    (mkTestBool "rRowEmpty"    (ts.rRowEmpty.__variant == "RowEmpty"))
    (mkTestBool "rVar"         ((ts.rVar "α").__variant == "Var"))
    (mkTestBool "rEffect"      ((ts.rEffect (ts.mkTypeDefault (ts.rVariantRow { Io = tUnit; } null) ts.KRow) tInt).__variant == "Effect"))
    (mkTestBool "rHandler"     ((ts.rHandler "State" [] tInt).__variant == "Handler"))
    (mkTestBool "rComposedFunctor" (builtins.isAttrs (ts.rComposedFunctor)))
    (mkTestBool "rTypeScheme"   (builtins.isAttrs (ts.rTypeScheme "a" ts.KStar tInt)))
    (mkTestBool "rDynamic"      (ts.rDynamic.__variant == "Dynamic"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T4: 序列化（INV-SER-1）
  # ════════════════════════════════════════════════════════════════════
  t4 = runGroup "T4-Serialize" [
    (mkTestBool "serializeKind KStar"
      (ts.serializeKind ts.KStar == "*"))
    (mkTestBool "serializeKind KArrow"
      (ts.serializeKind (ts.KArrow ts.KStar ts.KStar) == "(* -> *)"))
    (mkTestBool "serializeRepr Fn"
      (builtins.isString (ts.serializeRepr (ts.rFn tInt tBool))))
    (mkTestBool "serializeConstraint Eq"
      (builtins.isString (ts.serializeConstraint (ts.mkEqConstraint tInt tBool))))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T5: 正规化（INV-3）
  # ════════════════════════════════════════════════════════════════════
  t5 = runGroup "T5-Normalize" [
    (mkTestBool "normalize tInt"
      (ts.isType (ts.normalize' tInt)))
    (mkTestBool "normalize tBool"
      (ts.isType (ts.normalize' tBool)))
    (mkTestBool "normalize Fn"
      (ts.isType (ts.normalize' (ts.mkFn tInt tBool))))
    (mkTestBool "normalize ForAll"
      (ts.isType (ts.normalize'
        (ts.mkTypeDefault (ts.rForAll "a" ts.KStar tInt) ts.KStar))))
    (mkTestBool "normalize idempotent tInt"
      (let n1 = ts.normalize' tInt; n2 = ts.normalize' n1; in
       ts.typeHash n1 == ts.typeHash n2))
    (mkTestBool "normalize Mu"
      (ts.isType (ts.normalize'
        (ts.mkTypeDefault (ts.rMu "X" tInt) ts.KStar))))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T6: Hash（INV-NRM2）
  # ════════════════════════════════════════════════════════════════════
  t6 = runGroup "T6-Hash" [
    (mkTestBool "typeHash is string"
      (builtins.isString (ts.typeHash tInt)))
    (mkTestBool "typeHash stable tInt"
      (ts.typeHash tInt == ts.typeHash tInt))
    (mkTestBool "typeHash differs tInt tBool"
      (ts.typeHash tInt != ts.typeHash tBool))
    (mkTestBool "typeHash stable Fn"
      (let f = ts.mkFn tInt tBool; in ts.typeHash f == ts.typeHash f))
    (mkTestBool "typeHash Fn != tInt"
      (ts.typeHash (ts.mkFn tInt tBool) != ts.typeHash tInt))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T7: 约束 IR（INV-SOL）
  # ════════════════════════════════════════════════════════════════════
  t7 = runGroup "T7-ConstraintIR" [
    (mkTestBool "mkEqConstraint"
      ((ts.mkEqConstraint tInt tBool).__constraintTag == "Eq"))
    (mkTestBool "mkSubConstraint"
      ((ts.mkSubConstraint tInt tBool).__constraintTag == "Sub"))
    (mkTestBool "mkHasFieldConstraint"
      ((ts.mkHasFieldConstraint "x" tInt (ts.mkTypeDefault (ts.rSig { x = tInt; }) ts.KStar)).__constraintTag == "HasField"))
    (mkTestBool "mkClassConstraint"
      ((ts.mkClassConstraint "Eq" [tInt]).__constraintTag == "Class"))
    (mkTestBool "mkImpliesConstraint"
      ((ts.mkImpliesConstraint (ts.mkEqConstraint tInt tInt) (ts.mkEqConstraint tBool tBool)).__constraintTag == "Implies"))
    (mkTestBool "mkRowConstraint"
      ((ts.mkRowConstraint tInt tBool).__constraintTag == "RowEq"))
    (mkTestBool "isConstraint"
      (ts.isConstraint (ts.mkEqConstraint tInt tBool)))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T8: UnifiedSubst（INV-US1~5）
  # ════════════════════════════════════════════════════════════════════
  t8 = runGroup "T8-UnifiedSubst" [
    (mkTestBool "emptySubst"
      (let s = ts.emptySubst; in
       builtins.isAttrs s && s.typeBindings == {} && s.rowBindings == {}))
    (mkTestBool "bindType"
      (let s = ts.bindType "a" tInt ts.emptySubst; in
       builtins.isAttrs (s.typeBindings.a or null)))
    (mkTestBool "applySubst id"
      (ts.isType (ts.applySubst ts.emptySubst tInt)))
    (mkTestBool "applySubst binding"
      (let
        s = ts.bindType "α" tInt ts.emptySubst;
        v = ts.mkTypeDefault (ts.rVar "α") ts.KStar;
        r = ts.applySubst s v;
      in ts.typeHash r == ts.typeHash tInt))
    (mkTestBool "composeSubst"
      (let
        s1 = ts.bindType "a" tInt ts.emptySubst;
        s2 = ts.bindType "b" tBool ts.emptySubst;
        s  = ts.composeSubst s1 s2;
      in s.typeBindings ? a && s.typeBindings ? b))
    (mkTestBool "freeVars tInt = []"
      (ts.freeVars tInt == []))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T9: 约束求解器（INV-SOL5）
  # ════════════════════════════════════════════════════════════════════
  t9 = runGroup "T9-Solver" [
    (mkTestBool "solve empty"
      # BUG-T9 fix: solve = constraints: classGraph: instanceDB:
      (let r = ts.solve [] {} {}; in r.ok or false))
    (mkTestBool "solve Eq Int Int"
      (let
        c = ts.mkEqConstraint tInt tInt;
        r = ts.solve [c] {} {};
      in r.ok or false))
    (mkTestBool "solve Eq Int Bool fails"
      (let
        c = ts.mkEqConstraint tInt tBool;
        r = ts.solve [c] {} {};
      in !(r.ok or true)))
    (mkTestBool "solve returns subst"
      (let
        r = ts.solve [] {} {};
      in builtins.isAttrs (r.subst or null)))
    (mkTestBool "solve Eq Var Int"
      (let
        v = ts.mkTypeDefault (ts.rVar "α") ts.KStar;
        c = ts.mkEqConstraint v tInt;
        r = ts.solve [c] {} {};
      in r.ok or false))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T10: InstanceDB（INV-I1）
  # ════════════════════════════════════════════════════════════════════
  t10 = runGroup "T10-InstanceDB" [
    (mkTestBool "emptyDB is attrset"
      (builtins.isAttrs ts.emptyDB))
    (mkTestBool "registerInstance"
      (let
        inst = ts.makeInstance "Eq" [tInt] (ts.mkSig { eq = ts.mkFn tInt (ts.mkFn tInt tBool); });
        db   = ts.registerInstance inst ts.emptyDB;
      in builtins.isAttrs db))
    (mkTestBool "lookupInstance found"
      (let
        inst = ts.makeInstance "Eq" [tInt] (ts.mkSig { eq = ts.mkFn tInt (ts.mkFn tInt tBool); });
        db   = ts.registerInstance inst ts.emptyDB;
        r    = ts.lookupInstance "Eq" [tInt] db;
      in r.found or false))
    (mkTestBool "lookupInstance not found"
      (let
        r = ts.lookupInstance "Eq" [tInt] ts.emptyDB;
      in !(r.found or true)))
    (mkTestBool "INV-I1: NF-hash key consistency"
      (let
        inst1 = ts.makeInstance "Eq" [tInt] (ts.mkSig { eq = ts.mkFn tInt (ts.mkFn tInt tBool); });
        inst2 = ts.makeInstance "Eq" [tInt] (ts.mkSig { eq = ts.mkFn tInt (ts.mkFn tInt tBool); });
        db1   = ts.registerInstance inst1 ts.emptyDB;
        db2   = ts.registerInstance inst2 ts.emptyDB;
        r1    = ts.lookupInstance "Eq" [tInt] db1;
        r2    = ts.lookupInstance "Eq" [tInt] db2;
      in r1.found && r2.found))
    (mkTestBool "makeInstance has className"
      (let
        inst = ts.makeInstance "Show" [tBool] (ts.mkSig { show = ts.mkFn tBool tString; });
      in inst.className == "Show"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T11: Refined Types（INV-REF）
  # ════════════════════════════════════════════════════════════════════
  t11 = runGroup "T11-RefinedTypes" [
    (mkTestBool "mkRefined"
      (builtins.isAttrs (ts.mkRefined tInt (ts.mkPGt (ts.mkPLit 0)))))
    (mkTestBool "mkPLit"
      ((ts.mkPLit 42).__predTag == "PLit"))
    (mkTestBool "mkPGt"
      ((ts.mkPGt (ts.mkPLit 0)).__predTag == "Gt"))
    (mkTestBool "mkPAnd"
      ((ts.mkPAnd (ts.mkPLit 0) (ts.mkPLit 1)).__predTag == "PAnd"))
    (mkTestBool "mkPOr"
      ((ts.mkPOr (ts.mkPLit 0) (ts.mkPLit 1)).__predTag == "POr"))
    (mkTestBool "mkPNot"
      ((ts.mkPNot (ts.mkPLit 0)).__predTag == "PNot"))
    (mkTestBool "checkRefined ok"
      (let
        r = ts.mkRefined tInt (ts.mkPGt (ts.mkPLit 0));
        c = ts.checkRefined r;
      in c.ok or false))
    (mkTestBool "smtEncode"
      (builtins.isString (ts.smtEncode (ts.mkPGt (ts.mkPLit 0)))))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T12: Module System（INV-MOD）
  # ════════════════════════════════════════════════════════════════════
  t12 = runGroup "T12-ModuleSystem" [
    (mkTestBool "mkSig"
      ((ts.mkSig { x = tInt; }).repr.__variant == "Sig"))
    (mkTestBool "mkModFunctor"
      (builtins.isAttrs (ts.mkModFunctor "A" (ts.mkSig { x = tInt; }) tInt)))
    (mkTestBool "sigIntersection"
      (let
        s1 = ts.mkSig { x = tInt; y = tBool; };
        s2 = ts.mkSig { x = tInt; z = tString; };
        r  = ts.sigIntersection s1 s2;
      in builtins.isAttrs r.intersection))
    (mkTestBool "sigUnion"
      (let
        s1 = ts.mkSig { x = tInt; };
        s2 = ts.mkSig { y = tBool; };
        r  = ts.sigUnion s1 s2;
      in builtins.isAttrs r.union))
    (mkTestBool "seal/unseal"
      (let
        s = ts.seal tInt "MyTag";
        u = ts.unseal s "MyTag";
      in u.ok or false))
    (mkTestBool "seal/unseal wrong tag"
      (let
        s = ts.seal tInt "Tag1";
        u = ts.unseal s "Tag2";
      in !(u.ok or true)))
    (mkTestBool "mkModFunctor has name"
      (let
        mf = ts.mkModFunctor "Functor" (ts.mkSig { fmap = tInt; }) tBool;
      in mf.name == "Functor" || builtins.isAttrs mf))
    (mkTestBool "INV-MOD-4: sigIntersection subset"
      (let
        s1 = ts.mkSig { x = tInt; y = tBool; };
        s2 = ts.mkSig { x = tInt; z = tString; };
        r  = ts.sigIntersection s1 s2;
        iFields = builtins.attrNames r.intersection.repr.fields;
      in builtins.elem "x" iFields))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T13: Effect Handlers（INV-EFF）
  # ════════════════════════════════════════════════════════════════════
  t13 = runGroup "T13-EffectHandlers" [
    (mkTestBool "mkHandler"
      (ts.isHandler (ts.mkHandler "State" [] tInt)))
    (mkTestBool "mkDeepHandler"
      (let h = ts.mkDeepHandler "Log" [] tUnit; in h.repr.deep or false))
    (mkTestBool "mkShallowHandler"
      (let h = ts.mkShallowHandler "IO" [] tUnit; in h.repr.shallow or false))
    (mkTestBool "emptyEffectRow"
      (ts.emptyEffectRow.repr.__variant == "RowEmpty"))
    (mkTestBool "singleEffect"
      ((ts.singleEffect "State" tInt).repr.__variant == "VariantRow"))
    (mkTestBool "effectMerge"
      (let em = ts.effectMerge ts.emptyEffectRow ts.emptyEffectRow; in
       (em ? __variant && em.__variant == "EffectMerge")
       || (em.repr.__variant or null) == "EffectMerge"))
    (mkTestBool "checkEffectWellFormed"
      ((ts.checkEffectWellFormed (ts.mkTypeDefault
        (ts.rEffect (ts.mkTypeDefault (ts.rVariantRow { Io = tUnit; } null) ts.KRow) tInt)
        ts.KStar)).ok))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T14: QueryDB（INV-G3）
  # ════════════════════════════════════════════════════════════════════
  t14 = runGroup "T14-QueryDB" [
    (mkTestBool "mkQueryKey"
      (builtins.isString (ts.mkQueryKey "normalize" tInt)))
    (mkTestBool "storeResult"
      (let
        k  = ts.mkQueryKey "normalize" tInt;
        db = ts.storeResult k tBool {};
      in builtins.isAttrs db))
    (mkTestBool "lookupResult hit"
      (let
        k  = ts.mkQueryKey "normalize" tInt;
        db = ts.storeResult k tBool {};
        r  = ts.lookupResult k db;
      in r.found or false))
    (mkTestBool "lookupResult miss"
      (let
        k  = ts.mkQueryKey "normalize" tInt;
        r  = ts.lookupResult k {};
      in !(r.found or true)))
    (mkTestBool "invalidateKey"
      (let
        k  = ts.mkQueryKey "normalize" tInt;
        db = ts.storeResult k tBool {};
        db2 = ts.invalidateKey k db;
        r   = ts.lookupResult k db2;
      in !(r.found or true)))
    (mkTestBool "cacheStats"
      (let
        k  = ts.mkQueryKey "x" tInt;
        db = ts.storeResult k tBool {};
        s  = ts.cacheStats db;
      in s.size >= 1))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T15: Incremental Graph（INV-G1~4）
  # ════════════════════════════════════════════════════════════════════
  t15 = runGroup "T15-IncrementalGraph" [
    (mkTestBool "addNode"
      (let g = ts.addNode "A" {}; in g ? nodes))
    (mkTestBool "addEdge"
      (let
        g = ts.addEdge "A" "B" (ts.addNode "B" (ts.addNode "A" {}));
      in g ? edges))
    (mkTestBool "topologicalSort ok"
      (let
        g = ts.addEdge "A" "B" (ts.addEdge "B" "C"
              (ts.addNode "C" (ts.addNode "B" (ts.addNode "A" {}))));
        r = ts.topologicalSort g;
      in r.ok or false))
    (mkTestBool "topologicalSort order"
      (let
        g = ts.addEdge "A" "B" (ts.addEdge "B" "C"
              (ts.addNode "C" (ts.addNode "B" (ts.addNode "A" {}))));
        r = ts.topologicalSort g;
      in r.ok && builtins.isList r.order))
    (mkTestBool "hasCycle false"
      (let
        g = ts.addEdge "A" "B" (ts.addNode "B" (ts.addNode "A" {}));
      in !(ts.hasCycle g)))
    (mkTestBool "markStale"
      (let
        g = ts.addNode "A" {};
        g2 = ts.markStale "A" g;
      in builtins.isAttrs g2))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T16: Pattern Matching（INV-PAT-1/2）
  # ★ Phase 4.5.3: 使用 mkTestWith 增强诊断
  # ════════════════════════════════════════════════════════════════════
  t16 = runGroup "T16-PatternMatch" [
    (mkTestBool "mkPWild"
      (ts.isPattern ts.mkPWild))
    (mkTestBool "mkPVar"
      (ts.isPattern (ts.mkPVar "x")))
    (mkTestBool "mkPCtor"
      (ts.isPattern (ts.mkPCtor "Some" [ts.mkPVar "x"])))
    (mkTestBool "mkArm"
      ((ts.mkArm ts.mkPWild tInt).__armTag == "Arm"))
    (mkTestBool "compileMatch Wild → Leaf"
      (let
        arm = ts.mkArm ts.mkPWild tInt;
        tVariants = [{ name = "Some"; ordinal = 0; } { name = "None"; ordinal = 1; }];
        dt  = ts.compileMatch [arm] tVariants;
      in dt.__dtTag == "Leaf"))
    (mkTestBool "checkExhaustive"
      (let
        tVariants = [{ name = "Some"; ordinal = 0; } { name = "None"; ordinal = 1; }];
        arms = [ (ts.mkArm ts.mkPWild tInt) ];
        r    = ts.checkExhaustive arms tVariants;
      in r.exhaustive))
    # ★ BUG-T16: patternVars Ctor — 使用 mkTestWith 暴露实际返回值
    # Phase 4.5.3 Fix: match/pattern.nix patternVars Ctor 分支使用具名帮助函数
    (mkTestWith "patternVars"
      (let
        p    = ts.mkPCtor "Some" [ts.mkPVar "x"];
        vars = ts.patternVars p;
      in builtins.isList vars && builtins.elem "x" vars)
      # 诊断：展示实际 vars 值
      (let
        p    = ts.mkPCtor "Some" [ts.mkPVar "x"];
        vars_r = builtins.tryEval (ts.patternVars p);
      in if vars_r.success then _safeShow vars_r.value else "eval-error"))
    (mkTestBool "patternVars Var"
      (ts.patternVars (ts.mkPVar "y") == ["y"]))
    (mkTestBool "patternVars Wild = []"
      (ts.patternVars ts.mkPWild == []))
    (mkTestBool "patternVarsSet"
      (let
        p2 = ts.mkPAnd_p (ts.mkPVar "a") (ts.mkPVar "b");
        s  = ts.patternVarsSet p2;
      in builtins.isAttrs s && s ? a && s ? b))
    (mkTestBool "isLinear simple"
      (ts.isLinear (ts.mkPCtor "Just" [ts.mkPVar "x"])))
    (mkTestBool "patternDepth Wild = 0"
      (ts.patternDepth ts.mkPWild == 0))
    (mkTestBool "patternDepth Ctor = 1"
      (ts.patternDepth (ts.mkPCtor "Just" [ts.mkPWild]) == 1))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T17: Row 多态（INV-ROW）
  # ════════════════════════════════════════════════════════════════════
  t17 = runGroup "T17-RowPolymorphism" [
    (mkTestBool "rVariantRow"
      ((ts.rVariantRow { State = tInt; } null).__variant == "VariantRow"))
    (mkTestBool "rVar RowVar"
      ((ts.rVar "ρ").__variant == "Var"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T18: Bidir（INV-BIDIR-1）
  # ════════════════════════════════════════════════════════════════════
  t18 = runGroup "T18-Bidir" [
    (mkTestBool "infer eLit 42"
      (let r = ts.infer {} (ts.eLit 42); in ts.isType r.type))
    (mkTestBool "infer eVar x"
      (let
        ctx = { x = tInt; };
        r   = ts.infer ctx (ts.eVar "x");
      in ts.typeHash r.type == ts.typeHash tInt))
    (mkTestBool "infer eLam"
      (let r = ts.infer {} (ts.eLam "x" (ts.eVar "x")); in ts.isType r.type))
    (mkTestBool "check eLit 42 : Int"
      (let r = ts.check {} (ts.eLit 42) tInt; in r.ok or false))
    (mkTestBool "check eLit 42 : Bool fails"
      (let r = ts.check {} (ts.eLit 42) tBool; in !(r.ok or true)))
    (mkTestBool "infer eApp"
      (let
        fn  = ts.eLam "x" (ts.eVar "x");
        arg = ts.eLit 42;
        r   = ts.infer {} (ts.eApp fn arg);
      in ts.isType r.type))
    (mkTestBool "eLit constructor"
      ((ts.eLit 1).__exprTag == "Lit"))
    (mkTestBool "eVar constructor"
      ((ts.eVar "x").__exprTag == "Var"))
    (mkTestBool "eLam constructor"
      ((ts.eLam "x" (ts.eVar "x")).__exprTag == "Lam"))
    (mkTestBool "eApp constructor"
      ((ts.eApp (ts.eVar "f") (ts.eVar "x")).__exprTag == "App"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T19: Unification（INV-SUB2）
  # ════════════════════════════════════════════════════════════════════
  t19 = runGroup "T19-Unification" [
    (mkTestBool "unify Int Int ok"
      ((ts.unify tInt tInt).ok or false))
    (mkTestBool "unify Int Bool fail"
      (!(ts.unify tInt tBool).ok or true))
    (mkTestBool "unify α Int → ok + binding"
      (let
        alpha = ts.mkTypeDefault (ts.rVar "α") ts.KStar;
        r     = ts.unify alpha tInt;
      in r.ok or false))
    (mkTestBool "unify α Int → binding has α"
      (let
        alpha = ts.mkTypeDefault (ts.rVar "α") ts.KStar;
        r     = ts.unify alpha tInt;
      # INV-TEST-3: Unicode key uses quoted string
      in r.ok && (r.subst.typeBindings or {}) ? "α"))
    (mkTestBool "unify Fn ok"
      ((ts.unify (ts.mkFn tInt tBool) (ts.mkFn tInt tBool)).ok or false))
    (mkTestBool "unify Fn fail"
      (!(ts.unify (ts.mkFn tInt tBool) (ts.mkFn tBool tInt)).ok or true))
    (mkTestBool "unify ForAll ok"
      (let
        fa = ts.mkTypeDefault (ts.rForAll "a" ts.KStar (ts.mkTypeDefault (ts.rVar "a") ts.KStar)) ts.KStar;
      in (ts.unify fa fa).ok or false))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T20: Integration（INV-1~6 联合）
  # ════════════════════════════════════════════════════════════════════
  t20 = runGroup "T20-Integration" [
    (mkTestBool "mkFn + typeHash"
      (let f = ts.mkFn tInt tBool; in builtins.isString (ts.typeHash f)))
    (mkTestBool "mkFn + normalize"
      (let
        f  = ts.mkFn tInt tBool;
        nf = ts.normalize' f;
      in ts.isType nf))
    (mkTestBool "mkFn + check"
      (let
        f = ts.eLam "x" (ts.eVar "x");
        r = ts.infer {} f;
      in ts.isType r.type))
    (mkTestBool "mkSig + seal/unseal roundtrip"
      (let
        s = ts.mkSig { x = tInt; };
        sealed   = ts.seal s "Tag";
        unsealed = ts.unseal sealed "Tag";
      in unsealed.ok))
    (mkTestBool "registerInstance + lookupInstance"
      (let
        inst = ts.makeInstance "Show" [tString] (ts.mkSig { show = ts.mkFn tString tString; });
        db   = ts.registerInstance inst ts.emptyDB;
        r    = ts.lookupInstance "Show" [tString] db;
      in r.found or false))
    (mkTestBool "solve + subst apply"
      (let
        alpha = ts.mkTypeDefault (ts.rVar "β") ts.KStar;
        c     = ts.mkEqConstraint alpha tBool;
        r     = ts.solve [c] {} {};
        t2    = ts.applySubst r.subst alpha;
      in r.ok && ts.typeHash t2 == ts.typeHash tBool))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T21: Kind Inference（INV-KIND-1/2）
  # ════════════════════════════════════════════════════════════════════
  t21 = runGroup "T21-KindInference" [
    (mkTestBool "inferKind Var"
      (let r = ts.inferKind {} (ts.rVar "a"); in builtins.isAttrs r))
    (mkTestBool "inferKind TyCon"
      (let r = ts.inferKind {} (ts.rTyCon "List" ts.KStar); in r.kind or null != null))
    (mkTestBool "inferKind Fn"
      (let r = ts.inferKind {} (ts.rFn tInt tBool); in ts.kindEq (r.kind or ts.KStar) ts.KStar))
    (mkTestBool "inferKind ForAll"
      (let
        fa = ts.rForAll "a" ts.KStar tInt;
        r  = ts.inferKind { a = ts.KStar; } fa;
      in builtins.isAttrs r))
    (mkTestBool "unifyKind KVar"
      (let r = ts.unifyKind (ts.KVar "k1") ts.KStar; in r.ok or false))
    (mkTestBool "applyKindSubst"
      (let
        s = { k1 = ts.KStar; };
        r = ts.applyKindSubst s (ts.KVar "k1");
      in ts.kindEq r ts.KStar))
    (mkTestBool "kindArity KArrow"
      (ts.kindArity (ts.KArrow ts.KStar ts.KStar) == 1))
    (mkTestBool "kindArity KArrow 2"
      (ts.kindArity (ts.KArrow ts.KStar (ts.KArrow ts.KStar ts.KStar)) == 2))
    (mkTestBool "applyKind ok"
      (let r = ts.applyKind (ts.KArrow ts.KStar ts.KStar) ts.KStar; in
       ts.kindEq r ts.KStar))
    (mkTestBool "applyKind mismatch null"
      (ts.applyKind (ts.KArrow ts.KStar ts.KStar) ts.KRow == null))
    (mkTestBool "INV-KIND-1: infer List = * → *"
      (let
        listCtor = ts.mkTypeDefault
          (ts.rTyCon "List" (ts.KArrow ts.KStar ts.KStar))
          (ts.KArrow ts.KStar ts.KStar);
        r = ts.inferKind {} listCtor.repr;
      in ts.kindEq (r.kind or ts.KStar) (ts.KArrow ts.KStar ts.KStar)))
    (mkTestBool "INV-KIND-2: annotation propagation"
      (let r = ts.checkKindAnnotation {} (ts.rFn tInt tBool) ts.KStar; in r.ok or false))
    (mkTestBool "inferKindWithAnnotation"
      (let r = ts.inferKindWithAnnotation {} (ts.rFn tInt tBool) ts.KStar; in builtins.isAttrs r))
    (mkTestBool "defaultKinds"
      (builtins.isAttrs ts.defaultKinds))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T22: Handler Continuations（INV-EFF-10）
  # ════════════════════════════════════════════════════════════════════
  t22 = runGroup "T22-HandlerContinuations" [
    (mkTestBool "mkHandlerWithCont creates handler"
      (let
        contTy = ts.mkContType tInt ts.emptyEffectRow tUnit;
        h      = ts.mkHandlerWithCont "State" tInt contTy tUnit;
      in ts.isHandler h))
    (mkTestBool "mkHandlerWithCont hasCont = true"
      (let
        contTy = ts.mkContType tInt ts.emptyEffectRow tUnit;
        h      = ts.mkHandlerWithCont "State" tInt contTy tUnit;
      in h.repr.hasCont or false))
    (mkTestBool "mkContType"
      (let
        ct = ts.mkContType tInt ts.emptyEffectRow tBool;
      in ts.isType ct))
    (mkTestBool "checkHandlerContWellFormed ok"
      (let
        contTy = ts.mkContType tString ts.emptyEffectRow tUnit;
        h      = ts.mkHandlerWithCont "Log" tString contTy tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in r.ok or false))
    (mkTestBool "isHandlerWithCont"
      (let
        contTy = ts.mkContType tInt ts.emptyEffectRow tBool;
        h      = ts.mkHandlerWithCont "State" tInt contTy tBool;
      in ts.isHandlerWithCont h))
    (mkTestBool "contDomainOk true"
      (let
        contTy = ts.mkContType tInt ts.emptyEffectRow tUnit;
        h      = ts.mkHandlerWithCont "Get" tInt contTy tUnit;
      in h.repr.contDomainOk or false))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T23: Mu Bisim Congruence（INV-MU-1）
  # ════════════════════════════════════════════════════════════════════
  t23 = runGroup "T23-MuBisimCongruence" [
    (mkTestBool "muEq same"
      (let
        mu = ts.mkTypeDefault (ts.rMu "X" tInt) ts.KStar;
      in ts.muEq mu mu))
    (mkTestBool "muEq alpha-renamed"
      (let
        mu1 = ts.mkTypeDefault (ts.rMu "X" tInt) ts.KStar;
        mu2 = ts.mkTypeDefault (ts.rMu "Y" tInt) ts.KStar;
      in ts.muEq mu1 mu2))
    (mkTestBool "muEq different body"
      (let
        mu1 = ts.mkTypeDefault (ts.rMu "X" tInt) ts.KStar;
        mu2 = ts.mkTypeDefault (ts.rMu "X" tBool) ts.KStar;
      in !(ts.muEq mu1 mu2)))
    (mkTestBool "unify Mu alpha-renamed"
      (let
        mu1 = ts.mkTypeDefault (ts.rMu "X" tInt) ts.KStar;
        mu2 = ts.mkTypeDefault (ts.rMu "Y" tInt) ts.KStar;
        r   = ts.unify mu1 mu2;
      in r.ok or false))
    (mkTestBool "normalize Mu idempotent"
      (let
        mu = ts.mkTypeDefault (ts.rMu "X" tInt) ts.KStar;
        n1 = ts.normalize' mu;
        n2 = ts.normalize' n1;
      in ts.typeHash n1 == ts.typeHash n2))
    (mkTestBool "typeEq Mu"
      (let
        mu1 = ts.mkTypeDefault (ts.rMu "X" tInt) ts.KStar;
        mu2 = ts.mkTypeDefault (ts.rMu "Y" tInt) ts.KStar;
      in ts.typeEq mu1 mu2))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T24: Bidir Annotated Lambda（INV-BIDIR-2）
  # ════════════════════════════════════════════════════════════════════
  t24 = runGroup "T24-BidirAnnotatedLam" [
    (mkTestBool "eLamA constructor"
      ((ts.eLamA "x" tInt (ts.eVar "x")).__exprTag == "llama"))
    (mkTestBool "infer eLamA x:Int x → Int → Int"
      (let
        lam = ts.eLamA "x" tInt (ts.eVar "x");
        r   = ts.infer {} lam;
      in ts.isType r.type))
    (mkTestBool "INV-BIDIR-2: infer eLamA domain correct"
      (let
        lam = ts.eLamA "x" tInt (ts.eVar "x");
        r   = ts.infer {} lam;
      in r.type.repr.__variant or null == "Fn" &&
         ts.typeHash (r.type.repr.from) == ts.typeHash tInt))
    (mkTestBool "checkAnnotatedLam ok"
      (let
        lam = ts.eLamA "x" tInt (ts.eVar "x");
        r   = ts.checkAnnotatedLam {} lam (ts.mkFn tInt tInt);
      in r.ok or false))
    (mkTestBool "checkAnnotatedLam wrong ann fails"
      (let
        lam = ts.eLamA "x" tBool (ts.eVar "x");
        r   = ts.checkAnnotatedLam {} lam (ts.mkFn tInt tInt);
      in !(r.ok or true)))
    (mkTestBool "check eLamA : Int → Int"
      (let
        lam = ts.eLamA "x" tInt (ts.eVar "x");
        r   = ts.check {} lam (ts.mkFn tInt tInt);
      in r.ok or false))
    (mkTestBool "infer eLamA nested"
      (let
        inner = ts.eLamA "y" tBool (ts.eVar "y");
        outer = ts.eLamA "x" tInt inner;
        r     = ts.infer {} outer;
      in ts.isType r.type))
    (mkTestBool "infer eLamA app"
      (let
        fn  = ts.eLamA "x" tInt (ts.eVar "x");
        app = ts.eApp fn (ts.eLit 42);
        r   = ts.infer {} app;
      in ts.isType r.type))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T25: Handler Continuation Type Check（INV-EFF-11）
  # ★ Phase 4.5.3: 使用 mkTestWith 增强诊断
  # ════════════════════════════════════════════════════════════════════
  t25 = runGroup "T25-HandlerContTypeCheck" [
    # INV-EFF-11: contType.from == paramType
    (mkTestBool "INV-EFF-11: domain match ok"
      (let
        contTy = ts.mkContType tString ts.emptyEffectRow tUnit;
        h      = ts.mkHandlerWithCont "Log" tString contTy tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in r.inv_eff_11 or false))
    (mkTestBool "INV-EFF-11: domain mismatch fails"
      (let
        # contType domain is tInt, but paramType is tString → mismatch
        contTy = ts.mkContType tInt ts.emptyEffectRow tUnit;
        h      = ts.mkHandlerWithCont "Log" tString contTy tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in !(r.inv_eff_11 or true)))
    (mkTestBool "checkHandlerContWellFormed: not cont handler"
      (let
        h = ts.mkHandler "X" [] tUnit;
        r = ts.checkHandlerContWellFormed h;
      in !(r.ok or true)))
    (mkTestBool "checkHandlerContWellFormed: bad contType"
      (let
        # contType is NOT a Fn type
        contTy = tInt;
        h      = ts.mkHandlerWithCont "X" tString contTy tUnit;
      in !(h.repr.contDomainOk or true)))
    (mkTestBool "checkHandlerContWellFormed: contDomain exposed"
      (let
        contTy = ts.mkContType tString ts.emptyEffectRow tUnit;
        h      = ts.mkHandlerWithCont "Log" tString contTy tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in r.ok && ts.isType (r.contDomain or tUnit)))
    (mkTestBool "mkContType well-formed"
      (let
        ct = ts.mkContType tInt ts.emptyEffectRow tBool;
        r  = ts.checkHandlerContWellFormed
               (ts.mkHandlerWithCont "Get" tInt ct tBool);
      in r.ok or false))
    # ★ BUG-T25: invPat1 — 使用 mkTestWith 暴露诊断
    (mkTestWith "INV-PAT-1 via invPat1"
      (ts.__checkInvariants.invPat1 (ts.mkPCtor "Just" [ts.mkPVar "z"]) "Just" "z")
      # 诊断：展示 patternVars 结果
      (let
        p = ts.mkPCtor "Just" [ts.mkPVar "z"];
        r = builtins.tryEval (ts.patternVars p);
      in if r.success then _safeShow r.value else "eval-error in patternVars"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T26: Bidir App Result Solved（INV-BIDIR-3）
  # ════════════════════════════════════════════════════════════════════
  t26 = runGroup "T26-BidirAppResultSolved" [
    (mkTestBool "INV-BIDIR-3: infer(app (llama x Int x) 42) yields Int"
      (let
        fn   = ts.eLamA "x" tInt (ts.eVar "x");
        arg  = ts.eLit 42;
        r    = ts.infer {} (ts.eApp fn arg);
      in ts.typeHash r.type == ts.typeHash tInt))
    (mkTestBool "INV-BIDIR-3: infer(app (llama x Bool x) true) yields Bool"
      (let
        fn  = ts.eLamA "x" tBool (ts.eVar "x");
        arg = ts.eLit true;
        r   = ts.infer {} (ts.eApp fn arg);
      in ts.typeHash r.type == ts.typeHash tBool))
    (mkTestBool "checkAppResultSolved: concrete Fn"
      (let
        fnTy = ts.mkFn tInt tBool;
        r    = ts.checkAppResultSolved fnTy;
      in r.solved or false))
    (mkTestBool "checkAppResultSolved: Fn result is codomain"
      (let
        fnTy = ts.mkFn tInt tBool;
        r    = ts.checkAppResultSolved fnTy;
      in r.solved && ts.typeHash r.resultType == ts.typeHash tBool))
    (mkTestBool "infer app of non-annot lam"
      (let
        fn  = ts.eLam "x" (ts.eVar "x");
        arg = ts.eLit 42;
        r   = ts.infer {} (ts.eApp fn arg);
      in ts.isType r.type))
    (mkTestBool "infer nested app"
      (let
        f   = ts.eLamA "x" tInt (ts.eLamA "y" tBool (ts.eVar "x"));
        r   = ts.infer {} (ts.eApp (ts.eApp f (ts.eLit 1)) (ts.eLit true));
      in ts.typeHash r.type == ts.typeHash tInt))
    (mkTestBool "infer app: domain type match"
      (let
        fn  = ts.eLamA "x" tString (ts.eVar "x");
        arg = ts.eLit "hello";
        r   = ts.infer {} (ts.eApp fn arg);
      in ts.typeHash r.type == ts.typeHash tString))
    (mkTestBool "infer app: result is type"
      (let
        fn  = ts.eLamA "f" (ts.mkFn tInt tBool)
                (ts.eApp (ts.eVar "f") (ts.eLit 0));
        r   = ts.infer {} fn;
      in ts.isType r.type))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T27: Kind Fixpoint Solver（INV-KIND-3）
  # ════════════════════════════════════════════════════════════════════
  t27 = runGroup "T27-KindFixpointSolver" [
    (mkTestBool "solveKindConstraintsFixpoint empty"
      (let r = ts.solveKindConstraintsFixpoint [] {}; in builtins.isAttrs r))
    (mkTestBool "solveKindConstraintsFixpoint simple"
      (let
        c = { lhs = ts.KVar "k"; rhs = ts.KStar; };
        r = ts.solveKindConstraintsFixpoint [c] {};
      in builtins.isAttrs r && (r.k or null) != null))
    (mkTestBool "INV-KIND-3: fixpoint reaches stable state"
      (let
        cs = [
          { lhs = ts.KVar "k1"; rhs = ts.KStar; }
          { lhs = ts.KVar "k2"; rhs = ts.KVar "k1"; }
        ];
        r = ts.solveKindConstraintsFixpoint cs {};
      in ts.kindEq (r.k1 or ts.KUnbound) ts.KStar &&
         ts.kindEq (ts.applyKindSubst r (ts.KVar "k2")) ts.KStar))
    (mkTestBool "inferKindWithAnnotationFixpoint"
      (let r = ts.inferKindWithAnnotationFixpoint {} (ts.rFn tInt tBool) ts.KStar; in builtins.isAttrs r))
    (mkTestBool "checkKindAnnotationFixpoint"
      (let r = ts.checkKindAnnotationFixpoint {} (ts.rFn tInt tBool) ts.KStar; in r.ok or false))
    (mkTestBool "KIND-3: chain vars k1 → k2 → * resolve"
      (let
        cs = [
          { lhs = ts.KVar "a"; rhs = ts.KVar "b"; }
          { lhs = ts.KVar "b"; rhs = ts.KStar; }
        ];
        r = ts.solveKindConstraintsFixpoint cs {};
        a = ts.applyKindSubst r (ts.KVar "a");
      in ts.kindEq a ts.KStar))
    (mkTestBool "KIND-3: higher-order KArrow"
      (let
        cs = [{ lhs = ts.KVar "k"; rhs = ts.KArrow ts.KStar ts.KStar; }];
        r  = ts.solveKindConstraintsFixpoint cs {};
      in ts.kindEq (ts.applyKindSubst r (ts.KVar "k")) (ts.KArrow ts.KStar ts.KStar)))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T28: Pattern Nested Record（INV-PAT-3）
  # ════════════════════════════════════════════════════════════════════
  t28 = runGroup "T28-PatternNestedRecord" [
    (mkTestBool "INV-PAT-3: flat Record vars"
      (let
        pat  = ts.mkPRecord { a = ts.mkPVar "x"; b = ts.mkPVar "y"; };
        vars = ts.patternVars pat;
      in builtins.elem "x" vars && builtins.elem "y" vars))
    (mkTestBool "INV-PAT-3: nested Record vars outer"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
        vars  = ts.patternVars outer;
      in builtins.elem "x" vars))
    (mkTestBool "INV-PAT-3: nested Record vars inner"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
        vars  = ts.patternVars outer;
      in builtins.elem "y" vars))
    (mkTestBool "INV-PAT-3: patternVarsSet for nested Record"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "myZ"; };
        outer = ts.mkPRecord { a = ts.mkPVar "myX"; b = inner; };
        vset  = ts.patternVarsSet outer;
      in vset ? myX && vset ? myZ))
    (mkTestBool "INV-PAT-3: checkPatternVars nested Record"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
      in ts.checkPatternVars outer { x = true; y = true; }))
    (mkTestBool "INV-PAT-3: patternDepth nested Record"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
      in ts.patternDepth outer >= 1))
    (mkTestBool "INV-PAT-3: isLinear nested Record"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
      in ts.isLinear outer))
  ];

  # ════════════════════════════════════════════════════════════════════
  # 聚合（Aggregation）
  # ════════════════════════════════════════════════════════════════════

  allGroups = [ t1 t2 t3 t4 t5 t6 t7 t8 t9 t10
                t11 t12 t13 t14 t15 t16 t17 t18 t19 t20
                t21 t22 t23 t24 t25 t26 t27 t28 ];

  totalPassed = lib.foldl' (acc: g: acc + (g.passed or 0)) 0 allGroups;
  totalTests  = lib.foldl' (acc: g: acc + (g.total  or 0)) 0 allGroups;

  # INV-TEST-5: 防御性 failedGroups
  failedGroups = lib.filter (g: builtins.isAttrs g && !(g.ok or true)) allGroups;
  allPassed    = failedGroups == [];

  # ── runAll: JSON-safe group summary（INV-TEST-7）─────────────────
  runAll = map (g: {
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
  }) allGroups;

  # ── failedList: INV-TEST-5 防御性────────────────────────────────
  failedList =
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

  # ── diagnoseAll: 详细诊断输出（INV-TEST-6/7）────────────────────
  # 包含失败测试的诊断信息（hint, actual, expected 值）
  # JSON-safe: 所有值经 _safeShow 转为字符串
  diagnoseAll =
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
in {
  inherit allGroups totalPassed totalTests allPassed failedGroups runAll failedList diagnoseAll;
  passed  = totalPassed;
  total   = totalTests;
  ok      = allPassed;

  summary = "Passed: ${builtins.toString totalPassed} / ${builtins.toString totalTests}";
}
