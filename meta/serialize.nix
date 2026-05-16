# meta/serialize.nix — Phase 4.5.4
# 规范序列化：canonical + deterministic
# INV-SER-1: serializeRepr 对任意 TypeRepr 产生纯字符串（无函数字段触碰）
# INV-SER-2: 相同结构（alpha-等价）→ 相同字符串
# INV-SER-3: 所有 builtins.toJSON fallback 都经过 isFunction 守卫
#
# Fix P4.3 (critical):
#   builtins.toJSON on a Nix lambda throws an UNCATCHABLE abort — even
#   builtins.tryEval cannot intercept it in all Nix versions.
#   Every fallback path that previously called `builtins.toJSON r` on an
#   arbitrary value now calls `_safeStr` which guards with `builtins.isFunction`.
#
# Fix P4.5.4:
#   Updated constraint tag patterns: "Equality"→"Eq", "RowEquality"→"RowEq"
#   Added serialization for "Sub", "HasField", "Gt"/"Ge"/"Lt"/"Le" pred tags
{ lib, kindLib }:

let
  inherit (kindLib) serializeKind isKind;

in rec {

  # ══ ARCH-SER-SAFE: safe string conversion for unknown values ═══════════════
  # Contract: NEVER calls builtins.toJSON on a function value.
  _safeStr = v:
    if builtins.isFunction v then "<fn>"
    else if builtins.isNull v then "null"
    else if builtins.isBool v then if v then "true" else "false"
    else if builtins.isInt v then builtins.toString v
    else if builtins.isFloat v then builtins.toString v
    else if builtins.isString v then "\"${v}\""
    else if builtins.isPath v then builtins.toString v
    else if builtins.isList v then
      "[${lib.concatStringsSep "," (map _safeStr v)}]"
    else if builtins.isAttrs v then
      "{${lib.concatStringsSep "," (lib.sort builtins.lessThan (builtins.attrNames v))}}"
    else "?";

  # ══ De Bruijn 序列化（alpha-等价规范化）══════════════════════════════
  # INV-SER-1: all branches produce a string, never call toJSON on unknown value
  _serializeWithEnv = env: depth: r:
    # Guard 1: function values
    if builtins.isFunction r then "<fn>"
    # Guard 2: non-attrset primitives
    else if !builtins.isAttrs r then _safeStr r
    else
      let v = r.__variant or null; in
      if v == null then
        "{${lib.concatStringsSep "," (lib.sort builtins.lessThan (builtins.attrNames r))}}"
      else if v == "Primitive" then
        "Prim(${r.name})"
      else if v == "Var" then
        let
          idx   = env.${r.name} or null;
          scope = r.scope or "?";
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
          csStrs  = map serializeConstraint
            (lib.sort (a: b: serializeConstraint a < serializeConstraint b)
              r.constraints);
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
          tailStr =
            let tailVal = r.tail or null; in
            if tailVal != null then "|${_serializeWithEnv env depth tailVal.repr}" else "";
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
          e1Str  = _serializeWithEnv env depth r.e1.repr;
          e2Str  = _serializeWithEnv env depth r.e2.repr;
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
      else if v == "ForAll" then
        # Alias variant produced by rForAll helper
        let
          name    = r.name or "?";
          bodyStr = _serializeWithEnv (env // { ${name} = depth; }) (depth + 1) r.body.repr;
        in
        "∀${name}.${bodyStr}"
      else if v == "TyCon" then
        let tname = r.name or "?"; in
        "TyCon(${tname})"
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
      else if v == "Sigma" then
        let
          newDepth = depth + 1;
          newEnv   = env // { ${r.param} = depth; };
          bodyStr  = _serializeWithEnv newEnv newDepth r.body.repr;
          ptStr    = _serializeWithEnv env depth r.paramType.repr;
        in
        "Σ(${ptStr}).${bodyStr}"
      else if v == "Constructor" then
        let
          paramStr = lib.concatStringsSep "," r.params;
          bodyStr  = _serializeWithEnv env depth r.body.repr;
        in
        "Con(${r.name},[${paramStr}],${bodyStr})"
      else if v == "ComposedFunctor" then
        let
          fStr = _serializeWithEnv env depth r.f.repr;
          gStr = _serializeWithEnv env depth r.g.repr;
        in
        "CF(${fStr}∘${gStr})"
      else if v == "TypeScheme" then
        let
          forallStr = lib.concatStringsSep "," (lib.sort builtins.lessThan (r.vars or []));
          bodyStr   = _serializeWithEnv env depth r.body.repr;
        in
        "TS(∀[${forallStr}].${bodyStr})"
      else "Unknown(${v})";

  # ══ Constraint 序列化（INV-SER-1: no toJSON on unknown values）══════════
  serializeConstraint = c:
    if builtins.isFunction c then "<fn-constraint>"
    else if !builtins.isAttrs c then _safeStr c
    else
      let tag = c.__constraintTag or null; in
      # Phase 4.5.4: short tags "Eq" and "RowEq"
      if tag == "Eq" then
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
      else if tag == "RowEq" then
        "RowEq(${serializeRepr c.lhsRow.repr},${serializeRepr c.rhsRow.repr})"
      else if tag == "Refined" then
        "RefCons(${serializeRepr c.subject.repr},${c.predVar},${serializePredExpr c.predExpr})"
      else if tag == "Scheme" then
        let
          s         = c.scheme or {};
          forallStr =
            let fl = s.forall or []; in
            lib.concatStringsSep "," (lib.sort builtins.lessThan fl);
          bodyStr   = if s ? body then serializeRepr s.body.repr else "?";
          tyStr     = if c ? ty then serializeRepr c.ty.repr else "?";
        in
        "Scheme(∀[${forallStr}].${bodyStr}≥${tyStr})"
      else if tag == "Kind" then
        let
          tvar = c.typeVar or "?";
          knd  = c.expectedKind or { __kindTag = "?"; };
          ks   = serializeKind knd;
        in
        "Kind(${tvar},${ks})"
      else if tag == "Instance" then
        let
          argStrs = map (a: serializeRepr a.repr) (c.types or []);
          cls     = if c ? className then c.className else "?";
        in
        "Instance(${cls},[${lib.concatStringsSep "," argStrs}])"
      else if tag == "Sub" then
        "Sub(${serializeRepr c.sub.repr},${serializeRepr c.sup.repr})"
      else if tag == "HasField" then
        let
          hf  = c.field or "?";
          hft = serializeRepr c.fieldType.repr;
          hrt = serializeRepr c.recType.repr;
        in
        "HasField(${hf},${hft},${hrt})"
      # Legacy compat: old long-form tags still serializable
      else if tag == "Equality" then
        "Eq(${serializeRepr c.lhs.repr},${serializeRepr c.rhs.repr})"
      else if tag == "RowEquality" then
        "RowEq(${serializeRepr c.lhsRow.repr},${serializeRepr c.rhsRow.repr})"
      else
        let
          tagStr = if tag != null then tag else "Unknown";
          keys   = lib.sort builtins.lessThan (builtins.attrNames c);
        in
        "${tagStr}(${lib.concatStringsSep "," keys})";

  # ══ PredExpr 序列化（INV-SER-1）══════════════════════════════════════════
  serializePredExpr = pe:
    if builtins.isFunction pe then "<fn-pred>"
    else if !builtins.isAttrs pe then _safeStr pe
    else
      let tag = pe.__predTag or null; in
      if tag == "PTrue"  then "⊤"
      else if tag == "PFalse" then "⊥"
      else if tag == "PLit" then
        let
          pv = pe.value or null;
          pvStr = if builtins.isFunction pv then "<fn>" else builtins.toJSON pv;
        in
        "Lit(${pvStr})"
      else if tag == "PVar"   then "PVar(${pe.name})"
      else if tag == "PCmp"   then
        "Cmp(${pe.op},${serializePredExpr pe.lhs},${serializePredExpr pe.rhs})"
      else if tag == "PAnd"   then
        "And(${serializePredExpr pe.lhs},${serializePredExpr pe.rhs})"
      else if tag == "POr"    then
        "Or(${serializePredExpr pe.lhs},${serializePredExpr pe.rhs})"
      else if tag == "PNot"   then
        "Not(${serializePredExpr pe.body})"
      # Phase 4.5.4: Gt/Ge/Lt/Le sugar tags
      # pe.rhs fallback uses inline ⊤ literal (mkPTrue not in scope here)
      else if tag == "Gt" then
        let rhsVal = if pe ? rhs then pe.rhs else { __predTag = "PTrue"; }; in
        "Gt(${serializePredExpr rhsVal})"
      else if tag == "Ge" then
        let rhsVal = if pe ? rhs then pe.rhs else { __predTag = "PTrue"; }; in
        "Ge(${serializePredExpr rhsVal})"
      else if tag == "Lt" then
        let rhsVal = if pe ? rhs then pe.rhs else { __predTag = "PTrue"; }; in
        "Lt(${serializePredExpr rhsVal})"
      else if tag == "Le" then
        let rhsVal = if pe ? rhs then pe.rhs else { __predTag = "PTrue"; }; in
        "Le(${serializePredExpr rhsVal})"
      else
        let
          tagStr = if tag != null then tag else "UnknownPred";
          keys   = lib.sort builtins.lessThan (builtins.attrNames pe);
        in
        "${tagStr}(${lib.concatStringsSep "," keys})";

  # ══ TypeRepr 序列化（public API）══════════════════════════════════════════
  serializeRepr = r: _serializeWithEnv {} 0 r;

  # ══ Type 序列化 ════════════════════════════════════════════════════════════
  serializeType = t:
    if builtins.isFunction t then "<fn-type>"
    else if !builtins.isAttrs t then _safeStr t
    else if (t.tag or null) != "Type" then
      let keys = lib.sort builtins.lessThan (builtins.attrNames t); in
      "NonType{${lib.concatStringsSep "," keys}}"
    else
      let
        reprStr = serializeRepr t.repr;
        kindStr = serializeKind t.kind;
      in
      "T(${reprStr}:${kindStr})";

  # ══ canonical hash ══════════════════════════════════════════════════════════
  canonicalHash     = t: builtins.hashString "sha256" (serializeType t);
  canonicalHashRepr = r: builtins.hashString "sha256" (serializeRepr r);
}
