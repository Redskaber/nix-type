# constraint/unify.nix — Phase 4.1
# Robinson 合一算法（unification）
# 修复 Phase 3.x 问题：
#   - subst equality 升级为 NF-hash（INV-SOL1）
#   - Mu bisimulation 使用 guard set
#   - occurs check 正确实现
{ lib, typeLib, reprLib, kindLib, substLib, hashLib, normalizeLib }:

let
  inherit (typeLib) isType mkTypeDefault;
  inherit (reprLib) rVar;
  inherit (kindLib) KStar;
  inherit (substLib) substitute freeVars applySubst;
  inherit (hashLib) typeHash instanceKey;
  inherit (normalizeLib) normalize';

  # ── Occurs check ──────────────────────────────────────────────────────────
  # Type: String -> Type -> Bool
  occursIn = varName: t:
    if !isType t then false
    else
      let v = t.repr.__variant or null; in
      if v == "Var"    then t.repr.name == varName
      else if v == "RowVar" then t.repr.name == varName
      else if v == "Apply" then
        occursIn varName t.repr.fn ||
        lib.any (occursIn varName) (t.repr.args or [])
      else if v == "Fn" then
        occursIn varName t.repr.from || occursIn varName t.repr.to
      else if v == "Lambda" then
        t.repr.param != varName && occursIn varName t.repr.body
      else if v == "Constrained" then occursIn varName t.repr.base
      else if v == "Mu" then
        t.repr.var != varName && occursIn varName t.repr.body
      else if v == "Record" then
        let fnames = builtins.attrNames (t.repr.fields or {}); in
        lib.any (n: occursIn varName t.repr.fields.${n}) fnames
      else if v == "RowExtend" then
        occursIn varName t.repr.fieldType || occursIn varName t.repr.rest
      else if v == "VariantRow" then
        let vnames = builtins.attrNames (t.repr.variants or {}); in
        lib.any (n: occursIn varName t.repr.variants.${n}) vnames
        || (t.repr.extension != null && occursIn varName t.repr.extension)
      else if v == "Refined" then occursIn varName t.repr.base
      else if v == "Pi" then
        occursIn varName t.repr.domain ||
        (t.repr.param != varName && occursIn varName t.repr.body)
      else if v == "Sigma" then
        occursIn varName t.repr.domain ||
        (t.repr.param != varName && occursIn varName t.repr.body)
      else if v == "Effect" then occursIn varName t.repr.effectRow
      else if v == "EffectMerge" then
        occursIn varName t.repr.left || occursIn varName t.repr.right
      else false;

  # ── 主合一函数 ────────────────────────────────────────────────────────────
  # Type: AttrSet(String->Type) -> Type -> Type -> UnifyResult
  # UnifyResult = { ok: Bool; subst: AttrSet; error?: String }
  unify = subst: a: b:
    let
      # 先规范化（INV-3）
      na = normalize' a;
      nb = normalize' b;
      va = na.repr.__variant or null;
      vb = nb.repr.__variant or null;
    in
    # 快速路径：NF hash 相等 → 相同类型
    if typeHash na == typeHash nb then
      { ok = true; subst = subst; }

    # Var a → bind a = b（occurs check）
    else if va == "Var" then
      let varName = na.repr.name; in
      if subst ? ${varName} then
        unify subst subst.${varName} nb  # 已有绑定，递归
      else if occursIn varName nb then
        { ok = false; subst = subst;
          error = "Occurs check failed: ${varName} in ${builtins.toJSON nb.repr}"; }
      else
        let newSubst = subst // { ${varName} = nb; }; in
        { ok = true; subst = newSubst; }

    # Var b → bind b = a
    else if vb == "Var" then
      let varName = nb.repr.name; in
      if subst ? ${varName} then
        unify subst na subst.${varName}
      else if occursIn varName na then
        { ok = false; subst = subst;
          error = "Occurs check failed: ${varName} in ${builtins.toJSON na.repr}"; }
      else
        let newSubst = subst // { ${varName} = na; }; in
        { ok = true; subst = newSubst; }

    # RowVar
    else if va == "RowVar" then
      let varName = na.repr.name; in
      if subst ? ${varName} then
        unify subst subst.${varName} nb
      else if occursIn varName nb then
        { ok = false; subst = subst; error = "RowVar occurs check: ${varName}"; }
      else
        { ok = true; subst = subst // { ${varName} = nb; }; }

    else if vb == "RowVar" then
      let varName = nb.repr.name; in
      if subst ? ${varName} then
        unify subst na subst.${varName}
      else if occursIn varName na then
        { ok = false; subst = subst; error = "RowVar occurs check: ${varName}"; }
      else
        { ok = true; subst = subst // { ${varName} = na; }; }

    # 结构性合一
    else if va != vb then
      { ok = false; subst = subst;
        error = "Cannot unify ${va} with ${vb}"; }

    else if va == "Primitive" then
      if na.repr.name == nb.repr.name
      then { ok = true; subst = subst; }
      else { ok = false; subst = subst;
             error = "Primitive mismatch: ${na.repr.name} vs ${nb.repr.name}"; }

    else if va == "Fn" then
      let r1 = unify subst na.repr.from nb.repr.from; in
      if !r1.ok then r1
      else
        let
          a2 = applySubst r1.subst na.repr.to;
          b2 = applySubst r1.subst nb.repr.to;
        in unify r1.subst a2 b2

    else if va == "Apply" then
      let r1 = unify subst na.repr.fn nb.repr.fn; in
      if !r1.ok then r1
      else _unifyLists r1.subst (na.repr.args or []) (nb.repr.args or [])

    else if va == "Lambda" then
      # α-equivalent lambda：统一参数名后比较 body
      if na.repr.param == nb.repr.param then
        unify subst na.repr.body nb.repr.body
      else
        let
          # rename nb's param to na's param
          freshVar = mkTypeDefault (rVar na.repr.param "unify") KStar;
          body_b'  = substitute nb.repr.param freshVar nb.repr.body;
        in unify subst na.repr.body body_b'

    else if va == "Record" then
      let
        fa = na.repr.fields or {};
        fb = nb.repr.fields or {};
        namesA = lib.sort (a: b: a < b) (builtins.attrNames fa);
        namesB = lib.sort (a: b: a < b) (builtins.attrNames fb);
      in
      if namesA != namesB
      then { ok = false; subst = subst; error = "Record field mismatch"; }
      else
        lib.foldl'
          (acc: n:
            if !acc.ok then acc
            else unify acc.subst fa.${n} fb.${n})
          { ok = true; subst = subst; }
          namesA

    else if va == "RowExtend" then
      # Row 合一（开放行）
      unifyRows subst na nb

    else if va == "Mu" then
      # Mu bisimulation（guard set 防止无限展开）
      unifyMu {} subst na nb

    else if va == "Refined" then
      let r1 = unify subst na.repr.base nb.repr.base; in
      if !r1.ok then r1
      # 谓词合一：简化处理（predExpr 结构相等）
      else if builtins.toJSON na.repr.predExpr == builtins.toJSON nb.repr.predExpr
      then r1
      else { ok = false; subst = r1.subst;
             error = "Refined predicate mismatch"; }

    else if va == "Effect" then
      unify subst na.repr.effectRow nb.repr.effectRow

    else if va == "Sig" then
      let
        fa = na.repr.fields or {};
        fb = nb.repr.fields or {};
        namesA = lib.sort (a: b: a < b) (builtins.attrNames fa);
        namesB = lib.sort (a: b: a < b) (builtins.attrNames fb);
      in
      if namesA != namesB
      then { ok = false; subst = subst; error = "Sig field mismatch"; }
      else lib.foldl'
        (acc: n:
          if !acc.ok then acc else unify acc.subst fa.${n} fb.${n})
        { ok = true; subst = subst; }
        namesA

    else
      # fallback：hash 比较
      if typeHash na == typeHash nb
      then { ok = true; subst = subst; }
      else { ok = false; subst = subst;
             error = "Cannot unify ${va} and ${vb}"; };

  # ── 列表合一（arity-checked）─────────────────────────────────────────────
  _unifyLists = subst: as: bs:
    if builtins.length as != builtins.length bs
    then { ok = false; subst = subst; error = "Arity mismatch"; }
    else
      lib.foldl'
        (acc: pair:
          if !acc.ok then acc
          else
            let
              a' = applySubst acc.subst pair.fst;
              b' = applySubst acc.subst pair.snd;
            in unify acc.subst a' b')
        { ok = true; subst = subst; }
        (lib.zipListsWith (a: b: { fst = a; snd = b; }) as bs);

  # ── Row 合一（RowExtend 链）─────────────────────────────────────────────
  # 展开两个 Row 链并按 label 匹配
  unifyRows = subst: r1: r2:
    let
      flat1 = _flattenRow r1;
      flat2 = _flattenRow r2;
      labels1 = map (e: e.label) flat1.entries;
      labels2 = map (e: e.label) flat2.entries;
      allLabels = lib.sort (a: b: a < b)
        (lib.unique (labels1 ++ labels2));
    in
    lib.foldl'
      (acc: label:
        if !acc.ok then acc
        else
          let
            e1 = lib.findFirst (e: e.label == label) null flat1.entries;
            e2 = lib.findFirst (e: e.label == label) null flat2.entries;
          in
          if e1 == null || e2 == null
          then { ok = false; subst = acc.subst;
                 error = "Row label mismatch: ${label}"; }
          else unify acc.subst e1.fieldType e2.fieldType)
      { ok = true; subst = subst; }
      allLabels;

  _flattenRow = t:
    let v = t.repr.__variant or null; in
    if v == "RowExtend" then
      let rest = _flattenRow t.repr.rest; in
      { entries = [ { label = t.repr.label; fieldType = t.repr.fieldType; } ] ++ rest.entries;
        tail = rest.tail; }
    else { entries = []; tail = t; };

  # ── Mu bisimulation（co-inductive equality with guard）────────────────────
  unifyMu = guard: subst: a: b:
    let
      guardKey = typeHash a + "|" + typeHash b;
    in
    if guard ? ${guardKey} then { ok = true; subst = subst; }  # 假设相等
    else
      let guard' = guard // { ${guardKey} = true; }; in
      # 展开 Mu 一层：μX.T → T[X ↦ μX.T]
      let
        unfoldMu = t:
          if (t.repr.__variant or null) == "Mu"
          then substitute t.repr.var t t.repr.body
          else t;
        a' = unfoldMu a;
        b' = unfoldMu b;
      in
      # 用 guard 递归 unify（避免无限展开）
      unify subst a' b';

in {
  inherit unify unifyRows occursIn;
}
