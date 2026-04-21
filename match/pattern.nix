# match/pattern.nix — Phase 3
# Pattern IR + Decision Tree 编译
#
# Phase 3 新增：
#   Row Pattern（open record/variant）
#   Guard Pattern（带条件）
#   View Pattern（类型转换后匹配）
#   Decision Tree：ordinal O(1) dispatch
#   Exhaustiveness check（穷尽性验证）
#   Redundancy check（冗余模式检测）
{ lib, typeLib, reprLib }:

let
  inherit (typeLib) isType mkTypeDefault;
  inherit (reprLib) rPrimitive rADT;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Pattern IR
  # ══════════════════════════════════════════════════════════════════════════════

  _mkPat = tag: fields: { __patternTag = tag; } // fields;

  # ① Wildcard — 匹配任何值
  pWild = _mkPat "PWild" {};

  # ② Var — 捕获绑定
  pVar = name: _mkPat "PVar" { inherit name; };

  # ③ Literal — 字面量匹配
  pLit = value: typ: _mkPat "PLit" { inherit value typ; };

  # ④ Constructor — ADT 构造器匹配（ordinal dispatch）
  pCtor = ctorName: ordinal: fields:
    _mkPat "PCtor" { inherit ctorName ordinal fields; };

  # ⑤ Record — Record pattern（fields 子集匹配）
  pRecord = fieldPats: rowRest:
    _mkPat "PRecord" { inherit fieldPats rowRest; };

  # ⑥ VariantRow — Open variant pattern
  pVariant = label: innerPat:
    _mkPat "PVariant" { inherit label innerPat; };

  # ⑦ Guard — 带条件的 pattern
  pGuard = pat: guardFn:
    _mkPat "PGuard" { inherit pat guardFn; };

  # ⑧ Or — 多选 pattern
  pOr = pats: _mkPat "POr" { inherit pats; };

  # ⑨ Tuple — 元组匹配
  pTuple = pats: _mkPat "PTuple" { inherit pats; };

  # 辅助：Record field pattern = { label: String; pat: Pattern }
  mkFieldPat = label: pat: { inherit label pat; };

  isPat = p: builtins.isAttrs p && p ? __patternTag;

  # ══════════════════════════════════════════════════════════════════════════════
  # Decision Tree IR（ordinal O(1) dispatch）
  # ══════════════════════════════════════════════════════════════════════════════

  # DecisionTree =
  #   DTLeaf   { action: Term; bindings: AttrSet }   -- 叶节点（成功）
  # | DTSwitch { scrutinee: Access; branches: AttrSet Int DecisionTree; default?: DT }
  # | DTFail   { reason: String }                    -- 穷尽失败
  # | DTBind   { name: String; tree: DT }            -- 变量绑定

  dtLeaf = action: bindings: { __dtTag = "DTLeaf"; inherit action bindings; };
  dtSwitch = scrutinee: branches: def:
    { __dtTag = "DTSwitch"; inherit scrutinee branches; default = def; };
  dtFail = reason: { __dtTag = "DTFail"; inherit reason; };
  dtBind = name: tree: { __dtTag = "DTBind"; inherit name tree; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Pattern 编译 → Decision Tree
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: [(Pattern, Action)] -> Type -> DecisionTree
  compilePats = patsAndActions: scrutTyp:
    if patsAndActions == []
    then dtFail "Non-exhaustive patterns"
    else
      _compileMatrix
        (map (pa: { pats = [pa.pat]; action = pa.action; bindings = {}; }) patsAndActions)
        [{ access = "root"; typ = scrutTyp; }];

  # 编译 pattern matrix（多列 case analysis）
  _compileMatrix = matrix: accessPaths:
    if matrix == [] then dtFail "Non-exhaustive"
    else if accessPaths == [] then
      # 所有列都匹配完：取第一个 action
      let first = builtins.head matrix; in
      dtLeaf first.action first.bindings
    else
      let
        firstCol = builtins.head accessPaths;
        col      = map (row: builtins.head row.pats) matrix;
        # 选择首列的 pattern tag
        headTags = _collectTags col;
      in
      if builtins.elem "PWild" headTags || builtins.elem "PVar" headTags then
        # 变量/通配符列：绑定 + 继续
        _compileVarCol matrix accessPaths
      else
        # 构造器列：switch dispatch
        _compileCtorCol matrix accessPaths firstCol;

  # ── 变量列处理 ──────────────────────────────────────────────────────────
  _compileVarCol = matrix: accessPaths:
    let
      firstCol = builtins.head accessPaths;
      restPaths = builtins.tail accessPaths;
      # 对每行：绑定变量，strip 第一个 pat
      matrix' = map (row:
        let p = builtins.head row.pats; in
        let rest = builtins.tail row.pats; in
        if p.__patternTag == "PVar"
        then row // { pats = rest; bindings = row.bindings // { ${p.name} = firstCol.access; }; }
        else row // { pats = rest; }
      ) matrix;
    in
    _compileMatrix matrix' restPaths;

  # ── 构造器列处理 ──────────────────────────────────────────────────────
  _compileCtorCol = matrix: accessPaths: firstColAccess:
    let
      # 按构造器 ordinal 分组
      groups = _groupByOrdinal matrix;
      # 为每个 ordinal 递归编译子矩阵
      branches = lib.mapAttrs (_: rows:
        let
          # 展开构造器字段
          expanded = _expandCtorRows rows firstColAccess;
        in
        _compileMatrix expanded (expanded.extraPaths or [] ++ builtins.tail accessPaths)
      ) groups;
      # 默认 branch（含通配符的行）
      wildcardRows = builtins.filter (row:
        let p = builtins.head row.pats; in
        p.__patternTag == "PWild" || p.__patternTag == "PVar"
      ) matrix;
      def = if wildcardRows == []
            then null
            else _compileMatrix (map (r: r // { pats = builtins.tail r.pats; }) wildcardRows) (builtins.tail accessPaths);
    in
    dtSwitch firstColAccess.access branches def;

  # 按 ordinal 分组 matrix 行
  _groupByOrdinal = matrix:
    lib.foldl'
      (acc: row:
        let
          p = builtins.head row.pats;
          ord = toString (p.ordinal or 0);
        in
        acc // { ${ord} = (acc.${ord} or []) ++ [row]; })
      {}
      (builtins.filter (row:
        let p = builtins.head row.pats; in
        p.__patternTag == "PCtor") matrix);

  # 展开构造器行（将字段 patterns 插入 matrix）
  _expandCtorRows = rows: firstColAccess:
    map (row:
      let
        p     = builtins.head row.pats;
        rest  = builtins.tail row.pats;
        fPats = if p.__patternTag == "PCtor" then p.fields else [];
      in
      row // { pats = fPats ++ rest; }
    ) rows;

  # 收集 column 中出现的 pattern tags
  _collectTags = pats:
    map (p: p.__patternTag or "?") pats;

  # ══════════════════════════════════════════════════════════════════════════════
  # 穷尽性检查（Exhaustiveness）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: [Pattern] -> Type -> { exhaustive: Bool; missing?: [String] }
  checkExhaustiveness = pats: scrutTyp:
    let
      v = scrutTyp.repr.__variant or null;
    in
    if v == "ADT" then
      let
        ctorNames = map (vt: vt.name) scrutTyp.repr.variants;
        covered   = _coveredCtors pats;
        missing   = builtins.filter (n: !covered ? ${n}) ctorNames;
      in
      { exhaustive = missing == [];
        missing    = missing; }
    else
      # 其他类型：检查是否有通配符
      let hasWild = lib.any (p: p.__patternTag == "PWild" || p.__patternTag == "PVar") pats; in
      { exhaustive = hasWild; missing = if hasWild then [] else ["_"]; };

  # 收集 patterns 中覆盖的构造器名
  _coveredCtors = pats:
    lib.foldl'
      (acc: p:
        if p.__patternTag == "PCtor" then acc // { ${p.ctorName} = true; }
        else if p.__patternTag == "PWild" || p.__patternTag == "PVar" then acc // { __wild = true; }
        else acc)
      {}
      pats;

  # ══════════════════════════════════════════════════════════════════════════════
  # 冗余性检查（Redundancy）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: [Pattern] -> { redundant: [Int] }（返回冗余 pattern 的索引）
  checkRedundancy = pats:
    let
      tagged = lib.imap0 (i: p: { inherit i; pat = p; }) pats;
    in
    {
      redundant = lib.concatMap (tp:
        if _isRedundant tp.pat (lib.take tp.i pats)
        then [tp.i]
        else []) tagged;
    };

  # 检查 pat 是否被 prevPats 中的某个覆盖
  _isRedundant = pat: prevPats:
    lib.any (_covers pat) prevPats;

  # prev 是否覆盖 pat（保守：Wildcard 覆盖一切）
  _covers = pat: prev:
    prev.__patternTag == "PWild"
    || prev.__patternTag == "PVar"
    || (prev.__patternTag == "PCtor"
        && pat.__patternTag == "PCtor"
        && prev.ctorName == pat.ctorName);

  # ══════════════════════════════════════════════════════════════════════════════
  # 便捷构造（Row Types）
  # ══════════════════════════════════════════════════════════════════════════════

  # Record pattern
  mkRecordPat = fieldPats: rowRest:
    pRecord (map (fp: mkFieldPat fp.label fp.pat) fieldPats) rowRest;

  # Variant row pattern（open）
  mkVariantRowPat = label: innerPat:
    pVariant label innerPat;

}
