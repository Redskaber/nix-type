# match/pattern.nix — Phase 4.5.6
# Pattern Matching + Decision Tree compiler
# Pattern → Decision Tree (ordinal O(1) dispatch)
#
# ★ INV-PAT-1: patternVars(mkPCtor c [mkPVar v]) ∋ v
# ★ INV-PAT-2: patternVars is linear (no duplicate bindings)
# ★ INV-PAT-3: patternVars(mkPRecord {f:p,…}) = ⋃ patternVars(pᵢ)
# ★ INV-NIX-2: _patternVarsGo and _patternDepthGo MUST be defined in the
#              TOP-LEVEL `let` block (before `in rec {`), never inside rec{}.
#
# ══ Root Cause of INV-PAT-1 Failure ══════════════════════════════════════
#
#   BUGGY pattern (DO NOT USE):
#
#     in rec {
#       patternVars = pat:
#         let go = pat: ...
#                  "Ctor" → builtins.foldl' (acc: p: acc ++ go p) [] fields;
#         in go pat;
#     }
#
#   When Nix evaluates `builtins.foldl' f [] fields`, it forces the thunk
#   `f`. The thunk `(acc: p: acc ++ go p)` closes over `go`. But `go` is a
#   `let` binding *inside* the `patternVars` thunk body. Because `patternVars`
#   is a `rec{}` self-reference, forcing it re-enters its own thunk → Nix
#   black-hole (the thunk evaluates to its own unevaluated state) → returns []
#   silently instead of the correct variable list.
#
#   CORRECT pattern (this file):
#
#     let
#       _patternVarsGo = pat: ...  # ← plain let binding, top-level
#         "Ctor" → builtins.foldl' (acc: p: acc ++ _patternVarsGo p) [] fields;
#     in rec {
#       patternVars = _patternVarsGo;  # ← alias only, no re-entry
#     }
#
#   At the top-level `let`, self-recursion is standard Nix letrec semantics
#   (safe). The thunk for `_patternVarsGo` is NOT inside `rec{}`, so no
#   rec-self-reference cycle can form. Passing it to `builtins.foldl'` is safe.
#
# ══ Invariants ════════════════════════════════════════════════════════════
#
#   INV-NIX-2  _patternVarsGo/_patternDepthGo defined at top-level let
#   INV-PAT-1  patternVars(mkPCtor c [mkPVar v]) ∋ v
#   INV-PAT-2  isLinear pat ↔ no duplicate bindings in patternVars pat
#   INV-PAT-3  patternVars(mkPRecord {f:p}) = ⋃ patternVars(p_f)
#   INV-SER-1  no builtins.toJSON on Type objects or function values
#
{ lib, typeLib, reprLib, kindLib }:

let
  inherit (typeLib) isType;

  # ── Safe literal key ──────────────────────────────────────────────────
  # builtins.toString is total; prefix prevents int/string collision.
  _safeLitKey = v:
    if      builtins.isString v then "s:${v}"
    else if builtins.isInt    v then "i:${builtins.toString v}"
    else if builtins.isBool   v then "b:${builtins.toString v}"
    else if builtins.isFloat  v then "f:${builtins.toString v}"
    else                             "v:${builtins.toString v}";

  # ══════════════════════════════════════════════════════════════════════
  # _patternVarsGo — TOP-LEVEL let (INV-NIX-2 ★ INV-PAT-1/3 definitive fix)
  #
  # Type: Pattern → [String]
  #
  # This is the ONLY correct location for a recursive pattern-variable
  # extractor. Defined here, self-recursion is standard letrec, and there
  # is no rec{} thunk cycle.  All public exports are simple aliases below.
  # ══════════════════════════════════════════════════════════════════════
  _patternVarsGo = pat:
    if !builtins.isAttrs pat then []
    else
      let tag = pat.__patTag or null; in
      if tag == null then []

      # Var: single binding
      else if tag == "Var" then
        (if pat ? name then [ pat.name ] else [])

      # Ctor: recurse into each field (INV-PAT-1)
      # builtins.foldl' is safe here because _patternVarsGo is a plain
      # let-binding (not a rec{} thunk) — no re-entry risk.
      else if tag == "Ctor" then
        let fields = if pat ? fields && builtins.isList pat.fields
                     then pat.fields else [];
        in builtins.foldl'
             (acc: p: acc ++ _patternVarsGo p)
             []
             fields

      # And: union of both sub-patterns
      else if tag == "And" then
        (if pat ? p1 then _patternVarsGo pat.p1 else []) ++
        (if pat ? p2 then _patternVarsGo pat.p2 else [])

      # Guard: variables come from the guarded pattern only
      else if tag == "Guard" then
        (if pat ? pat then _patternVarsGo pat.pat else [])

      # Record: recurse into every field sub-pattern (INV-PAT-3)
      else if tag == "Record" then
        if pat ? fields && builtins.isAttrs pat.fields
        then builtins.foldl'
               (acc: k: acc ++ _patternVarsGo pat.fields.${k})
               []
               (builtins.attrNames pat.fields)
        else []

      # Wild / Lit / unknown: no bindings
      else [];

  # ══════════════════════════════════════════════════════════════════════
  # _patternDepthGo — TOP-LEVEL let (INV-NIX-2, same rationale)
  # Type: Pattern → Int
  # ══════════════════════════════════════════════════════════════════════
  _patternDepthGo = pat:
    if !builtins.isAttrs pat then 0
    else
      let tag = pat.__patTag or null; in
      if tag == null || tag == "Wild" || tag == "Var" || tag == "Lit" then 0

      else if tag == "Ctor" then
        let
          fields = pat.fields or [];
          depths = if builtins.isList fields
                   then map (p: _patternDepthGo p) fields else [];
        in
        1 + lib.foldl' (acc: d: if d > acc then d else acc) 0 depths

      else if tag == "And" then
        let
          d1 = if pat ? p1 then _patternDepthGo pat.p1 else 0;
          d2 = if pat ? p2 then _patternDepthGo pat.p2 else 0;
        in
        1 + (if d1 > d2 then d1 else d2)

      else if tag == "Guard" then
        1 + (if pat ? pat then _patternDepthGo pat.pat else 0)

      else if tag == "Record" then
        if pat ? fields && builtins.isAttrs pat.fields
        then
          let depths = map (k: _patternDepthGo pat.fields.${k})
                           (builtins.attrNames pat.fields);
          in 1 + lib.foldl' (acc: d: if d > acc then d else acc) 0 depths
        else 1

      else 0;

in rec {

  # ══ Pattern IR ════════════════════════════════════════════════════════
  # Constructors: pure attr-set records, no functions embedded → INV-SER-1 safe
  mkPWild   = { __patTag = "Wild"; };
  mkPVar    = name:   { __patTag = "Var";    name   = name;   };
  mkPCtor   = name: fields:
                      { __patTag = "Ctor";   name   = name;   fields = fields; };
  mkPLit    = value:  { __patTag = "Lit";    value  = value;  };
  mkPAnd    = p1: p2: { __patTag = "And";    p1     = p1;     p2 = p2; };
  mkPGuard  = pat: guard:
                      { __patTag = "Guard";  pat    = pat;    guard = guard; };
  mkPRecord = fields: { __patTag = "Record"; fields = fields; };

  # ── Predicates ──────────────────────────────────────────────────────
  isPattern = p: builtins.isAttrs p && p ? __patTag;
  isWild    = p: isPattern p && p.__patTag == "Wild";
  isVar     = p: isPattern p && p.__patTag == "Var";
  isCtor    = p: isPattern p && p.__patTag == "Ctor";
  isLit     = p: isPattern p && p.__patTag == "Lit";
  isRecord  = p: isPattern p && p.__patTag == "Record";

  # ══ Match Arm ══════════════════════════════════════════════════════════
  mkArm = pat: body: { __armTag = "Arm"; pat = pat; body = body; };

  # ══ Decision Tree IR ══════════════════════════════════════════════════
  mkDTLeaf   = bindings: body:
    { __dtTag = "Leaf"; bindings = bindings; body = body; };
  mkDTFail   = { __dtTag = "Fail"; };
  mkDTSwitch = scrutinee: branches: default_:
    { __dtTag = "Switch"; scrutinee = scrutinee;
      branches = branches; default_ = default_; };
  mkDTGuard  = guard: yes: no:
    { __dtTag = "Guard"; guard = guard; yes = yes; no = no; };

  # ══ Pattern compiler (Pattern → Decision Tree) ════════════════════════
  #
  # Compiles a list of match arms + ADT variant descriptors into a decision
  # tree for O(1) ordinal dispatch.  The `adtVariants` list has elements of
  # the form `{ name = "CtorName"; ordinal = N; }`.
  compileMatch = arms: adtVariants:
    if arms == [] then mkDTFail
    else
      let
        firstArm = builtins.head arms;
        restArms = builtins.tail arms;
        pat      = firstArm.pat;
        tag      = pat.__patTag or null;
      in

      # Wild / Var → unconditional leaf
      if tag == "Wild" || tag == "Var" then
        let bindings = if tag == "Var"
                       then { ${pat.name} = "__scrutinee"; } else {};
        in mkDTLeaf bindings firstArm.body

      # Lit → switch on serialised literal key
      else if tag == "Lit" then
        let litKey = _safeLitKey (pat.value or null); in
        mkDTSwitch "__scrutinee"
          { ${litKey} = mkDTLeaf {} firstArm.body; }
          (compileMatch restArms adtVariants)

      # Ctor → switch on constructor ordinal
      else if tag == "Ctor" then
        let
          ctorOrdinal = _lookupOrdinal adtVariants pat.name;
          ctorKey     = builtins.toString ctorOrdinal;
          ctorFields  = pat.fields or [];
          fieldArms   =
            if ctorFields == [] then [ (mkArm mkPWild firstArm.body) ]
            else [ (mkArm (builtins.head ctorFields) firstArm.body) ];
          innerDT = compileMatch fieldArms adtVariants;
          restDT  = compileMatch restArms  adtVariants;
        in
        mkDTSwitch "__scrutinee" { ${ctorKey} = innerDT; } restDT

      # Guard → conditional branch
      else if tag == "Guard" then
        let
          matchPat = mkArm pat.pat firstArm.body;
          innerDT  = compileMatch ([ matchPat ] ++ restArms) adtVariants;
        in
        mkDTGuard pat.guard innerDT (compileMatch restArms adtVariants)

      # And → nested arm
      else if tag == "And" then
        let
          innerArm = mkArm pat.p1 (mkArm pat.p2 firstArm.body);
        in
        compileMatch ([ innerArm ] ++ restArms) adtVariants

      # Record → build field-accessor binding map
      else if tag == "Record" then
        let
          subPats = if builtins.isAttrs (pat.fields or null)
                    then pat.fields else {};
          # _patternVarsGo is the top-level helper — safe to call from rec{}
          fieldBindings = builtins.foldl'
            (acc: fieldName:
              let
                subPat  = subPats.${fieldName} or mkPWild;
                subVars = _patternVarsGo subPat;
              in
              lib.foldl'
                (innerAcc: varName:
                  innerAcc // { ${varName} = "__scrutinee.${fieldName}"; })
                acc
                subVars)
            {}
            (builtins.attrNames subPats);
        in
        mkDTLeaf fieldBindings firstArm.body

      else mkDTFail;

  # ── Ordinal lookup ────────────────────────────────────────────────────
  _lookupOrdinal = adtVariants: ctorName:
    let v = lib.findFirst (v: v.name == ctorName) null adtVariants; in
    if v != null then v.ordinal else -1;

  # ══ Exhaustiveness check ══════════════════════════════════════════════
  checkExhaustive = arms: adtVariants:
    let
      ctorsCovered = lib.concatMap (arm:
        let pat = arm.pat; in
        if      (pat.__patTag or null) == "Ctor" then [ pat.name ]
        else if (pat.__patTag or null) == "Wild" ||
                (pat.__patTag or null) == "Var"
        then map (v: v.name) adtVariants
        else []
      ) arms;
      allCtors = map (v: v.name) adtVariants;
      missing  = lib.filter (c: !(builtins.elem c ctorsCovered)) allCtors;
    in
    { exhaustive = missing == []; missing = missing; };

  # ══ Pattern variable extraction (INV-PAT-1/3) ════════════════════════
  # Public alias to the top-level helper.  This is just an alias — no logic.
  # ★ DO NOT inline a `let go = …; in go` here; that recreates the thunk cycle.
  patternVars = _patternVarsGo;

  # ══ Pattern variable set (deduplicated attr-set) ═══════════════════════
  patternVarsSet = pat:
    lib.foldl' (acc: v: acc // { ${v} = true; }) {} (patternVars pat);

  # ══ INV-PAT-2: linearity check ════════════════════════════════════════
  isLinear = pat:
    let
      vars = patternVars pat;
      uniq = lib.unique vars;
    in
    builtins.length vars == builtins.length uniq;

  # ══ Pattern depth ══════════════════════════════════════════════════════
  patternDepth = _patternDepthGo;

  # ══ INV-PAT-3 verifier ════════════════════════════════════════════════
  # Type: Pattern → {String → Bool} → Bool
  checkPatternVars = pat: expectedVarsSet:
    let
      actual       = patternVarsSet pat;
      actualKeys   = builtins.attrNames actual;
      expectedKeys = builtins.attrNames expectedVarsSet;
    in
    builtins.length actualKeys == builtins.length expectedKeys &&
    lib.all (k: actual ? ${k}) expectedKeys;
}
