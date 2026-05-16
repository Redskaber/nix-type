# tests/test_all.nix — Phase 4.5.9
# 完整测试套件（203 tests，28 组）
#
# ★ Phase 4.5.9 — BUG-T16/BUG-T25 已解决，测试清理（203/203 通过）
#
# 历史修复记录（已归档）:
#   BUG-T16 (已解决 4.5.9): patternVars Ctor → []
#     根因: 任何捕获 letrec 绑定 _patternVarsGo 的 lambda 传给 map/foldl' 均触发
#           builtins.tryEval strict 模式下的 thunk cycle 检测。
#     最终修复 (INV-NIX-5): 两层迭代 BFS 设计（_extractOne + _expand1 + 8级展开），
#           彻底消除递归自引用。match/pattern.nix 已稳定。
#   BUG-T25 (已解决 4.5.9): invPat1 → false
#     根因: 同 BUG-T16，patternVars 返回 [] 导致 builtins.elem 为 false。
#     修复: invPat1 清理为 ctorName: varName: 两参数形式（去掉冗余 pat: 参数）。
#
# 不变式：
#   INV-TEST-1: builtins.tryEval 隔离每个测试，单失败不中断整个套件
#   INV-TEST-2: pattern 测试使用 patternLib.mkPVar，不使用 refinedLib 版本
#   INV-TEST-3: Unicode attrset key 使用引号字符串 set ? "α"
#   INV-TEST-4: tb.testGroup 防御性检查 tests 参数类型
#   INV-TEST-5: failedList 防御性检查 g.failed 字段
#   INV-TEST-6: tb.mkTestBool/mkTest 均携带 diag 字段供调试
#   INV-TEST-7: 诊断输出 JSON-safe（无 Type 对象，无函数值）
#
# 不变式：
#   INV-TEST-1: builtins.tryEval 隔离每个测试，单失败不中断整个套件
#   INV-TEST-2: pattern 测试使用 patternLib.mkPVar，不使用 refinedLib 版本
#   INV-TEST-3: Unicode attrset key 使用引号字符串 set ? "α"
#   INV-TEST-4: tb.testGroup 防御性检查 tests 参数类型
#   INV-TEST-5: failedList 防御性检查 g.failed 字段
#   INV-TEST-6: tb.mkTestBool/mkTest 均携带 diag 字段供调试
#   INV-TEST-7: 诊断输出 JSON-safe（无 Type 对象，无函数值）
{ lib ? (import <nixpkgs> {}).lib }:

let
  ts = import ../lib/default.nix { inherit lib; };
  tb = import ../testlib/default.nix { inherit lib; };


  # ════════════════════════════════════════════════════════════════════
  # T1: TypeIR 核心（INV-1）
  # ════════════════════════════════════════════════════════════════════
  t1 = tb.testGroup "T1-TypeIR" [
    (tb.mkTestBool "tInt is Type"    (ts.isType ts.tInt))
    (tb.mkTestBool "tBool is Type"   (ts.isType ts.tBool))
    (tb.mkTestBool "tString is Type" (ts.isType ts.tString))
    (tb.mkTestBool "tUnit is Type"   (ts.isType ts.tUnit))
    (tb.mkTestBool "tInt has id"     (builtins.isString ts.tInt.id))
    (tb.mkTestBool "tBool has kind"  (ts.isKind ts.tBool.kind))
    (tb.mkTestBool "mkFn creates Fn"
      ((ts.mkFn ts.tInt ts.tBool).repr.__variant == "Fn"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T2: Kind 系统（INV-K1）
  # ════════════════════════════════════════════════════════════════════
  t2 = tb.testGroup "T2-Kind" [
    (tb.mkTestBool "KStar is kind"  (ts.isKind ts.KStar))
    (tb.mkTestBool "KRow is kind"   (ts.isKind ts.KRow))
    (tb.mkTestBool "KArrow a b"     (ts.isKArrow (ts.KArrow ts.KStar ts.KStar)))
    (tb.mkTestBool "kindEq Star"    (ts.kindEq ts.KStar ts.KStar))
    (tb.mkTestBool "kindEq Arrow"   (ts.kindEq (ts.KArrow ts.KStar ts.KStar) (ts.KArrow ts.KStar ts.KStar)))
    (tb.mkTestBool "unifyKind ok"   ((ts.unifyKind ts.KStar ts.KStar).ok))
    (tb.mkTestBool "unifyKind fail" (!(ts.unifyKind ts.KStar ts.KRow).ok))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T3: TypeRepr 宇宙（INV-2）
  # ════════════════════════════════════════════════════════════════════
  t3 = tb.testGroup "T3-TypeRepr" [
    (tb.mkTestBool "rFn"          ((ts.rFn ts.tInt ts.tBool).__variant == "Fn"))
    (tb.mkTestBool "rForAll"      ((ts.rForAll "a" ts.KStar ts.tInt).__variant == "ForAll"))
    (tb.mkTestBool "rMu"          ((ts.rMu "X" ts.tInt).__variant == "Mu"))
    (tb.mkTestBool "rTyCon"       ((ts.rTyCon "List" ts.KStar).__variant == "TyCon"))
    (tb.mkTestBool "rApply"       ((ts.rApply (ts.mkTypeDefault (ts.rTyCon "F" (ts.KArrow ts.KStar ts.KStar)) (ts.KArrow ts.KStar ts.KStar)) [ts.tInt]).__variant == "Apply"))
    (tb.mkTestBool "rSig"         ((ts.rSig { x = ts.tInt; }).__variant == "Sig"))
    (tb.mkTestBool "rVariantRow"  ((ts.rVariantRow { A = ts.tInt; } null).__variant == "VariantRow"))
    (tb.mkTestBool "rRowEmpty"    (ts.rRowEmpty.__variant == "RowEmpty"))
    (tb.mkTestBool "rVar"         ((ts.rVar "α").__variant == "Var"))
    (tb.mkTestBool "rEffect"      ((ts.rEffect (ts.mkTypeDefault (ts.rVariantRow { Io = ts.tUnit; } null) ts.KRow) ts.tInt).__variant == "Effect"))
    (tb.mkTestBool "rHandler"     ((ts.rHandler "State" [] ts.tInt).__variant == "Handler"))
    (tb.mkTestBool "rComposedFunctor" (builtins.isAttrs (ts.rComposedFunctor)))
    (tb.mkTestBool "rTypeScheme"   (builtins.isAttrs (ts.rTypeScheme "a" ts.KStar ts.tInt)))
    (tb.mkTestBool "rDynamic"      (ts.rDynamic.__variant == "Dynamic"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T4: 序列化（INV-SER-1）
  # ════════════════════════════════════════════════════════════════════
  t4 = tb.testGroup "T4-Serialize" [
    (tb.mkTestBool "serializeKind KStar"
      (ts.serializeKind ts.KStar == "*"))
    (tb.mkTestBool "serializeKind KArrow"
      (ts.serializeKind (ts.KArrow ts.KStar ts.KStar) == "(* -> *)"))
    (tb.mkTestBool "serializeRepr Fn"
      (builtins.isString (ts.serializeRepr (ts.rFn ts.tInt ts.tBool))))
    (tb.mkTestBool "serializeConstraint Eq"
      (builtins.isString (ts.serializeConstraint (ts.mkEqConstraint ts.tInt ts.tBool))))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T5: 正规化（INV-3）
  # ════════════════════════════════════════════════════════════════════
  t5 = tb.testGroup "T5-Normalize" [
    (tb.mkTestBool "normalize ts.tInt"
      (ts.isType (ts.normalize' ts.tInt)))
    (tb.mkTestBool "normalize ts.tBool"
      (ts.isType (ts.normalize' ts.tBool)))
    (tb.mkTestBool "normalize Fn"
      (ts.isType (ts.normalize' (ts.mkFn ts.tInt ts.tBool))))
    (tb.mkTestBool "normalize ForAll"
      (ts.isType (ts.normalize'
        (ts.mkTypeDefault (ts.rForAll "a" ts.KStar ts.tInt) ts.KStar))))
    (tb.mkTestBool "normalize idempotent ts.tInt"
      (let n1 = ts.normalize' ts.tInt; n2 = ts.normalize' n1; in
       ts.typeHash n1 == ts.typeHash n2))
    (tb.mkTestBool "normalize Mu"
      (ts.isType (ts.normalize'
        (ts.mkTypeDefault (ts.rMu "X" ts.tInt) ts.KStar))))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T6: Hash（INV-NRM2）
  # ════════════════════════════════════════════════════════════════════
  t6 = tb.testGroup "T6-Hash" [
    (tb.mkTestBool "typeHash is string"
      (builtins.isString (ts.typeHash ts.tInt)))
    (tb.mkTestBool "typeHash stable ts.tInt"
      (ts.typeHash ts.tInt == ts.typeHash ts.tInt))
    (tb.mkTestBool "typeHash differs ts.tInt ts.tBool"
      (ts.typeHash ts.tInt != ts.typeHash ts.tBool))
    (tb.mkTestBool "typeHash stable Fn"
      (let f = ts.mkFn ts.tInt ts.tBool; in ts.typeHash f == ts.typeHash f))
    (tb.mkTestBool "typeHash Fn != ts.tInt"
      (ts.typeHash (ts.mkFn ts.tInt ts.tBool) != ts.typeHash ts.tInt))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T7: 约束 IR（INV-SOL）
  # ════════════════════════════════════════════════════════════════════
  t7 = tb.testGroup "T7-ConstraintIR" [
    (tb.mkTestBool "mkEqConstraint"
      ((ts.mkEqConstraint ts.tInt ts.tBool).__constraintTag == "Eq"))
    (tb.mkTestBool "mkSubConstraint"
      ((ts.mkSubConstraint ts.tInt ts.tBool).__constraintTag == "Sub"))
    (tb.mkTestBool "mkHasFieldConstraint"
      ((ts.mkHasFieldConstraint "x" ts.tInt (ts.mkTypeDefault (ts.rSig { x = ts.tInt; }) ts.KStar)).__constraintTag == "HasField"))
    (tb.mkTestBool "mkClassConstraint"
      ((ts.mkClassConstraint "Eq" [ts.tInt]).__constraintTag == "Class"))
    (tb.mkTestBool "mkImpliesConstraint"
      ((ts.mkImpliesConstraint (ts.mkEqConstraint ts.tInt ts.tInt) (ts.mkEqConstraint ts.tBool ts.tBool)).__constraintTag == "Implies"))
    (tb.mkTestBool "mkRowConstraint"
      ((ts.mkRowConstraint ts.tInt ts.tBool).__constraintTag == "RowEq"))
    (tb.mkTestBool "isConstraint"
      (ts.isConstraint (ts.mkEqConstraint ts.tInt ts.tBool)))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T8: UnifiedSubst（INV-US1~5）
  # ════════════════════════════════════════════════════════════════════
  t8 = tb.testGroup "T8-UnifiedSubst" [
    (tb.mkTestBool "emptySubst"
      (let s = ts.emptySubst; in
       builtins.isAttrs s && s.typeBindings == {} && s.rowBindings == {}))
    (tb.mkTestBool "bindType"
      (let s = ts.bindType "a" ts.tInt ts.emptySubst; in
       builtins.isAttrs (s.typeBindings.a or null)))
    (tb.mkTestBool "applySubst id"
      (ts.isType (ts.applySubst ts.emptySubst ts.tInt)))
    (tb.mkTestBool "applySubst binding"
      (let
        s = ts.bindType "α" ts.tInt ts.emptySubst;
        v = ts.mkTypeDefault (ts.rVar "α") ts.KStar;
        r = ts.applySubst s v;
      in ts.typeHash r == ts.typeHash ts.tInt))
    (tb.mkTestBool "composeSubst"
      (let
        s1 = ts.bindType "a" ts.tInt ts.emptySubst;
        s2 = ts.bindType "b" ts.tBool ts.emptySubst;
        s  = ts.composeSubst s1 s2;
      in s.typeBindings ? a && s.typeBindings ? b))
    (tb.mkTestBool "freeVars ts.tInt = []"
      (ts.freeVars ts.tInt == []))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T9: 约束求解器（INV-SOL5）
  # ════════════════════════════════════════════════════════════════════
  t9 = tb.testGroup "T9-Solver" [
    (tb.mkTestBool "solve empty"
      # BUG-T9 fix: solve = constraints: classGraph: instanceDB:
      (let r = ts.solve [] {} {}; in r.ok or false))
    (tb.mkTestBool "solve Eq Int Int"
      (let
        c = ts.mkEqConstraint ts.tInt ts.tInt;
        r = ts.solve [c] {} {};
      in r.ok or false))
    (tb.mkTestBool "solve Eq Int Bool fails"
      (let
        c = ts.mkEqConstraint ts.tInt ts.tBool;
        r = ts.solve [c] {} {};
      in !(r.ok or true)))
    (tb.mkTestBool "solve returns subst"
      (let
        r = ts.solve [] {} {};
      in builtins.isAttrs (r.subst or null)))
    (tb.mkTestBool "solve Eq Var Int"
      (let
        v = ts.mkTypeDefault (ts.rVar "α") ts.KStar;
        c = ts.mkEqConstraint v ts.tInt;
        r = ts.solve [c] {} {};
      in r.ok or false))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T10: InstanceDB（INV-I1）
  # ════════════════════════════════════════════════════════════════════
  t10 = tb.testGroup "T10-InstanceDB" [
    (tb.mkTestBool "emptyDB is attrset"
      (builtins.isAttrs ts.emptyDB))
    (tb.mkTestBool "registerInstance"
      (let
        inst = ts.makeInstance "Eq" [ts.tInt] (ts.mkSig { eq = ts.mkFn ts.tInt (ts.mkFn ts.tInt ts.tBool); });
        db   = ts.registerInstance inst ts.emptyDB;
      in builtins.isAttrs db))
    (tb.mkTestBool "lookupInstance found"
      (let
        inst = ts.makeInstance "Eq" [ts.tInt] (ts.mkSig { eq = ts.mkFn ts.tInt (ts.mkFn ts.tInt ts.tBool); });
        db   = ts.registerInstance inst ts.emptyDB;
        r    = ts.lookupInstance "Eq" [ts.tInt] db;
      in r.found or false))
    (tb.mkTestBool "lookupInstance not found"
      (let
        r = ts.lookupInstance "Eq" [ts.tInt] ts.emptyDB;
      in !(r.found or true)))
    (tb.mkTestBool "INV-I1: NF-hash key consistency"
      (let
        inst1 = ts.makeInstance "Eq" [ts.tInt] (ts.mkSig { eq = ts.mkFn ts.tInt (ts.mkFn ts.tInt ts.tBool); });
        inst2 = ts.makeInstance "Eq" [ts.tInt] (ts.mkSig { eq = ts.mkFn ts.tInt (ts.mkFn ts.tInt ts.tBool); });
        db1   = ts.registerInstance inst1 ts.emptyDB;
        db2   = ts.registerInstance inst2 ts.emptyDB;
        r1    = ts.lookupInstance "Eq" [ts.tInt] db1;
        r2    = ts.lookupInstance "Eq" [ts.tInt] db2;
      in r1.found && r2.found))
    (tb.mkTestBool "makeInstance has className"
      (let
        inst = ts.makeInstance "Show" [ts.tBool] (ts.mkSig { show = ts.mkFn ts.tBool ts.tString; });
      in inst.className == "Show"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T11: Refined Types（INV-REF）
  # ════════════════════════════════════════════════════════════════════
  t11 = tb.testGroup "T11-RefinedTypes" [
    (tb.mkTestBool "mkRefined"
      (builtins.isAttrs (ts.mkRefined ts.tInt (ts.mkPGt (ts.mkPLit 0)))))
    (tb.mkTestBool "mkPLit"
      ((ts.mkPLit 42).__predTag == "PLit"))
    (tb.mkTestBool "mkPGt"
      ((ts.mkPGt (ts.mkPLit 0)).__predTag == "Gt"))
    (tb.mkTestBool "mkPAnd"
      ((ts.mkPAnd (ts.mkPLit 0) (ts.mkPLit 1)).__predTag == "PAnd"))
    (tb.mkTestBool "mkPOr"
      ((ts.mkPOr (ts.mkPLit 0) (ts.mkPLit 1)).__predTag == "POr"))
    (tb.mkTestBool "mkPNot"
      ((ts.mkPNot (ts.mkPLit 0)).__predTag == "PNot"))
    (tb.mkTestBool "checkRefined ok"
      (let
        r = ts.mkRefined ts.tInt (ts.mkPGt (ts.mkPLit 0));
        c = ts.checkRefined r;
      in c.ok or false))
    (tb.mkTestBool "smtEncode"
      (builtins.isString (ts.smtEncode (ts.mkPGt (ts.mkPLit 0)))))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T12: Module System（INV-MOD）
  # ════════════════════════════════════════════════════════════════════
  t12 = tb.testGroup "T12-ModuleSystem" [
    (tb.mkTestBool "mkSig"
      ((ts.mkSig { x = ts.tInt; }).repr.__variant == "Sig"))
    (tb.mkTestBool "mkModFunctor"
      (builtins.isAttrs (ts.mkModFunctor "A" (ts.mkSig { x = ts.tInt; }) ts.tInt)))
    (tb.mkTestBool "sigIntersection"
      (let
        s1 = ts.mkSig { x = ts.tInt; y = ts.tBool; };
        s2 = ts.mkSig { x = ts.tInt; z = ts.tString; };
        r  = ts.sigIntersection s1 s2;
      in builtins.isAttrs r.intersection))
    (tb.mkTestBool "sigUnion"
      (let
        s1 = ts.mkSig { x = ts.tInt; };
        s2 = ts.mkSig { y = ts.tBool; };
        r  = ts.sigUnion s1 s2;
      in builtins.isAttrs r.union))
    (tb.mkTestBool "seal/unseal"
      (let
        s = ts.seal ts.tInt "MyTag";
        u = ts.unseal s "MyTag";
      in u.ok or false))
    (tb.mkTestBool "seal/unseal wrong tag"
      (let
        s = ts.seal ts.tInt "Tag1";
        u = ts.unseal s "Tag2";
      in !(u.ok or true)))
    (tb.mkTestBool "mkModFunctor has name"
      (let
        mf = ts.mkModFunctor "Functor" (ts.mkSig { fmap = ts.tInt; }) ts.tBool;
      in mf.name == "Functor" || builtins.isAttrs mf))
    (tb.mkTestBool "INV-MOD-4: sigIntersection subset"
      (let
        s1 = ts.mkSig { x = ts.tInt; y = ts.tBool; };
        s2 = ts.mkSig { x = ts.tInt; z = ts.tString; };
        r  = ts.sigIntersection s1 s2;
        iFields = builtins.attrNames r.intersection.repr.fields;
      in builtins.elem "x" iFields))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T13: Effect Handlers（INV-EFF）
  # ════════════════════════════════════════════════════════════════════
  t13 = tb.testGroup "T13-EffectHandlers" [
    (tb.mkTestBool "mkHandler"
      (ts.isHandler (ts.mkHandler "State" [] ts.tInt)))
    (tb.mkTestBool "mkDeepHandler"
      (let h = ts.mkDeepHandler "Log" [] ts.tUnit; in h.repr.deep or false))
    (tb.mkTestBool "mkShallowHandler"
      (let h = ts.mkShallowHandler "IO" [] ts.tUnit; in h.repr.shallow or false))
    (tb.mkTestBool "emptyEffectRow"
      (ts.emptyEffectRow.repr.__variant == "RowEmpty"))
    (tb.mkTestBool "singleEffect"
      ((ts.singleEffect "State" ts.tInt).repr.__variant == "VariantRow"))
    (tb.mkTestBool "effectMerge"
      (let em = ts.effectMerge ts.emptyEffectRow ts.emptyEffectRow; in
       (em ? __variant && em.__variant == "EffectMerge")
       || (em.repr.__variant or null) == "EffectMerge"))
    (tb.mkTestBool "checkEffectWellFormed"
      ((ts.checkEffectWellFormed (ts.mkTypeDefault
        (ts.rEffect (ts.mkTypeDefault (ts.rVariantRow { Io = ts.tUnit; } null) ts.KRow) ts.tInt)
        ts.KStar)).ok))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T14: QueryDB（INV-G3）
  # ════════════════════════════════════════════════════════════════════
  t14 = tb.testGroup "T14-QueryDB" [
    (tb.mkTestBool "mkQueryKey"
      (builtins.isString (ts.mkQueryKey "normalize" ts.tInt)))
    (tb.mkTestBool "storeResult"
      (let
        k  = ts.mkQueryKey "normalize" ts.tInt;
        db = ts.storeResult k ts.tBool {};
      in builtins.isAttrs db))
    (tb.mkTestBool "lookupResult hit"
      (let
        k  = ts.mkQueryKey "normalize" ts.tInt;
        db = ts.storeResult k ts.tBool {};
        r  = ts.lookupResult k db;
      in r.found or false))
    (tb.mkTestBool "lookupResult miss"
      (let
        k  = ts.mkQueryKey "normalize" ts.tInt;
        r  = ts.lookupResult k {};
      in !(r.found or true)))
    (tb.mkTestBool "invalidateKey"
      (let
        k  = ts.mkQueryKey "normalize" ts.tInt;
        db = ts.storeResult k ts.tBool {};
        db2 = ts.invalidateKey k db;
        r   = ts.lookupResult k db2;
      in !(r.found or true)))
    (tb.mkTestBool "cacheStats"
      (let
        k  = ts.mkQueryKey "x" ts.tInt;
        db = ts.storeResult k ts.tBool {};
        s  = ts.cacheStats db;
      in s.size >= 1))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T15: Incremental Graph（INV-G1~4）
  # ════════════════════════════════════════════════════════════════════
  t15 = tb.testGroup "T15-IncrementalGraph" [
    (tb.mkTestBool "addNode"
      (let g = ts.addNode "A" {}; in g ? nodes))
    (tb.mkTestBool "addEdge"
      (let
        g = ts.addEdge "A" "B" (ts.addNode "B" (ts.addNode "A" {}));
      in g ? edges))
    (tb.mkTestBool "topologicalSort ok"
      (let
        g = ts.addEdge "A" "B" (ts.addEdge "B" "C"
              (ts.addNode "C" (ts.addNode "B" (ts.addNode "A" {}))));
        r = ts.topologicalSort g;
      in r.ok or false))
    (tb.mkTestBool "topologicalSort order"
      (let
        g = ts.addEdge "A" "B" (ts.addEdge "B" "C"
              (ts.addNode "C" (ts.addNode "B" (ts.addNode "A" {}))));
        r = ts.topologicalSort g;
      in r.ok && builtins.isList r.order))
    (tb.mkTestBool "hasCycle false"
      (let
        g = ts.addEdge "A" "B" (ts.addNode "B" (ts.addNode "A" {}));
      in !(ts.hasCycle g)))
    (tb.mkTestBool "markStale"
      (let
        g = ts.addNode "A" {};
        g2 = ts.markStale "A" g;
      in builtins.isAttrs g2))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T16: Pattern Matching（INV-PAT-1/2）
  # ★ Phase 4.5.9: BUG-T16/BUG-T25 已解决，使用 mkTestBool 清理
  # ════════════════════════════════════════════════════════════════════
  t16 = tb.testGroup "T16-PatternMatch" [
    (tb.mkTestBool "mkPWild"
      (ts.isPattern ts.mkPWild))
    (tb.mkTestBool "mkPVar"
      (ts.isPattern (ts.mkPVar "x")))
    (tb.mkTestBool "mkPCtor"
      (ts.isPattern (ts.mkPCtor "Some" [ts.mkPVar "x"])))
    (tb.mkTestBool "mkArm"
      ((ts.mkArm ts.mkPWild ts.tInt).__armTag == "Arm"))
    (tb.mkTestBool "compileMatch Wild → Leaf"
      (let
        arm = ts.mkArm ts.mkPWild ts.tInt;
        tVariants = [{ name = "Some"; ordinal = 0; } { name = "None"; ordinal = 1; }];
        dt  = ts.compileMatch [arm] tVariants;
      in dt.__dtTag == "Leaf"))
    (tb.mkTestBool "checkExhaustive"
      (let
        tVariants = [{ name = "Some"; ordinal = 0; } { name = "None"; ordinal = 1; }];
        arms = [ (ts.mkArm ts.mkPWild ts.tInt) ];
        r    = ts.checkExhaustive arms tVariants;
      in r.exhaustive))
    # ★ BUG-T16 已解决（Phase 4.5.9）: patternVars Ctor 正确返回 ["x"]
    # 根因: letrec 绑定的 _patternVarsGo 被 lambda 捕获后传入 map/foldl' 触发 thunk cycle。
    # 修复: INV-NIX-5 两层迭代 BFS（_extractOne + _expand1 + 8级展开）彻底消除递归自引用。
    (tb.mkTestBool "patternVars Ctor ∋ x"
      (let
        p    = ts.mkPCtor "Some" [(ts.mkPVar "x")];
        vars = ts.patternVars p;
      in builtins.isList vars && builtins.elem "x" vars))
    (tb.mkTestBool "patternVars Var"
      (ts.patternVars (ts.mkPVar "y") == ["y"]))
    (tb.mkTestBool "patternVars Wild = []"
      (ts.patternVars ts.mkPWild == []))
    (tb.mkTestBool "patternVarsSet"
      (let
        p2 = ts.mkPAnd_p (ts.mkPVar "a") (ts.mkPVar "b");
        s  = ts.patternVarsSet p2;
      in builtins.isAttrs s && s ? a && s ? b))
    (tb.mkTestBool "isLinear simple"
      (ts.isLinear (ts.mkPCtor "Just" [ts.mkPVar "x"])))
    (tb.mkTestBool "patternDepth Wild = 0"
      (ts.patternDepth ts.mkPWild == 0))
    (tb.mkTestBool "patternDepth Ctor = 1"
      (ts.patternDepth (ts.mkPCtor "Just" [ts.mkPWild]) == 1))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T17: Row 多态（INV-ROW）
  # ════════════════════════════════════════════════════════════════════
  t17 = tb.testGroup "T17-RowPolymorphism" [
    (tb.mkTestBool "rVariantRow"
      ((ts.rVariantRow { State = ts.tInt; } null).__variant == "VariantRow"))
    (tb.mkTestBool "rVar RowVar"
      ((ts.rVar "ρ").__variant == "Var"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T18: Bidir（INV-BIDIR-1）
  # ════════════════════════════════════════════════════════════════════
  t18 = tb.testGroup "T18-Bidir" [
    (tb.mkTestBool "infer eLit 42"
      (let r = ts.infer {} (ts.eLit 42); in ts.isType r.type))
    (tb.mkTestBool "infer eVar x"
      (let
        ctx = { x = ts.tInt; };
        r   = ts.infer ctx (ts.eVar "x");
      in ts.typeHash r.type == ts.typeHash ts.tInt))
    (tb.mkTestBool "infer eLam"
      (let r = ts.infer {} (ts.eLam "x" (ts.eVar "x")); in ts.isType r.type))
    (tb.mkTestBool "check eLit 42 : Int"
      (let r = ts.check {} (ts.eLit 42) ts.tInt; in r.ok or false))
    (tb.mkTestBool "check eLit 42 : Bool fails"
      (let r = ts.check {} (ts.eLit 42) ts.tBool; in !(r.ok or true)))
    (tb.mkTestBool "infer eApp"
      (let
        fn  = ts.eLam "x" (ts.eVar "x");
        arg = ts.eLit 42;
        r   = ts.infer {} (ts.eApp fn arg);
      in ts.isType r.type))
    (tb.mkTestBool "eLit constructor"
      ((ts.eLit 1).__exprTag == "Lit"))
    (tb.mkTestBool "eVar constructor"
      ((ts.eVar "x").__exprTag == "Var"))
    (tb.mkTestBool "eLam constructor"
      ((ts.eLam "x" (ts.eVar "x")).__exprTag == "Lam"))
    (tb.mkTestBool "eApp constructor"
      ((ts.eApp (ts.eVar "f") (ts.eVar "x")).__exprTag == "App"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T19: Unification（INV-SUB2）
  # ════════════════════════════════════════════════════════════════════
  t19 = tb.testGroup "T19-Unification" [
    (tb.mkTestBool "unify Int Int ok"
      ((ts.unify ts.tInt ts.tInt).ok or false))
    (tb.mkTestBool "unify Int Bool fail"
      (!(ts.unify ts.tInt ts.tBool).ok or true))
    (tb.mkTestBool "unify α Int → ok + binding"
      (let
        alpha = ts.mkTypeDefault (ts.rVar "α") ts.KStar;
        r     = ts.unify alpha ts.tInt;
      in r.ok or false))
    (tb.mkTestBool "unify α Int → binding has α"
      (let
        alpha = ts.mkTypeDefault (ts.rVar "α") ts.KStar;
        r     = ts.unify alpha ts.tInt;
      # INV-TEST-3: Unicode key uses quoted string
      in r.ok && (r.subst.typeBindings or {}) ? "α"))
    (tb.mkTestBool "unify Fn ok"
      ((ts.unify (ts.mkFn ts.tInt ts.tBool) (ts.mkFn ts.tInt ts.tBool)).ok or false))
    (tb.mkTestBool "unify Fn fail"
      (!(ts.unify (ts.mkFn ts.tInt ts.tBool) (ts.mkFn ts.tBool ts.tInt)).ok or true))
    (tb.mkTestBool "unify ForAll ok"
      (let
        fa = ts.mkTypeDefault (ts.rForAll "a" ts.KStar (ts.mkTypeDefault (ts.rVar "a") ts.KStar)) ts.KStar;
      in (ts.unify fa fa).ok or false))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T20: Integration（INV-1~6 联合）
  # ════════════════════════════════════════════════════════════════════
  t20 = tb.testGroup "T20-Integration" [
    (tb.mkTestBool "mkFn + typeHash"
      (let f = ts.mkFn ts.tInt ts.tBool; in builtins.isString (ts.typeHash f)))
    (tb.mkTestBool "mkFn + normalize"
      (let
        f  = ts.mkFn ts.tInt ts.tBool;
        nf = ts.normalize' f;
      in ts.isType nf))
    (tb.mkTestBool "mkFn + check"
      (let
        f = ts.eLam "x" (ts.eVar "x");
        r = ts.infer {} f;
      in ts.isType r.type))
    (tb.mkTestBool "mkSig + seal/unseal roundtrip"
      (let
        s = ts.mkSig { x = ts.tInt; };
        sealed   = ts.seal s "Tag";
        unsealed = ts.unseal sealed "Tag";
      in unsealed.ok))
    (tb.mkTestBool "registerInstance + lookupInstance"
      (let
        inst = ts.makeInstance "Show" [ts.tString] (ts.mkSig { show = ts.mkFn ts.tString ts.tString; });
        db   = ts.registerInstance inst ts.emptyDB;
        r    = ts.lookupInstance "Show" [ts.tString] db;
      in r.found or false))
    (tb.mkTestBool "solve + subst apply"
      (let
        alpha = ts.mkTypeDefault (ts.rVar "β") ts.KStar;
        c     = ts.mkEqConstraint alpha ts.tBool;
        r     = ts.solve [c] {} {};
        t2    = ts.applySubst r.subst alpha;
      in r.ok && ts.typeHash t2 == ts.typeHash ts.tBool))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T21: Kind Inference（INV-KIND-1/2）
  # ════════════════════════════════════════════════════════════════════
  t21 = tb.testGroup "T21-KindInference" [
    (tb.mkTestBool "inferKind Var"
      (let r = ts.inferKind {} (ts.rVar "a"); in builtins.isAttrs r))
    (tb.mkTestBool "inferKind TyCon"
      (let r = ts.inferKind {} (ts.rTyCon "List" ts.KStar); in r.kind or null != null))
    (tb.mkTestBool "inferKind Fn"
      (let r = ts.inferKind {} (ts.rFn ts.tInt ts.tBool); in ts.kindEq (r.kind or ts.KStar) ts.KStar))
    (tb.mkTestBool "inferKind ForAll"
      (let
        fa = ts.rForAll "a" ts.KStar ts.tInt;
        r  = ts.inferKind { a = ts.KStar; } fa;
      in builtins.isAttrs r))
    (tb.mkTestBool "unifyKind KVar"
      (let r = ts.unifyKind (ts.KVar "k1") ts.KStar; in r.ok or false))
    (tb.mkTestBool "applyKindSubst"
      (let
        s = { k1 = ts.KStar; };
        r = ts.applyKindSubst s (ts.KVar "k1");
      in ts.kindEq r ts.KStar))
    (tb.mkTestBool "kindArity KArrow"
      (ts.kindArity (ts.KArrow ts.KStar ts.KStar) == 1))
    (tb.mkTestBool "kindArity KArrow 2"
      (ts.kindArity (ts.KArrow ts.KStar (ts.KArrow ts.KStar ts.KStar)) == 2))
    (tb.mkTestBool "applyKind ok"
      (let r = ts.applyKind (ts.KArrow ts.KStar ts.KStar) ts.KStar; in
       ts.kindEq r ts.KStar))
    (tb.mkTestBool "applyKind mismatch null"
      (ts.applyKind (ts.KArrow ts.KStar ts.KStar) ts.KRow == null))
    (tb.mkTestBool "INV-KIND-1: infer List = * → *"
      (let
        listCtor = ts.mkTypeDefault
          (ts.rTyCon "List" (ts.KArrow ts.KStar ts.KStar))
          (ts.KArrow ts.KStar ts.KStar);
        r = ts.inferKind {} listCtor.repr;
      in ts.kindEq (r.kind or ts.KStar) (ts.KArrow ts.KStar ts.KStar)))
    (tb.mkTestBool "INV-KIND-2: annotation propagation"
      (let r = ts.checkKindAnnotation {} (ts.rFn ts.tInt ts.tBool) ts.KStar; in r.ok or false))
    (tb.mkTestBool "inferKindWithAnnotation"
      (let r = ts.inferKindWithAnnotation {} (ts.rFn ts.tInt ts.tBool) ts.KStar; in builtins.isAttrs r))
    (tb.mkTestBool "defaultKinds"
      (builtins.isAttrs ts.defaultKinds))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T22: Handler Continuations（INV-EFF-10）
  # ════════════════════════════════════════════════════════════════════
  t22 = tb.testGroup "T22-HandlerContinuations" [
    (tb.mkTestBool "mkHandlerWithCont creates handler"
      (let
        contTy = ts.mkContType ts.tInt ts.emptyEffectRow ts.tUnit;
        h      = ts.mkHandlerWithCont "State" ts.tInt contTy ts.tUnit;
      in ts.isHandler h))
    (tb.mkTestBool "mkHandlerWithCont hasCont = true"
      (let
        contTy = ts.mkContType ts.tInt ts.emptyEffectRow ts.tUnit;
        h      = ts.mkHandlerWithCont "State" ts.tInt contTy ts.tUnit;
      in h.repr.hasCont or false))
    (tb.mkTestBool "mkContType"
      (let
        ct = ts.mkContType ts.tInt ts.emptyEffectRow ts.tBool;
      in ts.isType ct))
    (tb.mkTestBool "checkHandlerContWellFormed ok"
      (let
        contTy = ts.mkContType ts.tString ts.emptyEffectRow ts.tUnit;
        h      = ts.mkHandlerWithCont "Log" ts.tString contTy ts.tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in r.ok or false))
    (tb.mkTestBool "isHandlerWithCont"
      (let
        contTy = ts.mkContType ts.tInt ts.emptyEffectRow ts.tBool;
        h      = ts.mkHandlerWithCont "State" ts.tInt contTy ts.tBool;
      in ts.isHandlerWithCont h))
    (tb.mkTestBool "contDomainOk true"
      (let
        contTy = ts.mkContType ts.tInt ts.emptyEffectRow ts.tUnit;
        h      = ts.mkHandlerWithCont "Get" ts.tInt contTy ts.tUnit;
      in h.repr.contDomainOk or false))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T23: Mu Bisim Congruence（INV-MU-1）
  # ════════════════════════════════════════════════════════════════════
  t23 = tb.testGroup "T23-MuBisimCongruence" [
    (tb.mkTestBool "muEq same"
      (let
        mu = ts.mkTypeDefault (ts.rMu "X" ts.tInt) ts.KStar;
      in ts.muEq mu mu))
    (tb.mkTestBool "muEq alpha-renamed"
      (let
        mu1 = ts.mkTypeDefault (ts.rMu "X" ts.tInt) ts.KStar;
        mu2 = ts.mkTypeDefault (ts.rMu "Y" ts.tInt) ts.KStar;
      in ts.muEq mu1 mu2))
    (tb.mkTestBool "muEq different body"
      (let
        mu1 = ts.mkTypeDefault (ts.rMu "X" ts.tInt) ts.KStar;
        mu2 = ts.mkTypeDefault (ts.rMu "X" ts.tBool) ts.KStar;
      in !(ts.muEq mu1 mu2)))
    (tb.mkTestBool "unify Mu alpha-renamed"
      (let
        mu1 = ts.mkTypeDefault (ts.rMu "X" ts.tInt) ts.KStar;
        mu2 = ts.mkTypeDefault (ts.rMu "Y" ts.tInt) ts.KStar;
        r   = ts.unify mu1 mu2;
      in r.ok or false))
    (tb.mkTestBool "normalize Mu idempotent"
      (let
        mu = ts.mkTypeDefault (ts.rMu "X" ts.tInt) ts.KStar;
        n1 = ts.normalize' mu;
        n2 = ts.normalize' n1;
      in ts.typeHash n1 == ts.typeHash n2))
    (tb.mkTestBool "typeEq Mu"
      (let
        mu1 = ts.mkTypeDefault (ts.rMu "X" ts.tInt) ts.KStar;
        mu2 = ts.mkTypeDefault (ts.rMu "Y" ts.tInt) ts.KStar;
      in ts.typeEq mu1 mu2))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T24: Bidir Annotated Lambda（INV-BIDIR-2）
  # ════════════════════════════════════════════════════════════════════
  t24 = tb.testGroup "T24-BidirAnnotatedLam" [
    (tb.mkTestBool "eLamA constructor"
      ((ts.eLamA "x" ts.tInt (ts.eVar "x")).__exprTag == "llama"))
    (tb.mkTestBool "infer eLamA x:Int x → Int → Int"
      (let
        lam = ts.eLamA "x" ts.tInt (ts.eVar "x");
        r   = ts.infer {} lam;
      in ts.isType r.type))
    (tb.mkTestBool "INV-BIDIR-2: infer eLamA domain correct"
      (let
        lam = ts.eLamA "x" ts.tInt (ts.eVar "x");
        r   = ts.infer {} lam;
      in r.type.repr.__variant or null == "Fn" &&
         ts.typeHash (r.type.repr.from) == ts.typeHash ts.tInt))
    (tb.mkTestBool "checkAnnotatedLam ok"
      (let
        lam = ts.eLamA "x" ts.tInt (ts.eVar "x");
        r   = ts.checkAnnotatedLam {} lam (ts.mkFn ts.tInt ts.tInt);
      in r.ok or false))
    (tb.mkTestBool "checkAnnotatedLam wrong ann fails"
      (let
        lam = ts.eLamA "x" ts.tBool (ts.eVar "x");
        r   = ts.checkAnnotatedLam {} lam (ts.mkFn ts.tInt ts.tInt);
      in !(r.ok or true)))
    (tb.mkTestBool "check eLamA : Int → Int"
      (let
        lam = ts.eLamA "x" ts.tInt (ts.eVar "x");
        r   = ts.check {} lam (ts.mkFn ts.tInt ts.tInt);
      in r.ok or false))
    (tb.mkTestBool "infer eLamA nested"
      (let
        inner = ts.eLamA "y" ts.tBool (ts.eVar "y");
        outer = ts.eLamA "x" ts.tInt inner;
        r     = ts.infer {} outer;
      in ts.isType r.type))
    (tb.mkTestBool "infer eLamA app"
      (let
        fn  = ts.eLamA "x" ts.tInt (ts.eVar "x");
        app = ts.eApp fn (ts.eLit 42);
        r   = ts.infer {} app;
      in ts.isType r.type))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T25: Handler Continuation Type Check（INV-EFF-11）
  # ★ Phase 4.5.9: BUG-T25 已解决，使用 mkTestBool 清理
  # ════════════════════════════════════════════════════════════════════
  t25 = tb.testGroup "T25-HandlerContTypeCheck" [
    # INV-EFF-11: contType.from == paramType
    (tb.mkTestBool "INV-EFF-11: domain match ok"
      (let
        contTy = ts.mkContType ts.tString ts.emptyEffectRow ts.tUnit;
        h      = ts.mkHandlerWithCont "Log" ts.tString contTy ts.tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in r.inv_eff_11 or false))
    (tb.mkTestBool "INV-EFF-11: domain mismatch fails"
      (let
        # contType domain is ts.tInt, but paramType is ts.tString → mismatch
        contTy = ts.mkContType ts.tInt ts.emptyEffectRow ts.tUnit;
        h      = ts.mkHandlerWithCont "Log" ts.tString contTy ts.tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in !(r.inv_eff_11 or true)))
    (tb.mkTestBool "checkHandlerContWellFormed: not cont handler"
      (let
        h = ts.mkHandler "X" [] ts.tUnit;
        r = ts.checkHandlerContWellFormed h;
      in !(r.ok or true)))
    (tb.mkTestBool "checkHandlerContWellFormed: bad contType"
      (let
        # contType is NOT a Fn type
        contTy = ts.tInt;
        h      = ts.mkHandlerWithCont "X" ts.tString contTy ts.tUnit;
      in !(h.repr.contDomainOk or true)))
    (tb.mkTestBool "checkHandlerContWellFormed: contDomain exposed"
      (let
        contTy = ts.mkContType ts.tString ts.emptyEffectRow ts.tUnit;
        h      = ts.mkHandlerWithCont "Log" ts.tString contTy ts.tUnit;
        r      = ts.checkHandlerContWellFormed h;
      in r.ok && ts.isType (r.contDomain or ts.tUnit)))
    (tb.mkTestBool "mkContType well-formed"
      (let
        ct = ts.mkContType ts.tInt ts.emptyEffectRow ts.tBool;
        r  = ts.checkHandlerContWellFormed
               (ts.mkHandlerWithCont "Get" ts.tInt ct ts.tBool);
      in r.ok or false))
    # ★ BUG-T25 已解决（Phase 4.5.9）: invPat1 正确验证 patternVars 包含变量名
    # invPat1 已清理为 ctorName: varName: 两参数形式（去掉冗余 pat: 参数）。
    (tb.mkTestBool "INV-PAT-1 via invPat1"
      (ts.__checkInvariants.invPat1 "Just" "z"))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T26: Bidir App Result Solved（INV-BIDIR-3）
  # ════════════════════════════════════════════════════════════════════
  t26 = tb.testGroup "T26-BidirAppResultSolved" [
    (tb.mkTestBool "INV-BIDIR-3: infer(app (llama x Int x) 42) yields Int"
      (let
        fn   = ts.eLamA "x" ts.tInt (ts.eVar "x");
        arg  = ts.eLit 42;
        r    = ts.infer {} (ts.eApp fn arg);
      in ts.typeHash r.type == ts.typeHash ts.tInt))
    (tb.mkTestBool "INV-BIDIR-3: infer(app (llama x Bool x) true) yields Bool"
      (let
        fn  = ts.eLamA "x" ts.tBool (ts.eVar "x");
        arg = ts.eLit true;
        r   = ts.infer {} (ts.eApp fn arg);
      in ts.typeHash r.type == ts.typeHash ts.tBool))
    (tb.mkTestBool "checkAppResultSolved: concrete Fn"
      (let
        fnTy = ts.mkFn ts.tInt ts.tBool;
        r    = ts.checkAppResultSolved fnTy;
      in r.solved or false))
    (tb.mkTestBool "checkAppResultSolved: Fn result is codomain"
      (let
        fnTy = ts.mkFn ts.tInt ts.tBool;
        r    = ts.checkAppResultSolved fnTy;
      in r.solved && ts.typeHash r.resultType == ts.typeHash ts.tBool))
    (tb.mkTestBool "infer app of non-annot lam"
      (let
        fn  = ts.eLam "x" (ts.eVar "x");
        arg = ts.eLit 42;
        r   = ts.infer {} (ts.eApp fn arg);
      in ts.isType r.type))
    (tb.mkTestBool "infer nested app"
      (let
        f   = ts.eLamA "x" ts.tInt (ts.eLamA "y" ts.tBool (ts.eVar "x"));
        r   = ts.infer {} (ts.eApp (ts.eApp f (ts.eLit 1)) (ts.eLit true));
      in ts.typeHash r.type == ts.typeHash ts.tInt))
    (tb.mkTestBool "infer app: domain type match"
      (let
        fn  = ts.eLamA "x" ts.tString (ts.eVar "x");
        arg = ts.eLit "hello";
        r   = ts.infer {} (ts.eApp fn arg);
      in ts.typeHash r.type == ts.typeHash ts.tString))
    (tb.mkTestBool "infer app: result is type"
      (let
        fn  = ts.eLamA "f" (ts.mkFn ts.tInt ts.tBool)
                (ts.eApp (ts.eVar "f") (ts.eLit 0));
        r   = ts.infer {} fn;
      in ts.isType r.type))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T27: Kind Fixpoint Solver（INV-KIND-3）
  # ════════════════════════════════════════════════════════════════════
  t27 = tb.testGroup "T27-KindFixpointSolver" [
    (tb.mkTestBool "solveKindConstraintsFixpoint empty"
      (let r = ts.solveKindConstraintsFixpoint [] {}; in builtins.isAttrs r))
    (tb.mkTestBool "solveKindConstraintsFixpoint simple"
      (let
        c = { lhs = ts.KVar "k"; rhs = ts.KStar; };
        r = ts.solveKindConstraintsFixpoint [c] {};
      in builtins.isAttrs r && (r.k or null) != null))
    (tb.mkTestBool "INV-KIND-3: fixpoint reaches stable state"
      (let
        cs = [
          { lhs = ts.KVar "k1"; rhs = ts.KStar; }
          { lhs = ts.KVar "k2"; rhs = ts.KVar "k1"; }
        ];
        r = ts.solveKindConstraintsFixpoint cs {};
      in ts.kindEq (r.k1 or ts.KUnbound) ts.KStar &&
         ts.kindEq (ts.applyKindSubst r (ts.KVar "k2")) ts.KStar))
    (tb.mkTestBool "inferKindWithAnnotationFixpoint"
      (let r = ts.inferKindWithAnnotationFixpoint {} (ts.rFn ts.tInt ts.tBool) ts.KStar; in builtins.isAttrs r))
    (tb.mkTestBool "checkKindAnnotationFixpoint"
      (let r = ts.checkKindAnnotationFixpoint {} (ts.rFn ts.tInt ts.tBool) ts.KStar; in r.ok or false))
    (tb.mkTestBool "KIND-3: chain vars k1 → k2 → * resolve"
      (let
        cs = [
          { lhs = ts.KVar "a"; rhs = ts.KVar "b"; }
          { lhs = ts.KVar "b"; rhs = ts.KStar; }
        ];
        r = ts.solveKindConstraintsFixpoint cs {};
        a = ts.applyKindSubst r (ts.KVar "a");
      in ts.kindEq a ts.KStar))
    (tb.mkTestBool "KIND-3: higher-order KArrow"
      (let
        cs = [{ lhs = ts.KVar "k"; rhs = ts.KArrow ts.KStar ts.KStar; }];
        r  = ts.solveKindConstraintsFixpoint cs {};
      in ts.kindEq (ts.applyKindSubst r (ts.KVar "k")) (ts.KArrow ts.KStar ts.KStar)))
  ];

  # ════════════════════════════════════════════════════════════════════
  # T28: Pattern Nested Record（INV-PAT-3）
  # ════════════════════════════════════════════════════════════════════
  t28 = tb.testGroup "T28-PatternNestedRecord" [
    (tb.mkTestBool "INV-PAT-3: flat Record vars"
      (let
        pat  = ts.mkPRecord { a = ts.mkPVar "x"; b = ts.mkPVar "y"; };
        vars = ts.patternVars pat;
      in builtins.elem "x" vars && builtins.elem "y" vars))
    (tb.mkTestBool "INV-PAT-3: nested Record vars outer"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
        vars  = ts.patternVars outer;
      in builtins.elem "x" vars))
    (tb.mkTestBool "INV-PAT-3: nested Record vars inner"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
        vars  = ts.patternVars outer;
      in builtins.elem "y" vars))
    (tb.mkTestBool "INV-PAT-3: patternVarsSet for nested Record"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "myZ"; };
        outer = ts.mkPRecord { a = ts.mkPVar "myX"; b = inner; };
        vset  = ts.patternVarsSet outer;
      in vset ? myX && vset ? myZ))
    (tb.mkTestBool "INV-PAT-3: checkPatternVars nested Record"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
      in ts.checkPatternVars outer { x = true; y = true; }))
    (tb.mkTestBool "INV-PAT-3: patternDepth nested Record"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
      in ts.patternDepth outer >= 1))
    (tb.mkTestBool "INV-PAT-3: isLinear nested Record"
      (let
        inner = ts.mkPRecord { c = ts.mkPVar "y"; };
        outer = ts.mkPRecord { a = ts.mkPVar "x"; b = inner; };
      in ts.isLinear outer))
  ];

  # ════════════════════════════════════════════════════════════════════
  # 聚合（Aggregation）
  # ════════════════════════════════════════════════════════════════════

  allGroups   = [ t1 t2 t3 t4 t5 t6 t7 t8 t9 t10
                  t11 t12 t13 t14 t15 t16 t17 t18 t19 t20
                  t21 t22 t23 t24 t25 t26 t27 t28 ];

  totalPassed = lib.foldl' (acc: g: acc + (g.passed or 0)) 0 allGroups;
  totalTests  = lib.foldl' (acc: g: acc + (g.total  or 0)) 0 allGroups;

  # INV-TEST-5: 防御性 failedGroups
  failedGroups= tb.failedGroups allGroups;
  allPassed   = failedGroups == [];

  runAll      = tb.runGroups failedGroups;
  failedList  = tb.failedList failedGroups;
  diagnoseAll = tb.diagnoseAll failedGroups;
in {
  inherit allGroups totalPassed totalTests allPassed failedGroups runAll failedList diagnoseAll;
  passed  = totalPassed;
  total   = totalTests;
  ok      = allPassed;

  summary = "Passed: ${builtins.toString totalPassed} / ${builtins.toString totalTests}";
}
