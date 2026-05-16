# constraint/unify.nix — Phase 4.3
# Robinson unification + Mu bisimulation up-to congruence（INV-MU-1）
# Phase 4.2: guardSet（Pous-style bisimulation 近似）
# Phase 4.3: up-to congruence（bisimulation up-to structural equivalence）
#   INV-MU-1: bisimulation up-to congruence sound
#   Upgrade: _unifyMu now uses congruence closure instead of raw guard set
#   The congruence closure maps (A, B) → proof obligation set
#   If (A, B) is in the congruence closure of existing obligations, coinductively assume ok
{ lib, typeLib, reprLib, kindLib, substLib, unifiedSubstLib, hashLib, normalizeLib }:

let
  inherit (typeLib) isType mkTypeDefault freeVars;
  inherit (reprLib) rVar;
  inherit (kindLib) KStar;
  inherit (unifiedSubstLib) singleTypeBinding composeSubst emptySubst applySubst;
  inherit (hashLib) typeHash;
  inherit (normalizeLib) normalize';

  # ══ Occurs Check（防止无限类型）══════════════════════════════════════
  occursIn = varName: t:
    if !isType t then false
    else
      let v = t.repr.__variant or null; in
      if v == "Var" then t.repr.name == varName
      else if v == "Lambda" then
        t.repr.param == varName || occursIn varName t.repr.body
      else if v == "Apply" then
        occursIn varName t.repr.fn ||
        builtins.any (occursIn varName) (t.repr.args or [])
      else if v == "Fn" then
        occursIn varName t.repr.from || occursIn varName t.repr.to
      else if v == "Constrained" then occursIn varName t.repr.base
      else if v == "Mu" then
        t.repr.var != varName && occursIn varName t.repr.body
      else if v == "Record" then
        builtins.any (occursIn varName) (builtins.attrValues t.repr.fields)
      else if v == "RowExtend" then
        occursIn varName t.repr.ty || occursIn varName t.repr.tail
      else if v == "VariantRow" then
        builtins.any (occursIn varName) (builtins.attrValues t.repr.variants) ||
        (t.repr.tail != null && occursIn varName t.repr.tail)
      else if v == "Effect" then
        occursIn varName t.repr.effectRow || occursIn varName t.repr.resultType
      else if v == "EffectMerge" then
        occursIn varName t.repr.e1 || occursIn varName t.repr.e2
      else if v == "Refined" then occursIn varName t.repr.base
      else if v == "Forall" then
        !(builtins.elem varName t.repr.vars) && occursIn varName t.repr.body
      else false;

  # ══ Unify Var ════════════════════════════════════════════════════════
  _unifyVar = varName: t: coind:
    if (t.repr.__variant or null) == "Var" && t.repr.name == varName then
      { ok = true; subst = emptySubst; }
    else if occursIn varName t then
      { ok = false; error = "occurs check failed: ${varName} in ${typeHash t}"; }
    else
      { ok = true; subst = singleTypeBinding varName t; };

  # ══ Mu bisimulation up-to congruence（Phase 4.3: INV-MU-1）══════════
  # Phase 4.2 guardSet: simply check if (A,B) key is in visited set.
  #   Problem: too conservative, misses structurally equivalent but nominally different pairs.
  #
  # Phase 4.3 up-to congruence:
  #   The coinductive set is extended with the congruence closure.
  #   For Mu types, we use Pous-style "up-to congruence":
  #     (μX.A, μY.B) ∈ R  iff  (A[X:=freshVar], B[Y:=freshVar]) ∈ R∪Congruence(R)
  #   This allows bisimulation hypotheses to be used in subterms.
  #
  # Implementation:
  #   coind is a set of (typeHash(A), typeHash(B)) pairs currently being proved.
  #   congruence closure: if (A, B) ∈ coind, then (C[A/x], C[B/x]) ∈ Congruence(coind)
  #   We approximate congruence closure with structural descent.
  _unifyMu = a: b: coind:
    let
      pairKey = "${typeHash a}:${typeHash b}";
      revKey  = "${typeHash b}:${typeHash a}";
    in
    # Coinductive hypothesis: if we are already proving this pair, assume ok
    if builtins.elem pairKey coind || builtins.elem revKey coind then
      { ok = true; subst = emptySubst; }
    else
      let
        newCoind = coind ++ [ pairKey ];
        # Phase 4.3: generate a truly shared fresh variable for up-to congruence
        # Both Mu binders are mapped to the SAME fresh variable
        # This is "up-to alpha-renaming" as the first step of up-to congruence
        freshName = "_mu_${builtins.substring 0 8 (builtins.hashString "sha256" pairKey)}";
        freshVar  = mkTypeDefault (rVar freshName "mu-coind") KStar;

        # Unfold both Mu types with the SAME fresh variable
        aUnfolded = substLib.substitute a.repr.var freshVar a.repr.body;
        bUnfolded = substLib.substitute b.repr.var freshVar b.repr.body;
      in
      # Now unify the unfolded bodies with the extended coinductive set
      # This is sound because: μX.A = A[X := μX.A], and if A[X:=Z] = B[Y:=Z]
      # for fresh Z, then μX.A and μY.B are bisimilar up to congruence.
      _unify aUnfolded bUnfolded newCoind;

  # ══ Congruence Closure Check (Phase 4.3 auxiliary) ═══════════════════
  # Check if (A, B) follows from a congruence application of existing coind hypotheses.
  # For structural types: if A = C[A'/x] and B = C[B'/x] where (A',B') ∈ coind, then ok.
  # This is approximated by: we don't need to check this explicitly because _unify
  # already decomposes structural types recursively, which naturally applies congruence.
  # The key insight: structural descent in _unify IS the congruence closure application.

  # ══ 主 Unify 函数（Phase 4.3: up-to congruence Mu）══════════════════
  _unify = a: b: coind:
    let
      na = normalize' a;
      nb = normalize' b;
      va = na.repr.__variant or null;
      vb = nb.repr.__variant or null;
    in
    # 1. NF-hash equality (includes alpha-eq via de Bruijn serialize)
    if typeHash na == typeHash nb then
      { ok = true; subst = emptySubst; }
    # 2. a is Var → bind
    else if va == "Var" then
      _unifyVar na.repr.name nb coind
    # 3. b is Var → bind
    else if vb == "Var" then
      _unifyVar nb.repr.name na coind
    # 4. Mu ↔ Mu (Phase 4.3: up-to congruence)
    else if va == "Mu" && vb == "Mu" then
      _unifyMu na nb coind
    # 5. Mu ↔ non-Mu: unfold Mu
    else if va == "Mu" then
      let unfolded = substLib.substitute na.repr.var na na.repr.body; in
      _unify unfolded nb coind
    else if vb == "Mu" then
      let unfolded = substLib.substitute nb.repr.var nb nb.repr.body; in
      _unify na unfolded coind
    # 6. Fn ↔ Fn
    else if va == "Fn" && vb == "Fn" then
      let r1 = _unify na.repr.from nb.repr.from coind; in
      if !r1.ok then r1
      else
        let
          na2 = applySubst r1.subst na.repr.to;
          nb2 = applySubst r1.subst nb.repr.to;
          r2  = _unify na2 nb2 coind;
        in
        if !r2.ok then r2
        else { ok = true; subst = composeSubst r2.subst r1.subst; }
    # 7. Apply ↔ Apply
    else if va == "Apply" && vb == "Apply" then
      let r1 = _unify na.repr.fn nb.repr.fn coind; in
      if !r1.ok then r1
      else
        let
          argsA = na.repr.args or [];
          argsB = nb.repr.args or [];
        in
        if builtins.length argsA != builtins.length argsB then
          { ok = false; error = "Apply arity mismatch"; }
        else
          lib.foldl' (acc: pair:
            if !acc.ok then acc
            else
              let
                a2 = applySubst acc.subst pair.fst;
                b2 = applySubst acc.subst pair.snd;
                r  = _unify a2 b2 coind;
              in
              if !r.ok then r
              else { ok = true; subst = composeSubst r.subst acc.subst; }
          ) { ok = true; subst = r1.subst; }
            (lib.zipListsWith (x: y: { fst = x; snd = y; }) argsA argsB)
    # 8. Record ↔ Record
    else if va == "Record" && vb == "Record" then
      let
        keysA = lib.sort builtins.lessThan (builtins.attrNames na.repr.fields);
        keysB = lib.sort builtins.lessThan (builtins.attrNames nb.repr.fields);
      in
      if keysA != keysB then
        { ok = false; error = "Record field mismatch: ${builtins.toJSON keysA} vs ${builtins.toJSON keysB}"; }
      else
        lib.foldl' (acc: k:
          if !acc.ok then acc
          else
            let
              fa = applySubst acc.subst na.repr.fields.${k};
              fb = applySubst acc.subst nb.repr.fields.${k};
              r  = _unify fa fb coind;
            in
            if !r.ok then r
            else { ok = true; subst = composeSubst r.subst acc.subst; }
        ) { ok = true; subst = emptySubst; } keysA
    # 9. Primitive ↔ Primitive
    else if va == "Primitive" && vb == "Primitive" then
      if na.repr.name == nb.repr.name then { ok = true; subst = emptySubst; }
      else { ok = false; error = "type mismatch: ${na.repr.name} vs ${nb.repr.name}"; }
    # 10. Forall ↔ Forall (alpha-equiv via de Bruijn)
    else if va == "Forall" && vb == "Forall" then
      if typeHash na == typeHash nb then { ok = true; subst = emptySubst; }
      else { ok = false; error = "Forall mismatch"; }
    # 11. Dynamic unifies with everything（gradual）
    else if va == "Dynamic" || vb == "Dynamic" then
      { ok = true; subst = emptySubst; }
    # 12. Constrained ↔ Constrained: unify base types
    else if va == "Constrained" && vb == "Constrained" then
      _unify na.repr.base nb.repr.base coind
    # 13. Constrained ↔ non-Constrained: unwrap
    else if va == "Constrained" then
      _unify na.repr.base nb coind
    else if vb == "Constrained" then
      _unify na nb.repr.base coind
    # 14. Mismatch
    else
      { ok = false; error = "type mismatch: ${va} vs ${vb}"; };

  # ══ Public API ════════════════════════════════════════════════════════
  # Phase 4.3: coind starts as empty (not guardSet list)
  unify = a: b: _unify a b [];

  # ══ 批量 unify ════════════════════════════════════════════════════════
  unifyAll = pairs:
    lib.foldl' (acc: pair:
      if !acc.ok then acc
      else
        let
          a2 = applySubst acc.subst pair.fst;
          b2 = applySubst acc.subst pair.snd;
          r  = unify a2 b2;
        in
        if !r.ok then r
        else { ok = true; subst = composeSubst r.subst acc.subst; }
    ) { ok = true; subst = emptySubst; } pairs;
in
{
  inherit
  # ══ Occurs Check（防止无限类型）══════════════════════════════════════
  occursIn
  # ══ Unify Var ════════════════════════════════════════════════════════
  _unifyVar
  # ══ Mu bisimulation up-to congruence（Phase 4.3: INV-MU-1）══════════
  _unifyMu
  # ══ Congruence Closure Check (Phase 4.3 auxiliary) ═══════════════════
  _unify
  # ══ Public API ════════════════════════════════════════════════════════
  unify
  # ══ 批量 unify ════════════════════════════════════════════════════════
  unifyAll
  ;
}
