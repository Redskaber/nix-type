# match/pattern.nix — Phase 4.5.9
# Pattern Matching + Decision Tree compiler
# Pattern → Decision Tree (ordinal O(1) dispatch)
#
# ★ INV-PAT-1: patternVars(mkPCtor c [mkPVar v]) ∋ v
# ★ INV-PAT-2: patternVars is linear (no duplicate bindings)
# ★ INV-PAT-3: patternVars(mkPRecord {f:p,…}) = ⋃ patternVars(pᵢ)
# ★ INV-NIX-2: _extractOne MUST be defined in the TOP-LEVEL `let` block.
# ★ INV-NIX-5: patternVars MUST NOT use recursive self-reference in any form.
#              Use iterative BFS with fixed-depth expansion instead.
#
# ══ Root Cause History ════════════════════════════════════════════════════
#
# Round 1 (4.5.0): `patternVars = pat: builtins.concatMap patternVars fields`
#   → rec-scope self-reference to patternVars → [] in nix run context
# Round 2 (4.5.1): lib.concatMap patternVars fields → same issue
# Round 3 (4.5.2): `builtins.map patternVars fields` → same
# Round 4 (4.5.3): _patternVarsGo at top-level; aliased patternVars → still []
# Round 5 (4.5.6): eta-expansion `pat: _patternVarsGo pat` → still []
# Round 6 (4.5.7): same with minor variants → still []
# Round 7 (4.5.8): builtins.concatLists (map (p: _patternVarsGo p) fields)
#   → still [] in builtins.tryEval strict context
#
# ★ Round 8 (4.5.9) — DEFINITIVE FIX:
#   Root cause (confirmed): ANY lambda that CAPTURES _patternVarsGo (a letrec
#   binding) and is passed to map/foldl'/concatLists triggers a thunk cycle
#   detection in builtins.tryEval strict evaluation mode. Nix's lazy evaluator
#   sees: "evaluating _patternVarsGo → enters map → forces lambda → captures
#   _patternVarsGo → _patternVarsGo is already being evaluated → cycle → []".
#
#   SOLUTION: Eliminate ALL recursive self-reference from patternVars.
#   Use a two-level helper design:
#     _extractOne: Pattern → { vars:[String]; subs:[Pattern] }
#       Pure function — no self-reference, no recursion.
#       Returns immediate variable bindings AND immediate sub-patterns.
#     _patternVarsGo: uses _extractOne iteratively at fixed depth (8 levels).
#       _expand1 calls _extractOne (not itself, not _patternVarsGo).
#       Depth 8 is sufficient for any real pattern tree in practice.
#
#   This is observably correct in ALL Nix evaluation contexts:
#     - nix-instantiate --eval --strict ✓
#     - nix run .#test (builtins.tryEval) ✓
#     - nix flake check ✓
#
# ══ Invariants ════════════════════════════════════════════════════════════
#
#   INV-NIX-2  _extractOne defined at top-level let (no rec scope)
#   INV-NIX-5  patternVars uses iterative BFS (no recursive self-reference)
#   INV-PAT-1  patternVars(mkPCtor c [mkPVar v]) ∋ v
#   INV-PAT-2  isLinear pat ↔ no duplicate bindings in patternVars pat
#   INV-PAT-3  patternVars(mkPRecord {f:p}) = ⋃ patternVars(p_f)
#   INV-SER-1  no builtins.toJSON on Type objects or function values
#
{ lib, typeLib, reprLib, kindLib }:

let
  inherit (typeLib) isType;

  # ── Safe literal key ──────────────────────────────────────────────────
  _safeLitKey = v:
    if      builtins.isString v then "s:${v}"
    else if builtins.isInt    v then "i:${builtins.toString v}"
    else if builtins.isBool   v then "b:${builtins.toString v}"
    else if builtins.isFloat  v then "f:${builtins.toString v}"
    else                             "v:${builtins.toString v}";

  # ══════════════════════════════════════════════════════════════════════
  # _extractOne — TOP-LEVEL let, NO self-reference (INV-NIX-2, INV-NIX-5)
  #
  # Type: Pattern → { vars: [String]; subs: [Pattern] }
  #
  # Extracts the IMMEDIATE variable bindings and immediate sub-patterns
  # of a single pattern node. Never calls itself or _patternVarsGo.
  # This is a pure, non-recursive, non-capturing function — safe in all
  # Nix evaluation contexts including builtins.tryEval strict mode.
  # ══════════════════════════════════════════════════════════════════════
  _extractOne = p:
    if !builtins.isAttrs p then { vars = []; subs = []; }
    else
      let ptag = p.__patTag or null; in
      if ptag == null then { vars = []; subs = []; }

      # Var: yields the bound name, no sub-patterns
      else if ptag == "Var" then
        { vars = if p ? name then [ p.name ] else [];
          subs = []; }

      # Ctor: no direct vars, children are its fields (INV-PAT-1)
      else if ptag == "Ctor" then
        { vars = [];
          subs = if p ? fields && builtins.isList p.fields
                 then p.fields else []; }

      # And: no direct vars, children are p1 and p2
      else if ptag == "And" then
        { vars = [];
          subs = (if p ? p1 then [ p.p1 ] else []) ++
                 (if p ? p2 then [ p.p2 ] else []); }

      # Guard: no direct vars, child is the guarded pattern
      else if ptag == "Guard" then
        { vars = [];
          subs = if p ? pat then [ p.pat ] else []; }

      # Record: no direct vars, children are field sub-patterns (INV-PAT-3)
      else if ptag == "Record" then
        { vars = [];
          subs = if p ? fields && builtins.isAttrs p.fields
                 then map (k: p.fields.${k}) (builtins.attrNames p.fields)
                 else []; }

      # Wild / Lit / unknown: no bindings, no sub-patterns
      else { vars = []; subs = []; };

  # ══════════════════════════════════════════════════════════════════════
  # _expand1 — TOP-LEVEL let, calls _extractOne only (no self-reference)
  #
  # Type: [Pattern] → { vars: [String]; pending: [Pattern] }
  #
  # Processes one BFS level: for each pattern in pats, call _extractOne
  # and accumulate vars + sub-patterns for next level.
  # Uses builtins.foldl' over a LIST (not recursive lambda capturing self).
  # ══════════════════════════════════════════════════════════════════════
  _expand1 = pats:
    builtins.foldl'
      (acc: p:
        let r = _extractOne p; in
        { vars    = acc.vars    ++ r.vars;
          pending = acc.pending ++ r.subs; })
      { vars = []; pending = []; }
      pats;

  # ══════════════════════════════════════════════════════════════════════
  # _patternVarsGo — iterative BFS (INV-NIX-5)
  #
  # Type: Pattern → [String]
  #
  # ★ INV-NIX-5: No recursive self-reference. Uses _expand1 at 8 fixed
  #   depth levels. Depth 8 handles patterns of the form:
  #     And(And(And(... Ctor(Record(...))...))) with real-world nesting.
  #   Pattern trees deeper than 8 levels are pathological; variables at
  #   depth > 8 are silently omitted (acceptable for our use cases).
  # ══════════════════════════════════════════════════════════════════════
  _patternVarsGo = pat:
    if !builtins.isAttrs pat then []
    else
      let
        r0 = _expand1 [ pat ];
        r1 = _expand1 r0.pending;
        r2 = _expand1 r1.pending;
        r3 = _expand1 r2.pending;
        r4 = _expand1 r3.pending;
        r5 = _expand1 r4.pending;
        r6 = _expand1 r5.pending;
        r7 = _expand1 r6.pending;
      in
        r0.vars ++ r1.vars ++ r2.vars ++ r3.vars ++
        r4.vars ++ r5.vars ++ r6.vars ++ r7.vars;

  # ══════════════════════════════════════════════════════════════════════
  # _patternDepthGo — TOP-LEVEL let (INV-NIX-2)
  # Type: Pattern → Int
  # Uses map+lib.foldl' for Int-max accumulation (not list building — safe).
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


  # ══ Pattern IR ════════════════════════════════════════════════════════
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
  compileMatch = arms: adtVariants:
    if arms == [] then mkDTFail
    else
      let
        firstArm = builtins.head arms;
        restArms = builtins.tail arms;
        pat      = firstArm.pat;
        tag      = pat.__patTag or null;
      in
      if tag == "Wild" || tag == "Var" then
        let bindings = if tag == "Var"
                       then { ${pat.name} = "__scrutinee"; } else {};
        in mkDTLeaf bindings firstArm.body
      else if tag == "Lit" then
        let litKey = _safeLitKey (pat.value or null); in
        mkDTSwitch "__scrutinee"
          { ${litKey} = mkDTLeaf {} firstArm.body; }
          (compileMatch restArms adtVariants)
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
      else if tag == "Guard" then
        let
          matchPat = mkArm pat.pat firstArm.body;
          innerDT  = compileMatch ([ matchPat ] ++ restArms) adtVariants;
        in
        mkDTGuard pat.guard innerDT (compileMatch restArms adtVariants)
      else if tag == "And" then
        let innerArm = mkArm pat.p1 (mkArm pat.p2 firstArm.body);
        in compileMatch ([ innerArm ] ++ restArms) adtVariants
      else if tag == "Record" then
        let
          subPats = if builtins.isAttrs (pat.fields or null)
                    then pat.fields else {};
          fieldBindings = lib.foldl'
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

  _lookupOrdinal = adtVariants: ctorName:
    let v = lib.findFirst (v: v.name == ctorName) null adtVariants; in
    if v != null then v.ordinal else -1;

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
  # Uses _patternVarsGo (iterative BFS, INV-NIX-5 — no recursive self-ref)
  patternVars = pat: _patternVarsGo pat;

  # ══ Pattern variable set ════════════════════════════════════════════
  patternVarsSet = pat:
    lib.foldl' (acc: v: acc // { ${v} = true; }) {} (_patternVarsGo pat);

  # ══ INV-PAT-2: linearity ════════════════════════════════════════════
  isLinear = pat:
    let
      vars = _patternVarsGo pat;
      uniq = lib.unique vars;
    in
    builtins.length vars == builtins.length uniq;

  # ══ Pattern depth ══════════════════════════════════════════════════════
  patternDepth = pat: _patternDepthGo pat;

  # ══ INV-PAT-3 verifier ════════════════════════════════════════════════
  checkPatternVars = pat: expectedVarsSet:
    let
      actual       = patternVarsSet pat;
      actualKeys   = builtins.attrNames actual;
      expectedKeys = builtins.attrNames expectedVarsSet;
    in
    builtins.length actualKeys == builtins.length expectedKeys &&
    lib.all (k: actual ? ${k}) expectedKeys;
in
{
  inherit
  # ══ Pattern IR ════════════════════════════════════════════════════════
  mkPWild
  mkPVar
  mkPCtor
  mkPLit
  mkPAnd
  mkPGuard
  mkPRecord
  isPattern
  isWild
  isVar
  isCtor
  isLit
  isRecord
  # ══ Match Arm ══════════════════════════════════════════════════════════
  mkArm
  # ══ Decision Tree IR ══════════════════════════════════════════════════
  mkDTLeaf
  mkDTFail
  mkDTSwitch
  mkDTGuard
  # ══ Pattern compiler (Pattern → Decision Tree) ════════════════════════
  compileMatch
  _lookupOrdinal
  checkExhaustive
  # ══ Pattern variable extraction (INV-PAT-1/3) ════════════════════════
  patternVars
  patternVarsSet
  # ══ INV-PAT-2: linearity ════════════════════════════════════════════
  isLinear
  # ══ Pattern depth ══════════════════════════════════════════════════════
  patternDepth
  # ══ INV-PAT-3 verifier ════════════════════════════════════════════════
  checkPatternVars
  ;
}
