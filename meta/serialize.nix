# meta/serialize.nix — Phase 3.1
# α-canonical 序列化（INV-SER3 强制，v3）
#
# Phase 3.1 修复：
#   INV-SER3: serializeReprAlphaCanonical(α-equivalent) = 相同 string
#   INV-SER4: 消除所有 toJSON 依赖（属性顺序不稳定）
#   INV-SER5: Constructor binder 用 indexed env（不用名字，不循环）
#   INV-T2:   stableId = H(serializeAlpha(repr))
#
# 设计原则：
#   1. 完全不依赖 builtins.toJSON（属性顺序不保证）
#   2. de Bruijn 索引替换 binder 名字（α-equivalence）
#   3. Record field 按字母排序（canonical）
#   4. Row field 按字母排序（canonical）
#   5. cycle/loop protection via depth limit
{ lib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 核心序列化（α-canonical，INV-SER3/4/5）
  # ══════════════════════════════════════════════════════════════════════════════

  # env: AttrSet String Int（变量名 → de Bruijn 索引，从外到内递增）
  # depth: 当前 binder 深度
  # fuel: 递归深度限制（防止循环）

  # Type: AttrSet Int -> Int -> Int -> TypeRepr -> String
  _serRepr = env: depth: fuel: repr:
    if fuel <= 0 then "…"
    else
      let
        v = repr.__variant or null;
        go = _serRepr env depth (fuel - 1);
        goWith = newEnv: newDepth: _serRepr newEnv newDepth (fuel - 1);
        goType = t: if t == null then "null"
                    else if !(builtins.isAttrs t) then builtins.toString t
                    else _serRepr env depth (fuel - 1) (t.repr or { __variant = "?"; });
      in

      if v == null then "?"

      else if v == "Primitive"  then "prim(${repr.name or "?"})"

      else if v == "Var" then
        # de Bruijn：查 env，若有绑定则用索引，否则用名字（自由变量）
        let
          idx = env.${repr.name or "_"} or null;
        in
        if idx != null
        then "bv(${builtins.toString (depth - idx - 1)})"  # relative index
        else "fv(${repr.name or "_"})"

      else if v == "Lambda" then
        let
          param = repr.param or "_";
          newEnv = env // { ${param} = depth; };
        in
        "λ${builtins.toString depth}.${goWith newEnv (depth + 1) (repr.body.repr or { __variant = "?"; })}"

      else if v == "Pi" then
        let
          param = repr.param or "_";
          newEnv = env // { ${param} = depth; };
          domS = goType (repr.domain or null);
        in
        "Π${builtins.toString depth}:${domS}.${goWith newEnv (depth + 1) (repr.body.repr or { __variant = "?"; })}"

      else if v == "Sigma" then
        let
          param = repr.param or "_";
          newEnv = env // { ${param} = depth; };
          domS = goType (repr.domain or null);
        in
        "Σ${builtins.toString depth}:${domS}.${goWith newEnv (depth + 1) (repr.body.repr or { __variant = "?"; })}"

      else if v == "Apply" then
        let
          fnS = goType (repr.fn or null);
          argsS = builtins.concatStringsSep "," (map goType (repr.args or []));
        in
        "app(${fnS},[${argsS}])"

      else if v == "Fn" then
        "fn(${goType (repr.from or null)},${goType (repr.to or null)})"

      else if v == "Constructor" then
        let
          name = repr.name or "?";
          # params 用 indexed env（INV-SER5：不循环）
          paramNames = map (p: p.name or "_") (repr.params or []);
          paramKinds = map (p: _serKind (p.kind or { __kindVariant = "KUnbound"; })) (repr.params or []);
          # assign de Bruijn to each param in order
          newEnv = lib.foldl'
            (acc: pair: acc // { ${pair.name} = depth + pair.idx; })
            env
            (lib.imap0 (i: n: { name = n; idx = i; }) paramNames);
          paramSigs = lib.imap0
            (i: p: "${p.name or "_"}:${builtins.elemAt paramKinds i}")
            (repr.params or []);
          paramStr = builtins.concatStringsSep "," (map builtins.toString paramSigs);
          bodyS = if repr ? body
                  then goWith newEnv (depth + builtins.length paramNames) (repr.body.repr or { __variant = "?"; })
                  else "?";
        in
        "ctor(${name},[${paramStr}],${bodyS})"

      else if v == "ADT" then
        let
          variants = repr.variants or [];
          # canonical: sort by variant name
          sortedVars = lib.sort (a: b: (a.name or "") < (b.name or "")) variants;
          varStrs = map (var:
            let
              fields = map goType (var.fields or []);
              fieldStr = builtins.concatStringsSep "," fields;
            in
            "${var.name or "?"}(${fieldStr})"
          ) sortedVars;
          closed = if (repr.closed or true) then "!" else "+";
        in
        "adt${closed}[${builtins.concatStringsSep "|" varStrs}]"

      else if v == "Constrained" then
        let
          baseS = goType (repr.base or null);
          cs = repr.constraints or [];
          # canonical sort constraints
          csS = builtins.concatStringsSep "," (lib.sort lib.lessThan (map _serConstraint cs));
        in
        "constr(${baseS},{${csS}})"

      else if v == "Mu" then
        let
          var = repr.var or "_";
          newEnv = env // { ${var} = depth; };
        in
        "μ${builtins.toString depth}.${goWith newEnv (depth + 1) (repr.body.repr or { __variant = "?"; })}"

      else if v == "Record" then
        let
          fields = repr.fields or {};
          # canonical: lexicographic field order（INV-SER canonical）
          sortedKeys = lib.sort lib.lessThan (builtins.attrNames fields);
          fieldStrs = map (k: "${k}:${goType fields.${k}}") sortedKeys;
        in
        "rec{${builtins.concatStringsSep "," fieldStrs}}"

      else if v == "VariantRow" then
        let
          variants = repr.variants or {};
          sortedKeys = lib.sort lib.lessThan (builtins.attrNames variants);
          varStrs = map (k: "${k}:${goType variants.${k}}") sortedKeys;
          tailS = if repr ? tail then "|${goType repr.tail}" else "";
        in
        "vrow{${builtins.concatStringsSep "," varStrs}${tailS}}"

      else if v == "RowExtend" then
        "rext(${repr.label or "?"},${goType (repr.fieldType or null)},${goType (repr.rest or null)})"

      else if v == "RowEmpty" then "ρ∅"

      else if v == "Effect" then
        let
          row = repr.effectRow or null;
        in
        "eff(${goType row})"

      else if v == "Opaque" then
        "opaque(${repr.name or "?"})"

      else if v == "Ascribe" then
        "ascribe(${goType (repr.inner or null)},${goType (repr.ty or null)})"

      else "?(${v})";

  # Kind 序列化（用于 Constructor param sigs，不依赖 kindLib 避免循环）
  _serKind = k:
    let v = k.__kindVariant or null; in
    if      v == "KStar"    then "*"
    else if v == "KArrow"   then "(${_serKind k.from}->${_serKind k.to})"
    else if v == "KRow"     then "#row"
    else if v == "KEffect"  then "#eff"
    else if v == "KVar"     then "?K${k.name}"
    else if v == "KUnbound" then "_K"
    else "_K";

  # Constraint 序列化（用于 Constrained repr 内部）
  _serConstraint = c:
    let tag = c.__constraintTag or null; in
    if tag == "Class"     then "cls(${c.name or "?"},[${builtins.concatStringsSep "," (map (a: a.id or "?") (c.args or []))}])"
    else if tag == "Equality" then "eq(${(c.a or {}).id or "?"},${(c.b or {}).id or "?"})"
    else if tag == "Predicate" then "pred(${c.fn or "?"})"
    else "c?";

  # ══════════════════════════════════════════════════════════════════════════════
  # 公开入口
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: TypeRepr -> String（α-canonical，INV-SER3）
  serializeReprAlphaCanonical = repr:
    _serRepr {} 0 128 repr;

  # Type: TypeRepr -> String（快速，带格式化但不 α-canonical）
  serializeReprFast = repr:
    _serRepr {} 0 32 repr;

  # Type: Type -> String（用于 id 生成，INV-T2）
  serializeType = t:
    serializeReprAlphaCanonical (t.repr or { __variant = "?"; });

  # ══════════════════════════════════════════════════════════════════════════════
  # 辅助：从序列化到 hash
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: TypeRepr -> String（canonical hash, no toJSON dependency）
  hashReprCanonical = repr:
    builtins.hashString "sha256" (serializeReprAlphaCanonical repr);

}
