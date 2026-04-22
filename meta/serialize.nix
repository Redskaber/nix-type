# meta/serialize.nix — Phase 4.2
# 规范序列化：canonical + deterministic
# 关键：Lambda 使用 de Bruijn index（alpha-等价 → 相同序列化）
# INV-4 前置：serialize(NF(a)) == serialize(NF(b)) ⟺ typeEq(a, b)
{ lib, kindLib }:

let
  inherit (kindLib) serializeKind isKind;

in rec {

  # ══ De Bruijn 环境（alpha-规范化）════════════════════════════════════
  # env: attrset name → de Bruijn index (Int)
  # depth: 当前 lambda 深度

  _serializeWithEnv = env: depth: r:
    if !builtins.isAttrs r then builtins.toJSON r
    else
      let v = r.__variant or null; in
      if v == null then builtins.toJSON r
      else if v == "Primitive" then
        "Prim(${r.name})"
      else if v == "Var" then
        let
          idx   = env.${r.name} or null;
          scope = if r ? scope then r.scope else "?";
        in
        if idx != null then "DB(${builtins.toString (depth - idx - 1)})"
        else "Free(${r.name}@${scope})"
      else if v == "Lambda" then
        let
          newDepth = depth + 1;
          newEnv   = env // { ${r.param} = depth; };
          bodyStr  = _serializeWithEnv newEnv newDepth r.body.repr;
        in
        "λ.${bodyStr}"
      else if v == "Apply" then
        let
          fnStr   = _serializeWithEnv env depth r.fn.repr;
          argStrs = map (a: _serializeWithEnv env depth a.repr) (r.args or []);
        in
        "(${fnStr} ${lib.concatStringsSep " " argStrs})"
      else if v == "Fn" then
        let
          fromStr = _serializeWithEnv env depth r.from.repr;
          toStr   = _serializeWithEnv env depth r.to.repr;
        in
        "(${fromStr} → ${toStr})"
      else if v == "ADT" then
        let
          varStrs = map (vr:
            "${vr.name}(${lib.concatStringsSep "," (map (f: _serializeWithEnv env depth f.repr) vr.fields)})"
          ) (lib.sort (a: b: a.ordinal < b.ordinal) r.variants);
        in
        "ADT[${lib.concatStringsSep "|" varStrs}]${if r.closed then "!" else ""}"
      else if v == "Constrained" then
        let
          baseStr = _serializeWithEnv env depth r.base.repr;
          csStrs  = map (c: serializeConstraint c) (lib.sort (a: b:
            builtins.toJSON a < builtins.toJSON b
          ) r.constraints);
        in
        "Cs(${baseStr};${lib.concatStringsSep "," csStrs})"
      else if v == "Mu" then
        let
          newDepth = depth + 1;
          newEnv   = env // { ${r.var} = depth; };
          bodyStr  = _serializeWithEnv newEnv newDepth r.body.repr;
        in
        "μ.${bodyStr}"
      else if v == "Record" then
        let
          sortedFields = lib.sort (a: b: a < b) (builtins.attrNames r.fields);
          fieldStrs = map (n:
            "${n}:${_serializeWithEnv env depth r.fields.${n}.repr}"
          ) sortedFields;
        in
        "{${lib.concatStringsSep "," fieldStrs}}"
      else if v == "RowExtend" then
        let tailStr = _serializeWithEnv env depth r.tail.repr; in
        "(${r.label}:${_serializeWithEnv env depth r.ty.repr}|${tailStr})"
      else if v == "RowEmpty" then
        "()"
      else if v == "VariantRow" then
        let
          sortedVars = lib.sort (a: b: a < b) (builtins.attrNames r.variants);
          varStrs = map (n:
            "${n}:${_serializeWithEnv env depth r.variants.${n}.repr}"
          ) sortedVars;
          tailStr = if r.tail != null then "|${_serializeWithEnv env depth r.tail.repr}" else "";
        in
        "VRow[${lib.concatStringsSep "," varStrs}${tailStr}]"
      else if v == "Effect" then
        let
          rowStr = _serializeWithEnv env depth r.effectRow.repr;
          resStr = _serializeWithEnv env depth r.resultType.repr;
        in
        "Eff(${rowStr},${resStr})"
      else if v == "EffectMerge" then
        let
          e1Str = _serializeWithEnv env depth r.e1.repr;
          e2Str = _serializeWithEnv env depth r.e2.repr;
          # canonical: sorted to ensure confluence
          sorted = lib.sort (a: b: a < b) [e1Str e2Str];
        in
        "EMerge(${lib.concatStringsSep "++" sorted})"
      else if v == "Refined" then
        let baseStr = _serializeWithEnv env depth r.base.repr; in
        "Ref(${baseStr},${r.predVar},${serializePredExpr r.predExpr})"
      else if v == "Sig" then
        let
          sortedFields = lib.sort (a: b: a < b) (builtins.attrNames r.fields);
          fieldStrs = map (n:
            "${n}:${_serializeWithEnv env depth r.fields.${n}.repr}"
          ) sortedFields;
        in
        "Sig{${lib.concatStringsSep "," fieldStrs}}"
      else if v == "Struct" then
        let
          sortedImpls = lib.sort (a: b: a < b) (builtins.attrNames r.impls);
          implStrs = map (n:
            "${n}=${_serializeWithEnv env depth r.impls.${n}.repr}"
          ) sortedImpls;
        in
        "Struct{${lib.concatStringsSep "," implStrs}}"
      else if v == "ModFunctor" then
        "Functor(${r.param},${_serializeWithEnv env depth r.paramSig.repr},${_serializeWithEnv env depth r.body.repr})"
      else if v == "Opaque" then
        "Opaque(${r.tag},${_serializeWithEnv env depth r.inner.repr})"
      else if v == "Forall" then
        let
          sortedVars = lib.sort builtins.lessThan r.vars;
          newDepth   = depth + builtins.length sortedVars;
          newEnv = lib.foldl' (acc: nv:
            let idx = acc.depth; in
            { env = acc.env // { ${nv} = idx; }; depth = idx + 1; }
          ) { env = env; depth = depth; } sortedVars;
          bodyStr = _serializeWithEnv newEnv.env newDepth r.body.repr;
        in
        "∀[${lib.concatStringsSep "," sortedVars}].${bodyStr}"
      else if v == "Dynamic" then "Dyn"
      else if v == "Hole" then "Hole(${r.holeId})"
      else if v == "Pi" then
        let
          newDepth = depth + 1;
          newEnv   = env // { ${r.param} = depth; };
          bodyStr  = _serializeWithEnv newEnv newDepth r.body.repr;
          ptStr    = _serializeWithEnv env depth r.paramType.repr;
        in
        "Π(${ptStr}).${bodyStr}"
      else if v == "Constructor" then
        let
          paramStr = lib.concatStringsSep "," r.params;
          bodyStr  = _serializeWithEnv env depth r.body.repr;
        in
        "Con(${r.name},[${paramStr}],${bodyStr})"
      else "Unknown(${v})";

  # ══ Constraint 序列化 ══════════════════════════════════════════════════
  serializeConstraint = c:
    if !builtins.isAttrs c then builtins.toJSON c
    else
      let tag = c.__constraintTag or null; in
      if tag == "Equality" then
        "Eq(${serializeRepr c.lhs.repr},${serializeRepr c.rhs.repr})"
      else if tag == "Class" then
        let argStrs = map (a: serializeRepr a.repr) (c.args or []); in
        "Class(${c.className},[${lib.concatStringsSep "," argStrs}])"
      else if tag == "Predicate" then
        "Pred(${c.predName},${serializeRepr c.subject.repr})"
      else if tag == "Implies" then
        let
          premStrs = map serializeConstraint c.premises;
          concStr  = serializeConstraint c.conclusion;
        in
        "Impl([${lib.concatStringsSep "," premStrs}]→${concStr})"
      else if tag == "RowEquality" then
        "RowEq(${serializeRepr c.lhsRow.repr},${serializeRepr c.rhsRow.repr})"
      else if tag == "Refined" then
        "RefCons(${serializeRepr c.subject.repr},${c.predVar},${serializePredExpr c.predExpr})"
      else builtins.toJSON c;

  # ══ PredExpr 序列化（用于 Refined 类型）══════════════════════════════
  serializePredExpr = pe:
    if !builtins.isAttrs pe then builtins.toJSON pe
    else
      let tag = pe.__predTag or null; in
      if tag == "PTrue"  then "⊤"
      else if tag == "PFalse" then "⊥"
      else if tag == "PLit"   then "Lit(${builtins.toJSON pe.value})"
      else if tag == "PVar"   then "PVar(${pe.name})"
      else if tag == "PCmp"   then
        "Cmp(${pe.op},${serializePredExpr pe.lhs},${serializePredExpr pe.rhs})"
      else if tag == "PAnd"   then
        "And(${serializePredExpr pe.lhs},${serializePredExpr pe.rhs})"
      else if tag == "POr"    then
        "Or(${serializePredExpr pe.lhs},${serializePredExpr pe.rhs})"
      else if tag == "PNot"   then
        "Not(${serializePredExpr pe.body})"
      else builtins.toJSON pe;

  # ══ TypeRepr 序列化（public API）══════════════════════════════════════
  # Type: TypeRepr → String（canonical，alpha-规范化）
  serializeRepr = r:
    _serializeWithEnv {} 0 r;

  # Type: Type → String（完整 Type，含 kind）
  serializeType = t:
    if !builtins.isAttrs t || (t.tag or null) != "Type" then builtins.toJSON t
    else
      let
        reprStr = serializeRepr t.repr;
        kindStr = serializeKind t.kind;
      in
      "T(${reprStr}:${kindStr})";

  # ══ canonical hash（供 hashLib 使用）══════════════════════════════════
  canonicalHash = t:
    builtins.hashString "sha256" (serializeType t);

  canonicalHashRepr = r:
    builtins.hashString "sha256" (serializeRepr r);
}
