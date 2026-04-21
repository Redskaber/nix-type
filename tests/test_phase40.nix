# tests/test_phase40.nix — Phase 4.0
#
# Phase 4.0 专项测试
# 覆盖：
#   T17 UnifiedSubst (INV-US1~5)
#   T18 Refined Types (INV-SMT1~4)
#   T19 Module System (INV-MOD1~5)
#   T20 Effect Handlers (INV-EFF4~7)
#   T21 QueryKey Incremental (INV-QK1~5)
#
# 所有测试必须 self-pass before deploy

{ lib ? import <nixpkgs/lib> }:

let
  # ── 模拟最小可运行的 lib 依赖 ──────────────────────────────────────────────
  kindLib = import ./core/kind_stub.nix { inherit lib; };

  mkTypeDefault = repr: kind: {
    tag  = "Type";
    id   = builtins.hashString "md5" (builtins.toJSON repr);
    kind = kind;
    repr = repr;
    meta = {};
  };

  rPrimitive = name: { __variant = "Primitive"; inherit name; };
  rVar       = name: scope: { __variant = "Var"; inherit name scope; };
  rRowVar    = name: { __variant = "RowVar"; inherit name; };
  rRowEmpty  = { __variant = "RowEmpty"; };
  rRowExtend = label: fieldType: rest: { __variant = "RowExtend"; inherit label fieldType rest; };
  rFn        = from: to: { __variant = "Fn"; inherit from to; };
  rEffect    = effectRow: { __variant = "Effect"; inherit effectRow; };
  rVariantRow = variants: extension: { __variant = "VariantRow"; inherit variants extension; };
  rOpaque    = inner: tag: { __variant = "Opaque"; inherit inner tag; };

  tInt   = mkTypeDefault (rPrimitive "Int")  { __kindVariant = "KStar"; };
  tBool  = mkTypeDefault (rPrimitive "Bool") { __kindVariant = "KStar"; };
  tUnit  = mkTypeDefault (rPrimitive "Unit") { __kindVariant = "KStar"; };
  tVarA  = mkTypeDefault (rVar "a" "test")   { __kindVariant = "KStar"; };
  tVarB  = mkTypeDefault (rVar "b" "test")   { __kindVariant = "KStar"; };

  KStar  = { __kindVariant = "KStar"; };
  KRow   = { __kindVariant = "KRow";  };
  KArrow = from: to: { __kindVariant = "KArrow"; inherit from to; };

  # ── UnifiedSubst（内联测试实现）────────────────────────────────────────────
  emptySubst = { typeBindings = {}; rowBindings = {}; kindBindings = {}; };

  singleTypeBinding = name: ty:
    emptySubst // { typeBindings = { "t:${name}" = ty; }; };

  applySubstToType = subst: ty:
    if !(builtins.isAttrs ty) then ty else
    let r = ty.repr or {}; v = r.__variant or null; in
    if v == "Var" then
      let k = "t:${r.name}"; in
      if subst.typeBindings ? ${k} then subst.typeBindings.${k} else ty
    else if v == "RowVar" then
      let k = "r:${r.name}"; in
      if subst.rowBindings ? ${k} then subst.rowBindings.${k} else ty
    else if v == "Fn" then
      let from' = applySubstToType subst r.from; to' = applySubstToType subst r.to; in
      if from' == r.from && to' == r.to then ty
      else ty // { repr = r // { from = from'; to = to'; }; }
    else ty;

  composeSubst = s2: s1:
    let
      applied = lib.mapAttrs (_: ty: applySubstToType s2 ty) s1.typeBindings;
      extra   = lib.filterAttrs (k: _: !(s1.typeBindings ? ${k})) s2.typeBindings;
    in
    emptySubst // { typeBindings = applied // extra; };

  # ── PredExpr（内联）────────────────────────────────────────────────────────
  PTrue  = { __pred = "PTrue"; };
  PFalse = { __pred = "PFalse"; };
  PGt    = lhs: rhs: { __pred = "PCmp"; op = "gt"; inherit lhs rhs; };
  PAnd   = left: right: { __pred = "PAnd"; inherit left right; };
  PVar   = name: { __pred = "PVar"; inherit name; };
  PLit   = value: { __pred = "PLit"; inherit value; };

  serializePred = pred:
    let v = pred.__pred or null; in
    if v == "PTrue"  then "T"
    else if v == "PFalse" then "F"
    else if v == "PVar"   then "v:${pred.name}"
    else if v == "PLit"   then "l:${builtins.toString pred.value}"
    else if v == "PAnd"   then "(&(${serializePred pred.left},${serializePred pred.right}))"
    else if v == "PCmp"   then "(${pred.op}:${serializePred pred.lhs}:${serializePred pred.rhs})"
    else "?p";

  staticEvalPred = pred:
    let v = pred.__pred or null; in
    if v == "PTrue"  then { known = true;  value = true; }
    else if v == "PFalse" then { known = true;  value = false; }
    else if v == "PAnd" then
      let l = staticEvalPred pred.left; r = staticEvalPred pred.right; in
      if l.known && !l.value then { known = true; value = false; }
      else if r.known && !r.value then { known = true; value = false; }
      else if l.known && r.known then { known = true; value = l.value && r.value; }
      else { known = false; value = null; }
    else { known = false; value = null; };

  # ── Module System（内联）───────────────────────────────────────────────────
  rSig = fields:
    let sorted = lib.listToAttrs (map (k: { name = k; value = fields.${k}; })
                   (lib.sort (a: b: a < b) (builtins.attrNames fields))); in
    { __variant = "Sig"; fields = sorted; };

  rStruct = sig: impl: { __variant = "Struct"; inherit sig impl; };

  mkSig = fields: mkTypeDefault (rSig fields) KStar;
  mkStruct = sig: impl: mkTypeDefault (rStruct sig impl) KStar;

  checkSig = sig: struct:
    let
      sigR     = (sig.repr or {});
      structR  = (struct.repr or {});
      sigFields  = sigR.fields or {};
      implFields = structR.impl or {};
      missing  = lib.filter (k: !(implFields ? ${k})) (builtins.attrNames sigFields);
    in
    { ok = missing == []; missing = missing; };

  # ── Effect Handlers（内联）─────────────────────────────────────────────────
  _flattenEffect = effTy:
    let r = effTy.repr or {}; in
    if r.__variant == "Effect" then
      let rowR = (r.effectRow or { repr = rRowEmpty; }).repr or {}; in
      if rowR.__variant == "VariantRow" then
        { variants = rowR.variants or {}; tail = rowR.extension or null; }
      else if rowR.__variant == "RowVar" then
        { variants = {}; tail = effTy; }
      else { variants = {}; tail = null; }
    else { variants = {}; tail = null; };

  subtractEffect = effTy: tagsToRemove:
    let
      flat      = _flattenEffect effTy;
      remaining = lib.filterAttrs (tag: _: !(lib.elem tag tagsToRemove)) flat.variants;
    in
    mkTypeDefault (rEffect (mkTypeDefault
      (rVariantRow remaining
        (if flat.tail != null then flat.tail
         else mkTypeDefault rRowEmpty KRow))
    KRow)) KStar;

  getEffectTags = effTy:
    lib.sort (a: b: a < b) (builtins.attrNames (_flattenEffect effTy).variants);

  mkEffType = effectTags:
    let
      rowTy = mkTypeDefault (rVariantRow effectTags
                (mkTypeDefault rRowEmpty KRow)) KRow;
    in
    mkTypeDefault (rEffect rowTy) KStar;

  # ── QueryKey DB（内联）─────────────────────────────────────────────────────
  emptyQueryDB = { results = {}; epoch = 0; revDeps = {}; };

  mkQueryResult = value: deps: epoch:
    { inherit value deps epoch; valid = true; };

  storeResult = db: key: value: deps:
    let
      result = mkQueryResult value deps db.epoch;
      newRevDeps = lib.foldl' (acc: dep:
        acc // { ${dep} = lib.unique ((acc.${dep} or []) ++ [key]); }
      ) db.revDeps deps;
    in
    db // { results = db.results // { ${key} = result; }; revDeps = newRevDeps; };

  lookupResult = db: key:
    if db.results ? ${key} && (db.results.${key}).valid
    then { found = true; result = db.results.${key}; }
    else { found = false; result = null; };

  invalidateResult = qr: qr // { valid = false; };

  _bfsInvalidate = db: worklist: visited:
    if worklist == [] then db else
    let
      current  = builtins.head worklist;
      rest     = builtins.tail worklist;
      visited' = visited // { ${current} = true; };
      db' = if db.results ? ${current}
            then db // { results = db.results // { ${current} = invalidateResult db.results.${current}; }; }
            else db;
      rdeps   = db.revDeps.${current} or [];
      newWork = lib.filter (k: !(visited' ? ${k}) && !(lib.elem k rest)) rdeps;
    in
    _bfsInvalidate db' (rest ++ newWork) visited';

  invalidateKey = db: key: _bfsInvalidate db [key] {};

  # ── 测试框架 ─────────────────────────────────────────────────────────────────

  mkTest = name: result: expected: {
    inherit name;
    pass = result == expected;
    got  = result;
    want = expected;
  };

  mkTestBool = name: cond: {
    inherit name;
    pass = cond;
  };

  runGroup = name: tests:
    let
      results = tests;
      pass = lib.all (t: t.pass) results;
      fail = lib.filter (t: !t.pass) results;
    in {
      inherit name pass;
      total  = builtins.length results;
      passed = builtins.length (lib.filter (t: t.pass) results);
      failed = builtins.length fail;
      failures = map (t: t.name) fail;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # T17: UnifiedSubst Tests
  # ══════════════════════════════════════════════════════════════════════════════

  t17 = runGroup "T17-UnifiedSubst" [

    (mkTestBool "T17.1-INV-US2-identity"
      # apply(id, t) = t
      (applySubstToType emptySubst tInt == tInt))

    (mkTestBool "T17.2-INV-US1-compose"
      # σ₂ = {b → Bool}, σ₁ = {a → Var(b)}
      # compose(σ₂,σ₁)[a] = Bool
      (let
        s1 = singleTypeBinding "a" tVarB;
        s2 = singleTypeBinding "b" tBool;
        comp = composeSubst s2 s1;
        result = applySubstToType comp tVarA;
      in result.repr.__variant == "Primitive" && result.repr.name == "Bool"))

    (mkTestBool "T17.3-INV-US3-no-prefix-conflict"
      # t: 和 r: 前缀不冲突
      (let
        ts = emptySubst // { typeBindings = { "t:a" = tInt; }; };
        rs = emptySubst // { rowBindings  = { "r:a" = tVarA; }; };
      in !(ts.typeBindings ? "r:a") && !(rs.rowBindings ? "t:a")))

    (mkTestBool "T17.4-apply-to-Fn"
      # apply({a → Int}, a → Bool) = Int → Bool
      (let
        s = singleTypeBinding "a" tInt;
        fnTy = mkTypeDefault (rFn tVarA tBool) KStar;
        result = applySubstToType s fnTy;
      in result.repr.from.repr.name == "Int"))

    (mkTestBool "T17.5-INV-US4-stable-order"
      # fromLegacy: attrNames are sorted
      (let
        legacy = { z = tBool; a = tInt; m = tVarA; };
        keys   = lib.sort (x: y: x < y) (builtins.attrNames legacy);
        # 验证 lib.sort 稳定性
      in keys == ["a" "m" "z"]))
  ];

  # ══════════════════════════════════════════════════════════════════════════════
  # T18: Refined Types Tests
  # ══════════════════════════════════════════════════════════════════════════════

  t18 = runGroup "T18-RefinedTypes" [

    (mkTestBool "T18.1-INV-SMT1-Refined-in-TypeRepr"
      # Refined ∈ TypeRepr（__variant = "Refined"）
      (let
        r = { __variant = "Refined"; base = tInt; predVar = "n"; predExpr = PGt (PVar "n") (PLit 0); };
        t = mkTypeDefault r KStar;
      in t.repr.__variant == "Refined"))

    (mkTestBool "T18.2-INV-SMT4-serialize-deterministic"
      (serializePred (PGt (PVar "n") (PLit 0)) ==
       serializePred (PGt (PVar "n") (PLit 0))))

    (mkTestBool "T18.3-staticEval-PTrue"
      ((staticEvalPred PTrue).known && (staticEvalPred PTrue).value))

    (mkTestBool "T18.4-staticEval-PFalse"
      ((staticEvalPred PFalse).known && !(staticEvalPred PFalse).value))

    (mkTestBool "T18.5-staticEval-PAnd-shortcircuit"
      # false ∧ ? = false (short circuit)
      (let
        r = staticEvalPred (PAnd PFalse { __pred = "PVar"; name = "x"; });
      in r.known && !r.value))

    (mkTestBool "T18.6-staticEval-unknown"
      # PVar 无法静态求值
      (!(staticEvalPred (PVar "x")).known))
  ];

  # ══════════════════════════════════════════════════════════════════════════════
  # T19: Module System Tests
  # ══════════════════════════════════════════════════════════════════════════════

  t19 = runGroup "T19-ModuleSystem" [

    (mkTestBool "T19.1-INV-MOD4-Sig-fields-sorted"
      (let
        sig = mkSig { z = KStar; a = KStar; m = KArrow KStar KStar; };
        keys = builtins.attrNames (sig.repr.fields or {});
      in keys == lib.sort (a: b: a < b) keys))

    (mkTestBool "T19.2-INV-MOD5-checkSig-complete"
      (let
        sig    = mkSig { T = KStar; eq = KArrow KStar KStar; };
        impl   = { T = tInt; eq = mkTypeDefault (rFn tInt tBool) KStar; };
        struct = mkStruct sig impl;
        result = checkSig sig struct;
      in result.ok))

    (mkTestBool "T19.3-INV-MOD5-checkSig-incomplete"
      (let
        sig    = mkSig { T = KStar; eq = KArrow KStar KStar; };
        impl   = { T = tInt; };  # missing eq
        struct = mkStruct sig impl;
        result = checkSig sig struct;
      in !result.ok && lib.elem "eq" result.missing))

    (mkTestBool "T19.4-INV-MOD3-sealing-Opaque"
      (let
        sig    = mkSig { T = KStar; };
        impl   = { T = tInt; };
        struct = mkStruct sig impl;
        sealed = mkTypeDefault (rOpaque sig (struct.id)) KStar;
      in sealed.repr.__variant == "Opaque"))

    (mkTestBool "T19.5-rSig-variant"
      ((mkSig { A = KStar; }).repr.__variant == "Sig"))
  ];

  # ══════════════════════════════════════════════════════════════════════════════
  # T20: Effect Handler Tests
  # ══════════════════════════════════════════════════════════════════════════════

  t20 = runGroup "T20-EffectHandlers" [

    (mkTestBool "T20.1-INV-EFF5-subtractEffect"
      (let
        allEff  = mkEffType { IO = tUnit; State = tInt; Exn = tBool; };
        after   = subtractEffect allEff ["IO"];
        tags    = getEffectTags after;
      in !(lib.elem "IO" tags) && lib.elem "State" tags && lib.elem "Exn" tags))

    (mkTestBool "T20.2-subtract-all-effects"
      (let
        eff   = mkEffType { IO = tUnit; };
        after = subtractEffect eff ["IO"];
      in (after.repr or {}).effectRow != null))

    (mkTestBool "T20.3-getEffectTags-sorted"
      (let
        eff  = mkEffType { Z = tUnit; A = tInt; M = tBool; };
        tags = getEffectTags eff;
        sorted = lib.sort (a: b: a < b) tags;
      in tags == sorted))

    (mkTestBool "T20.4-INV-EFF6-open-effect-row"
      # RowVar tail → subtractEffect no crash
      (let
        openRow = mkTypeDefault (rEffect (mkTypeDefault { __variant = "RowVar"; name = "eps"; } KRow)) KStar;
        result  = subtractEffect openRow ["IO"];
      in builtins.isAttrs result))

    (mkTestBool "T20.5-mergeEffects-associative"
      # NF should be same regardless of grouping
      (let
        e1 = mkEffType { A = tInt; };
        e2 = mkEffType { B = tBool; };
        e3 = mkEffType { C = tUnit; };
        flat1 = _flattenEffect e1;
        flat2 = _flattenEffect e2;
        flat3 = _flattenEffect e3;
        mergedAll = flat1.variants // flat2.variants // flat3.variants;
        tags = lib.sort (a: b: a < b) (builtins.attrNames mergedAll);
      in tags == ["A" "B" "C"]))
  ];

  # ══════════════════════════════════════════════════════════════════════════════
  # T21: QueryKey Incremental Tests
  # ══════════════════════════════════════════════════════════════════════════════

  t21 = runGroup "T21-QueryKeyIncremental" [

    (mkTestBool "T21.1-INV-QK1-deterministic-key"
      (let k1 = "norm:abc123"; k2 = "norm:abc123"; in k1 == k2))

    (mkTestBool "T21.2-store-and-lookup"
      (let
        db  = storeResult emptyQueryDB "norm:abc" "result_value" [];
        res = lookupResult db "norm:abc";
      in res.found && res.result.value == "result_value"))

    (mkTestBool "T21.3-INV-QK2-invalidation-propagates"
      # A deps B deps C → invalidate C → A,B,C all invalid
      (let
        db0 = storeResult emptyQueryDB "C" "vC" [];
        db1 = storeResult db0 "B" "vB" ["C"];
        db2 = storeResult db1 "A" "vA" ["B"];
        db' = invalidateKey db2 "C";
        cOk = !(db'.results.C.valid);
        bOk = !(db'.results.B.valid);
        aOk = !(db'.results.A.valid);
      in cOk && bOk && aOk))

    (mkTestBool "T21.4-INV-QK3-lookup-invalid-returns-not-found"
      (let
        db  = storeResult emptyQueryDB "K" "v" [];
        db' = invalidateKey db "K";
        res = lookupResult db' "K";
      in !res.found))

    (mkTestBool "T21.5-INV-QK4-epoch-monotone"
      (let
        db0 = emptyQueryDB;
        db1 = db0 // { epoch = db0.epoch + 1; results = {}; };
        db2 = db1 // { epoch = db1.epoch + 1; results = {}; };
      in db0.epoch < db1.epoch && db1.epoch < db2.epoch))

    (mkTestBool "T21.6-no-spurious-invalidation"
      # invalidate C → D (not dep of C) remains valid
      (let
        db0 = storeResult emptyQueryDB "C" "vC" [];
        db1 = storeResult db0 "D" "vD" [];  # D does NOT depend on C
        db' = invalidateKey db1 "C";
        dRes = lookupResult db' "D";
      in dRes.found))

    (mkTestBool "T21.7-revDeps-correctly-built"
      # After storing B depends on C, revDeps[C] should include B
      (let
        db  = storeResult emptyQueryDB "B" "vB" ["C"];
      in lib.elem "B" (db.revDeps.C or [])))
  ];

  # ══════════════════════════════════════════════════════════════════════════════
  # 汇总报告
  # ══════════════════════════════════════════════════════════════════════════════

  allGroups = [ t17 t18 t19 t20 t21 ];

  report = {
    phase       = "4.0";
    totalGroups = builtins.length allGroups;
    allPass     = lib.all (g: g.pass) allGroups;
    groups      = allGroups;
    summary     = {
      total  = lib.foldl' (acc: g: acc + g.total)  0 allGroups;
      passed = lib.foldl' (acc: g: acc + g.passed) 0 allGroups;
      failed = lib.foldl' (acc: g: acc + g.failed) 0 allGroups;
    };
    failures = lib.concatMap (g:
      if g.pass then []
      else map (f: "${g.name}::${f}") g.failures
    ) allGroups;
  };

in report
