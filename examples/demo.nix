# examples/demo.nix — Phase 4.2
# 综合示例（6 个端到端场景）
{ lib ? (import <nixpkgs> {}).lib }:

let ts = import ../lib/default.nix { inherit lib; }; in

{
  # ══ 场景 1: ADT + Pattern Matching ═══════════════════════════════════
  scenario1_adt = rec {
    # Maybe Int
    maybeVariants = [
      (ts.mkVariant "Nothing" [] 0)
      (ts.mkVariant "Just" [ts.tInt] 1)
    ];
    tMaybeInt = ts.mkTypeDefault (ts.rADT maybeVariants true) ts.KStar;

    # Pattern: match maybe { Nothing → 0; Just x → x }
    arms = [
      (ts.mkArm (ts.mkPCtor "Nothing" []) ts.tInt)
      (ts.mkArm (ts.mkPCtor "Just" [ts.mkPVar "x"]) ts.tInt)
    ];
    decisionTree    = ts.compileMatch arms maybeVariants;
    exhaustiveCheck = ts.checkExhaustive arms maybeVariants;
  };

  # ══ 场景 2: Constraint Solver ════════════════════════════════════════
  scenario2_solver = rec {
    alpha = ts.mkTypeDefault (ts.rVar "α" "") ts.KStar;
    beta  = ts.mkTypeDefault (ts.rVar "β" "") ts.KStar;
    constraints = [
      (ts.mkEqConstraint alpha ts.tInt)   # α ≡ Int
      (ts.mkEqConstraint beta ts.tBool)   # β ≡ Bool
      (ts.mkClassConstraint "Eq" [alpha]) # Eq α
    ];
    result    = ts.solveSimple constraints;
    typeSubst = ts.getTypeSubst result;
  };

  # ══ 场景 3: Module Functor Composition（Phase 4.2）══════════════════
  scenario3_modules = rec {
    # Sig: { compare: Int → Int → Bool }
    ordSig = ts.mkSig { compare = ts.mkTypeDefault (ts.rFn ts.tInt (ts.mkTypeDefault (ts.rFn ts.tInt ts.tBool) ts.KStar)) ts.KStar; };

    # Functor 1: takes an Ord module, returns a sorted list type
    sortFunctor = ts.mkModFunctor "Ord" ordSig ts.tInt;

    # Functor 2: takes an Ord module, returns a set type
    setFunctor  = ts.mkModFunctor "Ord" ordSig ts.tBool;

    # INV-MOD-8: compose → λM.sortFunctor(setFunctor(M))
    composed = ts.composeFunctors sortFunctor setFunctor;

    # Verify composition is well-formed
    composedOk = ts.isModFunctor composed;

    # Chain of 2 functors
    chain = ts.composeFunctorChain [sortFunctor setFunctor];
    chainOk = ts.isModFunctor chain;
  };

  # ══ 场景 4: Refined Types + SMT Oracle ═══════════════════════════════
  scenario4_refined = rec {
    # { n: Int | n > 0 }
    posInt = ts.tPositiveInt;

    # { n: Int | n >= 0 }
    nonNeg = ts.tNonNegInt;

    # Static evaluation: { n | n > 0 } ⊆ { n | n >= 0 }?
    # (Static oracle stub; real check needs external SMT)
    smtQuery = ts.defaultSmtOracle "n" (ts.mkPCmp ">" (ts.mkPVar "n") (ts.mkPLit 0));

    # 精化类型规范化：{ n: Int | ⊤ } → Int
    trivialRef  = ts.mkRefined ts.tInt "n" ts.mkPTrue;
    normalized  = ts.normalize' trivialRef;
    isNormalized = (normalized.repr.__variant or null) == "Primitive";
  };

  # ══ 场景 5: Effect Handlers（deep/shallow）════════════════════════════
  scenario5_effects = rec {
    # Effect row: { State: Int, Log: String }
    effState = ts.singleEffect "State" ts.tInt;
    effLog   = ts.singleEffect "Log" ts.tString;
    effBoth  = ts.effectMerge effState effLog;

    # Deep handler for State
    deepStateHandler  = ts.mkDeepHandler "State" [] ts.tUnit;

    # Shallow handler for Log
    shallowLogHandler = ts.mkShallowHandler "Log" [] ts.tUnit;

    # Check handlers
    stateCheck = ts.checkHandler deepStateHandler effBoth;
    logCheck   = ts.checkHandler shallowLogHandler effBoth;

    # Handle all
    handleResult = ts.handleAll [deepStateHandler shallowLogHandler] effBoth;
  };

  # ══ 场景 6: Bidirectional Inference + let-generalization（Phase 4.2）
  scenario6_bidir = rec {
    # let id = λx.x in id 42
    idExpr = ts.eLet "id"
      (ts.eLam "x" (ts.eVar "x"))
      (ts.eApp (ts.eVar "id") (ts.eLit 42));

    result = ts.infer {} idExpr;

    # generalize λx.x
    lamExpr = ts.eLam "x" (ts.eVar "x");
    lamResult = ts.infer {} lamExpr;
    scheme    = ts.generalize {} lamResult.type lamResult.constraints;
    isPolymorphic = ts.isScheme scheme;
  };
}
