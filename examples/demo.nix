# examples/demo.nix — Phase 4.1
# 综合示例：展示 Phase 4.1 所有核心能力
{ lib ? (import <nixpkgs> {}).lib }:

let
  ts = import ../lib/default.nix { inherit lib; };

  # ── 基础类型 ──────────────────────────────────────────────────────────────
  tInt    = ts.mkTypeDefault (ts.rPrimitive "Int")    ts.KStar;
  tBool   = ts.mkTypeDefault (ts.rPrimitive "Bool")   ts.KStar;
  tString = ts.mkTypeDefault (ts.rPrimitive "String") ts.KStar;

  # ═══════════════════════════════════════════════════════════════════════════
  # 示例 1: Refined Types + SMT Oracle（Phase 4.1 INV-SMT-5）
  # ═══════════════════════════════════════════════════════════════════════════
  example1_refined =
    let
      # { n : Int | n > 0 }
      posInt = ts.mkPositiveInt tInt;
      # { n : Int | n >= 0 }
      nonNeg = ts.mkNonNegInt tInt;

      # 静态检查（直接求值）
      staticCheck = ts.staticEvalPred (ts.mkPCmp "gt" (ts.mkPLit 5) (ts.mkPLit 0));

      # SMT bridge（生成 SMTLIB2 供外部 z3 调用）
      smtScript = ts.smtBridge [
        { subject = tInt;
          predVar = "n";
          predExpr = ts.mkPCmp "gt" (ts.mkPVar "n") (ts.mkPLit 0); }
      ];

      # checkRefinedSubtype with mock oracle
      # { n:Int | n>0 } <: { n:Int | n>=0 }  → valid（n>0 implies n>=0）
      mockOracle = smtInput: "unsat";  # 模拟 z3 返回 unsat（subtype holds）
      subtypeResult = ts.checkRefinedSubtype posInt nonNeg mockOracle;
    in
    { staticOk     = staticCheck.discharged;
      smtScript    = smtScript;
      subtypeOk    = subtypeResult.ok;
      subtypeWitness = subtypeResult.witness or null; };

  # ═══════════════════════════════════════════════════════════════════════════
  # 示例 2: Module System（Phase 4.1 INV-MOD-6/7）
  # ═══════════════════════════════════════════════════════════════════════════
  example2_modules =
    let
      # 定义 Printable 签名
      printableSig = ts.mkSig {
        show    = tString;
        display = tString;
      };

      # 实现 Int printable
      intPrintable = ts.mkStruct printableSig {
        show    = tString;
        display = tString;
      };

      # 检查实现是否满足签名
      checkResult = ts.checkSig intPrintable printableSig;

      # Functor：包装任意类型为 "Showable"
      showableFunctor = ts.mkModFunctor "M" printableSig
        (ts.mkSig {
          wrapped = tBool;  # 简化 body
        });

      # Apply functor
      applyResult = ts.applyFunctor showableFunctor intPrintable;

      # Compose functors（Phase 4.1）
      identity1 = ts.mkModFunctor "M1" printableSig
        (ts.mkTypeDefault (ts.rVar "M1" "f1") ts.KStar);
      identity2 = ts.mkModFunctor "M2" printableSig
        (ts.mkTypeDefault (ts.rVar "M2" "f2") ts.KStar);
      composed = ts.composeFunctors identity1 identity2;

      # mergeLocalInstances（Phase 4.1 INV-MOD-7）
      globalInstances = { inst_eq_int = { className = "Eq"; }; };
      localInstances  = { inst_show_int = { className = "Show"; }; };
      mergeResult     = ts.mergeLocalInstances globalInstances localInstances;
    in
    { sigCheckOk     = checkResult.ok;
      functorApplyOk = applyResult.ok;
      composedParam  = composed.repr.param or "?";
      mergeOk        = mergeResult.ok;
      mergedCount    = builtins.length (builtins.attrNames mergeResult.db); };

  # ═══════════════════════════════════════════════════════════════════════════
  # 示例 3: Effect Handler Pipeline（Phase 4.1 INV-EFF-8/9）
  # ═══════════════════════════════════════════════════════════════════════════
  example3_effects =
    let
      inherit (ts.effectLib) singleEffect;

      # Effect rows
      stateEff = singleEffect "State" tInt;
      ioEff    = singleEffect "IO"    tString;
      stateIO  = ts.effectMerge stateEff ioEff;

      # Handlers
      stateHandler = ts.mkDeepHandler "State"
        [ { effectTag = "State"; paramType = tInt; body = tInt; } ]
        tInt;
      ioHandler = ts.mkShallowHandler "IO"
        [ { effectTag = "IO"; paramType = tString; body = tString; } ]
        tString;

      # Effect type
      effType = ts.mkTypeDefault (ts.rEffect stateIO) ts.KEffect;

      # Check and handle
      checkState = ts.checkHandler stateHandler effType;
      handleAll  = ts.handleAll [ stateHandler ioHandler ] effType;

      # Normalize effect row（INV-EFF-6: VariantRow canonical sort）
      normEff = ts.normalize' stateIO;
    in
    { stateHandlerIsDeep = stateHandler.repr.deep or false;
      ioHandlerIsShallow = ioHandler.repr.shallow or false;
      checkOk            = checkState.ok;
      handleAllOk        = handleAll.ok;
      normVariant        = normEff.repr.__variant or "?"; };

  # ═══════════════════════════════════════════════════════════════════════════
  # 示例 4: Incremental Cache（Phase 4.1 RISK-D 修复）
  # ═══════════════════════════════════════════════════════════════════════════
  example4_cache =
    let
      # 初始化双层缓存
      initDB   = ts.emptyQueryDB;
      initMemo = {};

      # cacheNormalize：同时写入 QueryDB + Memo
      afterNorm = ts.cacheNormalize initDB initMemo "type_int" tInt
        [ (ts.queryLib.mkQueryKey "hash" [ "type_int" ]) ];

      # 验证：两层缓存都有数据
      normKey   = ts.queryLib.mkQueryKey "norm" [ "type_int" ];
      inQueryDB = (ts.queryLib.lookupResult afterNorm.queryDB normKey).found;
      inMemo    = afterNorm.memo ? "type_int";

      # bumpEpochDB：同步清空两层
      bumpedState = ts.queryLib.bumpEpochDB afterNorm;
      afterBump_db_found   = (ts.queryLib.lookupResult bumpedState.queryDB normKey).found;
      afterBump_memo_empty = bumpedState.memo == {};

      # QueryKey schema validation（INV-QK-SCHEMA）
      validKey   = ts.queryLib.validateQueryKey "norm:type_int";
      invalidKey = ts.queryLib.validateQueryKey "unknown:type_int";
    in
    { inQueryDB    = inQueryDB;
      inMemo       = inMemo;
      bumpClearsDB = !afterBump_db_found;
      bumpClearsMemo = afterBump_memo_empty;
      schemaValid   = validKey;
      schemaInvalid = !invalidKey; };

  # ═══════════════════════════════════════════════════════════════════════════
  # 示例 5: Constraint Solver（统一 UnifiedSubst pipeline）
  # ═══════════════════════════════════════════════════════════════════════════
  example5_solver =
    let
      # 类型变量
      tAlpha = ts.mkTypeDefault (ts.rVar "α" "demo") ts.KStar;
      tBeta  = ts.mkTypeDefault (ts.rVar "β" "demo") ts.KStar;

      # 约束：α = Int, β = Bool → Fn(α, β)
      c1 = ts.mkEqConstraint tAlpha tInt;
      c2 = ts.mkEqConstraint tBeta tBool;

      # 求解
      result = ts.solveSimple [ c1 c2 ];

      # 应用 subst 到函数类型
      fnTy     = ts.mkTypeDefault (ts.rFn tAlpha tBeta) ts.KStar;
      resolvedFn = ts.applyUnifiedSubst result.subst fnTy;
      normFn     = ts.normalize' resolvedFn;

      # Row equality
      rowA = ts.mkTypeDefault (ts.rRowExtend "x" tInt
               (ts.mkTypeDefault ts.rRowEmpty ts.KRow)) ts.KRow;
      rowB = ts.mkTypeDefault (ts.rVar "r" "row") ts.KRow;
      rowC = ts.mkEqConstraint rowA rowB;
      rowResult = ts.solveSimple [ rowC ];
    in
    { solverOk   = result.ok;
      substSize  = ts.unifiedSubstLib.substSize result.subst;
      fnResolved = normFn.repr.__variant or "?";
      rowSolveOk = rowResult.ok; };

  # ═══════════════════════════════════════════════════════════════════════════
  # 示例 6: ADT + Pattern Matching
  # ═══════════════════════════════════════════════════════════════════════════
  example6_adt =
    let
      # Option a = Some a | None
      optionBody = ts.mkTypeDefault (ts.rADT [
        (ts.mkVariant "Some" [ tInt ] 0)
        (ts.mkVariant "None" []       1)
      ] true) ts.KStar;

      # Pattern arms
      someArm = ts.mkArm
        (ts.mkPatConstructor "Some" [ ts.mkPatVar "x" ] null)
        "some_body";
      noneArm = ts.mkArm
        ts.mkPatWildcard
        "none_body";

      # Compile to Decision Tree
      dt = ts.compileMatch [ someArm noneArm ] optionBody;

      # Exhaustiveness check
      exh = ts.checkExhaustive [ someArm noneArm ] optionBody;
    in
    { dtTag      = dt.__dtTag or "?";
      exhaustive = exh.exhaustive;
      missing    = exh.missing; };

in {
  example1_refined  = example1_refined;
  example2_modules  = example2_modules;
  example3_effects  = example3_effects;
  example4_cache    = example4_cache;
  example5_solver   = example5_solver;
  example6_adt      = example6_adt;

  # 全部通过断言
  allOk =
    example1_refined.subtypeOk &&
    example2_modules.sigCheckOk &&
    example2_modules.functorApplyOk &&
    example2_modules.mergeOk &&
    example3_effects.checkOk &&
    example3_effects.stateHandlerIsDeep &&
    example3_effects.ioHandlerIsShallow &&
    example4_cache.inQueryDB &&
    example4_cache.inMemo &&
    example4_cache.bumpClearsDB &&
    example4_cache.bumpClearsMemo &&
    example4_cache.schemaValid &&
    example4_cache.schemaInvalid &&
    example5_solver.solverOk &&
    example6_adt.exhaustive;
}
