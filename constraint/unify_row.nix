# constraint/unify_row.nix — Phase 4.2
# Row 多态 unification
{ lib, typeLib, reprLib, kindLib, substLib, unifiedSubstLib, normalizeLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith;
  inherit (reprLib) rRowEmpty rRowExtend rVariantRow rVar;
  inherit (kindLib) KRow;
  # Fix: inherit from unifiedSubstLib, not substLib
  inherit (unifiedSubstLib) singleRowBinding composeSubst emptySubst applySubst;
  inherit (normalizeLib) normalize';

in rec {

  # ══ Row 结构分析 ═══════════════════════════════════════════════════════
  _rowSpine = row:
    let v = row.repr.__variant or null; in
    if v == "RowEmpty" then { labels = {}; tail = null; }
    else if v == "RowExtend" then
      let inner = _rowSpine row.repr.tail; in
      { labels = { ${row.repr.label} = row.repr.ty; } // inner.labels;
        tail   = inner.tail; }
    else if v == "VariantRow" then
      { labels = row.repr.variants; tail = row.repr.tail; }
    else if v == "Var" then
      { labels = {}; tail = row; }
    else { labels = {}; tail = row; };

  # ══ Row 重建（从 labels + tail）══════════════════════════════════════
  _rebuildRow = labels: tail:
    let
      sorted = lib.sort builtins.lessThan (builtins.attrNames labels);
      base   = if tail == null then mkTypeDefault rRowEmpty KRow else tail;
    in
    lib.foldl' (acc: l:
      mkTypeWith (rRowExtend l labels.${l} acc) KRow (acc.meta)
    ) base (lib.reverseList sorted);

  # ══ Row Unification ═══════════════════════════════════════════════════
  unifyRow = a: b:
    let
      na = normalize' a;
      nb = normalize' b;
      sa = _rowSpine na;
      sb = _rowSpine nb;

      onlyA  = lib.filterAttrs (l: _: !(sb.labels ? ${l})) sa.labels;
      onlyB  = lib.filterAttrs (l: _: !(sa.labels ? ${l})) sb.labels;
      common = lib.filterAttrs (l: _: sb.labels ? ${l}) sa.labels;

      commonResult = lib.foldl' (acc: l:
        if !acc.ok then acc
        else
          let
            ta = applySubst acc.subst sa.labels.${l};
            tb = applySubst acc.subst sb.labels.${l};
            r  = _unifyTypes ta tb;
          in
          if !r.ok then r
          else { ok = true; subst = composeSubst r.subst acc.subst; }
      ) { ok = true; subst = emptySubst; }
        (builtins.attrNames common);
    in
    if !commonResult.ok then commonResult
    else
      let s0 = commonResult.subst; in
      if onlyA == {} && onlyB == {} && sa.tail == null && sb.tail == null then
        { ok = true; subst = s0; }
      else if onlyA == {} && onlyB != {} && sa.tail != null then
        let aVar = sa.tail; in
        if (aVar.repr.__variant or null) != "Var" then
          { ok = false; error = "row tail mismatch: extra labels in b but a has non-var tail"; }
        else
          let
            newRow = _rebuildRow onlyB sb.tail;
            r      = singleRowBinding aVar.repr.name newRow;
          in
          { ok = true; subst = composeSubst r s0; }
      else if onlyB == {} && onlyA != {} && sb.tail != null then
        let bVar = sb.tail; in
        if (bVar.repr.__variant or null) != "Var" then
          { ok = false; error = "row tail mismatch: extra labels in a but b has non-var tail"; }
        else
          let
            newRow = _rebuildRow onlyA sa.tail;
            r      = singleRowBinding bVar.repr.name newRow;
          in
          { ok = true; subst = composeSubst r s0; }
      else if onlyA != {} && onlyB != {} && sa.tail != null && sb.tail != null then
        if (sa.tail.repr.__variant or null) != "Var" ||
           (sb.tail.repr.__variant or null) != "Var" then
          { ok = false; error = "cannot unify open rows with non-var tails"; }
        else
          let
            freshVar = mkTypeDefault
              (rVar "_r${builtins.hashString "sha256" (builtins.toJSON { a = sa; b = sb; })}" "")
              KRow;
            rowForA = _rebuildRow onlyB (if sb.tail != null then sb.tail else freshVar);
            rowForB = _rebuildRow onlyA (if sa.tail != null then sa.tail else freshVar);
            r1      = singleRowBinding sa.tail.repr.name rowForA;
            r2      = singleRowBinding sb.tail.repr.name rowForB;
          in
          { ok = true; subst = composeSubst (composeSubst r2 r1) s0; }
      else
        { ok = false; error = "row label mismatch"; };

  # 简单类型统一（避免循环依赖，仅处理 Var）
  _unifyTypes = a: b:
    if builtins.hashString "sha256" (builtins.toJSON a) ==
       builtins.hashString "sha256" (builtins.toJSON b)
    then { ok = true; subst = emptySubst; }
    else
      let
        va = a.repr.__variant or null;
        vb = b.repr.__variant or null;
      in
      if va == "Var" then { ok = true; subst = singleRowBinding a.repr.name b; }
      else if vb == "Var" then { ok = true; subst = singleRowBinding b.repr.name a; }
      else { ok = false; error = "type mismatch in row field"; };
}
