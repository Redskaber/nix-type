# match/pattern.nix — Phase 4.1
# Pattern Matching + Decision Tree 编译器
# 合并原 match/pattern.nix + match/pattern_p33.nix
# Pattern → Decision Tree → O(1) ordinal dispatch
{ lib, typeLib, reprLib, kindLib }:

let
  inherit (typeLib) isType mkTypeDefault;
  inherit (reprLib) rADT mkVariant;
  inherit (kindLib) KStar;

in rec {

  # ══ Pattern IR ═════════════════════════════════════════════════════════════

  # 构造器模式（匹配 ADT variant）
  mkPatConstructor = variantName: subPatterns: guard:
    { __patTag    = "Constructor";
      variantName = variantName;
      subPatterns = subPatterns;  # [Pattern]
      guard       = guard;        # PredExpr | null
    };

  # 变量绑定模式（always match，绑定值）
  mkPatVar = name:
    { __patTag = "Var"; name = name; };

  # 通配符（always match，不绑定）
  mkPatWildcard =
    { __patTag = "Wildcard"; };

  # 字面量模式
  mkPatLiteral = value:
    { __patTag = "Literal"; value = value; };

  # OR 模式（p1 | p2）
  mkPatOr = left: right:
    { __patTag = "Or"; inherit left right; };

  # Tuple/Record 模式
  mkPatRecord = fields:
    { __patTag = "Record"; inherit fields; };

  # ── Pattern 谓词 ──────────────────────────────────────────────────────────
  isPat         = p: builtins.isAttrs p && p ? __patTag;
  isPatCtor     = p: isPat p && p.__patTag == "Constructor";
  isPatVar      = p: isPat p && p.__patTag == "Var";
  isPatWildcard = p: isPat p && p.__patTag == "Wildcard";
  isPatLiteral  = p: isPat p && p.__patTag == "Literal";
  isPatOr       = p: isPat p && p.__patTag == "Or";
  isPatRecord   = p: isPat p && p.__patTag == "Record";

  # ══ Match Arm ══════════════════════════════════════════════════════════════

  # Type: Pattern -> Any(body) -> MatchArm
  mkArm = pattern: body: { inherit pattern body; };

  # ══ Decision Tree（编译目标）═══════════════════════════════════════════════

  # DTLeaf: 匹配成功，执行 body
  mkDTLeaf = body: bindings:
    { __dtTag = "Leaf"; inherit body bindings; };

  # DTFail: 匹配失败
  mkDTFail =
    { __dtTag = "Fail"; };

  # DTSwitch: 按 ordinal dispatch（O(1)）
  mkDTSwitch = scrutinee: cases: defaultCase:
    { __dtTag   = "Switch";
      inherit scrutinee cases defaultCase; };
  # cases: AttrSet(ordinal:String -> DecisionTree)

  # DTGuard: 带 guard 的条件跳转
  mkDTGuard = guard: thenBranch: elseBranch:
    { __dtTag   = "Guard";
      inherit guard thenBranch elseBranch; };

  # DTBind: 变量绑定
  mkDTBind = varName: source: continuation:
    { __dtTag   = "Bind";
      inherit varName source continuation; };

  # ══ Decision Tree 编译器 ════════════════════════════════════════════════════

  # Type: [MatchArm] -> ADT Type -> DecisionTree
  # 将 arms 列表编译为 Decision Tree
  compileMatch = arms: scrutineeType:
    if arms == [] then mkDTFail
    else
      let
        firstArm = builtins.head arms;
        restArms = builtins.tail arms;
        pat      = firstArm.pattern;
        body     = firstArm.body;
      in
      _compilePat pat body restArms;

  # 按模式类型分发编译策略
  _compilePat = pat: body: restArms:
    if isPatWildcard pat || isPatVar pat then
      # 通配符/变量：always match
      let
        leaf = mkDTLeaf body
          (if isPatVar pat then [ { var = pat.name; source = "scrutinee"; } ] else []);
      in leaf  # 后续 restArms 不可达（警告：可选，Phase 4.x）

    else if isPatLiteral pat then
      # 字面量：guard 形式
      let
        guard    = { __predTag = "PCmp"; op = "eq";
                     lhs = { __predTag = "PVar"; name = "_scrutinee_"; };
                     rhs = { __predTag = "PLit"; value = pat.value; }; };
        thenBranch = mkDTLeaf body [];
        elseBranch = compileMatch restArms null;
      in mkDTGuard guard thenBranch elseBranch

    else if isPatCtor pat then
      # 构造器：按 ordinal dispatch
      _compileCtor pat body restArms

    else if isPatOr pat then
      # OR 模式：编译两个分支
      let
        left  = mkArm pat.left body;
        right = mkArm pat.right body;
      in compileMatch ([ left right ] ++ restArms) null

    else if isPatRecord pat then
      # Record 模式：依次检查各字段
      _compileRecord pat body restArms

    else
      # 未知模式：fallthrough
      mkDTLeaf body [];

  # 构造器模式编译（ordinal-based switch）
  _compileCtor = pat: body: restArms:
    let
      # 收集所有处理相同 variant 的 arm
      sameVariant = lib.filter (arm:
        isPatCtor arm.pattern && arm.pattern.variantName == pat.variantName
      ) restArms;
      otherArms = lib.filter (arm:
        !(isPatCtor arm.pattern && arm.pattern.variantName == pat.variantName)
      ) restArms;

      # 当前 arm 的 body（含子模式）
      subDT = _compileSubPatterns (pat.subPatterns or []) body;

      # 带 guard
      patDT = if pat.guard == null then subDT
              else mkDTGuard pat.guard subDT mkDTFail;

      # 构建 switch case（按 ordinal）
      ordinalStr = builtins.toString (pat.ordinal or 0);

      # 编译 default（其他模式）
      defaultDT = compileMatch otherArms null;
    in
    mkDTSwitch "_scrutinee_"
      { ${ordinalStr} = patDT; }
      defaultDT;

  # 子模式编译（按位置 bind）
  _compileSubPatterns = subPats: body:
    if subPats == [] then mkDTLeaf body []
    else
      let
        indexed = lib.imap0 (i: p:
          { idx = i; pat = p; source = "_field_${builtins.toString i}"; }
        ) subPats;
        # 依次 bind 各字段
        go = acc: item:
          let
            p = item.pat;
            src = item.source;
          in
          if isPatVar p then
            mkDTBind p.name src acc
          else if isPatWildcard p then acc
          else acc;  # 简化：嵌套模式 Phase 4.x 完善
      in lib.foldl' go (mkDTLeaf body []) (lib.reverseList indexed);

  # Record 模式编译
  _compileRecord = pat: body: restArms:
    let
      fieldNames = builtins.attrNames (pat.fields or {});
      # 将字段模式转为 bindings
      bindings = map (n: { var = n; source = "_field_${n}"; }) fieldNames;
    in mkDTLeaf body bindings;

  # ══ Pattern 合法性检查（静态穷尽性 — 简化版）══════════════════════════════

  # Type: [MatchArm] -> ADT Type -> { exhaustive: Bool; missing: [String] }
  checkExhaustive = arms: adtType:
    let
      variantNames = if isType adtType && (adtType.repr.__variant or null) == "ADT"
                     then map (v: v.name) (adtType.repr.variants or [])
                     else [];
      coveredVariants = lib.concatMap (arm:
        let p = arm.pattern; in
        if isPatCtor p then [ p.variantName ]
        else if isPatWildcard p || isPatVar p then variantNames  # covers all
        else []
      ) arms;
      missing = lib.filter (v: !builtins.elem v coveredVariants) variantNames;
    in
    { exhaustive = missing == [];
      missing    = missing; };
}
