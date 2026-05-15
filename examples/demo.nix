# examples/demo.nix — Phase 4.5.1-Fix
# 综合示例（8 个端到端场景）
#
# ★ Phase 4.5.1-Fix: 每个 scenario 只输出布尔摘要（ok 字段），
#   不直接暴露 Type/Constraint/Scheme 对象给 --json 序列化器。
#   背景: nix-instantiate --eval --strict --json 会递归 JSON 化整个结果，
#   遇到任何含函数字段的 attrset（或通过某些路径可达的 lambda）会 abort。
#   解决方法: 将 scenario 结果归约为只含 bool/string/int 的 summary attrset。
#
# Phase 4.3 additions: scenario7 Kind Inference, scenario8 Handler Continuations
{ lib ? (import <nixpkgs> {}).lib }:

let
  ts = import ../lib/default.nix { inherit lib; };

  # 安全求值助手：将 thunk 归约为 bool，任何错误视为 false
  _safe = thunk:
    let r = builtins.tryEval thunk; in
    r.success && r.value == true;

  _safeOk = thunk:
    let r = builtins.tryEval (thunk.ok or false); in
    r.success && r.value;

in

rec {
  # ══ 场景 1: ADT + Pattern Matching ═══════════════════════════════════
  scenario1_adt = rec {
    maybeVariants = [
      (ts.mkVariant "Nothing" [] 0)
      (ts.mkVariant "Just" [ts.tInt] 1)
    ];
    tMaybeIntOk = ts.isType (ts.mkTypeDefault (ts.rADT maybeVariants true) ts.KStar);

    # ts.mkPVar is patternLib.mkPVar → Pattern Var { __patTag = "Var" }
    armsOk = builtins.isList [
      (ts.mkArm (ts.mkPCtor "Nothing" []) ts.tInt)
      (ts.mkArm (ts.mkPCtor "Just" [ts.mkPVar "x"]) ts.tInt)
    ];

    # Evaluate decision tree tag only (not the full DT with body=tInt Type object)
    _arms = [
      (ts.mkArm (ts.mkPCtor "Nothing" []) ts.tInt)
      (ts.mkArm (ts.mkPCtor "Just" [ts.mkPVar "x"]) ts.tInt)
    ];
    decisionTreeTag     = (ts.compileMatch _arms maybeVariants).__dtTag or "none";
    decisionTreeOk      = decisionTreeTag == "Switch";
    exhaustiveCheckOk   = (ts.checkExhaustive _arms maybeVariants).exhaustive;

    ok = tMaybeIntOk && armsOk && decisionTreeOk && exhaustiveCheckOk;
  };

  # ══ 场景 2: Constraint Solver ════════════════════════════════════════
  scenario2_solver = rec {
    alpha = ts.mkTypeDefault (ts.rVar "α" "") ts.KStar;
    beta  = ts.mkTypeDefault (ts.rVar "β" "") ts.KStar;
    constraints = [
      (ts.mkEqConstraint alpha ts.tInt)
      (ts.mkEqConstraint beta ts.tBool)
      (ts.mkClassConstraint "Eq" [alpha])
    ];
    result       = ts.solveSimple constraints;
    solveOk      = result.ok or false;
    typeSubstOk  = builtins.isAttrs (ts.getTypeSubst result);
    ok = solveOk && typeSubstOk;
  };

  # ══ 场景 3: Module Functor Composition ══════════════════════════════
  scenario3_modules = rec {
    ordSig      = ts.mkSig {
      compare = ts.mkTypeDefault (ts.rFn ts.tInt (ts.mkTypeDefault (ts.rFn ts.tInt ts.tBool) ts.KStar)) ts.KStar;
    };
    sortFunctor = ts.mkModFunctor "Ord" ordSig ts.tInt;
    setFunctor  = ts.mkModFunctor "Ord" ordSig ts.tBool;
    composed    = ts.composeFunctors sortFunctor setFunctor;
    composedOk  = ts.isModFunctor composed;
    chain       = ts.composeFunctorChain [sortFunctor setFunctor];
    chainOk     = ts.isModFunctor chain;
    ok = composedOk && chainOk;
  };

  # ══ 场景 4: Refined Types ════════════════════════════════════════════
  scenario4_refined = rec {
    posIntOk     = ts.isType ts.tPositiveInt;
    nonNegOk     = ts.isType ts.tNonNegInt;
    # Fix P4.3-naming: SMT predicate uses PredExpr PVar → ts.mkPPredVar
    smtOk        = builtins.isAttrs (ts.defaultSmtOracle "n" (ts.mkPCmp ">" (ts.mkPPredVar "n") (ts.mkPLit 0)));
    trivialRef   = ts.mkRefined ts.tInt "n" ts.mkPTrue;
    normalized   = ts.normalize' trivialRef;
    isNormalized = (normalized.repr.__variant or null) == "Primitive";
    ok = posIntOk && nonNegOk && smtOk && isNormalized;
  };

  # ══ 场景 5: Effect Handlers（deep/shallow）════════════════════════════
  scenario5_effects = rec {
    effState           = ts.singleEffect "State" ts.tInt;
    effLog             = ts.singleEffect "Log" ts.tString;
    effBoth            = ts.effectMerge effState effLog;
    deepStateHandler   = ts.mkDeepHandler "State" [] ts.tUnit;
    shallowLogHandler  = ts.mkShallowHandler "Log" [] ts.tUnit;
    stateCheckOk       = (ts.checkHandler deepStateHandler effBoth).ok;
    logCheckOk         = (ts.checkHandler shallowLogHandler effBoth).ok;
    handleResultOk     = (ts.handleAll [deepStateHandler shallowLogHandler] effBoth).ok;
    ok = stateCheckOk && logCheckOk && handleResultOk;
  };

  # ══ 场景 6: Bidirectional Inference ══════════════════════════════════
  scenario6_bidir = rec {
    idExpr = ts.eLet "id"
      (ts.eLam "x" (ts.eVar "x"))
      (ts.eApp (ts.eVar "id") (ts.eLit 42));
    resultOk      = ts.isType (ts.infer {} idExpr).type;
    lamExpr       = ts.eLam "x" (ts.eVar "x");
    lamResultType = (ts.infer {} lamExpr).type;
    lamOk         = ts.isType lamResultType;
    scheme        = ts.generalize {} lamResultType ((ts.infer {} lamExpr).constraints or []);
    isPolymorphic = ts.isScheme scheme;
    ok = resultOk && lamOk && isPolymorphic;
  };

  # ══ 场景 7: Kind Inference（Phase 4.3: INV-KIND-1）═══════════════════
  scenario7_kind = rec {
    listCtor = ts.mkTypeDefault
      (ts.rConstructor "List" (ts.KArrow ts.KStar ts.KStar) ["a"]
        (ts.mkTypeDefault (ts.rADT [
          (ts.mkVariant "Nil" [] 0)
          (ts.mkVariant "Cons" [ts.tInt] 1)
        ] true) ts.KStar))
      (ts.KArrow ts.KStar ts.KStar);

    kindResult  = ts.inferKind {} listCtor.repr;
    inferOk     = ts.isKArrow kindResult.kind || ts.isStar kindResult.kind;

    kv          = ts.KVar "kv";
    unifyKindR  = ts.unifyKind (ts.KArrow ts.KStar ts.KStar) (ts.KArrow kv kv);
    kindUnifyOk = unifyKindR.ok;

    kindCs      = [ (ts.mkKindConstraint "α" ts.KStar)
                    (ts.mkKindConstraint "β" (ts.KArrow ts.KStar ts.KStar)) ];
    kindSolveR  = ts.solveKindConstraints kindCs;
    kindSolveOk = kindSolveR.ok;

    ok = inferOk && kindUnifyOk && kindSolveOk;
  };

  # ══ 场景 8: Handler Continuations（Phase 4.3: INV-EFF-10）════════════
  scenario8_handler_cont = rec {
    contTy   = ts.mkTypeDefault (ts.rFn ts.tInt ts.tBool) ts.KStar;
    handler  = ts.mkHandlerWithCont "State" ts.tInt contTy ts.tBool;

    contOk   = ts.isHandlerWithCont handler;
    contCheckOk = (ts.checkHandlerContWellFormed handler).ok;

    effRow   = ts.emptyEffectRow;
    fullCont = ts.mkContType ts.tInt effRow ts.tBool;
    contIsOk = (fullCont.repr.__variant or null) == "Fn";

    effState      = ts.singleEffect "State" ts.tInt;
    handlerCheckOk = (ts.checkHandler handler effState).ok;

    ok = contOk && contCheckOk && contIsOk && handlerCheckOk;
  };

  # ══ 整体摘要 ══════════════════════════════════════════════════════════
  allOk =
    scenario1_adt.ok &&
    scenario2_solver.ok &&
    scenario3_modules.ok &&
    scenario4_refined.ok &&
    scenario5_effects.ok &&
    scenario6_bidir.ok &&
    scenario7_kind.ok &&
    scenario8_handler_cont.ok;

  summary = {
    s1_adt         = scenario1_adt.ok;
    s2_solver      = scenario2_solver.ok;
    s3_modules     = scenario3_modules.ok;
    s4_refined     = scenario4_refined.ok;
    s5_effects     = scenario5_effects.ok;
    s6_bidir       = scenario6_bidir.ok;
    s7_kind        = scenario7_kind.ok;
    s8_handler     = scenario8_handler_cont.ok;
    all            = allOk;
  };
}
