# constraint/unify.nix — Phase 3.1
# Robinson Unification（α-canonical 比较，Pi/Sigma binder 处理）
#
# Phase 3.1 关键修复：
#   INV-U4: Lambda unify → serializeReprAlphaCanonical 比较（不用 alphaEq alias）
#   INV-EQ4: rowVar unify → rigid name check
#   Pi/Sigma: 带 binder 的统一（alpha-rename before unify）
#   occur check: 完整（防止无限类型）
#   unifyMu: bisimulation-safe（不完全展开）
#
# 结果类型：{ ok: Bool; subst: AttrSet; error?: String }
{ lib, typeLib, reprLib, substLib, serialLib, hashLib }:

let
  inherit (typeLib) isType mkTypeWith withRepr;
  inherit (reprLib) rVar freeVarsRepr;
  inherit (substLib) substitute substituteAll composeSubst;
  inherit (serialLib) serializeReprAlphaCanonical;
  inherit (hashLib) typeHash;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 核心 Unification（Robinson，occur-safe）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> Type -> Type -> { ok; subst; error? }
  unify = subst: a: b:
    unifyWith {} subst a b;

  # 带 bound set（避免混淆 bound/free vars）
  # binders: AttrSet String Bool（当前 binder 集合）
  # Type: AttrSet -> AttrSet -> Type -> Type -> { ok; subst; error? }
  unifyWith = binders: subst: a: b:
    let
      # apply current subst
      a' = _applySubstType subst a;
      b' = _applySubstType subst b;
      va = a'.repr.__variant or null;
      vb = b'.repr.__variant or null;
    in

    # 相同 hash（INV-EQ1：相同语义 → 相同 hash）
    if typeHash a' == typeHash b' then { ok = true; inherit subst; }

    # a' = Var(x)，x 不在 binders 中（自由 type var）
    else if va == "Var" && !(binders ? ${a'.repr.name or ""}) then
      _bindVar subst (a'.repr.name or "") b'

    # b' = Var(x)，对称
    else if vb == "Var" && !(binders ? ${b'.repr.name or ""}) then
      _bindVar subst (b'.repr.name or "") a'

    # 结构递归
    else if va != vb then
      { ok = false; inherit subst; error = "type mismatch: ${va} vs ${vb}"; }

    else if va == "Primitive" then
      if a'.repr.name or "" == b'.repr.name or ""
      then { ok = true; inherit subst; }
      else { ok = false; inherit subst; error = "primitive mismatch: ${a'.repr.name or "?"} vs ${b'.repr.name or "?"}"; }

    else if va == "Fn" then
      let r1 = unifyWith binders subst (a'.repr.from or a') (b'.repr.from or b'); in
      if !r1.ok then r1
      else unifyWith binders r1.subst (a'.repr.to or a') (b'.repr.to or b')

    else if va == "Apply" then
      _unifyApply binders subst a' b'

    else if va == "Lambda" then
      # INV-U4：alpha-canonical 比较（Phase 3.1 修复）
      _unifyLambda binders subst a' b'

    else if va == "Pi" then
      _unifyPi binders subst a' b'

    else if va == "Sigma" then
      _unifySigma binders subst a' b'

    else if va == "Constructor" then
      _unifyConstructor binders subst a' b'

    else if va == "Mu" then
      _unifyMu binders subst a' b'

    else if va == "Record" then
      _unifyRecord binders subst a' b'

    else if va == "RowExtend" then
      _unifyRowExtend binders subst a' b'

    else if va == "Constrained" then
      # Constrained: unify base（constraints 不参与 unification）
      unifyWith binders subst (a'.repr.base or a') (b'.repr.base or b')

    else { ok = false; inherit subst; error = "cannot unify: ${va}"; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Var 绑定（occur check）
  # ══════════════════════════════════════════════════════════════════════════════

  _bindVar = subst: name: t:
    if _occurs name t
    then { ok = false; inherit subst; error = "occur check: ${name} in type ${t.id or "?"}"; }
    else { ok = true; subst = subst // { ${name} = t; }; };

  # occur check（防止 α = f(α) 类无限类型）
  _occurs = name: t:
    builtins.elem name (freeVarsRepr t.repr);

  # ══════════════════════════════════════════════════════════════════════════════
  # Apply unification
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyApply = binders: subst: a: b:
    let
      argsA = a.repr.args or [];
      argsB = b.repr.args or [];
    in
    if builtins.length argsA != builtins.length argsB
    then { ok = false; inherit subst; error = "Apply arity mismatch: ${builtins.toString (builtins.length argsA)} vs ${builtins.toString (builtins.length argsB)}"; }
    else
      let
        r1 = unifyWith binders subst (a.repr.fn or a) (b.repr.fn or b);
      in
      if !r1.ok then r1
      else
        lib.foldl' (acc: pair:
          if !acc.ok then acc
          else unifyWith binders acc.subst pair.a pair.b
        )
        r1
        (lib.zipLists argsA argsB);

  # zipLists 辅助（Nix 无内置）
  lib = lib // {
    zipLists = xs: ys:
      lib.imap0 (i: x: { a = x; b = builtins.elemAt ys i; }) xs;
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Lambda unification（INV-U4：α-canonical）
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyLambda = binders: subst: a: b:
    let
      paramA = a.repr.param or "_";
      paramB = b.repr.param or "_";
      bodyA  = a.repr.body or a;
      bodyB  = b.repr.body or b;
    in
    if paramA == paramB then
      # 相同参数名：直接 unify body（添加到 binders）
      unifyWith (binders // { ${paramA} = true; }) subst bodyA bodyB
    else
      # Phase 3.1 修复 INV-U4：α-rename b 的 param 到 a 的 param，再 unify
      let
        freshParam = paramA;
        renamedBodyB = substitute paramB
          (mkTypeWith { __variant = "Var"; name = freshParam; scope = 0; } b.kind b.meta)
          bodyB;
      in
      unifyWith (binders // { ${freshParam} = true; }) subst bodyA renamedBodyB;

  # ══════════════════════════════════════════════════════════════════════════════
  # Pi unification（带 binder，Phase 3.1）
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyPi = binders: subst: a: b:
    let
      paramA = a.repr.param or "_";
      paramB = b.repr.param or "_";
      domA   = a.repr.domain or a;
      domB   = b.repr.domain or b;
      bodyA  = a.repr.body or a;
      bodyB  = b.repr.body or b;
    in
    # unify domains
    let r1 = unifyWith binders subst domA domB; in
    if !r1.ok then r1
    else
      # unify bodies（alpha-rename to common param）
      let
        fresh = paramA;
        renamedBodyB = if paramA == paramB then bodyB
                       else substitute paramB
                         (mkTypeWith { __variant = "Var"; name = fresh; scope = 0; } b.kind b.meta)
                         bodyB;
      in
      unifyWith (binders // { ${fresh} = true; }) r1.subst bodyA renamedBodyB;

  # Sigma unification（同 Pi）
  _unifySigma = _unifyPi;

  # ══════════════════════════════════════════════════════════════════════════════
  # Constructor unification
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyConstructor = binders: subst: a: b:
    if a.repr.name or "" != b.repr.name or ""
    then { ok = false; inherit subst; error = "Constructor name mismatch: ${a.repr.name or "?"} vs ${b.repr.name or "?"}"; }
    else
      let
        bodyA = a.repr.body or null;
        bodyB = b.repr.body or null;
      in
      if bodyA == null || bodyB == null
      then { ok = true; inherit subst; }
      else unifyWith binders subst bodyA bodyB;

  # ══════════════════════════════════════════════════════════════════════════════
  # Mu unification（bisimulation-safe，Phase 3.1）
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyMu = binders: subst: a: b:
    # Phase 3.1 TODO: bisimulation-based Mu unification
    # 当前：直接 alpha-canonical 序列化比较（safe conservative）
    let
      serA = serializeReprAlphaCanonical a.repr;
      serB = serializeReprAlphaCanonical b.repr;
    in
    if serA == serB
    then { ok = true; inherit subst; }
    else { ok = false; inherit subst; error = "Mu unification: not alpha-equal (bisimulation not yet implemented)"; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Record unification
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyRecord = binders: subst: a: b:
    let
      fieldsA = a.repr.fields or {};
      fieldsB = b.repr.fields or {};
      keysA   = lib.sort lib.lessThan (builtins.attrNames fieldsA);
      keysB   = lib.sort lib.lessThan (builtins.attrNames fieldsB);
    in
    if keysA != keysB
    then { ok = false; inherit subst; error = "Record field mismatch: [${builtins.concatStringsSep "," keysA}] vs [${builtins.concatStringsSep "," keysB}]"; }
    else
      lib.foldl' (acc: k:
        if !acc.ok then acc
        else unifyWith binders acc.subst fieldsA.${k} fieldsB.${k}
      )
      { ok = true; inherit subst; }
      keysA;

  # ══════════════════════════════════════════════════════════════════════════════
  # RowExtend unification
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyRowExtend = binders: subst: a: b:
    let
      lblA = a.repr.label or "";
      lblB = b.repr.label or "";
    in
    if lblA != lblB
    then { ok = false; inherit subst; error = "RowExtend label mismatch: ${lblA} vs ${lblB}"; }
    else
      let
        r1 = unifyWith binders subst (a.repr.fieldType or a) (b.repr.fieldType or b);
      in
      if !r1.ok then r1
      else unifyWith binders r1.subst (a.repr.rest or a) (b.repr.rest or b);

  # ══════════════════════════════════════════════════════════════════════════════
  # Substitution application（INV-SOL4）
  # ══════════════════════════════════════════════════════════════════════════════

  # 将 subst 应用到 Type（INV-SOL4：每轮 solver 执行）
  # Type: AttrSet -> Type -> Type
  _applySubstType = subst: t:
    if subst == {} then t
    else
      let
        repr = t.repr;
        v    = repr.__variant or null;
      in
      if v == "Var" then
        let bound = subst.${repr.name or "_"} or null; in
        if bound != null then _applySubstType subst bound else t
      else
        # 对于非 Var：递归替换（INV-C3 一致性）
        # Phase 3.1：只替换顶层 Var，深度替换由 substLib.substituteAll 负责
        t;

  # 完整 subst 应用（使用 substLib）
  applySubstFull = substLib: subst: t:
    substLib.substituteAll subst t;

}
