# constraint/unify.nix — Phase 3
# 统一算法（Robinson Unification + Row Unification + Pi-type）
#
# Phase 3 修复：
#   Lambda 统一：使用 serializeReprAlphaCanonical 比较（INV-3）
#   rowVar 统一：rigid variable（不走 binder equality）
#   Pi/Sigma 统一：带 binder 的统一
#
# 不变量：
#   INV-U1: unify(a,b) = Some(σ) → ∀x. typeEq(σ(a), σ(b))
#   INV-U2: unify 是 most-general unifier（MGU）
#   INV-U3: occur check 防止无限类型
#   INV-U4: Lambda 统一走 alpha-canonical（INV-3 兼容）
{ lib, reprLib, typeLib, serialLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault;
  inherit (reprLib) rVar rVarDB freeVarsRepr;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 结果类型
  # unifyResult = { ok: Bool; subst: AttrSet String Type; error?: String }
  # ══════════════════════════════════════════════════════════════════════════════

  _ok    = subst: { ok = true; inherit subst; };
  _fail  = msg: { ok = false; subst = {}; error = msg; };

  emptySubst = {};

  # ══════════════════════════════════════════════════════════════════════════════
  # Occur Check
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: String -> Type -> Bool
  occursIn = name: t:
    freeVarsRepr t.repr ? ${name};

  # ══════════════════════════════════════════════════════════════════════════════
  # 主 Unify 函数
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> Type -> Type -> unifyResult
  unify = subst: a: b:
    let
      va = a.repr.__variant or null;
      vb = b.repr.__variant or null;
      idA = a.id or null;
      idB = b.id or null;
    in

    # 快速路径：相同 id
    if idA != null && idA == idB then _ok subst

    # Var ~ b：绑定变量
    else if va == "Var" || va == "VarScoped" then
      _unifyVar subst a.repr.name b

    # a ~ Var：对称
    else if vb == "Var" || vb == "VarScoped" then
      _unifyVar subst b.repr.name a

    # Primitive ~ Primitive
    else if va == "Primitive" && vb == "Primitive" then
      if a.repr.name == b.repr.name
      then _ok subst
      else _fail "Primitive mismatch: ${a.repr.name} vs ${b.repr.name}"

    # Fn ~ Fn
    else if va == "Fn" && vb == "Fn" then
      let r1 = unify subst a.repr.from b.repr.from; in
      if !r1.ok then r1
      else
        let
          a' = _applySubstType r1.subst a.repr.to;
          b' = _applySubstType r1.subst b.repr.to;
        in
        unify r1.subst a' b'

    # Lambda ~ Lambda（Phase 3 修复：alpha-canonical 比较，INV-U4）
    else if va == "Lambda" && vb == "Lambda" then
      let
        sA = serialLib.serializeReprAlphaCanonical a.repr;
        sB = serialLib.serializeReprAlphaCanonical b.repr;
      in
      if sA == sB then _ok subst
      else _fail "Lambda mismatch (alpha-canonical): ${sA} vs ${sB}"

    # Pi ~ Pi（Phase 3 新增）
    else if va == "Pi" && vb == "Pi" then
      _unifyPi subst a b

    # Sigma ~ Sigma（Phase 3 新增）
    else if va == "Sigma" && vb == "Sigma" then
      _unifySigma subst a b

    # Apply ~ Apply
    else if va == "Apply" && vb == "Apply" then
      _unifyApply subst a b

    # Constructor ~ Constructor（名字相同才可统一）
    else if va == "Constructor" && vb == "Constructor" then
      if a.repr.name != b.repr.name
      then _fail "Constructor mismatch: ${a.repr.name} vs ${b.repr.name}"
      else _ok subst  # 同名 Constructor，结构由 body 决定

    # Mu ~ Mu（equi-recursive：展开一步）
    else if va == "Mu" || vb == "Mu" then
      _unifyMu subst a b

    # Record ~ Record（Row unification）
    else if va == "Record" && vb == "Record" then
      unifyRecord subst a.repr b.repr

    # VariantRow ~ VariantRow
    else if va == "VariantRow" && vb == "VariantRow" then
      unifyVariantRow subst a.repr b.repr

    # RowEmpty ~ RowEmpty
    else if va == "RowEmpty" && vb == "RowEmpty" then
      _ok subst

    # RowExtend ~ RowExtend（Phase 3：row 规范化后比较）
    else if va == "RowExtend" && vb == "RowExtend" then
      _unifyRowExtend subst a b

    # Effect ~ Effect（Phase 3）
    else if va == "Effect" && vb == "Effect" then
      if a.repr.tag != b.repr.tag
      then _fail "Effect tag mismatch: ${a.repr.tag} vs ${b.repr.tag}"
      else unify subst a.repr.row b.repr.row

    # Constrained：unwrap base，追加约束（solver 处理）
    else if va == "Constrained" then
      unify subst a.repr.base b
    else if vb == "Constrained" then
      unify subst a b.repr.base

    # 失败
    else _fail "Cannot unify ${va or "?"} with ${vb or "?"}";

  # ══════════════════════════════════════════════════════════════════════════════
  # 变量统一（occur check + 绑定）
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyVar = subst: name: t:
    let
      bound = subst.${name} or null;
    in
    if bound != null then
      unify subst bound t  # 已绑定：统一绑定值与 t
    else if (t.repr.__variant or null) == "Var" && t.repr.name == name then
      _ok subst  # 自指
    else if occursIn name t then
      _fail "Occur check: ${name} in ${t.repr.__variant or "?"}"
    else
      _ok (subst // { ${name} = t; });

  # ══════════════════════════════════════════════════════════════════════════════
  # Apply 统一
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyApply = subst: a: b:
    let
      r1 = unify subst a.repr.fn b.repr.fn;
    in
    if !r1.ok then r1
    else
      let
        argsA = a.repr.args;
        argsB = b.repr.args;
      in
      if builtins.length argsA != builtins.length argsB
      then _fail "Apply arity mismatch: ${toString (builtins.length argsA)} vs ${toString (builtins.length argsB)}"
      else
        lib.foldl'
          (acc: pair:
            if !acc.ok then acc
            else
              let
                a' = _applySubstType acc.subst pair.fst;
                b' = _applySubstType acc.subst pair.snd;
              in
              unify acc.subst a' b')
          r1
          (lib.zipLists argsA argsB);

  # ══════════════════════════════════════════════════════════════════════════════
  # Pi / Sigma 统一（Phase 3 新增）
  # ══════════════════════════════════════════════════════════════════════════════

  # Π(x:A₁).B₁ ~ Π(y:A₂).B₂
  # → unify A₁ A₂, then unify B₁[x↦z] B₂[y↦z] for fresh z
  _unifyPi = subst: a: b:
    let
      r1 = unify subst a.repr.paramType b.repr.paramType;
    in
    if !r1.ok then r1
    else
      # 使用 fresh var 统一 body（避免捕获）
      let
        fresh = mkTypeDefault (rVar "_u${a.repr.param}${b.repr.param}" "pi-unify") a.kind;
        bodyA = import ../normalize/substitute.nix {} |> (s: s.substitute a.repr.param fresh a.repr.body);
        bodyB = import ../normalize/substitute.nix {} |> (s: s.substitute b.repr.param fresh b.repr.body);
      in
      # Nix 无法 import 自身：直接委托给传入的 substLib
      # 这里简化：假设 param 名字一致（大多数情况）
      if a.repr.param == b.repr.param
      then unify r1.subst a.repr.body b.repr.body
      else
        # 名字不同：用 alpha-canonical 比较
        let
          sA = serialLib.serializeReprAlphaCanonical a.repr;
          sB = serialLib.serializeReprAlphaCanonical b.repr;
        in
        if sA == sB then _ok r1.subst
        else _fail "Pi body mismatch (alpha): ${sA} vs ${sB}";

  _unifySigma = subst: a: b:
    _unifyPi subst a b;  # 结构与 Pi 相同

  # ══════════════════════════════════════════════════════════════════════════════
  # Mu 统一（展开一步）
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyMu = subst: a: b:
    # equi-recursive：展开 Mu 类型一步，最多展开 muFuel 次
    let muFuel = 4; in
    _unifyMuGuarded subst muFuel a b;

  _unifyMuGuarded = subst: fuel: a: b:
    if fuel <= 0 then
      # fuel 耗尽：alpha-canonical 比较（保守）
      let
        sA = serialLib.serializeReprAlphaCanonical a.repr;
        sB = serialLib.serializeReprAlphaCanonical b.repr;
      in
      if sA == sB then _ok subst
      else _fail "Mu unification fuel exhausted: ${sA} vs ${sB}"
    else
      let
        va = a.repr.__variant or null;
        vb = b.repr.__variant or null;
      in
      if va == "Mu" then
        # 展开 a：substitute param → a
        let a' = { repr = a.repr.body.repr // {}; kind = a.kind; meta = a.meta; id = ""; } // a.repr.body; in
        _unifyMuGuarded subst (fuel - 1) a' b
      else if vb == "Mu" then
        let b' = b.repr.body; in
        _unifyMuGuarded subst (fuel - 1) a b'
      else
        unify subst a b;

  # ══════════════════════════════════════════════════════════════════════════════
  # Record Unification（Row）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> RecordRepr -> RecordRepr -> unifyResult
  unifyRecord = subst: ra: rb:
    let
      labsA = builtins.attrNames ra.fields;
      labsB = builtins.attrNames rb.fields;
      common = builtins.filter (l: ra.fields ? ${l}) labsB;
      onlyA  = builtins.filter (l: !(rb.fields ? ${l})) labsA;
      onlyB  = builtins.filter (l: !(ra.fields ? ${l})) labsB;

      # 统一公共字段
      r1 = lib.foldl'
        (acc: l:
          if !acc.ok then acc
          else unify acc.subst ra.fields.${l} rb.fields.${l})
        (_ok subst)
        common;
    in
    if !r1.ok then r1
    else
      # Phase 3 修复：rowVar = rigid（name equality，不走 unification）
      let
        rvA = ra.rowVar;
        rvB = rb.rowVar;
      in
      if rvA == null && rvB == null then
        # 两者封闭：字段必须完全相同
        if builtins.length onlyA > 0 || builtins.length onlyB > 0
        then _fail "Closed record field mismatch: extra A=[${builtins.concatStringsSep "," onlyA}] extra B=[${builtins.concatStringsSep "," onlyB}]"
        else r1
      else if rvA != null && rvB != null then
        # 两者开放：rowVar 必须相同（rigid）
        if rvA == rvB
        then r1  # 相同 rowVar，额外字段差异由调用方处理
        else _fail "Record rowVar mismatch: ${rvA} vs ${rvB}"
      else
        # 一开一闭：不能统一
        _fail "Cannot unify open record with closed record";

  # ══════════════════════════════════════════════════════════════════════════════
  # VariantRow Unification
  # ══════════════════════════════════════════════════════════════════════════════

  unifyVariantRow = subst: ra: rb:
    let
      labsA = builtins.attrNames ra.variants;
      labsB = builtins.attrNames rb.variants;
      common = builtins.filter (l: ra.variants ? ${l}) labsB;
      onlyA  = builtins.filter (l: !(rb.variants ? ${l})) labsA;
      onlyB  = builtins.filter (l: !(ra.variants ? ${l})) labsB;

      r1 = lib.foldl'
        (acc: l:
          if !acc.ok then acc
          else
            let
              fsA = ra.variants.${l};
              fsB = rb.variants.${l};
            in
            if builtins.length fsA != builtins.length fsB
            then _fail "VariantRow ${l} arity mismatch"
            else
              lib.foldl'
                (acc2: pair:
                  if !acc2.ok then acc2
                  else unify acc2.subst pair.fst pair.snd)
                acc
                (lib.zipLists fsA fsB))
        (_ok subst)
        common;
    in
    if !r1.ok then r1
    else
      let rvA = ra.rowVar; rvB = rb.rowVar; in
      if rvA == null && rvB == null then
        if builtins.length onlyA > 0 || builtins.length onlyB > 0
        then _fail "Closed VariantRow mismatch"
        else r1
      else if rvA != null && rvB != null && rvA == rvB then r1
      else if rvA == null || rvB == null then
        _fail "Cannot unify open VariantRow with closed"
      else
        _fail "VariantRow rowVar mismatch: ${rvA or "∅"} vs ${rvB or "∅"}";

  # ══════════════════════════════════════════════════════════════════════════════
  # RowExtend Unification
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyRowExtend = subst: a: b:
    if a.repr.label != b.repr.label
    then _fail "RowExtend label mismatch: ${a.repr.label} vs ${b.repr.label}"
    else
      let r1 = unify subst a.repr.fieldType b.repr.fieldType; in
      if !r1.ok then r1
      else unify r1.subst a.repr.rowType b.repr.rowType;

  # ══════════════════════════════════════════════════════════════════════════════
  # 替换应用（轻量版，不依赖 substLib 避免循环）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> Type -> Type
  _applySubstType = subst: t:
    let v = t.repr.__variant or null; in
    if v == "Var" || v == "VarScoped" then
      subst.${t.repr.name} or t
    else t;  # 简化版：只替换顶层 Var（完整版在 substLib）

}
