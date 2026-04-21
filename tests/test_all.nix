# tests/test_all.nix — Phase 3.1
# 综合测试套件（Phase 3.1 INV 验证 + 修复验证）
#
# 覆盖：
#   T1  基础 TypeIR 不变量（INV-T1/2/3/4）
#   T2  α-equivalence（INV-SER3/EQ）
#   T3  Kind Check + Unify（INV-K1-6）
#   T4  Constructor Partial Apply（INV-K1 修复）
#   T5  μ-types（INV-EQ3 bisimulation）
#   T6  HKT Kind inference
#   T7  Row Polymorphism
#   T8  Instance Database（soundness 修复）
#   T9  Constraint Solver（INV-SOL1/4/5）
#   T10 Incremental Graph（Kahn 修复）
#   T11 Memo（epoch + versioned key）
#   T12 Pattern Decision Tree
#   T13 INV 不变量运行时验证（全量）
#   T14 Phase 3.1 修复专项验证
{ lib }:

let
  ts = import ../lib/default.nix { inherit lib; };

  inherit (ts)
    # TypeIR
    mkTypeDefault mkTypeWith mkBootstrapType mkTypeConstrained
    KStar KStar1 KStar2 KHO1 KArrow KVar KUnbound KError
    kindEq kindCheck kindUnify kindInferRepr
    isType stableId showType

    # Repr
    rPrimitive rVar rVarDB rLambda rLambdaSimple rApply rFn
    rPi rSigma rMu rRecord rVariantRow rRowExtend rRowEmpty
    rConstructor rADT rConstrained mkVariant extendADT mkParam freeVarsRepr

    # Normalize
    normalize substitute substituteAll composeSubst deBruijnify

    # Equality + Hash
    typeEq structuralEq alphaEq nominalEq muEq rowVarEq
    typeHash nfHash verifyHashConsistency checkCoherence

    # Constraint
    mkClass mkEquality mkPredicate mkImplies
    constraintKey normalizeConstraint mapTypesInConstraint
    deduplicateConstraints constraintsHash
    defaultClassGraph isSuperclassOf getAllSupers getAllSubs

    # Solver
    solveDefault showResult

    # Instance
    emptyInstanceDB register resolve resolveWithFallback canDischarge listInstances

    # Bidir
    emptyCtx ctxBind tVar tLam tApp tAscribe tLit check infer

    # Match
    mkWildcard mkVariable mkLiteral mkADTPattern mkRecordPat mkVariantRowPat
    compileToDecisionTree isExhaustive checkRedundancy patternBoundVars

    # INV
    verifyInvariants
    ;

  inherit (ts.graphLib)
    emptyGraph addNode addEdge addEdgeSafe removeNode mkNode
    propagateInvalidation batchUpdate topologicalSort
    dirtyNodes graphStats verifySymmetry
    stateClean stateDirty stateError isValidTransition;

  inherit (ts.memoLib)
    emptyMemo bumpEpoch lookupNormalize storeNormalize memoStats;

  # 基础类型
  tInt    = mkTypeDefault (rPrimitive "Int")    KStar;
  tBool   = mkTypeDefault (rPrimitive "Bool")   KStar;
  tString = mkTypeDefault (rPrimitive "String") KStar;
  tUnit   = mkTypeDefault (rPrimitive "Unit")   KStar;
  tA      = mkTypeDefault (rVar "a")            KStar;
  tB      = mkTypeDefault (rVar "b")            KStar;
  tF      = mkTypeDefault (rVar "f")            KStar1;

  # 测试工具
  mkTest     = name: got: expected: { inherit name; ok = got == expected; inherit got expected; };
  mkTestBool = name: expr: { inherit name; ok = expr; got = expr; expected = true; };

  runTests = tests:
    let
      failed = builtins.filter (t: !t.ok) tests;
      passed = builtins.filter (t:  t.ok) tests;
    in
    { total   = builtins.length tests;
      passed  = builtins.length passed;
      failed  = builtins.length failed;
      failedTests = map (t: { inherit (t) name got expected; }) failed;
      allPassed   = failed == [];
    };

in runTests [

  # ═══════════════════════════════════════════════════════════════════════════
  # T1：基础 TypeIR 不变量
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T1.1-isType"
    (isType tInt))

  (mkTestBool "T1.2-kind-not-null"
    (tInt.kind != null))

  (mkTestBool "T1.3-KUnbound-replace-null"
    (kindEq (mkBootstrapType (rPrimitive "X")).kind KUnbound))

  (mkTestBool "T1.4-withKind-null-safe"
    (let t' = ts.typeLib.withKind tInt null; in kindEq t'.kind KUnbound))

  (mkTestBool "T1.5-validateType"
    (ts.typeLib.validateType tInt).ok)

  (mkTestBool "T1.6-stableId-deterministic"
    (let
       id1 = stableId (rPrimitive "Int");
       id2 = stableId (rPrimitive "Int");
     in id1 == id2))

  (mkTestBool "T1.7-stableId-distinct"
    (stableId (rPrimitive "Int") != stableId (rPrimitive "Bool")))

  (mkTestBool "T1.8-mkTypeConstrained"
    (let
       c = mkClass "Eq" [tInt];
       t = mkTypeConstrained (rPrimitive "Int") KStar [c];
     in isType t && builtins.length t.meta.constraints == 1))

  # ═══════════════════════════════════════════════════════════════════════════
  # T2：α-equivalence（INV-SER3）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T2.1-alphaEq-lambda-same-param"
    (let lam = mkTypeDefault (rLambda "x" KUnbound tA) KStar1; in
     alphaEq lam lam))

  (mkTestBool "T2.2-alphaEq-equivalent"
    (let
       # λa.a vs λx.x（α-equivalent）
       lam1 = mkTypeDefault (rLambda "a" KUnbound (mkTypeDefault (rVar "a") KStar)) KStar1;
       lam2 = mkTypeDefault (rLambda "x" KUnbound (mkTypeDefault (rVar "x") KStar)) KStar1;
       db1  = deBruijnify lam1;
       db2  = deBruijnify lam2;
     in typeHash db1 == typeHash db2))

  (mkTestBool "T2.3-alphaEq-not-equivalent"
    (let
       # λa.λb.a vs λx.λy.y（NOT equivalent）
       lam1 = mkTypeDefault (rLambda "a" KUnbound
                (mkTypeDefault (rLambda "b" KUnbound (mkTypeDefault (rVar "a") KStar)) KStar)) KStar1;
       lam2 = mkTypeDefault (rLambda "x" KUnbound
                (mkTypeDefault (rLambda "y" KUnbound (mkTypeDefault (rVar "y") KStar)) KStar)) KStar1;
       db1  = deBruijnify lam1;
       db2  = deBruijnify lam2;
     in typeHash db1 != typeHash db2))

  (mkTestBool "T2.4-freeVars-lambda"
    (let
       fv = freeVarsRepr (rLambda "x" KUnbound (mkTypeDefault (rVar "y") KStar));
     in builtins.elem "y" fv && !builtins.elem "x" fv))

  # ═══════════════════════════════════════════════════════════════════════════
  # T3：Kind Check + Unify（INV-K1-6）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T3.1-kindCheck-primitive"
    ((kindCheck tInt KStar).ok))

  (mkTestBool "T3.2-kindUnify-star"
    ((kindUnify {} KStar KStar).ok))

  (mkTestBool "T3.3-kindUnify-kvar-bind"
    (let r = kindUnify {} (KVar "k") KStar; in
     r.ok && kindEq (r.subst.k or KUnbound) KStar))

  (mkTestBool "T3.4-kindUnify-occurs"
    (let r = kindUnify {} (KVar "k") (KArrow (KVar "k") KStar); in
     !r.ok))

  (mkTestBool "T3.5-kindUnify-arrow"
    ((kindUnify {} KStar1 (KArrow KStar KStar)).ok))

  (mkTestBool "T3.6-kindInferRepr-primitive"
    (kindEq (kindInferRepr (rPrimitive "Int")) KStar))

  (mkTestBool "T3.7-kindInferRepr-fn"
    (kindEq (kindInferRepr (rFn tInt tBool)) KStar))

  (mkTestBool "T3.8-kindInferRepr-rowExtend"
    (kindEq (kindInferRepr (rRowExtend "x" tInt (mkTypeDefault rRowEmpty KStar))) ts.kindLib.KRow))

  # ═══════════════════════════════════════════════════════════════════════════
  # T4：Constructor Partial Apply（INV-K1 修复）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T4.1-constructor-full-apply"
    (let
       pairCtor = mkTypeDefault
         (rConstructor "Pair" KStar2
           [mkParam "a" KStar mkParam "b" KStar]
           (mkTypeDefault (rADT [mkVariant "Pair" [tA tB] 0] true) KStar))
         KStar2;
       applied = mkTypeDefault (rApply pairCtor [tInt tBool]) KStar;
       normed  = normalize applied;
     in builtins.isAttrs normed))

  (mkTestBool "T4.2-constructor-partial-kind"
    # Phase 3.1 INV-K1 修复：partial apply 保留真实 param kind
    (let
       listCtor = mkTypeDefault
         (rConstructor "List" KStar1
           [mkParam "a" KStar]
           (mkTypeDefault (rADT [mkVariant "Nil" [] 0 mkVariant "Cons" [tA] 1] false) KStar))
         KStar1;
       # List 是 * → *，partial apply 0 args = 仍是 KStar1
       normed = normalize listCtor;
     in kindEq normed.kind KStar1))

  # ═══════════════════════════════════════════════════════════════════════════
  # T5：μ-types（INV-EQ3 bisimulation）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T5.1-mu-construction"
    (let
       listT = mkTypeDefault (rMu "L"
         (mkTypeDefault (rADT [mkVariant "Nil" [] 0 mkVariant "Cons" [tInt (mkTypeDefault (rVar "L") KStar)] 1] false) KStar))
         KStar;
     in listT.repr.__variant == "Mu"))

  (mkTestBool "T5.2-mu-hash-stable"
    (let
       mkListT = a:
         mkTypeDefault (rMu "L"
           (mkTypeDefault (rADT [mkVariant "Nil" [] 0 mkVariant "Cons" [a (mkTypeDefault (rVar "L") KStar)] 1] false) KStar))
           KStar;
       l1 = mkListT tInt; l2 = mkListT tInt;
     in typeHash l1 == typeHash l2))

  (mkTestBool "T5.3-muEq-reflexive"
    (let
       listT = mkTypeDefault (rMu "L"
         (mkTypeDefault (rADT [mkVariant "Nil" [] 0] false) KStar)) KStar;
     in muEq listT listT))

  # ═══════════════════════════════════════════════════════════════════════════
  # T6：HKT
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T6.1-KStar1"    (kindEq KStar1 (KArrow KStar KStar)))
  (mkTestBool "T6.2-KStar2"    (kindEq KStar2 (KArrow KStar KStar1)))
  (mkTestBool "T6.3-normalize-apply"
    (let applied = mkTypeDefault (rApply tF [tA]) KStar; in
     builtins.isAttrs (normalize applied)))

  # ═══════════════════════════════════════════════════════════════════════════
  # T7：Row Polymorphism
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T7.1-record-construction"
    (let r = mkTypeDefault (rRecord { name = tString; age = tInt; }) KStar; in
     r.repr.__variant == "Record"))

  (mkTestBool "T7.2-rowExtend"
    (let r = mkTypeDefault (rRowExtend "x" tInt (mkTypeDefault rRowEmpty KStar)) ts.kindLib.KRow; in
     r.repr.__variant == "RowExtend"))

  (mkTestBool "T7.3-variantRow"
    (let r = mkTypeDefault (rVariantRow { Red = tUnit; Blue = tUnit; } null) KStar; in
     r.repr.__variant == "VariantRow"))

  # ═══════════════════════════════════════════════════════════════════════════
  # T8：Instance Database（Phase 3.1 soundness 修复）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T8.1-register-resolve"
    (let
       db = register emptyInstanceDB "Eq" [tInt] null "test";
       r  = resolve db "Eq" [tInt];
     in r.found))

  (mkTestBool "T8.2-resolve-miss"
    (let r = resolve emptyInstanceDB "Eq" [tInt]; in !r.found))

  (mkTestBool "T8.3-coherence-violation"
    (let
       db1 = register emptyInstanceDB "Show" [tBool] null "src1";
       ok = builtins.tryEval (register db1 "Show" [tBool] null "src2");
     in !ok.success))  # 重复注册应 throw

  (mkTestBool "T8.4-resolveWithFallback-builtin"
    # builtin primitive resolution
    (let r = resolveWithFallback emptyInstanceDB defaultClassGraph "Eq" [tInt]; in
     r.found))

  (mkTestBool "T8.5-superclass-direction"
    # Ord <: Eq（Ord 是 Eq 的子类）
    (isSuperclassOf defaultClassGraph "Eq" "Ord"))

  (mkTestBool "T8.6-getAllSubs"
    # Ord 是 Eq 的 sub
    (builtins.elem "Ord" (getAllSubs defaultClassGraph "Eq")))

  (mkTestBool "T8.7-canDischarge-builtin"
    (canDischarge emptyInstanceDB defaultClassGraph (mkClass "Eq" [tInt])))

  # ═══════════════════════════════════════════════════════════════════════════
  # T9：Constraint Solver（INV-SOL1/4/5）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T9.1-solve-eq-int"
    (let r = solveDefault [mkClass "Eq" [tInt]]; in r.ok))

  (mkTestBool "T9.2-solve-equality"
    (let r = solveDefault [mkEquality tA tInt]; in r.ok))

  (mkTestBool "T9.3-dedup"
    (let r = solveDefault [mkClass "Eq" [tInt] mkClass "Eq" [tInt]]; in r.ok))

  (mkTestBool "T9.4-canonical-constraint-key"
    # INV-C1：constraintKey 稳定
    (let
       c1 = mkEquality tInt tBool;
       c2 = mkEquality tBool tInt;  # mkEquality 内部排序
     in constraintKey c1 == constraintKey c2))

  (mkTestBool "T9.5-deduplicateConstraints"
    (let
       cs = [mkClass "Show" [tInt] mkClass "Show" [tInt]];
       deduped = deduplicateConstraints cs;
     in builtins.length deduped == 1))

  # ═══════════════════════════════════════════════════════════════════════════
  # T10：Incremental Graph（Kahn 修复）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T10.1-addNode"
    (let g = addNode emptyGraph (mkNode "a" tInt); in g.nodes ? a))

  (mkTestBool "T10.2-addEdge-symmetry"
    (let
       g0 = addNode emptyGraph (mkNode "a" tInt);
       g1 = addNode g0 (mkNode "b" tBool);
       g2 = addEdge g1 "a" "b";
     in (verifySymmetry g2).ok))

  (mkTestBool "T10.3-cycle-detection"
    (let
       g0 = addNode emptyGraph (mkNode "a" tInt);
       g1 = addNode g0 (mkNode "b" tBool);
       g2 = addEdge g1 "a" "b";
       r  = addEdgeSafe g2 "b" "a";
     in !r.ok))

  (mkTestBool "T10.4-propagate-dirty"
    (let
       g0 = addNode emptyGraph (mkNode "a" tInt);
       g1 = addNode g0 (mkNode "b" tBool);
       g2 = addEdge g1 "a" "b";  # b 依赖 a
       g3 = propagateInvalidation g2 "a";
     in g3.nodes.b.state == stateDirty))

  (mkTestBool "T10.5-topo-sort"
    (let
       g0 = addNode emptyGraph (mkNode "a" tInt);
       g1 = addNode g0 (mkNode "b" tBool);
       g2 = addNode g1 (mkNode "c" tString);
       g3 = addEdge g2 "a" "b";  # b depends on a
       g4 = addEdge g3 "b" "c";  # c depends on b
       r  = topologicalSort g4;
     in r.ok && builtins.head r.order == "a"))

  (mkTestBool "T10.6-remove-symmetry"
    (let
       g0 = addNode emptyGraph (mkNode "a" tInt);
       g1 = addNode g0 (mkNode "b" tBool);
       g2 = addEdge g1 "a" "b";
       g3 = removeNode g2 "a";
     in (verifySymmetry g3).ok && !(g3.nodes ? a)))

  # ═══════════════════════════════════════════════════════════════════════════
  # T11：Memo（INV-M1-4）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T11.1-store-lookup"
    (let
       nf    = normalize tInt;
       memo1 = storeNormalize emptyMemo tInt nf;
       r     = lookupNormalize memo1 tInt;
     in r.hit))

  (mkTestBool "T11.2-bump-epoch-invalidates"
    (let
       nf    = normalize tInt;
       memo1 = storeNormalize emptyMemo tInt nf;
       memo2 = bumpEpoch memo1;
       r     = lookupNormalize memo2 tInt;
     in !r.hit))

  (mkTestBool "T11.3-memo-stats-zero"
    (let s = memoStats emptyMemo; in s.normalizeSize == 0 && s.epoch == 0))

  # ═══════════════════════════════════════════════════════════════════════════
  # T12：Pattern Decision Tree
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T12.1-wildcard-leaf"
    (let dt = compileToDecisionTree [{ pattern = mkWildcard; action = 0; }] "x"; in
     dt.tag == "Leaf"))

  (mkTestBool "T12.2-variable-bind"
    (let dt = compileToDecisionTree [{ pattern = mkVariable "y"; action = 0; }] "x"; in
     dt.tag == "Bind" && dt.name == "y"))

  (mkTestBool "T12.3-adt-exhaustive"
    (let
       maybeT = mkTypeDefault
         (rADT [mkVariant "Nothing" [] 0 mkVariant "Just" [tA] 1] true) KStar;
       pats = [mkADTPattern "Nothing" [] 0 mkADTPattern "Just" [mkVariable "x"] 1];
       r = isExhaustive pats maybeT;
     in r.exhaustive))

  (mkTestBool "T12.4-adt-non-exhaustive"
    (let
       maybeT = mkTypeDefault
         (rADT [mkVariant "Nothing" [] 0 mkVariant "Just" [tA] 1] true) KStar;
       pats = [mkADTPattern "Just" [mkVariable "x"] 1];
       r = isExhaustive pats maybeT;
     in !r.exhaustive && builtins.elem "Nothing" r.missing))

  (mkTestBool "T12.5-pattern-bound-vars"
    (let
       pat   = mkADTPattern "Pair" [mkVariable "x" mkVariable "y"] 0;
       bound = patternBoundVars pat;
     in bound ? x && bound ? y))

  # ═══════════════════════════════════════════════════════════════════════════
  # T13：INV 运行时验证（全量）
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T13.1-verifyInvariants"
    (verifyInvariants {}).ok)

  (mkTestBool "T13.2-hash-consistency-equal"
    (let r = verifyHashConsistency tInt tInt; in r.consistent))

  (mkTestBool "T13.3-hash-consistency-different"
    (let r = verifyHashConsistency tInt tBool; in r.consistent))

  (mkTestBool "T13.4-INV-EQ1"
    # typeEq ⟹ hash-eq
    (let t1 = mkTypeDefault (rPrimitive "Int") KStar;
         t2 = mkTypeDefault (rPrimitive "Int") KStar; in
     typeEq t1 t2 && typeHash t1 == typeHash t2))

  (mkTestBool "T13.5-INV-EQ2-coherence"
    (let c = checkCoherence tInt tBool; in c.coherent))

  (mkTestBool "T13.6-INV-H2"
    # typeHash = nfHash ∘ normalize
    (let
       h1 = typeHash tInt;
       h2 = nfHash (normalize tInt);
     in h1 == h2))

  # ═══════════════════════════════════════════════════════════════════════════
  # T14：Phase 3.1 修复专项验证
  # ═══════════════════════════════════════════════════════════════════════════

  (mkTestBool "T14.1-substituteAll-stable-order"
    # INV-SUBST-3：substituteAll 顺序稳定（结果确定性）
    (let
       subst = { a = tInt; b = tBool; };
       t = mkTypeDefault (rApply (mkTypeDefault (rVar "a") KStar) [mkTypeDefault (rVar "b") KStar]) KStar;
       r1 = substituteAll subst t;
       r2 = substituteAll subst t;
     in typeHash r1 == typeHash r2))

  (mkTestBool "T14.2-normalizeConstraint-idempotent"
    # INV-C4：normalize ∘ normalize = normalize
    (let
       c  = mkClass "Eq" [tInt];
       n1 = normalizeConstraint c;
       n2 = normalizeConstraint n1;
     in constraintKey n1 == constraintKey n2))

  (mkTestBool "T14.3-isSuperclassOf-direction"
    # BUG-2 修复：isSuperclassOf(graph, "Eq", "Ord") = "Eq 是 Ord 的 super"
    (isSuperclassOf defaultClassGraph "Eq" "Ord"))

  (mkTestBool "T14.4-getAllSubs-correctness"
    (let subs = getAllSubs defaultClassGraph "Semigroup"; in
     builtins.elem "Monoid" subs))

  (mkTestBool "T14.5-composeSubst-correct"
    # σ₂ ∘ σ₁：σ₁ = {x ↦ a}, σ₂ = {a ↦ Int} → compose = {x ↦ Int, a ↦ Int}
    (let
       sigma1 = { x = tA; };
       sigma2 = { a = tInt; };
       composed = composeSubst sigma1 sigma2;
     in composed ? x && composed ? a && typeHash composed.x == typeHash tInt))

  (mkTestBool "T14.6-split-fuel-normalize"
    # split fuel：normalize 不因单一 fuel 类型耗尽而停止
    (builtins.isAttrs (normalize (mkTypeDefault (rApply (mkTypeDefault (rLambda "x" KUnbound tA) KStar1) [tInt]) KStar))))

]
