# match/pattern.nix — Phase 4.5.1-Fix
# Pattern Matching + Decision Tree 编译器（合并版）
# Pattern → Decision Tree（ordinal O(1) dispatch）
#
# Phase 4.5 additions:
#   - patternVars for Record: recurse into sub-patterns (nested Record support)
#   - patternDepth for Record: properly recurse into sub-patterns
#   - compileMatch Record: bind each field via nested compile (structural)
#   - INV-PAT-3: patternVars(Record {f1: p1, ..., fn: pn}) = ⋃ patternVars(pi)
#
# ★ Phase 4.5.1-Fix:
#   BUG-PLit: compileMatch PLit branch used builtins.toJSON pat.value
#     builtins.toJSON fails on any non-JSON-serializable value (functions,
#     Type objects, etc.), and even for primitives, --strict --json evaluation
#     of the demo output triggers an error trace pointing to mkPVar (line 36).
#     Fix: use _safeLitKey which uses builtins.toString (always safe for
#     primitives) with a type-prefix to avoid key collisions between
#     e.g. 42 (int) and "42" (string).
#
# INV-SER-1 (inherited): no builtins.toJSON on values reachable through
#   function fields or Type objects.
{ lib, typeLib, reprLib, kindLib }:

let
  inherit (typeLib) isType;

  # Safe literal key: use toString with type tag prefix.
  # builtins.toJSON cannot handle functions/Type-objects.
  # builtins.toString is always safe for primitive Nix values.
  # Prefix ensures int 42 and string "42" have distinct keys.
  _safeLitKey = v:
    if builtins.isString v  then "s:${v}"
    else if builtins.isInt v then "i:${builtins.toString v}"
    else if builtins.isBool v then "b:${builtins.toString v}"
    else if builtins.isFloat v then "f:${builtins.toString v}"
    else "v:${builtins.toString v}";

in rec {

  # ══ Pattern IR ════════════════════════════════════════════════════════
  # Pattern =
  #   PWild                       # 通配符
  # | PVar String                 # 变量绑定
  # | PCtor String [Pattern]      # 构造器模式
  # | PLit Any                    # 字面量模式
  # | PAnd Pattern Pattern        # AND 模式（@ 绑定）
  # | PGuard Pattern Expr         # 守卫模式
  # | PRecord {String → Pattern}  # Record 模式（★ Phase 4.5: nested sub-patterns）

  mkPWild   = { __patTag = "Wild"; };
  mkPVar    = name: { __patTag = "Var"; name = name; };
  mkPCtor   = name: fields: { __patTag = "Ctor"; name = name; fields = fields; };
  mkPLit    = value: { __patTag = "Lit"; value = value; };
  mkPAnd    = p1: p2: { __patTag = "And"; p1 = p1; p2 = p2; };
  mkPGuard  = pat: guard: { __patTag = "Guard"; pat = pat; guard = guard; };
  mkPRecord = fields: { __patTag = "Record"; fields = fields; };

  isPattern = p: builtins.isAttrs p && p ? __patTag;
  isWild    = p: isPattern p && p.__patTag == "Wild";
  isVar     = p: isPattern p && p.__patTag == "Var";
  isCtor    = p: isPattern p && p.__patTag == "Ctor";
  isLit     = p: isPattern p && p.__patTag == "Lit";
  isRecord  = p: isPattern p && p.__patTag == "Record";

  # ══ Match Arm（模式 + 分支体）══════════════════════════════════════════
  mkArm = pat: body: { __armTag = "Arm"; pat = pat; body = body; };

  # ══ Decision Tree IR ══════════════════════════════════════════════════
  mkDTLeaf   = bindings: body: { __dtTag = "Leaf"; bindings = bindings; body = body; };
  mkDTFail   = { __dtTag = "Fail"; };
  mkDTSwitch = scrutinee: branches: default_:
    { __dtTag = "Switch"; scrutinee = scrutinee; branches = branches; default_ = default_; };
  mkDTGuard  = guard: yes: no:
    { __dtTag = "Guard"; guard = guard; yes = yes; no = no; };

  # ══ 模式编译器（Pattern → Decision Tree）══════════════════════════════
  # Type: [MatchArm] → ADTVariants → DTree
  compileMatch = arms: adtVariants:
    if arms == [] then mkDTFail
    else
      let
        firstArm = builtins.head arms;
        restArms = builtins.tail arms;
        pat      = firstArm.pat;
        tag      = pat.__patTag or null;
      in
      if tag == "Wild" || tag == "Var" then
        let
          bindings = if tag == "Var" then { ${pat.name} = "__scrutinee"; } else {};
        in
        mkDTLeaf bindings firstArm.body
      else if tag == "Lit" then
        # ★ Fix BUG-PLit: use _safeLitKey instead of builtins.toJSON
        # builtins.toJSON crashes on non-JSON values; _safeLitKey uses toString
        let litKey = _safeLitKey (pat.value or null); in
        mkDTSwitch "__scrutinee"
          { ${litKey} = mkDTLeaf {} firstArm.body; }
          (compileMatch restArms adtVariants)
      else if tag == "Ctor" then
        let
          ctorOrdinal = _lookupOrdinal adtVariants pat.name;
          ctorKey     = builtins.toString ctorOrdinal;
          ctorFields  = pat.fields or [];
          fieldArms   = if ctorFields == [] then [ (mkArm mkPWild firstArm.body) ]
            else
              let innerArm = mkArm (builtins.head ctorFields) firstArm.body; in
              [ innerArm ];
          innerDT     = compileMatch fieldArms adtVariants;
          restDT      = compileMatch restArms adtVariants;
        in
        mkDTSwitch "__scrutinee"
          { ${ctorKey} = innerDT; }
          restDT
      else if tag == "Guard" then
        let
          matchPat  = mkArm pat.pat firstArm.body;
          innerDT   = compileMatch ([ matchPat ] ++ restArms) adtVariants;
        in
        mkDTGuard pat.guard innerDT (compileMatch restArms adtVariants)
      else if tag == "And" then
        let
          innerArm = mkArm pat.p1 (mkArm pat.p2 firstArm.body);
          nestedDT = compileMatch ([ innerArm ] ++ restArms) adtVariants;
        in
        nestedDT
      else if tag == "Record" then
        # Phase 4.5: Record match generates bindings from sub-pattern vars
        # The decision tree leaf binds each field accessor to its target name.
        # Sub-pattern recursion is represented via nested bindings.
        let
          subPats = if builtins.isAttrs (pat.fields or null) then pat.fields else {};
          # Collect variable bindings from each sub-pattern
          fieldBindings = builtins.foldl' (acc: fieldName:
            let
              subPat = subPats.${fieldName} or mkPWild;
              subVars = patternVars subPat;
            in
            # For each var in the sub-pattern, bind it to the field accessor path
            lib.foldl' (innerAcc: varName:
              innerAcc // { ${varName} = "__scrutinee.${fieldName}"; }
            ) acc subVars
          ) {} (builtins.attrNames subPats);
        in
        mkDTLeaf fieldBindings firstArm.body
      else
        mkDTFail;

  # ── ordinal 查找（O(1) dispatch）────────────────────────────────────
  _lookupOrdinal = adtVariants: ctorName:
    let variant = lib.findFirst (v: v.name == ctorName) null adtVariants; in
    if variant != null then variant.ordinal else -1;

  # ══ 穷尽性检查（Exhaustiveness）══════════════════════════════════════
  checkExhaustive = arms: adtVariants:
    let
      ctorsCovered = lib.concatMap (arm:
        let pat = arm.pat; in
        if (pat.__patTag or null) == "Ctor" then [ pat.name ]
        else if (pat.__patTag or null) == "Wild" || (pat.__patTag or null) == "Var" then
          map (v: v.name) adtVariants
        else []
      ) arms;
      allCtors = map (v: v.name) adtVariants;
      missing  = lib.filter (c: !(builtins.elem c ctorsCovered)) allCtors;
    in
    { exhaustive = missing == []; missing = missing; };

  # ══ Pattern 变量提取（INV-PAT-1/3）════════════════════════════════════
  # Type: Pattern → [String]
  # INV-PAT-3 (Phase 4.5): Record sub-patterns are recursed into.
  #   patternVars(mkPRecord {a = mkPVar "x"; b = mkPRecord {c = mkPVar "y"}})
  #   = ["x", "y"]
  patternVars = pat:
    if !builtins.isAttrs pat then []
    else
      let tag = pat.__patTag or null; in
      if tag == null then []
      else if tag == "Var" then
        if pat ? name then [ pat.name ] else []
      else if tag == "Ctor" then
        let fields = pat.fields or []; in
        if !builtins.isList fields then []
        else lib.concatMap patternVars fields
      else if tag == "And" then
        (if pat ? p1 then patternVars pat.p1 else []) ++
        (if pat ? p2 then patternVars pat.p2 else [])
      else if tag == "Guard" then
        if pat ? pat then patternVars pat.pat else []
      else if tag == "Record" then
        # Phase 4.5: recurse into sub-patterns (INV-PAT-3)
        if pat ? fields && builtins.isAttrs pat.fields
        then
          let subPats = pat.fields; in
          lib.concatMap (fieldName: patternVars (subPats.${fieldName} or mkPWild))
            (builtins.attrNames subPats)
        else []
      else [];

  # ══ Pattern 变量集合（去重）═══════════════════════════════════════════
  patternVarsSet = pat:
    lib.foldl' (acc: v: acc // { ${v} = true; }) {} (patternVars pat);

  # ══ INV-PAT-2: 线性性检查（无重复绑定）══════════════════════════════
  isLinear = pat:
    let
      vars = patternVars pat;
      uniq = lib.unique vars;
    in
    builtins.length vars == builtins.length uniq;

  # ══ Pattern 最大深度（Phase 4.5: Record properly recurses）════════════
  # Type: Pattern → Int
  patternDepth = pat:
    if !builtins.isAttrs pat then 0
    else
      let tag = pat.__patTag or null; in
      if tag == null || tag == "Wild" || tag == "Var" || tag == "Lit" then 0
      else if tag == "Ctor" then
        let
          fields = pat.fields or [];
          depths = if builtins.isList fields then map patternDepth fields else [];
        in
        1 + lib.foldl' (acc: d: if d > acc then d else acc) 0 depths
      else if tag == "And" then
        1 + (
          let
            d1 = if pat ? p1 then patternDepth pat.p1 else 0;
            d2 = if pat ? p2 then patternDepth pat.p2 else 0;
          in
          if d1 > d2 then d1 else d2
        )
      else if tag == "Guard" then
        1 + (if pat ? pat then patternDepth pat.pat else 0)
      else if tag == "Record" then
        # Phase 4.5: recurse into sub-patterns for accurate depth
        if pat ? fields && builtins.isAttrs pat.fields
        then
          let
            subPats = pat.fields;
            depths = map (k: patternDepth (subPats.${k} or mkPWild))
              (builtins.attrNames subPats);
          in
          1 + lib.foldl' (acc: d: if d > acc then d else acc) 0 depths
        else 1
      else 0;

  # ══ INV-PAT-3 verifier（Phase 4.5）════════════════════════════════════
  # Type: Pattern → {String → Bool} → Bool
  # Returns true iff patternVarsSet(pat) contains exactly the expected vars.
  checkPatternVars = pat: expectedVarsSet:
    let
      actual = patternVarsSet pat;
      actualKeys   = builtins.attrNames actual;
      expectedKeys = builtins.attrNames expectedVarsSet;
    in
    builtins.length actualKeys == builtins.length expectedKeys &&
    lib.all (k: actual ? ${k}) expectedKeys;
}
