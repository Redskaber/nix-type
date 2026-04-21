# constraint/unify_row.nix — Phase 3.3
# Row Unification（Open Record + RowVar Binding）
#
# Phase 3.3 新增：
#   P3.3-1: Open record pair 对齐（rowVar binding）
#   INV-ROW-3: Open record row unification sound
#
# 核心算法（Row Unification à la Wand/Rémy）：
#   unifyRow(r1, r2):
#     spine1 = unspine(r1)  → { fields: [(label,ty)]; tail: RowVar | RowEmpty }
#     spine2 = unspine(r2)  → { fields: [(label,ty)]; tail: RowVar | RowEmpty }
#
#     For each shared label:  unify(ty1, ty2)
#     Labels in r1 not in r2: require tail2 = RowVar(fresh) | tail2 has it
#     Labels in r2 not in r1: require tail1 = RowVar(fresh) | tail1 has it
#
#     tail1 = RowEmpty, tail2 = RowEmpty: all labels must match exactly
#     tail1 = RowVar(v1), tail2 = RowEmpty: bind v1 → missing labels from r2
#     tail1 = RowEmpty, tail2 = RowVar(v2): bind v2 → missing labels from r1
#     tail1 = RowVar(v1), tail2 = RowVar(v2): bind one to (missing + other var)
#
# 不变量：
#   INV-ROW-3: 若 unifyRow(r1, r2) = ok subst，则 subst(r1) ≈ subst(r2)（row equality）
#   INV-ROW-4: RowVar binding 无循环（occurs check）
{ lib, typeLib, reprLib, kindLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith withRepr;
  inherit (kindLib) KRow KStar;

  # ── RowVar 构造 ────────────────────────────────────────────────────────────────
  mkRowVar = name: mkTypeDefault { __variant = "RowVar"; inherit name; } KRow;
  mkRowEmpty    = mkTypeDefault { __variant = "RowEmpty"; } KRow;
  mkRowExtend   = label: fieldType: rest:
    mkTypeDefault { __variant = "RowExtend"; inherit label fieldType rest; } KRow;

  # ── Spine: unspine a row into fields + tail ───────────────────────────────────
  # Returns: { fields: [{ label: String; fieldType: Type }]; tail: Type; isClosed: Bool }
  unspineRow = ty:
    let r = ty.repr or {}; in
    if r.__variant or null == "RowExtend" then
      let inner = unspineRow (r.rest or mkRowEmpty); in
      { fields    = [ { label = r.label or ""; fieldType = r.fieldType or ty; } ]
                    ++ inner.fields;
        tail      = inner.tail;
        isClosed  = inner.isClosed; }
    else if r.__variant or null == "RowEmpty" then
      { fields = []; tail = ty; isClosed = true; }
    else if r.__variant or null == "RowVar" then
      { fields = []; tail = ty; isClosed = false; }
    else
      # Treat anything else as an opaque tail
      { fields = []; tail = ty; isClosed = false; };

  # ── Rebuild row from sorted (label,fieldType) list + tail ─────────────────────
  rebuildRow = fields: tail:
    let
      sorted = lib.sort (a: b: a.label < b.label) fields;
    in
    lib.foldr
      (f: acc: mkRowExtend f.label f.fieldType acc)
      tail
      sorted;

  # ── Index fields by label ─────────────────────────────────────────────────────
  fieldsIndex = fields:
    lib.listToAttrs (map (f: { name = f.label; value = f.fieldType; }) fields);

  # ── Row occurs check: does rowVar 'name' appear in 'ty' ───────────────────────
  rowVarOccurs = name: ty:
    let r = ty.repr or {}; in
    if r.__variant or null == "RowVar" then r.name or "" == name
    else if r.__variant or null == "RowExtend" then
      rowVarOccurs name (r.fieldType or ty) || rowVarOccurs name (r.rest or ty)
    else if r.__variant or null == "RowEmpty" then false
    else false;

in rec {

  # ════════════════════════════════════════════════════════════════════════════
  # Core: unifyRow
  # Returns: { ok: Bool; subst: AttrSet; error: String? }
  # subst maps type-variable names → Type (for row variables: "RowVar:name" → row)
  # ════════════════════════════════════════════════════════════════════════════

  # unifyRow : Type -> Type -> UnifResult
  # UnifResult = { ok: Bool; subst: AttrSet; constraints: [EqualityConstraint] }
  unifyRow = r1: r2:
    let
      s1 = unspineRow r1;
      s2 = unspineRow r2;

      idx1 = fieldsIndex s1.fields;
      idx2 = fieldsIndex s2.fields;

      labels1 = builtins.attrNames idx1;
      labels2 = builtins.attrNames idx2;

      # Shared labels → generate equality constraints
      sharedLabels = builtins.filter (l: idx2 ? ${l}) labels1;
      sharedConstraints = map (l: {
        __constraintTag = "Equality";
        lhs = idx1.${l};
        rhs = idx2.${l};
      }) sharedLabels;

      # Labels only in r1 (must be present in tail of r2 if open, else fail)
      onlyIn1 = builtins.filter (l: !(idx2 ? ${l})) labels1;
      fieldsOnlyIn1 = map (l: { label = l; fieldType = idx1.${l}; }) onlyIn1;

      # Labels only in r2
      onlyIn2 = builtins.filter (l: !(idx1 ? ${l})) labels2;
      fieldsOnlyIn2 = map (l: { label = l; fieldType = idx2.${l}; }) onlyIn2;

      tail1Var = s1.tail.repr.__variant or null;
      tail2Var = s2.tail.repr.__variant or null;
      rv1Name  = s1.tail.repr.name or null;
      rv2Name  = s2.tail.repr.name or null;

    in

    # Case 1: Both closed — all labels must match
    if s1.isClosed && s2.isClosed then
      if onlyIn1 != [] || onlyIn2 != [] then
        { ok = false;
          subst = {};
          constraints = [];
          error = "Row mismatch: closed rows differ in labels: "
                  + "only-in-r1=[${lib.concatStringsSep "," onlyIn1}] "
                  + "only-in-r2=[${lib.concatStringsSep "," onlyIn2}]"; }
      else
        { ok = true;
          subst = {};
          constraints = sharedConstraints; }

    # Case 2: r1 open, r2 closed — bind rv1 → row of onlyIn2 fields + RowEmpty
    else if !s1.isClosed && s2.isClosed && rv1Name != null then
      if onlyIn1 != [] then
        # r1 has labels not in (closed) r2 → fail
        { ok = false;
          subst = {};
          constraints = [];
          error = "Row mismatch: r1 has labels absent from closed r2: [${lib.concatStringsSep "," onlyIn1}]"; }
      else
        # Occurs check
        let rowBound = rebuildRow fieldsOnlyIn2 mkRowEmpty; in
        if rowVarOccurs rv1Name rowBound then
          { ok = false; subst = {}; constraints = [];
            error = "Row occurs check failed: ${rv1Name} in ${builtins.toString onlyIn2}"; }
        else
          { ok = true;
            subst = { "RowVar:${rv1Name}" = rowBound; };
            constraints = sharedConstraints; }

    # Case 3: r1 closed, r2 open — bind rv2 → row of onlyIn1 fields + RowEmpty
    else if s1.isClosed && !s2.isClosed && rv2Name != null then
      if onlyIn2 != [] then
        { ok = false;
          subst = {};
          constraints = [];
          error = "Row mismatch: r2 has labels absent from closed r1: [${lib.concatStringsSep "," onlyIn2}]"; }
      else
        let rowBound = rebuildRow fieldsOnlyIn1 mkRowEmpty; in
        if rowVarOccurs rv2Name rowBound then
          { ok = false; subst = {}; constraints = [];
            error = "Row occurs check failed: ${rv2Name}"; }
        else
          { ok = true;
            subst = { "RowVar:${rv2Name}" = rowBound; };
            constraints = sharedConstraints; }

    # Case 4: Both open — bind one to (missing fields + other var)
    else if !s1.isClosed && !s2.isClosed && rv1Name != null && rv2Name != null then
      if rv1Name == rv2Name then
        # Same row variable → onlyIn1 and onlyIn2 must be empty
        if onlyIn1 != [] || onlyIn2 != [] then
          { ok = false; subst = {}; constraints = [];
            error = "Row variable ${rv1Name} unified with itself but different fields"; }
        else
          { ok = true; subst = {}; constraints = sharedConstraints; }
      else
        # Bind rv1 → fieldsOnlyIn2 ++ RowVar(rv2)
        # Bind rv2 → fieldsOnlyIn1 ++ RowVar(rv1) ... but we only need one binding
        # Canonical: bind the lexicographically smaller variable
        # FIXME: Expecting a binding like `path = value;` or `inherit attr;`
        let
          (boundName, freeName, extraFields) =
            if rv1Name < rv2Name
            then { _1 = rv1Name; _2 = rv2Name; _3 = fieldsOnlyIn2; }
            else { _1 = rv2Name; _2 = rv1Name; _3 = fieldsOnlyIn1; };
          rowBound = rebuildRow extraFields (mkRowVar freeName);
        in
        if rowVarOccurs boundName rowBound then
          { ok = false; subst = {}; constraints = [];
            error = "Row occurs check: ${boundName} in bound row"; }
        else
          { ok = true;
            subst = { "RowVar:${boundName}" = rowBound; };
            constraints = sharedConstraints; }

    # Fallback: structural unification failure
    else
      { ok = false;
        subst = {};
        constraints = [];
        error = "Row unification: incompatible row tails"; };

  # ════════════════════════════════════════════════════════════════════════════
  # Apply row substitution to a type
  # ════════════════════════════════════════════════════════════════════════════

  # applyRowSubst : AttrSet -> Type -> Type
  applyRowSubst = rowSubst: ty:
    if rowSubst == {} then ty
    else _applyRowSubstT rowSubst ty;

  _applyRowSubstT = rowSubst: ty:
    let
      r = ty.repr or {};
      v = r.__variant or null;
      go = _applyRowSubstT rowSubst;
    in
    if v == "RowVar" then
      let key = "RowVar:${r.name or ""}"; in
      if rowSubst ? ${key} then rowSubst.${key}
      else ty
    else if v == "RowExtend" then
      withRepr ty (r // {
        fieldType = go (r.fieldType or ty);
        rest      = go (r.rest or ty);
      })
    else if v == "Record" then
      withRepr ty (r // { fields = builtins.mapAttrs (_: go) (r.fields or {}); })
    else if v == "Fn" then
      withRepr ty (r // { from = go (r.from or ty); to = go (r.to or ty); })
    else if v == "Apply" then
      withRepr ty (r // { fn = go (r.fn or ty); args = map go (r.args or []); })
    else if v == "Constrained" then
      withRepr ty (r // { base = go (r.base or ty); })
    else
      ty;

  # ════════════════════════════════════════════════════════════════════════════
  # Public API helpers
  # ════════════════════════════════════════════════════════════════════════════

  inherit mkRowVar mkRowEmpty mkRowExtend unspineRow rebuildRow;

  # Check if two row types are structurally equal (after canonical sort)
  rowTypesEq = r1: r2:
    let
      s1 = unspineRow r1;
      s2 = unspineRow r2;
      idx1 = fieldsIndex s1.fields;
      idx2 = fieldsIndex s2.fields;
    in
    builtins.attrNames idx1 == builtins.attrNames idx2
    && s1.isClosed == s2.isClosed
    && (if !s1.isClosed && !s2.isClosed
        then (s1.tail.repr.name or null) == (s2.tail.repr.name or null)
        else true);

}
