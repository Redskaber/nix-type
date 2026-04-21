# meta/serialize.nix — Phase 4.1
# 确定性 canonical 序列化
# INV-4: hash(t) = H(serialize(normalize(t)))
# 相同语义类型 → 相同序列化 → 相同 hash
# 注意：字段顺序必须固定（JSON attr ordering 在 Nix 中按字母序）
{ lib, kindLib }:

rec {
  # ── PredExpr 序列化 ────────────────────────────────────────────────────────
  serializePred = p:
    let t = p.__predTag or p.__variant or null; in
    if t == "PTrue"  then { t = "PT"; }
    else if t == "PFalse" then { t = "PF"; }
    else if t == "PAnd"   then { t = "PA"; l = serializePred p.left; r = serializePred p.right; }
    else if t == "POr"    then { t = "PO"; l = serializePred p.left; r = serializePred p.right; }
    else if t == "PNot"   then { t = "PN"; b = serializePred p.body; }
    else if t == "PCmp"   then { t = "PC"; op = p.op; l = serializePred p.lhs; r = serializePred p.rhs; }
    else if t == "PVar"   then { t = "PV"; n = p.name; }
    else if t == "PLit"   then { t = "PL"; v = builtins.toJSON p.value; }
    else if t == "PApp"   then { t = "PP"; f = p.fn; a = map serializePred p.args; }
    else { t = "P?"; };

  # ── Constraint 序列化 ─────────────────────────────────────────────────────
  serializeConstraint = c:
    let tag = c.__constraintTag or c.__tag or null; in
    if tag == "Equality"    then
      { t = "EQ";
        a = serializeRepr c.lhs.repr;
        b = serializeRepr c.rhs.repr; }
    else if tag == "Class"  then
      { t = "CL";
        n = c.className;
        a = map (x: serializeRepr x.repr) (c.args or []); }
    else if tag == "Predicate" then
      { t = "PR";
        fn = c.predName or c.fn or "?";
        a  = serializeRepr (c.subject or c.arg or { __variant = "?"; }).repr; }
    else if tag == "Implies" then
      { t = "IM";
        p = map serializeConstraint (c.premises or []);
        c = serializeConstraint (c.conclusion or { __constraintTag = "?"; }); }
    else if tag == "RowEquality" then
      { t = "RE";
        l = serializeRepr (c.lhsRow or { __variant = "?"; }).repr;
        r = serializeRepr (c.rhsRow or { __variant = "?"; }).repr; }
    else if tag == "Refined" then
      { t = "RF";
        s = serializeRepr (c.subject or { __variant = "?"; }).repr;
        v = c.predVar or "?";
        p = serializePred (c.predExpr or { __predTag = "PTrue"; }); }
    else { t = "C?"; raw = builtins.toJSON c; };

  # ── Variant 序列化 ────────────────────────────────────────────────────────
  serializeVariant = v: {
    n  = v.name;
    o  = v.ordinal;
    fs = map (f: serializeRepr f.repr) (v.fields or []);
  };

  # ── Handler Branch 序列化 ─────────────────────────────────────────────────
  serializeBranch = b: {
    tag = b.effectTag or b.tag or "?";
    ret = serializeRepr (b.body or b.returnType or { __variant = "?"; }).repr;
  };

  # ── TypeRepr 序列化（核心：必须 canonical）────────────────────────────────
  # Type: TypeRepr -> AttrSet (JSON-serializable, deterministic)
  serializeRepr = repr:
    let v = repr.__variant or null; in
    if v == "Primitive" then { v = "P"; n = repr.name; }

    else if v == "Var" then
      { v = "V"; n = repr.name; s = repr.scope or ""; }

    else if v == "Lambda" then
      # alpha-规范化：参数名参与序列化（de Bruijn 风格需要完整 rename 机制）
      # Phase 4.1: 使用参数名 + body，依赖 capture-safe substitute 保证正确性
      { v = "L";
        p  = repr.param;
        pk = kindLib.serializeKind (repr.paramKind or kindLib.KStar);
        b  = serializeRepr repr.body.repr; }

    else if v == "Apply" then
      { v = "A";
        f = serializeRepr repr.fn.repr;
        a = map (x: serializeRepr x.repr) (repr.args or []); }

    else if v == "Constructor" then
      { v = "C";
        n  = repr.name;
        ps = repr.params or [];
        b  = serializeRepr repr.body.repr; }

    else if v == "Fn" then
      { v = "F";
        fr = serializeRepr repr.from.repr;
        to = serializeRepr repr.to.repr; }

    else if v == "ADT" then
      { v = "D";
        cl = repr.closed;
        vs = map serializeVariant (repr.variants or []); }

    else if v == "Constrained" then
      { v = "CT";
        b  = serializeRepr repr.base.repr;
        # constraints 按 canonical 顺序序列化（sort by serialized form）
        cs = let
          raw = map serializeConstraint (repr.constraints or []);
          sorted = lib.sort (a: b: builtins.toJSON a < builtins.toJSON b) raw;
        in sorted; }

    else if v == "Mu" then
      { v = "MU"; var = repr.var; b = serializeRepr repr.body.repr; }

    else if v == "Record" then
      let
        fnames = lib.sort (a: b: a < b) (builtins.attrNames (repr.fields or {}));
        fs = map (n: { k = n; t = serializeRepr repr.fields.${n}.repr; }) fnames;
      in { v = "REC"; fs = fs; }

    else if v == "RowExtend" then
      { v = "RE";
        l  = repr.label;
        ft = serializeRepr repr.fieldType.repr;
        r  = serializeRepr repr.rest.repr; }

    else if v == "RowEmpty" then { v = "R0"; }

    else if v == "RowVar" then { v = "RV"; n = repr.name; }

    else if v == "VariantRow" then
      let
        vnames = lib.sort (a: b: a < b) (builtins.attrNames (repr.variants or {}));
        vs = map (n: { k = n; t = serializeRepr repr.variants.${n}.repr; }) vnames;
        ext = if repr.extension == null then null
              else serializeRepr repr.extension.repr;
      in { v = "VR"; vs = vs; ext = ext; }

    else if v == "Pi"    then
      { v = "PI";
        p  = repr.param;
        d  = serializeRepr repr.domain.repr;
        b  = serializeRepr repr.body.repr; }

    else if v == "Sigma" then
      { v = "SG";
        p  = repr.param;
        d  = serializeRepr repr.domain.repr;
        b  = serializeRepr repr.body.repr; }

    else if v == "Effect" then
      { v = "EFF"; r = serializeRepr repr.effectRow.repr; }

    else if v == "EffectMerge" then
      { v = "EM";
        l  = serializeRepr repr.left.repr;
        r  = serializeRepr repr.right.repr; }

    else if v == "Opaque" then
      { v = "OP"; t = repr.tag; i = serializeRepr repr.inner.repr; }

    else if v == "Ascribe" then
      { v = "AS";
        e = serializeRepr repr.expr.repr;
        t = serializeRepr repr.type.repr; }

    else if v == "Refined" then
      { v = "RF";
        b  = serializeRepr repr.base.repr;
        pv = repr.predVar;
        pe = serializePred repr.predExpr; }

    else if v == "Sig" then
      let
        fnames = lib.sort (a: b: a < b) (builtins.attrNames (repr.fields or {}));
        fs = map (n: { k = n; t = serializeRepr repr.fields.${n}.repr; }) fnames;
      in { v = "SIG"; fs = fs; }

    else if v == "Struct" then
      { v = "STR";
        sg = serializeRepr repr.sig.repr;
        im = let
          inames = lib.sort (a: b: a < b) (builtins.attrNames (repr.impl or {}));
        in map (n: { k = n; t = serializeRepr repr.impl.${n}.repr; }) inames; }

    else if v == "ModFunctor" then
      { v = "MF";
        p  = repr.param;
        pt = serializeRepr repr.paramTy.repr;
        b  = serializeRepr repr.body.repr; }

    else if v == "Handler" then
      { v = "HD";
        e  = repr.effectTag;
        bs = map serializeBranch (repr.branches or []);
        rt = serializeRepr repr.returnType.repr; }

    else if v == "Kind" then
      { v = "KD"; f = builtins.toJSON (repr.form or {}); }

    else { v = "?"; raw = builtins.toJSON repr; };

  # ── canonical hash（INV-4 核心）──────────────────────────────────────────
  # Type: TypeRepr -> String
  canonicalHash = repr:
    builtins.hashString "sha256"
      (builtins.toJSON (serializeRepr repr));

  # Type: Type -> String  (对完整 Type 结构 hash)
  canonicalTypeHash = t:
    canonicalHash t.repr;
}
