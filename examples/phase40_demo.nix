# examples/phase40_demo.nix — Phase 4.0
#
# Phase 4.0 全特性演示
#
# 1. Refined Types (Liquid Types / SMT Bridge)
# 2. Module System (Sig / Struct / Functor / Sealing)
# 3. Effect Handlers (algebraic effects dispatch)
# 4. UnifiedSubst (统一替换系统)
# 5. QueryKey Incremental Pipeline (Salsa-style)

let
  lib   = import <nixpkgs/lib>;
  ts    = import ../lib/default.nix { inherit lib; };

  inherit (ts)
    KStar KArrow KRow KEffect
    rPrimitive rVar rFn rEffect rVariantRow rRowEmpty rRowVar
    mkTypeDefault
    mkRefined mkPosInt mkNonNegInt mkBoundedInt
    mkSig mkStruct mkModFunctor sealModule
    mkHandler rHandlerBranch mkEffOp
    mkEffType subtractEffect addEffect getEffectTags hasEffect mergeEffects
    checkSig sigSubtype applyFunctor
    PTrue PFalse PAnd POr PNot PGt PLt PGe PLe PVar PLit
    serializePred predToSMT smtBridge tryDischargeRefined
    staticEvalPred refinedSubtypeObligation
    emptySubst singleTypeBinding applySubstToType composeSubst
    emptyQueryDB storeResult lookupResult invalidateKey bumpEpochDB detectCycle
    mkQueryKey qkNormalize qkHash queryStats
    verifyInvariants __typeMeta;

  tInt    = mkTypeDefault (rPrimitive "Int")    KStar;
  tBool   = mkTypeDefault (rPrimitive "Bool")   KStar;
  tString = mkTypeDefault (rPrimitive "String") KStar;
  tUnit   = mkTypeDefault (rPrimitive "Unit")   KStar;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 0. 系统不变量验证（Phase 4.0）
  # ══════════════════════════════════════════════════════════════════════════════

  invariants = verifyInvariants {};
  # invariants.allPass = true
  # invariants.phase   = "4.0"

  # ══════════════════════════════════════════════════════════════════════════════
  # 1. Refined Types（液体类型 / SMT Bridge）
  # ══════════════════════════════════════════════════════════════════════════════

  # { n : Int | n > 0 }
  tPosInt     = mkPosInt {};
  # { n : Int | n >= 0 }
  tNonNeg     = mkNonNegInt {};
  # { n : Int | 0 <= n <= 255 }
  tByte       = mkBoundedInt 0 255;

  # 自定义 Refined Type
  tEvenInt    = mkRefined tInt "n"
    (PEq (ts.PAnd (PVar "n") (PLit 1)) (PLit 0));  # n & 1 == 0

  # Predicate 序列化（确定性 hash）
  posIntPred  = serializePred (PGt (PVar "n") (PLit 0));
  # → "(gt:v:n:l:0)"

  # 静态求值
  trivialTrue  = staticEvalPred PTrue;    # { known=true; value=true }
  trivialFalse = staticEvalPred PFalse;   # { known=true; value=false }
  andFalse     = staticEvalPred (PAnd PFalse (PVar "x")); # short-circuit → false

  # Discharge attempt
  posIntConstraint = ts.mkRefinedConstraint tPosInt "n" (PGt (PVar "n") (PLit 0));
  dischargeResult  = tryDischargeRefined posIntConstraint;
  # { discharged = false; residual = ... }  → goes to SMT bridge

  trivialConstraint = ts.mkRefinedConstraint tInt "n" PTrue;
  trivialDischarge  = tryDischargeRefined trivialConstraint;
  # { discharged = true }  → statically OK

  # SMT Bridge（Pure string, no IO）
  smtScript = smtBridge [ posIntConstraint ];
  # → "(set-logic LIA)\n(declare-const x0 Int)\n(assert (not (> x0 0)))\n(check-sat)"

  # Refined Subtype Obligation
  # { n : Int | n >= 0 } <: { n : Int | n >= 0 } ← trivial
  # { n : Int | n > 0  } <: { n : Int | n >= 0 } ← need proof: n>0 → n>=0
  subtypeObligation = refinedSubtypeObligation tPosInt tNonNeg;
  # { trivial=false; smtScript="..." }

  # ══════════════════════════════════════════════════════════════════════════════
  # 2. Module System（Sig / Struct / Functor / Sealing）
  # ══════════════════════════════════════════════════════════════════════════════

  # ── Sig 定义 ─────────────────────────────────────────────────────────────────
  sigEq = mkSig {
    T  = KStar;
    eq = KArrow KStar (KArrow KStar KStar);
  };
  # INV-MOD-4: fields alphabetically sorted → { T; eq }

  sigOrd = mkSig {
    T       = KStar;
    compare = KArrow KStar (KArrow KStar KStar);
    eq      = KArrow KStar (KArrow KStar KStar);
  };

  # ── Struct 实现 ───────────────────────────────────────────────────────────────
  tIntEq = mkTypeDefault (rFn tInt (rFn tInt tBool)) KStar;
  structIntEq = mkStruct sigEq {
    T  = tInt;
    eq = tIntEq;
  };

  # Sig checking
  sigCheck = checkSig sigEq structIntEq;
  # { ok = true; missing = [] }

  # ── Functor（参数化模块）─────────────────────────────────────────────────────
  # SortedList(Eq a) = List of a, sorted using eq
  sigSortable = mkSig { T = KStar; cmp = KArrow KStar (KArrow KStar KStar); };

  tVarT    = mkTypeDefault (rVar "M.T" "functor") KStar;
  tSortedList = mkTypeDefault (rFn (rFn tVarT tBool) tVarT) KStar;

  sortedListFunctor = mkModFunctor "M" sigSortable tSortedList;

  # Apply functor with Int-Cmp struct
  structIntCmp = mkStruct sigSortable {
    T   = tInt;
    cmp = mkTypeDefault (rFn tInt (rFn tInt tBool)) KStar;
  };

  # applyFunctor → local instances（INV-MOD-2: isolated）
  sortedListInt = applyFunctor sortedListFunctor structIntCmp;
  # { ok = true; result = ...; localInstances = {} }

  # ── Sealing（信息隐藏，INV-MOD-3）────────────────────────────────────────────
  sealedIntEq = sealModule structIntEq sigEq;
  # repr.__variant = "Opaque" → 外部无法访问 impl 细节

  # ── Sig subtyping ─────────────────────────────────────────────────────────────
  # sigOrd <: sigEq（Ord 有更多字段，sigEq 字段 ⊆ sigOrd 字段）
  ordSubEq = sigSubtype sigOrd sigEq;
  # true：sigOrd provides everything sigEq requires

  # ══════════════════════════════════════════════════════════════════════════════
  # 3. Effect Handlers（代数效果分发）
  # ══════════════════════════════════════════════════════════════════════════════

  # ── Effect 类型构造 ────────────────────────────────────────────────────────────
  tState_Int = mkEffType { State = tInt; };      # Eff[State:Int]
  tIO_Effect  = mkEffType { IO = tUnit; };       # Eff[IO:Unit]
  tExn_Str    = mkEffType { Exn = tString; };    # Eff[Exn:String]

  # 合并 effects
  tAllEffects = mergeEffects (mergeEffects tState_Int tIO_Effect) tExn_Str;
  # Eff[Exn:String, IO:Unit, State:Int]（canonical sorted）

  # 验证结合律（INV-EFF-2）
  leftAssoc  = mergeEffects (mergeEffects tState_Int tIO_Effect) tExn_Str;
  rightAssoc = mergeEffects tState_Int (mergeEffects tIO_Effect tExn_Str);
  # getEffectTags(leftAssoc) == getEffectTags(rightAssoc)
  assocTags  = getEffectTags leftAssoc == getEffectTags rightAssoc;

  # ── Handler 定义 ──────────────────────────────────────────────────────────────
  stateHandler = mkHandler "State"
    [ (rHandlerBranch "get"    []     "resume" tInt)
      (rHandlerBranch "put"    [tInt] "resume" tUnit)
    ]
    tUnit;  # return type

  ioHandler = mkHandler "IO"
    [ (rHandlerBranch "putLine" [tString] "resume" tUnit)
      (rHandlerBranch "getLine" []        "resume" tString)
    ]
    tUnit;

  # ── handle：移除 handled effect（INV-EFF-4）──────────────────────────────────
  checkStateHandle = ts.checkHandler tAllEffects stateHandler;
  # { ok = true; effectTag = "State"; residualEffTy = Eff[Exn, IO] }

  afterStateHandle = checkStateHandle.residualEffTy;
  remainTags       = getEffectTags afterStateHandle;
  # ["Exn", "IO"]（State removed）
  stateRemoved     = !(hasEffect afterStateHandle "State");

  # ── handleAll：连续处理多个 handlers ──────────────────────────────────────────
  fullyHandled = ts.handleAll tAllEffects [ stateHandler ioHandler ];
  # Eff[Exn:String]（State + IO handled）

  # ── Open effect row（INV-EFF-6）────────────────────────────────────────────
  tOpenEff = mkTypeDefault (rEffect (mkTypeDefault (rRowVar "ε") KRow)) KStar;
  # Eff[ε]（open effect row with row variable）
  afterSubtract = subtractEffect tOpenEff ["IO"];
  # Eff[ε]（IO not present, no-op, no crash）

  # ══════════════════════════════════════════════════════════════════════════════
  # 4. UnifiedSubst（统一替换系统，解决 Phase 3.3 遗留风险 1）
  # ══════════════════════════════════════════════════════════════════════════════

  # ── 基础操作 ─────────────────────────────────────────────────────────────────
  tVarA = mkTypeDefault (rVar "a" "demo") KStar;
  tVarB = mkTypeDefault (rVar "b" "demo") KStar;

  # σ₁: a ↦ Var(b)
  subst1 = singleTypeBinding "a" tVarB;
  # σ₂: b ↦ Int
  subst2 = singleTypeBinding "b" tInt;

  # apply σ₁ to Var(a) → Var(b)
  applyS1 = applySubstToType subst1 tVarA;
  # repr.__variant = "Var", repr.name = "b"

  # compose σ₂ ∘ σ₁
  composed = composeSubst subst2 subst1;
  # apply composed to Var(a) → Int
  applyComposed = applySubstToType composed tVarA;
  # repr.__variant = "Primitive", repr.name = "Int"

  # INV-US1: compose law verified
  invUS1 = applyComposed.repr.name == "Int";

  # ── Row subst integration（解决遗留风险 1）────────────────────────────────────
  tRowVar = mkTypeDefault (rRowVar "ρ") KRow;
  tRowClosed = mkTypeDefault (rRowEmpty) KRow;

  rowSubst = emptySubst // { rowBindings = { "r:ρ" = tRowClosed; }; };
  appliedRow = applySubstToType rowSubst tRowVar;
  # repr.__variant = "RowEmpty"（RowVar bound to RowEmpty）

  # ══════════════════════════════════════════════════════════════════════════════
  # 5. QueryKey Incremental Pipeline（Salsa-style）
  # ══════════════════════════════════════════════════════════════════════════════

  # ── QueryKey 构造（INV-QK1：确定性）─────────────────────────────────────────
  normKey  = qkNormalize "type:Int:abc123";
  hashKey  = qkHash "type:Int:abc123";
  solveKey = ts.qkSolve "cs:sha256:deadbeef";

  # ── QueryDB 操作 ──────────────────────────────────────────────────────────────
  # 模拟增量管道：normalize(Int), hash(Int), check(expr)
  db0 = emptyQueryDB;
  db1 = storeResult db0 normKey  "NF:Int"   [];
  db2 = storeResult db1 hashKey  "h:abc123" [normKey];
  db3 = storeResult db2 solveKey "solved:[]" [normKey];

  # Cache hit
  normHit = lookupResult db3 normKey;
  # { found = true; result.value = "NF:Int" }

  # ── 细粒度失效（INV-QK2）─────────────────────────────────────────────────────
  # 修改 Int 的 normalize 结果 → hashKey + solveKey 失效
  db3_invalidated = invalidateKey db3 normKey;
  normAfter  = lookupResult db3_invalidated normKey;  # found = false
  hashAfter  = lookupResult db3_invalidated hashKey;  # found = false
  solveAfter = lookupResult db3_invalidated solveKey; # found = false

  # INV-QK2: 链式失效验证
  invQK2 = !normAfter.found && !hashAfter.found && !solveAfter.found;

  # ── Cycle detection（INV-QK5）────────────────────────────────────────────────
  dbCycle =
    let
      d0 = storeResult emptyQueryDB "X" "vX" ["Y"];
      d1 = storeResult d0 "Y" "vY" ["X"];
    in d1;
  cycleResult = detectCycle dbCycle "X";
  hasCycle    = cycleResult.hasCycle;  # true

  # ── Statistics ────────────────────────────────────────────────────────────────
  stats = queryStats db3;
  # { total = 3; valid = 3; epoch = 0; hitRate = 100 }

  # ══════════════════════════════════════════════════════════════════════════════
  # 综合使用场景：Functor + Effects + Refined
  # ══════════════════════════════════════════════════════════════════════════════

  # 场景：安全数组访问 API
  # 输入：{ n : Int | 0 <= n < len }，返回 Eff[Exn:BoundsError, ε] a
  tBoundsExn = mkRefined tInt "n" (PAnd
    (PGe (PVar "n") (PLit 0))
    (PLt (PVar "n") (PVar "len")));

  # 对应 Effect type：Eff[BoundsError | ε]
  tSafeArrayEff = mergeEffects
    (mkEffType { BoundsError = tBoundsExn; })
    (mkTypeDefault (rEffect (mkTypeDefault (rRowVar "ε") KRow)) KStar);

  # Sig for safe array module
  sigSafeArray = mkSig {
    T    = KStar;          # element type
    len  = KStar;          # length type
    get  = KArrow KStar (KArrow KStar KStar);  # get : idx → T
  };

  # Result summary
  summary = {
    phase       = "4.0";
    invariantsOk = invariants.allPass;
    features = {
      refinedTypes    = { posInt = tPosInt.repr.__variant == "Refined"; smtOk = builtins.isString smtScript; };
      moduleSystem    = { sigCheck = sigCheck.ok; sealingOk = sealedIntEq.repr.__variant == "Opaque"; };
      effectHandlers  = { stateRemoved = stateRemoved; assocOk = assocTags; };
      unifiedSubst    = { composeOk = invUS1; };
      queryKeyDB      = { cacheHit = normHit.found; invalidationOk = invQK2; cycleDetected = hasCycle; };
    };
  };

}
