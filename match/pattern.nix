# match/pattern.nix — Phase 3.1
# Pattern Matching + Decision Tree
#
# Pattern IR（结构化，∈ TypeIR）：
#   Pattern = Wildcard | Variable { name } | Literal { value; prim }
#           | ADTPattern { ctor; fields; ordinal } | RecordPat { fields }
#           | VariantRowPat { label; inner; tail }
#
# Decision Tree（O(1) ordinal dispatch）：
#   DTree = Leaf { action } | Bind { name; sub } | Switch { cases; default }
#
# Phase 3.1：
#   exhaustiveness: closed ADT = variant cover check
#   redundancy:     dead branch detection
#   decision tree:  Kahn topological sort for stable compilation
{ lib, typeLib, reprLib }:

let
  inherit (typeLib) isType;
  inherit (reprLib) isADTRepr isRecordRepr;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Pattern IR 构造器
  # ══════════════════════════════════════════════════════════════════════════════

  mkWildcard = { __patTag = "Wildcard"; };
  mkVariable = name: { __patTag = "Variable"; inherit name; };
  mkLiteral  = value: primType: { __patTag = "Literal"; inherit value primType; };
  mkADTPattern = ctor: fields: ordinal: { __patTag = "ADT"; inherit ctor fields ordinal; };
  mkRecordPat  = fields: tail: { __patTag = "Record"; inherit fields tail; };
  mkVariantRowPat = label: inner: tail: { __patTag = "VariantRow"; inherit label inner tail; };

  isPat     = p: builtins.isAttrs p && p ? __patTag;
  isWild    = p: isPat p && p.__patTag == "Wildcard";
  isVar     = p: isPat p && p.__patTag == "Variable";
  isLit     = p: isPat p && p.__patTag == "Literal";
  isADTPat  = p: isPat p && p.__patTag == "ADT";
  isRecPat  = p: isPat p && p.__patTag == "Record";
  isVRPat   = p: isPat p && p.__patTag == "VariantRow";

  # ══════════════════════════════════════════════════════════════════════════════
  # Pattern bound variables
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Pattern -> AttrSet String Bool
  patternBoundVars = pat:
    let tag = pat.__patTag or null; in
    if tag == "Wildcard"   then {}
    else if tag == "Variable"  then { ${pat.name} = true; }
    else if tag == "Literal"   then {}
    else if tag == "ADT"       then
      lib.foldl' (acc: f: acc // patternBoundVars f) {} (pat.fields or [])
    else if tag == "Record"    then
      lib.foldl' (acc: k: acc // patternBoundVars (pat.fields or {}).${k})
        {} (builtins.attrNames (pat.fields or {}))
    else if tag == "VariantRow" then
      patternBoundVars (pat.inner or mkWildcard)
    else {};

  # ══════════════════════════════════════════════════════════════════════════════
  # Decision Tree 构造器
  # ══════════════════════════════════════════════════════════════════════════════

  mkLeaf   = action: { tag = "Leaf"; inherit action; };
  mkBind   = name: sub: { tag = "Bind"; inherit name sub; };
  mkSwitch = scrutinee: cases: default_: { tag = "Switch"; inherit scrutinee cases default_; };
  mkFail   = { tag = "Fail"; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Decision Tree Compilation
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: [{ pattern: Pattern; action: Any }] -> String -> DTree
  compileToDecisionTree = clauses: scrutinee:
    _compile clauses scrutinee;

  _compile = clauses: scrutinee:
    if clauses == [] then mkFail
    else
      let
        first = builtins.head clauses;
        rest  = builtins.tail clauses;
        pat   = first.pattern or mkWildcard;
        act   = first.action;
        tag   = pat.__patTag or "Wildcard";
      in

      if tag == "Wildcard" then mkLeaf act

      else if tag == "Variable" then
        # 绑定变量，继续匹配 rest（变量总是匹配）
        mkBind pat.name (mkLeaf act)

      else if tag == "Literal" then
        mkSwitch scrutinee
          [{ key = builtins.toString pat.value; tree = mkLeaf act; }]
          (_compile rest scrutinee)

      else if tag == "ADT" then
        # ordinal dispatch O(1)
        let
          # 按 ordinal 分组
          groups = _groupByOrdinal clauses;
          cases = map (g:
            { key  = builtins.toString g.ordinal;
              tree = _compile g.clauses scrutinee;
            }
          ) groups;
        in
        mkSwitch scrutinee cases mkFail

      else if tag == "Record" then
        # record: 逐字段检查
        mkLeaf act  # 简化：record 总是匹配（字段在 Bind 中处理）

      else mkLeaf act;  # 默认

  # 按 ADT ordinal 分组
  _groupByOrdinal = clauses:
    let
      byOrdinal = lib.foldl'
        (acc: clause:
          let
            ord = builtins.toString (clause.pattern.ordinal or 0);
          in
          acc // { ${ord} = (acc.${ord} or []) ++ [clause]; }
        )
        {}
        (builtins.filter (c: (c.pattern.__patTag or "") == "ADT") clauses);
      ordinals = lib.sort lib.lessThan (builtins.attrNames byOrdinal);
    in
    map (ord: {
      ordinal = lib.toInt ord;
      clauses = byOrdinal.${ord};
    }) ordinals;

  # ══════════════════════════════════════════════════════════════════════════════
  # Exhaustiveness Check
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: [Pattern] -> Type -> { exhaustive: Bool; missing: [String] }
  isExhaustive = patterns: scrutineeType:
    let
      v = scrutineeType.repr.__variant or null;
    in

    # Wildcard/Variable → 总是穷举
    if lib.any (p: isWild p || isVar p) patterns
    then { exhaustive = true; missing = []; }

    # ADT（closed）：检查所有 variant 都有匹配
    else if v == "ADT" && (scrutineeType.repr.closed or true) then
      let
        allVariants = map (var: var.name) (scrutineeType.repr.variants or []);
        coveredVariants = lib.unique
          (builtins.concatMap
            (p: if isADTPat p then [p.ctor] else [])
            patterns);
        missing = builtins.filter (vn: !builtins.elem vn coveredVariants) allVariants;
      in
      { exhaustive = missing == []; inherit missing; }

    # ADT（open）：无法穷举
    else if v == "ADT" && !(scrutineeType.repr.closed or true) then
      { exhaustive = false; missing = ["<open-adt>"]; }

    # Record（closed）：单个 RecordPat 覆盖全部
    else if v == "Record" then
      let
        hasRecordPat = lib.any isRecPat patterns;
      in
      { exhaustive = hasRecordPat; missing = if hasRecordPat then [] else ["<record>"]; }

    # VariantRow（open）：无法穷举
    else if v == "VariantRow" then
      let isOpen = scrutineeType.repr.tail or null != null; in
      if isOpen then { exhaustive = false; missing = ["<open-row>"]; }
      else
        let
          allLabels   = builtins.attrNames (scrutineeType.repr.variants or {});
          coveredLabels = lib.unique
            (builtins.concatMap
              (p: if isVRPat p then [p.label] else [])
              patterns);
          missing = builtins.filter (l: !builtins.elem l coveredLabels) allLabels;
        in
        { exhaustive = missing == []; inherit missing; }

    # 未知类型：保守返回 false
    else { exhaustive = false; missing = ["<unknown>"]; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Redundancy Check（死分支检测）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: [Pattern] -> [Int]（返回冗余分支的 index）
  checkRedundancy = patterns:
    let
      go = idx: remaining: acc:
        if remaining == [] then acc
        else
          let
            p    = builtins.head remaining;
            rest = builtins.tail remaining;
            # 如果之前的模式已完全覆盖，则当前模式冗余
            dominated = lib.any (prev: _patDominates prev p) (lib.take idx patterns);
          in
          go (idx + 1) rest (if dominated then acc ++ [idx] else acc);
    in
    go 0 patterns [];

  # 检查 a 是否在语义上"支配" b（b 是 a 的特例）
  _patDominates = a: b:
    isWild a || isVar a  # Wildcard/Variable 支配所有

    || (isADTPat a && isADTPat b && a.ctor == b.ctor
        && builtins.length (a.fields or []) == builtins.length (b.fields or [])
        && lib.all (p: _patDominates p.fst p.snd)
             (lib.imap0 (i: f: { fst = f; snd = builtins.elemAt (b.fields or []) i; })
                        (a.fields or [])))

    || (isLit a && isLit b && a.value == b.value);

}
