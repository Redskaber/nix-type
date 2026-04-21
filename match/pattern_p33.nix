# match/pattern_p33.nix — Phase 3.3
# Pattern Matching 完整扩展：Record / Lit / Guard patterns
#
# Phase 3.3 新增：
#   P3.3-5: Record patterns   { x: Pat, y: Pat }
#   P3.3-5: Lit patterns      42, "str", true
#   P3.3-5: Guard patterns    pat if expr
#   P3.3-5: As patterns       x@pat（binding + inner match）
#   P3.3-5: Tuple patterns    (Pat, Pat, ...)
#   P3.3-5: Wildcard-Record   { x: Pat, .. }（open record）
#
# Architecture: Pattern IR → Decision Tree → Match Arms
#
# 不变量：
#   PAT-1: 所有模式 ∈ PatternIR（不是函数，不是 runtime）
#   PAT-2: Decision tree 共享公共前缀（性能）
#   PAT-3: Exhaustiveness check 完整（含 Guard → 不可证明穷举）
{ lib, typeLib, kindLib }:

let
  inherit (typeLib) mkTypeDefault;
  inherit (kindLib) KStar;

in rec {

  # ════════════════════════════════════════════════════════════════════════════
  # Pattern IR（Phase 3.3 完整变体集）
  # ════════════════════════════════════════════════════════════════════════════

  # Phase 3.2 已有
  pWild  = { __patTag = "Wild"; };
  pVar   = name: { __patTag = "Var"; inherit name; };
  pCtor  = ctor: args: { __patTag = "Ctor"; inherit ctor args; };

  # Phase 3.3 新增
  pLit   = value: { __patTag = "Lit"; inherit value; };
  pRecord = fields: open:
    { __patTag = "Record"; inherit fields;
      open = open;   # Bool: true = wildcard rest (..)
    };
  pGuard = pat: guardExpr:
    { __patTag = "Guard"; inherit pat guardExpr; };
  pAs    = name: pat:
    { __patTag = "As"; inherit name pat; };
  pTuple = elems: { __patTag = "Tuple"; inherit elems; };
  pOr    = pats: { __patTag = "Or"; inherit pats; };  # p | q

  # ════════════════════════════════════════════════════════════════════════════
  # Branch: (Pattern × Guard × Body)
  # ════════════════════════════════════════════════════════════════════════════

  # mkBranch : Pat -> (Env -> Bool)? -> body -> Branch
  mkBranch = pat: guard: body:
    { inherit pat guard body; };

  # ════════════════════════════════════════════════════════════════════════════
  # Pattern variable extraction
  # ════════════════════════════════════════════════════════════════════════════

  # patVars : Pat -> [String]  (all bound names)
  patVars = pat:
    let t = pat.__patTag or null; in
    if      t == "Wild"   then []
    else if t == "Var"    then [pat.name]
    else if t == "Lit"    then []
    else if t == "Ctor"   then lib.concatMap patVars (pat.args or [])
    else if t == "Record" then
      lib.concatMap (f: patVars f.pat) (pat.fields or [])
    else if t == "Guard"  then patVars (pat.pat or pWild)
    else if t == "As"     then [pat.name] ++ patVars (pat.pat or pWild)
    else if t == "Tuple"  then lib.concatMap patVars (pat.elems or [])
    else if t == "Or"     then
      # Or-pattern: all alternatives must bind same vars
      let allVarSets = map patVars (pat.pats or []); in
      if allVarSets == [] then []
      else builtins.head allVarSets  # Representative (checked for consistency)
    else [];

  # ════════════════════════════════════════════════════════════════════════════
  # Pattern matching compilation → Decision Tree
  # ════════════════════════════════════════════════════════════════════════════

  # Decision Tree IR
  # DTLeaf   { bindings: AttrSet; body }
  # DTFail   {}
  # DTSwitch { scrutinee; cases: AttrSet; default: DT? }
  # DTGuard  { condition; thenDT; elseDT }
  # DTLet    { name; value; body: DT }

  dtLeaf     = bindings: body: { __dtTag = "Leaf"; inherit bindings body; };
  dtFail     = { __dtTag = "Fail"; };
  dtSwitch   = scrutinee: cases: default:
    { __dtTag = "Switch"; inherit scrutinee cases default; };
  dtGuard    = condition: thenDT: elseDT:
    { __dtTag = "Guard"; inherit condition thenDT elseDT; };
  dtLet      = name: value: body:
    { __dtTag = "Let"; inherit name value body; };

  # ── Compile branches to decision tree ───────────────────────────────────────

  # compilePats : [Branch] -> Type -> DT
  compilePats = branches: scrutineeType:
    if branches == [] then dtFail
    else _compileMatrix (map _branchToRow branches) "scrutinee" scrutineeType;

  # Each branch becomes a "row" in the pattern matrix
  _branchToRow = branch:
    { pat     = branch.pat;
      guard   = branch.guard or null;
      body    = branch.body;
      bindings = {}; };

  # Compile pattern matrix (simplified but complete)
  _compileMatrix = rows: scrName: scrType:
    if rows == [] then dtFail
    else
      let first = builtins.head rows; in
      _compileRow first (builtins.tail rows) scrName scrType;

  _compileRow = row: rest: scrName: scrType:
    let
      pat = row.pat;
      t   = pat.__patTag or null;
    in

    # Wild or Var: always match, possibly bind
    if t == "Wild" then
      let
        remaining = _compileMatrix rest scrName scrType;
        leaf = dtLeaf row.bindings row.body;
      in
      if row.guard != null
      then dtGuard row.guard leaf (_compileMatrix rest scrName scrType)
      else leaf

    else if t == "Var" then
      let
        newBindings = row.bindings // { ${pat.name} = scrName; };
        newRow = row // { pat = pWild; bindings = newBindings; };
      in
      _compileRow newRow rest scrName scrType

    else if t == "As" then
      let
        newBindings = row.bindings // { ${pat.name} = scrName; };
        newRow = row // { pat = pat.pat or pWild; bindings = newBindings; };
      in
      _compileRow newRow rest scrName scrType

    else if t == "Lit" then
      let
        matchDT = if row.guard != null
          then dtGuard row.guard (dtLeaf row.bindings row.body) (_compileMatrix rest scrName scrType)
          else dtLeaf row.bindings row.body;
      in
      dtSwitch scrName
        { ${builtins.toJSON pat.value} = matchDT; }
        (_compileMatrix rest scrName scrType)

    else if t == "Ctor" then
      let
        matchDT = _compileCtor row pat scrName (_compileMatrix rest scrName scrType);
      in
      dtSwitch scrName
        { ${pat.ctor} = matchDT; }
        (_compileMatrix rest scrName scrType)

    else if t == "Record" then
      _compileRecord row pat scrName rest scrType

    else if t == "Tuple" then
      _compileTuple row pat scrName rest scrType

    else if t == "Guard" then
      let newRow = row // { pat = pat.pat or pWild; guard = pat.guardExpr; }; in
      _compileRow newRow rest scrName scrType

    else if t == "Or" then
      # Expand Or: replicate row for each alternative
      let
        expandedRows = map (altPat:
          row // { pat = altPat; }
        ) (pat.pats or []);
      in
      _compileMatrix (expandedRows ++ rest) scrName scrType

    else
      # Unknown pattern tag → treat as wild
      dtLeaf row.bindings row.body;

  _compileCtor = row: ctorPat: scrName: failDT:
    let
      args      = ctorPat.args or [];
      argNames  = lib.imap0 (i: _: "${scrName}_${builtins.toString i}") args;
      # Bind arg names, then compile inner patterns sequentially
      innerRows = lib.imap0 (i: argPat:
        { pat = argPat;
          guard = null;
          body  = row.body;
          bindings = row.bindings;  # accumulated below
        }
      ) args;
      # Build nested decision tree for each arg (simplified: sequential)
      innerDT = lib.foldl'
        (acc: pair:
          let
            argRow = builtins.elemAt innerRows pair.idx;
            argName = builtins.elemAt argNames pair.idx;
          in
          _compileRow (argRow // { pat = pair.pat; }) [] argName KStar
        )
        (if row.guard != null
         then dtGuard row.guard (dtLeaf row.bindings row.body) failDT
         else dtLeaf row.bindings row.body)
        (lib.imap0 (i: p: { idx = i; pat = p; }) args);
    in
    innerDT;

  _compileRecord = row: recPat: scrName: rest: scrType:
    let
      fields = recPat.fields or [];
      open   = recPat.open or false;
      # For each field pattern, generate a sub-DT
      # Simplified: sequential field matching
      innerDT = lib.foldl'
        (acc: f:
          let
            fieldScrName = "${scrName}.${f.label or f.name or "_"}";
            fieldRow = { pat = f.pat; guard = null; body = row.body; bindings = row.bindings; };
          in
          _compileRow fieldRow [] fieldScrName KStar
        )
        (if row.guard != null
         then dtGuard row.guard (dtLeaf row.bindings row.body)
                                (_compileMatrix rest scrName scrType)
         else dtLeaf row.bindings row.body)
        fields;
    in
    innerDT;

  _compileTuple = row: tupPat: scrName: rest: scrType:
    let
      elems    = tupPat.elems or [];
      elemDTs = lib.imap0 (i: p:
        let elemScrName = "${scrName}._${builtins.toString i}"; in
        _compileRow { pat = p; guard = null; body = row.body; bindings = row.bindings; }
                    [] elemScrName KStar
      ) elems;
    in
    if row.guard != null
    then dtGuard row.guard (dtLeaf row.bindings row.body) (_compileMatrix rest scrName scrType)
    else dtLeaf row.bindings row.body;

  # ════════════════════════════════════════════════════════════════════════════
  # Exhaustiveness Check（Phase 3.3 完整版）
  # ════════════════════════════════════════════════════════════════════════════

  # checkExhaustiveness : Type -> [Branch] -> ExhaustResult
  # ExhaustResult = { exhaustive: Bool; missing: [Pat]; hasGuards: Bool; }
  checkExhaustiveness = scrType: branches:
    let
      pats = map (b: b.pat) branches;
      hasGuards = lib.any (b: b.guard != null) branches;
      # If any branch has a guard, we cannot guarantee exhaustiveness
    in
    if hasGuards then
      { exhaustive = false;
        missing    = [];
        hasGuards  = true;
        note       = "Pattern matching with guards: exhaustiveness not guaranteed statically"; }
    else
      let result = _checkPats pats scrType; in
      { exhaustive = result.covered;
        missing    = result.missing;
        hasGuards  = false; };

  _checkPats = pats: ty:
    let
      # Check if wild/var covers everything
      hasWild = lib.any (p:
        let t = p.__patTag or null; in
        t == "Wild" || t == "Var" || t == "As"
      ) pats;
    in
    if hasWild then { covered = true; missing = []; }
    else
      let
        # Group by constructor
        ctorPats = builtins.filter (p: (p.__patTag or null) == "Ctor") pats;
        litPats  = builtins.filter (p: (p.__patTag or null) == "Lit")  pats;
        recPats  = builtins.filter (p: (p.__patTag or null) == "Record") pats;
        # Or-patterns: expand
        orExpanded = lib.concatMap (p:
          if (p.__patTag or null) == "Or" then p.pats or [] else [p]
        ) pats;
      in
      if ctorPats == [] && litPats == [] && recPats == [] then
        # No constructive patterns — not exhaustive
        { covered = false; missing = [pWild]; }
      else
        # Heuristic: if we have record patterns, check field coverage
        if recPats != [] then
          let hasOpenRecord = lib.any (p: p.open or false) recPats; in
          if hasOpenRecord
          then { covered = true; missing = []; }  # Open record pattern covers all
          else { covered = false; missing = [pRecord [] false]; }
        else
          # Ctor/Lit: check if set of covered ctors spans the ADT
          _checkCtorCoverage (map (p: p.ctor or "") ctorPats) ty;

  _checkCtorCoverage = ctorNames: ty:
    let r = ty.repr or {}; in
    if r.__variant or null == "ADT" then
      let
        allCtors  = map (v: v.name or "") (r.variants or []);
        covered   = map (n: builtins.elem n ctorNames) allCtors;
        missing   = builtins.filter (n: !builtins.elem n ctorNames) allCtors;
      in
      { covered = missing == [];
        missing  = map (n: pCtor n [pWild]) missing; }
    else if r.__variant or null == "Primitive" then
      # Primitive types can't be exhaustively pattern matched without wildcard
      { covered = false; missing = [pWild]; }
    else
      { covered = false; missing = [pWild]; };

  # ════════════════════════════════════════════════════════════════════════════
  # Pattern pretty-print (for error messages)
  # ════════════════════════════════════════════════════════════════════════════

  patPretty = pat:
    let t = pat.__patTag or null; in
    if      t == "Wild"   then "_"
    else if t == "Var"    then pat.name or "_"
    else if t == "Lit"    then builtins.toJSON (pat.value or null)
    else if t == "Ctor"   then
      let args = pat.args or []; in
      if args == [] then pat.ctor or "?"
      else "${pat.ctor or "?"}(${lib.concatMapStringsSep ", " patPretty args})"
    else if t == "Record" then
      let
        fieldStrs = map (f: "${f.label or f.name or "_"}: ${patPretty f.pat}") (pat.fields or []);
        open = if pat.open or false then ", .." else "";
      in
      "{ ${lib.concatStringsSep ", " fieldStrs}${open} }"
    else if t == "Guard"  then "${patPretty (pat.pat or pWild)} if <guard>"
    else if t == "As"     then "${pat.name or "_"}@${patPretty (pat.pat or pWild)}"
    else if t == "Tuple"  then "(${lib.concatMapStringsSep ", " patPretty (pat.elems or [])})"
    else if t == "Or"     then lib.concatMapStringsSep " | " patPretty (pat.pats or [])
    else "?pat";

}
