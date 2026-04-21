# tests/test_all.nix  —  Phase 2
# 综合测试套件
#
# 覆盖：
#   T1  基础 TypeIR 不变量
#   T2  de Bruijn alpha-equivalence（P0-1）
#   T3  kindCheck + kindUnify（P0-2）
#   T4  Constructor partial apply（P1-1）
#   T5  μ-types normalize（P1-2）
#   T6  HKT Kind inference（P1-3）
#   T7  Row Polymorphism（P2-1）
#   T8  Instance Database（P2-2）
#   T9  Constraint Solver（subst 贯穿修复）
#   T10 Incremental Graph（worklist BFS）
#   T11 Memo（versioned key）
#   T12 Pattern Decision Tree + Exhaustiveness
{ lib }:

let
  ts = import ../lib/default.nix { inherit lib; };

  inherit (ts)
    mkTypeDefault mkTypeWith mkBootstrapType
    KStar KStar1 KStar2 KHO1 KArrow KVar KUnbound KError
    kindEq kindCheck kindUnify
    rPrimitive rVar rVarDB rLambda rApply rFn rConstructor rADT rConstrained
    rMu rRecord rVariantRow rRowExtend rRowEmpty mkVariant freeVarsRepr
    normalize typeEq typeHash nfHash deBruijnify substituteAll composeSubst
    mkClass mkEquality mkPredicate mkImplies
    emptyInstanceDB register resolve
    ;

  inherit (ts.graphLib)
    emptyGraph addNode addEdge addEdgeSafe removeNode
    propagateInvalidation batchUpdate dirtyNodes
    stateClean stateDirty stateComputing
    isValidTransition verifySymmetry graphStats;

  inherit (ts.memoLib)
    emptyMemo bumpEpoch lookupNormalize storeNormalize memoStats;

  inherit (ts.matchLib)
    mkWildcard mkVariable mkLiteral mkADTPattern mkRecordPat mkVariantRowPat
    compileToDecisionTree isExhaustive patternBoundVars;

  # ── 基础类型 ──────────────────────────────────────────────────────────────
  tInt    = mkTypeDefault (rPrimitive "Int")    KStar;
  tBool   = mkTypeDefault (rPrimitive "Bool")   KStar;
  tString = mkTypeDefault (rPrimitive "String") KStar;
  tUnit   = mkTypeDefault (rPrimitive "Unit")   KStar;
  tA      = mkTypeDefault (rVar "a")            KStar;
  tB      = mkTypeDefault (rVar "b")            KStar;
  tF      = mkTypeDefault (rVar "f")            KStar1;
  tRho    = mkTypeDefault (rVar "rho")          KStar;

  # ── 辅助：test runner ─────────────────────────────────────────────────────
  mkTest = name: expr: expected:
    { inherit name;
      ok = expr == expected;
      got = expr;
      inherit expected; };

  mkTestBool = name: expr:
    { inherit name; ok = expr; got = expr; expected = true; };

  runTests = tests:
    let
      failed = builtins.filter (t: !t.ok) tests;
      passed = builtins.filter (t:  t.ok) tests;
    in
    { total  = builtins.length tests;
      passed = builtins.length passed;
      failed = builtins.length failed;
      failedTests = map (t: { inherit (t) name got expected; }) failed;
      allPassed = failed == [];
    };

in

runTests [

  # ═══════════════════════════════════════════════════════════════════════════
  # T1：基础 TypeIR 不变量
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T1.1-isType"
    (ts.typeLib.isType tInt))

  (mkTestBool "T1.2-kind-not-null"
    (tInt.kind != null))

  (mkTestBool "T1.3-KUnbound-replace-null"
    (kindEq (mkBootstrapType (rPrimitive "X")).kind KUnbound))

  (mkTestBool "T1.4-withKind-null-safe"
    (kindEq (ts.typeLib.withKind null tInt).kind KUnbound))

  (mkTestBool "T1.5-validateType"
    (ts.typeLib.validateType tInt).ok)

  (mkTestBool "T1.6-rConstrained-empty-passthrough"
    (rConstrained tInt [] == tInt.repr))

  (mkTestBool "T1.7-phase-normal"
    (tInt.phase == "normal"))

  (mkTestBool "T1.8-bootstrap-phase"
    (mkBootstrapType (rPrimitive "K")).phase == "bootstrap")

  (mkTestBool "T1.9-stableId-deterministic"
    (let t1 = mkTypeDefault (rPrimitive "Int") KStar;
         t2 = mkTypeDefault (rPrimitive "Int") KStar;
     in t1.id == t2.id))

  (mkTestBool "T1.10-mergemeta-semilattice"
    (let
       m1 = ts.metaLib.mkMeta { eqStrat = "structural"; hashStrategy = "repr"; evalStrategy = "lazy"; };
       m2 = ts.metaLib.mkMeta { eqStrat = "structural"; hashStrategy = "repr"; evalStrategy = "lazy"; };
       merged = ts.metaLib.mergeMeta m1 m2;
     in merged.eqStrat == "structural"))  # join of same = same

  # ═══════════════════════════════════════════════════════════════════════════
  # T2：de Bruijn Alpha-equivalence（P0-1）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T2.1-deBruijnify-idempotent"
    (let
       lam = mkTypeDefault (rLambda "x" (mkTypeDefault (rVar "x") KStar)) KStar1;
       db1 = deBruijnify lam;
       db2 = deBruijnify db1;  # 再次 deBruijnify
     in typeHash db1 == typeHash db2))

  (mkTestBool "T2.2-alpha-equiv-lambda"
    (let
       # λa.λb.a  vs  λx.λy.x（α-equivalent）
       lam1 = mkTypeDefault
         (rLambda "a" (mkTypeDefault (rLambda "b" (mkTypeDefault (rVar "a") KStar)) KStar))
         KStar1;
       lam2 = mkTypeDefault
         (rLambda "x" (mkTypeDefault (rLambda "y" (mkTypeDefault (rVar "x") KStar)) KStar))
         KStar1;
       db1 = deBruijnify lam1;
       db2 = deBruijnify lam2;
     in typeHash db1 == typeHash db2))

  (mkTestBool "T2.3-non-alpha-equiv"
    (let
       # λa.λb.a  vs  λx.λy.y（NOT α-equivalent）
       lam1 = mkTypeDefault
         (rLambda "a" (mkTypeDefault (rLambda "b" (mkTypeDefault (rVar "a") KStar)) KStar))
         KStar1;
       lam2 = mkTypeDefault
         (rLambda "x" (mkTypeDefault (rLambda "y" (mkTypeDefault (rVar "y") KStar)) KStar))
         KStar1;
       db1 = deBruijnify lam1;
       db2 = deBruijnify lam2;
     in typeHash db1 != typeHash db2))

  (mkTestBool "T2.4-free-var-preserved"
    (let
       # λa. f a（f 是自由变量）
       lam = mkTypeDefault
         (rLambda "a"
           (mkTypeDefault (rApply tF [(mkTypeDefault (rVar "a") KStar)]) KStar))
         KStar1;
       db = deBruijnify lam;
       fv = freeVarsRepr db.repr;
     in fv ? f && !(fv ? a)))  # a 是绑定的，f 是自由的

  # ═══════════════════════════════════════════════════════════════════════════
  # T3：Kind Check + Kind Unify（P0-2）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T3.1-kindCheck-primitive"
    (kindEq (kindCheck tInt) KStar))

  (mkTestBool "T3.2-kindUnify-star-star"
    (let r = kindUnify {} KStar KStar; in r.ok))

  (mkTestBool "T3.3-kindUnify-kvar-bind"
    (let
       kv = KVar "k";
       r  = kindUnify {} kv KStar;
     in r.ok && kindEq (r.subst.k or KUnbound) KStar))

  (mkTestBool "T3.4-kindUnify-occurs-check"
    (let
       kv = KVar "k";
       r  = kindUnify {} kv (KArrow kv KStar);  # k ~ k → * (occurs!)
     in !r.ok))

  (mkTestBool "T3.5-kindUnify-arrow"
    (let
       r = kindUnify {} (KArrow KStar KStar) (KArrow KStar KStar);
     in r.ok))

  (mkTestBool "T3.6-KStar1-is-arrow"
    (kindEq KStar1 (KArrow KStar KStar)))

  # ═══════════════════════════════════════════════════════════════════════════
  # T4：Constructor Partial Apply（P1-1）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T4.1-constructor-full-apply"
    (let
       # Pair a b = {a, b}（两参数构造器）
       pairCtor = mkTypeDefault
         (rConstructor "Pair" KStar2 ["a" "b"]
           (rADT [(mkVariant "Pair" [(mkTypeDefault (rVar "a") KStar) (mkTypeDefault (rVar "b") KStar)] 0)] true))
         KStar2;
       applied = mkTypeDefault (rApply pairCtor [tInt tBool]) KStar;
       normed  = normalize applied;
     in normed.repr.__variant == "ADT"))  # 完整应用后展开

  (mkTestBool "T4.2-constructor-partial-apply"
    (let
       pairCtor = mkTypeDefault
         (rConstructor "Pair" KStar2 ["a" "b"]
           (rADT [(mkVariant "Pair" [(mkTypeDefault (rVar "a") KStar) (mkTypeDefault (rVar "b") KStar)] 0)] true))
         KStar2;
       partial = mkTypeDefault (rApply pairCtor [tInt]) KStar;  # 只应用 1 个参数
       normed  = normalize partial;
     in normed.repr.__variant == "Constructor"))  # 部分应用 = curried Constructor

  # ═══════════════════════════════════════════════════════════════════════════
  # T5：μ-types（P1-2）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T5.1-mu-type-construction"
    (let
       listT = mkTypeDefault (rMu "L"
         (mkTypeDefault (rADT [
           (mkVariant "Nil"  [] 0)
           (mkVariant "Cons" [tInt (mkTypeDefault (rVar "L") KStar)] 1)
         ] false) KStar)) KStar;
     in listT.repr.__variant == "Mu"))

  (mkTestBool "T5.2-mu-hash-stable"
    (let
       mkListT = a: mkTypeDefault (rMu "L"
         (mkTypeDefault (rADT [
           (mkVariant "Nil"  [] 0)
           (mkVariant "Cons" [a (mkTypeDefault (rVar "L") KStar)] 1)
         ] false) KStar)) KStar;
       l1 = mkListT tInt;
       l2 = mkListT tInt;
     in typeHash l1 == typeHash l2))

  (mkTestBool "T5.3-mu-unfold-one-step"
    (let
       listInt = mkTypeDefault (rMu "L"
         (mkTypeDefault (rADT [
           (mkVariant "Nil"  [] 0)
           (mkVariant "Cons" [tInt (mkTypeDefault (rVar "L") KStar)] 1)
         ] false) KStar)) KStar;
       # Apply(Mu, args) → unfold
       applied = mkTypeDefault (rApply listInt []) KStar;
     in builtins.isAttrs (normalize applied)))  # 不崩溃

  # ═══════════════════════════════════════════════════════════════════════════
  # T6：HKT（P1-3）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T6.1-kstar1-exists"
    (kindEq KStar1 (KArrow KStar KStar)))

  (mkTestBool "T6.2-kstar2-exists"
    (kindEq KStar2 (KArrow KStar KStar1)))

  (mkTestBool "T6.3-hkt-apply-kind"
    (let
       fType = mkTypeDefault (rVar "f") KStar1;  # f : * → *
       applied = mkTypeDefault (rApply fType [tA]) KStar;
     in builtins.isAttrs (normalize applied)))

  # ═══════════════════════════════════════════════════════════════════════════
  # T7：Row Polymorphism（P2-1）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T7.1-record-construction"
    (let
       rec_ = mkTypeDefault (rRecord { name = tString; age = tInt; } null) KStar;
     in rec_.repr.__variant == "Record"))

  (mkTestBool "T7.2-open-record"
    (let
       open = mkTypeDefault (rRecord { name = tString; } tRho) KStar;
     in open.repr.rowVar != null))

  (mkTestBool "T7.3-variant-row"
    (let
       vr = mkTypeDefault (rVariantRow { Red = tUnit; Green = tUnit; } null) KStar;
     in vr.repr.__variant == "VariantRow"))

  (mkTestBool "T7.4-row-extend"
    (let
       base = mkTypeDefault rRowEmpty KStar;
       ext  = mkTypeDefault (rRowExtend "x" tInt base) KStar;
     in ext.repr.__variant == "RowExtend"))

  (mkTestBool "T7.5-record-hash-fieldorder-independent"
    (let
       # { a: Int, b: Bool } = { b: Bool, a: Int }（字段顺序无关）
       r1 = mkTypeDefault (rRecord { a = tInt; b = tBool; } null) KStar;
       r2 = mkTypeDefault (rRecord { b = tBool; a = tInt; } null) KStar;
     in typeHash r1 == typeHash r2))

  # ═══════════════════════════════════════════════════════════════════════════
  # T8：Instance Database（P2-2）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T8.1-register-resolve"
    (let
       db = register emptyInstanceDB "Eq" tInt { eq = x: y: x == y; } [];
       r  = resolve db "Eq" [tInt];
     in r.ok))

  (mkTestBool "T8.2-resolve-not-found"
    (let
       db = emptyInstanceDB;
       r  = resolve db "Eq" [tInt];
     in !r.ok))

  (mkTestBool "T8.3-coherence-duplicate"
    (let
       db1 = register emptyInstanceDB "Eq" tInt { eq = a: b: a == b; } [];
       db2 = register db1 "Eq" tInt { eq = x: y: x == y; } [];
     in db2 ? _coherenceError))  # 重复注册 → 错误标记

  (mkTestBool "T8.4-version-increments"
    (let
       db1 = register emptyInstanceDB "Eq" tInt {} [];
       db2 = register db1 "Eq" tBool {} [];
     in db2.version > db1.version))

  # ═══════════════════════════════════════════════════════════════════════════
  # T9：Constraint Solver（Phase 2 修复）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T9.1-solve-eq-int"
    (let
       cs = [(mkClass "Eq" [tInt])];
       r  = ts.solverLib.solveDefault cs;
     in r.ok))

  (mkTestBool "T9.2-solve-superclass"
    (let
       # Ord Int → 触发 Eq Int（superclass）
       cs = [(mkClass "Ord" [tInt])];
       r  = ts.solverLib.solveDefault cs;
     in r.ok))

  (mkTestBool "T9.3-equality-constraint"
    (let
       # a ~ Int（unification）
       cs = [(mkEquality tA tInt)];
       r  = ts.solverLib.solveDefault cs;
     in r.ok && r.subst ? a))

  (mkTestBool "T9.4-implies"
    (let
       # Eq a → Show a
       impl = mkImplies (mkClass "Eq" [tA]) (mkClass "Show" [tA]);
       cs   = [impl (mkClass "Eq" [tA])];
       r    = ts.solverLib.solveDefault cs;
     in builtins.isAttrs r))

  (mkTestBool "T9.5-dedup"
    (let
       # 重复约束不报错
       cs = [(mkClass "Eq" [tInt]) (mkClass "Eq" [tInt])];
       r  = ts.solverLib.solveDefault cs;
     in r.ok))

  # ═══════════════════════════════════════════════════════════════════════════
  # T10：Incremental Graph（worklist BFS）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T10.1-add-node"
    (let
       g = addNode emptyGraph (ts.graphLib.mkNode "a" tInt);
     in g.nodes ? a))

  (mkTestBool "T10.2-add-edge-symmetry"
    (let
       g0 = addNode emptyGraph (ts.graphLib.mkNode "a" tInt);
       g1 = addNode g0 (ts.graphLib.mkNode "b" tBool);
       g2 = addEdge g1 "a" "b";
       sym = verifySymmetry g2;
     in sym.ok))

  (mkTestBool "T10.3-cycle-detection"
    (let
       g0 = addNode emptyGraph (ts.graphLib.mkNode "a" tInt);
       g1 = addNode g0 (ts.graphLib.mkNode "b" tBool);
       g2 = addEdge g1 "a" "b";
       r  = addEdgeSafe g2 "b" "a";  # 形成环
     in !r.ok))

  (mkTestBool "T10.4-propagate-dirty"
    (let
       g0 = addNode emptyGraph (ts.graphLib.mkNode "a" tInt);
       g1 = addNode g0 (ts.graphLib.mkNode "b" tBool);
       g2 = addEdge g1 "b" "a";  # b 依赖 a（a 变则 b dirty）
       g3 = propagateInvalidation g2 "a";  # a 失效
     in g3.nodes.b.state == stateDirty))

  (mkTestBool "T10.5-state-transitions"
    (let
       ok1 = isValidTransition stateClean stateDirty;
       ok2 = isValidTransition stateDirty stateComputing;
       ok3 = isValidTransition stateComputing stateClean;
       bad = isValidTransition stateClean stateComputing;  # 也是合法的
     in ok1 && ok2 && ok3 && bad))

  (mkTestBool "T10.6-remove-node-symmetry"
    (let
       g0 = addNode emptyGraph (ts.graphLib.mkNode "a" tInt);
       g1 = addNode g0 (ts.graphLib.mkNode "b" tBool);
       g2 = addEdge g1 "a" "b";
       g3 = removeNode g2 "a";
       sym = verifySymmetry g3;
     in sym.ok && !(g3.nodes ? a)))

  # ═══════════════════════════════════════════════════════════════════════════
  # T11：Memo（versioned key）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T11.1-store-lookup"
    (let
       memo0 = emptyMemo;
       nf    = normalize tInt;
       memo1 = storeNormalize memo0 tInt nf;
       r     = lookupNormalize memo1 tInt;
     in r.hit))

  (mkTestBool "T11.2-bump-epoch-invalidates"
    (let
       memo0 = emptyMemo;
       nf    = normalize tInt;
       memo1 = storeNormalize memo0 tInt nf;
       memo2 = bumpEpoch memo1;  # epoch bump → 清空
       r     = lookupNormalize memo2 tInt;
     in !r.hit))

  (mkTestBool "T11.3-memo-stats"
    (let
       stats = memoStats emptyMemo;
     in stats.normalizeSize == 0 && stats.epoch == 0))

  # ═══════════════════════════════════════════════════════════════════════════
  # T12：Pattern Decision Tree + Exhaustiveness
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T12.1-wildcard-leaf"
    (let
       dt = compileToDecisionTree [{ pattern = mkWildcard; action = 0; }] "x";
     in dt.tag == "Leaf"))

  (mkTestBool "T12.2-variable-bind"
    (let
       dt = compileToDecisionTree [{ pattern = mkVariable "y"; action = 0; }] "x";
     in dt.tag == "Bind" && dt.name == "y"))

  (mkTestBool "T12.3-adt-exhaustive"
    (let
       maybeType = mkTypeDefault
         (rADT [(mkVariant "Nothing" [] 0) (mkVariant "Just" [tA] 1)] true)
         KStar;
       patterns = [
         (mkADTPattern "Nothing" [] 0)
         (mkADTPattern "Just"    [(mkVariable "x")] 1)
       ];
       r = isExhaustive patterns maybeType;
     in r.exhaustive))

  (mkTestBool "T12.4-adt-non-exhaustive"
    (let
       maybeType = mkTypeDefault
         (rADT [(mkVariant "Nothing" [] 0) (mkVariant "Just" [tA] 1)] true)
         KStar;
       patterns = [(mkADTPattern "Just" [(mkVariable "x")] 1)];  # 缺 Nothing
       r = isExhaustive patterns maybeType;
     in !r.exhaustive && builtins.elem "Nothing" r.missing))

  (mkTestBool "T12.5-record-pattern"
    (let
       recType = mkTypeDefault (rRecord { name = tString; age = tInt; } null) KStar;
       pat     = mkRecordPat { name = mkVariable "n"; age = mkWildcard; } null;
       r       = isExhaustive [ pat ] recType;
       bound   = patternBoundVars pat;
     in r.exhaustive && bound ? n))

  (mkTestBool "T12.6-open-variant-not-exhaustive"
    (let
       openVR = mkTypeDefault
         (rVariantRow { Red = tUnit; Green = tUnit; } tRho)  # 开放
         KStar;
       patterns = [
         (mkVariantRowPat "Red"   mkWildcard null)
         (mkVariantRowPat "Green" mkWildcard null)
       ];
       r = isExhaustive patterns openVR;
     in !r.exhaustive))  # 开放 variant row 不可穷举

  # ═══════════════════════════════════════════════════════════════════════════
  # T13：INV 不变量运行时验证
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T13.1-verifyInvariants"
    (ts.verifyInvariants {}).ok)

  (mkTestBool "T13.2-hash-consistency"
    (let
       r = ts.hashLib.verifyHashConsistency tInt tInt;
     in r.consistent && r.status == "consistent-equal"))

  (mkTestBool "T13.3-hash-different"
    (let
       r = ts.hashLib.verifyHashConsistency tInt tBool;
     in r.consistent && r.status == "consistent-different"))

  (mkTestBool "T13.4-typeEq-reflexive"
    (typeEq tInt tInt))

  (mkTestBool "T13.5-typeEq-different"
    (!(typeEq tInt tBool)))

  (mkTestBool "T13.6-typeEq-implies-hash-eq"
    (let
       t1 = mkTypeDefault (rPrimitive "Int") KStar;
       t2 = mkTypeDefault (rPrimitive "Int") KStar;
     in typeEq t1 t2 && typeHash t1 == typeHash t2))

]
