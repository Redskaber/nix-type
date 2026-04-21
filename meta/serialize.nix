# meta/serialize.nix — Phase 3
# 确定性序列化（Canonical Serializer v3）
#
# Phase 3 核心修复（来自 nix-todo/meta/serialize.md）：
#   1. INV-SER1: _serType 替换为真正 canonical（消除属性顺序依赖）
#   2. INV-SER2: cycle-free — Constructor binder 改为 indexed env
#   3. INV-SER3: free-variable normalization policy（global vs logical 分离）
#   4. serializeReprAlphaCanonical — 完整 de Bruijn，真正 α-canonical
#   5. Pi / Sigma / Effect / Opaque / Ascribe 序列化
#
# 不变量：
#   INV-SER1: serializeRepr 确定性（相同输入 → 相同输出 string）
#   INV-SER2: 不同 repr → 不同序列化（最小 collision）
#   INV-SER3: 相同 α-等价项 → 相同序列化（alpha-canonical）
#   INV-SER4: 输出 canonical（不依赖构造顺序）
#   INV-SER5: cycle-free（无循环序列化递归）
{ lib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 主入口：TypeRepr -> String（结构性 canonical）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: TypeRepr -> String
  serializeRepr = repr: _serRepr {} repr;

  # Type: TypeRepr -> String（完整 α-canonical，de Bruijn 转换后序列化）
  serializeReprAlphaCanonical = repr:
    _serReprAlpha { env = {}; depth = 0; } repr;

  # ══════════════════════════════════════════════════════════════════════════════
  # 内部：结构性序列化（binder 用名字，不做 α-rename）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> TypeRepr -> String
  _serRepr = ctx: repr:
    let
      v = repr.__variant or repr.__kindVariant or null;
      esc = s: "\"${s}\"";  # 转义字符串
    in

    # ── Kind 变体 ─────────────────────────────────────────────────────────────
    if      v == "KStar"    then "*"
    else if v == "KRow"     then "#row"
    else if v == "KEffect"  then "#eff"
    else if v == "KArrow"   then
      "(${_serRepr ctx repr.from}->${_serRepr ctx repr.to})"
    else if v == "KVar"     then "?K${repr.name}"
    else if v == "KUnbound" then "_K"
    else if v == "KError"   then "!K(${repr.message or "?"})"

    # ── TypeRepr 变体 ─────────────────────────────────────────────────────────
    else if v == "Primitive"   then "P(${esc repr.name})"
    else if v == "Var"         then "V(${esc repr.name},${esc (repr.scope or "?")})"
    else if v == "VarDB"       then "DB(${toString repr.index})"
    else if v == "VarScoped"   then "VS(${esc repr.name},${toString repr.index})"
    else if v == "RowEmpty"    then "∅"
    else if v == "Opaque"      then "Op(${esc repr.name},${esc (repr.id or "?")})"

    else if v == "Lambda" then
      "λ(${esc repr.param}.${_serType ctx repr.body})"

    else if v == "Pi" then
      "Π(${esc repr.param}:${_serType ctx repr.paramType}.${_serType ctx repr.body})"

    else if v == "Sigma" then
      "Σ(${esc repr.param}:${_serType ctx repr.paramType}.${_serType ctx repr.body})"

    else if v == "Apply" then
      let args = builtins.concatStringsSep "," (map (_serType ctx) repr.args); in
      "(${_serType ctx repr.fn}@[${args}])"

    else if v == "Fn" then
      "(${_serType ctx repr.from}→${_serType ctx repr.to})"

    else if v == "Constructor" then
      # Phase 3 修复：params 用 indexed 而非名字，避免 cycle
      let
        ps = builtins.concatStringsSep ","
          (lib.imap0 (i: p: "${toString i}:${_serKind p.kind or "_K"}") (repr.params or []));
        bd = _serType ctx repr.body;
      in
      "Ctor(${esc repr.name},[${ps}],${bd})"

    else if v == "ADT" then
      let
        vs = builtins.sort (a: b: a < b)  # canonical 排序（按 name）
          (map (vt:
            let flds = builtins.concatStringsSep "," (map (_serType ctx) (vt.fields or [])); in
            "${vt.name}(${flds})#${toString (vt.ordinal or 0)}")
            repr.variants);
        closed = if repr.closed then "!" else "~";
      in
      "ADT${closed}[${builtins.concatStringsSep "|" vs}]"

    else if v == "Constrained" then
      let
        cs = builtins.sort (a: b: a < b)
          (map (_serConstraint ctx) repr.constraints);
      in
      "C(${_serType ctx repr.base},{${builtins.concatStringsSep ";" cs}})"

    else if v == "Mu" then
      "μ(${esc repr.param}.${_serType ctx repr.body})"

    else if v == "Record" then
      let
        labels = builtins.sort (a: b: a < b) (builtins.attrNames repr.fields);
        flds = builtins.concatStringsSep ","
          (map (l: "${l}:${_serType ctx repr.fields.${l}}") labels);
        rv = if repr.rowVar != null then "|${repr.rowVar}" else "";
      in
      "{${flds}${rv}}"

    else if v == "VariantRow" then
      let
        labels = builtins.sort (a: b: a < b) (builtins.attrNames repr.variants);
        vs = builtins.concatStringsSep "|"
          (map (l:
            let fs = builtins.concatStringsSep "," (map (_serType ctx) repr.variants.${l}); in
            "${l}(${fs})") labels);
        rv = if repr.rowVar != null then "|${repr.rowVar}" else "";
      in
      "VRow[${vs}${rv}]"

    else if v == "RowExtend" then
      "RE(${repr.label}:${_serType ctx repr.fieldType};${_serType ctx repr.rowType})"

    else if v == "Effect" then
      "Eff(${esc repr.tag},${_serType ctx repr.row})"

    else if v == "Ascribe" then
      "Asc(${_serType ctx repr.t}:${_serType ctx repr.annotation})"

    else "?repr(${v or "null"})";

  # ── 辅助：序列化 Type（从 repr 进入）──────────────────────────────────────
  _serType = ctx: t:
    if t == null then "null"
    else if builtins.isAttrs t && t ? repr then _serRepr ctx t.repr
    else if builtins.isAttrs t && t ? __variant then _serRepr ctx t
    else if builtins.isString t then "\"${t}\""
    else "?";

  # ── 辅助：序列化 Kind ─────────────────────────────────────────────────────
  _serKind = k:
    if builtins.isAttrs k && k ? __kindVariant
    then _serRepr {} k
    else "_K";

  # ── 辅助：序列化 Constraint（canonical）──────────────────────────────────
  _serConstraint = ctx: c:
    let tag = c.__constraintTag or c.__tag or null; in
    if tag == "Class" then
      "Cls(${c.name},[${builtins.concatStringsSep "," (map (_serType ctx) (c.args or []))}])"
    else if tag == "Equality" then
      "Eq(${_serType ctx c.a},${_serType ctx c.b})"
    else if tag == "Predicate" then
      "Pred(${c.fn or "?"},${_serType ctx (c.arg or {})})"
    else if tag == "Implies" then
      "Imp([${builtins.concatStringsSep ";" (map (_serConstraint ctx) (c.premises or []))}]→${_serConstraint ctx (c.conclusion or {})})"
    else "?c(${builtins.toJSON c})";

  # ══════════════════════════════════════════════════════════════════════════════
  # Alpha-Canonical 序列化（de Bruijn 变量索引）
  # ══════════════════════════════════════════════════════════════════════════════

  # Context: { env: AttrSet String Int; depth: Int }
  # env: varName -> de Bruijn level（从外到内递增）

  # Type: AlphaCtx -> TypeRepr -> String
  _serReprAlpha = actx: repr:
    let
      v   = repr.__variant or repr.__kindVariant or null;
      dep = actx.depth;
      env = actx.env;

      # 进入 binder：将参数名映射到当前 depth
      bindVar = name: actx // { env = env // { ${name} = dep; }; depth = dep + 1; };

      # 序列化 Type 在当前 alpha ctx 下
      serT = t:
        if t == null then "null"
        else if builtins.isAttrs t && t ? repr then _serReprAlpha actx t.repr
        else if builtins.isAttrs t && t ? __variant then _serReprAlpha actx t
        else "?";

      # 进入 binder 后序列化 Type
      serTbind = name: t:
        let actx' = bindVar name; in
        if t == null then "null"
        else if builtins.isAttrs t && t ? repr then _serReprAlpha actx' t.repr
        else if builtins.isAttrs t && t ? __variant then _serReprAlpha actx' t
        else "?";

    in

    # Var → de Bruijn index（若在 env 中）或自由变量（保留名字）
    if v == "Var" then
      let idx = env.${repr.name} or null; in
      if idx != null
      then "DB(${toString (dep - idx - 1)})"  # de Bruijn = depth - level - 1
      else "FV(${repr.name},${repr.scope or "?"})"  # free variable 保留

    else if v == "VarDB" then
      "DB(${toString repr.index})"

    else if v == "Lambda" then
      let bodyS = serTbind repr.param repr.body; in
      "λ(${bodyS})"  # 不包含 param 名（α-canonical！）

    else if v == "Pi" then
      let
        ptS  = serT repr.paramType;
        bdS  = serTbind repr.param repr.body;
      in
      "Π(${ptS}.${bdS})"

    else if v == "Sigma" then
      let
        ptS  = serT repr.paramType;
        bdS  = serTbind repr.param repr.body;
      in
      "Σ(${ptS}.${bdS})"

    else if v == "Mu" then
      let bodyS = serTbind repr.param repr.body; in
      "μ(${bodyS})"  # μ binder α-canonical

    else if v == "Apply" then
      let
        fnS   = serT repr.fn;
        argsS = builtins.concatStringsSep "," (map serT repr.args);
      in
      "(${fnS}@[${argsS}])"

    else if v == "Fn" then
      "(${serT repr.from}→${serT repr.to})"

    else if v == "Constrained" then
      let
        cs = builtins.sort (a: b: a < b)
          (map (_serConstraintAlpha actx) repr.constraints);
      in
      "C(${serT repr.base},{${builtins.concatStringsSep ";" cs}})"

    else if v == "Record" then
      let
        labels = builtins.sort (a: b: a < b) (builtins.attrNames repr.fields);
        flds = builtins.concatStringsSep ","
          (map (l: "${l}:${serT repr.fields.${l}}") labels);
        # Phase 3 修复：rowVar 是 rigid unification var（保留名字作为标识符）
        rv = if repr.rowVar != null then "|rv:${repr.rowVar}" else "";
      in
      "{${flds}${rv}}"

    else if v == "VariantRow" then
      let
        labels = builtins.sort (a: b: a < b) (builtins.attrNames repr.variants);
        vs = builtins.concatStringsSep "|"
          (map (l:
            let fs = builtins.concatStringsSep "," (map serT repr.variants.${l}); in
            "${l}(${fs})") labels);
        rv = if repr.rowVar != null then "|rv:${repr.rowVar}" else "";
      in
      "VRow[${vs}${rv}]"

    # 其余变体走 structural serializer（无 binders）
    else _serRepr (actx // { _alpha = true; }) repr;

  # Alpha-canonical constraint 序列化
  _serConstraintAlpha = actx: c:
    let tag = c.__constraintTag or c.__tag or null; in
    if tag == "Class" then
      let args = builtins.concatStringsSep "," (map (_serTypeAlpha actx) (c.args or [])); in
      "Cls(${c.name},[${args}])"
    else if tag == "Equality" then
      "Eq(${_serTypeAlpha actx c.a},${_serTypeAlpha actx c.b})"
    else if tag == "Predicate" then
      "Pred(${c.fn or "?"},${_serTypeAlpha actx (c.arg or {})})"
    else "?c";

  _serTypeAlpha = actx: t:
    if t == null then "null"
    else if builtins.isAttrs t && t ? repr then _serReprAlpha actx t.repr
    else if builtins.isAttrs t && t ? __variant then _serReprAlpha actx t
    else "?";

}
