# normalize/rules.nix — Phase 4.2
# TRS 规则集（11 规则合并版，单文件）
# INV-2: 所有计算 = Rewrite(TypeIR)，fuel 保证终止
{ lib, typeLib, reprLib, kindLib, substLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault freeVars;
  inherit (reprLib)
    rPrimitive rVar rLambda rApply rFn rADT rConstrained rMu
    rRecord rRowExtend rRowEmpty rVariantRow rEffect rEffectMerge
    rRefined rSig rForall;
  inherit (kindLib) KStar KRow KEffect applyKind;
  inherit (substLib) substitute substituteParams applyUnifiedSubst;

in rec {

  # ══ RULE P1: β-reduction (Apply + Lambda) ════════════════════════════
  # Apply(Lambda(x, body), arg)  →  substitute(x → arg, body)
  ruleBetaReduce = t:
    let v = t.repr.__variant or null; in
    if v != "Apply" then null
    else
      let fn = t.repr.fn; in
      if (fn.repr.__variant or null) != "Lambda" then null
      else
        let
          args = t.repr.args or [];
          param = fn.repr.param;
          body  = fn.repr.body;
        in
        if builtins.length args == 0 then null
        else
          let
            firstArg  = builtins.head args;
            restArgs  = builtins.tail args;
            reduced   = substitute param firstArg body;
          in
          if builtins.length restArgs == 0 then { ok = true; result = reduced; }
          else { ok = true; result = mkTypeWith (rApply reduced restArgs) t.kind t.meta; };

  # ══ RULE P2: Constructor partial application ══════════════════════════
  # Apply(Constructor(params, body), args)  →  substitute(params → args, body)
  ruleConstructorPartial = t:
    let v = t.repr.__variant or null; in
    if v != "Apply" then null
    else
      let fn = t.repr.fn; in
      if (fn.repr.__variant or null) != "Constructor" then null
      else
        let
          params  = fn.repr.params or [];
          body    = fn.repr.body;
          args    = t.repr.args or [];
          nParams = builtins.length params;
          nArgs   = builtins.length args;
        in
        if nArgs < nParams then null  # partial: wait for more args
        else if nArgs == nParams then
          { ok = true; result = substituteParams params args body; }
        else
          # over-applied: apply remaining after substitution
          let
            applied = substituteParams params (lib.take nParams args) body;
            remaining = lib.drop nParams args;
          in
          { ok = true; result = mkTypeWith (rApply applied remaining) t.kind t.meta; };

  # ══ RULE P3: Constraint merge (nested Constrained) ═══════════════════
  # Constrained(Constrained(t, c1), c2)  →  Constrained(t, c1 ∪ c2)
  ruleConstraintMerge = t:
    let v = t.repr.__variant or null; in
    if v != "Constrained" then null
    else
      let inner = t.repr.base; in
      if (inner.repr.__variant or null) != "Constrained" then null
      else
        let
          c1 = inner.repr.constraints;
          c2 = t.repr.constraints;
          merged = lib.unique (c1 ++ c2);
        in
        { ok = true; result = mkTypeWith (rConstrained inner.repr.base merged) t.kind t.meta; };

  # ══ RULE P4: Constraint float (Apply + Constrained) ══════════════════
  # Apply(Constrained(f, cs), arg)  →  Constrained(Apply(f, arg), cs)
  ruleConstraintFloat = t:
    let v = t.repr.__variant or null; in
    if v != "Apply" then null
    else
      let fn = t.repr.fn; in
      if (fn.repr.__variant or null) != "Constrained" then null
      else
        let
          innerFn = fn.repr.base;
          cs      = fn.repr.constraints;
          applied = mkTypeWith (rApply innerFn t.repr.args) t.kind t.meta;
        in
        { ok = true; result = mkTypeWith (rConstrained applied cs) t.kind t.meta; };

  # ══ RULE P5: Row canonical (RowExtend spine sort) ════════════════════
  # INV-ROW: RowExtend spine 按 label 字母序 canonical
  ruleRowCanonical = t:
    let v = t.repr.__variant or null; in
    if v != "RowExtend" then null
    else
      # Collect all (label, ty) pairs from spine
      let
        collectSpine = row:
          let rv = row.repr.__variant or null; in
          if rv == "RowExtend" then
            [ { label = row.repr.label; ty = row.repr.ty; } ]
            ++ collectSpine row.repr.tail
          else [];
        getTail = row:
          let rv = row.repr.__variant or null; in
          if rv == "RowExtend" then getTail row.repr.tail
          else row;
        spine    = collectSpine t;
        tail     = getTail t;
        sorted   = lib.sort (a: b: a.label < b.label) spine;
        # Check if already sorted
        isCanon  = lib.all (i:
          let
            cur  = builtins.elemAt spine i;
            next = builtins.elemAt spine (i + 1);
          in
          cur.label <= next.label
        ) (lib.range 0 (builtins.length spine - 2));
      in
      if isCanon then null
      else
        let
          rebuild = pairs: tailT:
            if pairs == [] then tailT
            else
              let p = builtins.head pairs; in
              mkTypeWith (rRowExtend p.label p.ty (rebuild (builtins.tail pairs) tailT)) t.kind t.meta;
        in
        { ok = true; result = rebuild sorted tail; };

  # ══ RULE P6: VariantRow canonical ════════════════════════════════════
  # flatten nested VariantRow + sort labels + preserve open tail
  ruleVariantRowCanonical = t:
    let v = t.repr.__variant or null; in
    if v != "VariantRow" then null
    else
      let
        # Collect all variants from potentially nested VariantRow
        collectVR = row:
          let rv = row.repr.__variant or null; in
          if rv == "VariantRow" then
            { variants = row.repr.variants; tail = collectVR_tail row; }
          else { variants = {}; tail = row; };

        collectVR_tail = row:
          let rv = row.repr.__variant or null; in
          if rv == "VariantRow" then
            if row.repr.tail != null then collectVR_tail row.repr.tail
            else null
          else row;

        allVariants = t.repr.variants;
        tail        = t.repr.tail;
        sortedKeys  = lib.sort builtins.lessThan (builtins.attrNames allVariants);
        alreadySorted = (builtins.attrNames allVariants) ==
          lib.sort builtins.lessThan (builtins.attrNames allVariants);
      in
      if alreadySorted && builtins.attrNames allVariants == sortedKeys then null
      else
        { ok = true; result = mkTypeWith (rVariantRow allVariants tail) t.kind t.meta; };

  # ══ RULE P7: EffectMerge flatten + dedup + sort ══════════════════════
  # INV-EFF-6: EffectMerge canonical
  ruleEffectMerge = t:
    let v = t.repr.__variant or null; in
    if v != "EffectMerge" then null
    else
      let
        # Collect all effect labels from nested EffectMerge
        collectEffects = e:
          let ev = e.repr.__variant or null; in
          if ev == "EffectMerge" then
            collectEffects e.repr.e1 ++ collectEffects e.repr.e2
          else if ev == "VariantRow" then
            builtins.attrNames e.repr.variants
          else if ev == "Var" then [ "RowVar:${e.repr.name}" ]
          else [];

        getRowVarTail = e:
          let ev = e.repr.__variant or null; in
          if ev == "EffectMerge" then
            let t1 = getRowVarTail e.repr.e1;
                t2 = getRowVarTail e.repr.e2;
            in if t1 != null then t1 else t2
          else if ev == "Var" then e  # open tail
          else null;

        labels  = lib.unique (collectEffects t);
        sorted  = lib.sort builtins.lessThan labels;
        rowTail = getRowVarTail t;

        # Rebuild as VariantRow with sorted labels
        builtVariants = builtins.listToAttrs (map (l:
          lib.nameValuePair l (mkTypeDefault (rPrimitive l) KStar)
        ) (lib.filter (l: !(lib.hasPrefix "RowVar:" l)) sorted));

      in
      { ok = true; result = mkTypeWith (rVariantRow builtVariants rowTail) t.kind t.meta; };

  # ══ RULE P8: Refined trivial cases ════════════════════════════════════
  # INV-SMT-2: PTrue → 退化为 base（{ x: T | ⊤ } = T）
  ruleRefined = t:
    let v = t.repr.__variant or null; in
    if v != "Refined" then null
    else
      let pe = t.repr.predExpr; in
      if (pe.__predTag or null) == "PTrue" then
        { ok = true; result = t.repr.base; }
      else null;

  # ══ RULE P9: Sig fields alphabetical ════════════════════════════════
  # INV-MOD-4: Sig fields 字母序 canonical
  ruleSig = t:
    let v = t.repr.__variant or null; in
    if v != "Sig" then null
    else
      let
        keys   = builtins.attrNames t.repr.fields;
        sorted = lib.sort builtins.lessThan keys;
      in
      if keys == sorted then null
      else
        # Fields are already in attrset order (Nix does not reorder),
        # canonical form is enforced via serialization (sort in serialize.nix)
        null;  # No-op at repr level; canonical via serialize

  # ══ RULE P10: Record null field cleanup ═══════════════════════════════
  ruleRecordCanonical = t:
    let v = t.repr.__variant or null; in
    if v != "Record" then null
    else
      let
        nonNullFields = lib.filterAttrs (n: ft: ft != null) t.repr.fields;
      in
      if builtins.attrNames nonNullFields == builtins.attrNames t.repr.fields then null
      else { ok = true; result = mkTypeWith (rRecord nonNullFields) t.kind t.meta; };

  # ══ RULE P11: Effect normalize (VariantRow alphabetical) ═════════════
  ruleEffectNormalize = t:
    let v = t.repr.__variant or null; in
    if v != "Effect" then null
    else
      let rowV = t.repr.effectRow.repr.__variant or null; in
      if rowV != "VariantRow" then null
      else
        let
          row    = t.repr.effectRow;
          keys   = builtins.attrNames row.repr.variants;
          sorted = lib.sort builtins.lessThan keys;
        in
        if keys == sorted then null
        else
          # Already canonical via serialize; no-op at repr level
          null;

  # ══ 规则集（按优先级排列）═════════════════════════════════════════════
  allRules = [
    ruleBetaReduce          # P1 highest
    ruleConstructorPartial  # P2
    ruleConstraintMerge     # P3
    ruleConstraintFloat     # P4
    ruleRowCanonical        # P5
    ruleVariantRowCanonical # P6
    ruleEffectMerge         # P7
    ruleRefined             # P8
    ruleSig                 # P9
    ruleRecordCanonical     # P10
    ruleEffectNormalize     # P11
  ];

  # ══ 应用第一个匹配规则 ════════════════════════════════════════════════
  # Type: Type → { ok: Bool; result: Type } | null
  applyFirstRule = t:
    lib.foldl' (acc: rule:
      if acc != null then acc
      else rule t
    ) null allRules;
}
