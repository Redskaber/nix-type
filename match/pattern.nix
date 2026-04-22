# match/pattern.nix — Phase 4.2
# Pattern Matching + Decision Tree 编译器（合并版）
# Pattern → Decision Tree（ordinal O(1) dispatch）
{ lib, typeLib, reprLib, kindLib }:

let
  inherit (typeLib) isType;

in rec {

  # ══ Pattern IR ════════════════════════════════════════════════════════
  # Pattern =
  #   PWild                       # 通配符
  # | PVar String                 # 变量绑定
  # | PCtor String [Pattern]      # 构造器模式
  # | PLit Any                    # 字面量模式
  # | PAnd Pattern Pattern        # AND 模式（@ 绑定）
  # | PGuard Pattern Expr         # 守卫模式

  mkPWild  = { __patTag = "Wild"; };
  mkPVar   = name: { __patTag = "Var"; name = name; };
  mkPCtor  = name: fields: { __patTag = "Ctor"; name = name; fields = fields; };
  mkPLit   = value: { __patTag = "Lit"; value = value; };
  mkPAnd   = p1: p2: { __patTag = "And"; p1 = p1; p2 = p2; };
  mkPGuard = pat: guard: { __patTag = "Guard"; pat = pat; guard = guard; };
  mkPRecord = fields: { __patTag = "Record"; fields = fields; };

  isPattern = p: builtins.isAttrs p && p ? __patTag;
  isWild    = p: isPattern p && p.__patTag == "Wild";
  isVar     = p: isPattern p && p.__patTag == "Var";
  isCtor    = p: isPattern p && p.__patTag == "Ctor";
  isLit     = p: isPattern p && p.__patTag == "Lit";

  # ══ Match Arm（模式 + 分支体）══════════════════════════════════════════
  # Type: Pattern → Any(body) → MatchArm
  mkArm = pat: body: { __armTag = "Arm"; pat = pat; body = body; };

  # ══ Decision Tree IR ══════════════════════════════════════════════════
  # DTree =
  #   DTLeaf { body }                      # 匹配成功
  # | DTFail                               # 匹配失败
  # | DTSwitch { scrutinee; branches; default }  # ordinal switch
  # | DTGuard { guard; yes; no }           # 守卫条件

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
        # Wild/Var: always matches，绑定变量
        let
          bindings = if tag == "Var" then { ${pat.name} = "__scrutinee"; } else {};
        in
        mkDTLeaf bindings firstArm.body
      else if tag == "Lit" then
        # Literal match
        mkDTSwitch "__scrutinee"
          { ${builtins.toJSON pat.value} = mkDTLeaf {} firstArm.body; }
          (compileMatch restArms adtVariants)
      else if tag == "Ctor" then
        # 构造器模式：按 ordinal O(1) dispatch
        let
          ctorOrdinal = _lookupOrdinal adtVariants pat.name;
          ctorKey     = builtins.toString ctorOrdinal;
          # 编译子模式（fields）
          fieldArms   = if pat.fields == [] then [ (mkArm mkPWild firstArm.body) ]
            else
              let innerArm = mkArm (builtins.head pat.fields) firstArm.body; in
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
        # Record 模式：展开字段
        mkDTLeaf pat.fields firstArm.body
      else
        mkDTFail;

  # ── ordinal 查找（O(1) dispatch）────────────────────────────────────
  _lookupOrdinal = adtVariants: ctorName:
    let variant = lib.findFirst (v: v.name == ctorName) null adtVariants; in
    if variant != null then variant.ordinal else -1;

  # ══ 穷尽性检查（Exhaustiveness）══════════════════════════════════════
  # Type: [MatchArm] → ADT → { exhaustive: Bool; missing: [String] }
  checkExhaustive = arms: adtVariants:
    let
      ctorsCovered = lib.concatMap (arm:
        let pat = arm.pat; in
        if (pat.__patTag or null) == "Ctor" then [ pat.name ]
        else if (pat.__patTag or null) == "Wild" || (pat.__patTag or null) == "Var" then
          map (v: v.name) adtVariants  # covers all
        else []
      ) arms;
      allCtors = map (v: v.name) adtVariants;
      missing  = lib.filter (c: !(builtins.elem c ctorsCovered)) allCtors;
    in
    { exhaustive = missing == []; missing = missing; };

  # ══ Pattern 变量提取 ══════════════════════════════════════════════════
  patternVars = pat:
    let tag = pat.__patTag or null; in
    if tag == "Var" then [ pat.name ]
    else if tag == "Ctor" then lib.concatMap patternVars pat.fields
    else if tag == "And" then patternVars pat.p1 ++ patternVars pat.p2
    else if tag == "Guard" then patternVars pat.pat
    else if tag == "Record" then builtins.attrNames pat.fields
    else [];
}
