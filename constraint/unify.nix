# constraint/unify.nix — Phase 4.2
# Robinson unification（含 Row + Mu bisimulation guardset）
{ lib, typeLib, reprLib, kindLib, substLib, unifiedSubstLib, hashLib, normalizeLib }:

let
  inherit (typeLib) isType mkTypeDefault freeVars;
  inherit (reprLib) rVar;
  inherit (kindLib) KStar;
  # Fix: inherit from unifiedSubstLib, not substLib
  inherit (unifiedSubstLib) singleTypeBinding composeSubst emptySubst applySubst;
  inherit (hashLib) typeHash;
  inherit (normalizeLib) normalize';

in rec {

  # ══ Occurs Check（防止无限类型）══════════════════════════════════════
  # Type: String → Type → Bool（true = var 出现在 type 中）
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

  # ══ Unify Var（将变量绑定到类型）════════════════════════════════════
  _unifyVar = varName: t: guardSet:
    if (t.repr.__variant or null) == "Var" && t.repr.name == varName then
      { ok = true; subst = emptySubst; }
    else if occursIn varName t then
      { ok = false; error = "occurs check failed: ${varName} in ${typeHash t}"; }
    else
      { ok = true; subst = singleTypeBinding varName t; };

  # ══ Unify Mu（bisimulation 近似，使用 guard set）════════════════════
  _unifyMu = a: b: guardSet:
    let
      pairKey = "${typeHash a}:${typeHash b}";
    in
    if builtins.elem pairKey guardSet then
      { ok = true; subst = emptySubst; }
    else
      let
        newGuard = guardSet ++ [ pairKey ];
        unfoldMu = mu:
          substLib.substitute mu.repr.var mu mu.repr.body;
        aUnfolded = unfoldMu a;
        bUnfolded = unfoldMu b;
      in
      _unify aUnfolded bUnfolded newGuard;

  # ══ 主 Unify 函数 ════════════════════════════════════════════════════
  # Type: Type → Type → [String] → { ok: Bool; subst: UnifiedSubst; error?: String }
  _unify = a: b: guardSet:
    let
      na = normalize' a;
      nb = normalize' b;
      va = na.repr.__variant or null;
      vb = nb.repr.__variant or null;
    in
    # 1. 完全相同（NF-hash）
    if typeHash na == typeHash nb then
      { ok = true; subst = emptySubst; }
    # 2. a 是 Var → bind
    else if va == "Var" then
      _unifyVar na.repr.name nb guardSet
    # 3. b 是 Var → bind
    else if vb == "Var" then
      _unifyVar nb.repr.name na guardSet
    # 4. Mu ↔ Mu
    else if va == "Mu" && vb == "Mu" then
      _unifyMu na nb guardSet
    # 5. Mu ↔ non-Mu：展开 Mu
    else if va == "Mu" then
      let unfolded = substLib.substitute na.repr.var na na.repr.body; in
      _unify unfolded nb guardSet
    else if vb == "Mu" then
      let unfolded = substLib.substitute nb.repr.var nb nb.repr.body; in
      _unify na unfolded guardSet
    # 6. Fn ↔ Fn
    else if va == "Fn" && vb == "Fn" then
      let r1 = _unify na.repr.from nb.repr.from guardSet; in
      if !r1.ok then r1
      else
        let
          na2 = applySubst r1.subst na.repr.to;
          nb2 = applySubst r1.subst nb.repr.to;
          r2  = _unify na2 nb2 guardSet;
        in
        if !r2.ok then r2
        else { ok = true; subst = composeSubst r2.subst r1.subst; }
    # 7. Apply ↔ Apply
    else if va == "Apply" && vb == "Apply" then
      let r1 = _unify na.repr.fn nb.repr.fn guardSet; in
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
                r  = _unify a2 b2 guardSet;
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
              r  = _unify fa fb guardSet;
            in
            if !r.ok then r
            else { ok = true; subst = composeSubst r.subst acc.subst; }
        ) { ok = true; subst = emptySubst; } keysA
    # 9. Primitive ↔ Primitive
    else if va == "Primitive" && vb == "Primitive" then
      if na.repr.name == nb.repr.name then { ok = true; subst = emptySubst; }
      else { ok = false; error = "type mismatch: ${na.repr.name} vs ${nb.repr.name}"; }
    # 10. Forall ↔ Forall（alpha-equiv via de Bruijn serialization）
    else if va == "Forall" && vb == "Forall" then
      if typeHash na == typeHash nb then { ok = true; subst = emptySubst; }
      else { ok = false; error = "Forall mismatch"; }
    # 11. Dynamic unifies with everything（gradual）
    else if va == "Dynamic" || vb == "Dynamic" then
      { ok = true; subst = emptySubst; }
    # 12. Mismatch
    else
      { ok = false; error = "type mismatch: ${va} vs ${vb}"; };

  # ══ Public API ════════════════════════════════════════════════════════
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
}
