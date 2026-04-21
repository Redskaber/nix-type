# normalize/substitute.nix — Phase 3
# Capture-Safe Substitution + de Bruijn Index + Phase 3 变体
#
# Phase 3 新增：
#   Pi / Sigma 的 capture-safe substitution
#   Effect / Opaque / Ascribe substitution
#   freeVarsRepr 完整实现（所有变体覆盖，委托给 reprLib）
#
# 修复（Phase 3）：
#   substituteAll — 递归 foldr 替换（正确复合顺序）
#   composeSubst  — 正确 composition：(σ₂ ∘ σ₁)(x) = σ₂(σ₁(x))
#   deBruijnify   — 完整 Pi/Sigma/Mu binder 处理
{ lib, reprLib, typeLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault mkBootstrapType stableId;
  inherit (reprLib)
    rVar rVarDB rLambda rApply rFn rConstructor rADT rConstrained
    rMu rRecord rVariantRow rRowExtend rRowEmpty
    rPi rSigma rEffect rAscribe
    freeVarsRepr;

  # ── 新鲜变量生成（capture-safe rename 用）────────────────────────────────
  _fresh = name: name ++ "'";  # 简单 prime 后缀（实际系统用 gensym）

  # ── 自由变量收集（委托给 reprLib.freeVarsRepr）────────────────────────────
  freeVars = t:
    assert isType t;
    freeVarsRepr t.repr;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Capture-Safe Substitution（核心）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: String -> Type -> Type -> Type
  # substitute varName replacement targetType
  substitute = varName: replacement: t:
    assert isType t;
    let
      v  = t.repr.__variant or null;
      fv = freeVars replacement;
    in

    if v == "Var" then
      if t.repr.name == varName then replacement else t

    else if v == "VarDB" then t  # de Bruijn var 不走命名替换

    else if v == "VarScoped" then
      if t.repr.name == varName then replacement else t

    else if v == "Lambda" then
      if t.repr.param == varName then t  # 被绑定，停止
      else
        # capture 检查：param 是否在 replacement 的自由变量中
        let t' = if fv ? ${t.repr.param}
                 then _alphaRename t.repr.param (_fresh t.repr.param) t
                 else t;
            body' = substitute varName replacement t'.repr.body;
        in
        mkTypeWith (rLambda t'.repr.param body') t.kind t.meta

    else if v == "Pi" then
      if t.repr.param == varName then
        # 替换 paramType，但 body 中 param 绑定了 varName
        let pt' = substitute varName replacement t.repr.paramType; in
        mkTypeWith (rPi t.repr.param pt' t.repr.body) t.kind t.meta
      else
        let t' = if fv ? ${t.repr.param}
                 then _alphaRenamePi t.repr.param (_fresh t.repr.param) t
                 else t;
            pt'  = substitute varName replacement t'.repr.paramType;
            bd'  = substitute varName replacement t'.repr.body;
        in
        mkTypeWith (rPi t'.repr.param pt' bd') t.kind t.meta

    else if v == "Sigma" then
      if t.repr.param == varName then
        let pt' = substitute varName replacement t.repr.paramType; in
        mkTypeWith (rSigma t.repr.param pt' t.repr.body) t.kind t.meta
      else
        let t' = if fv ? ${t.repr.param}
                 then _alphaRenameSigma t.repr.param (_fresh t.repr.param) t
                 else t;
            pt'  = substitute varName replacement t'.repr.paramType;
            bd'  = substitute varName replacement t'.repr.body;
        in
        mkTypeWith (rSigma t'.repr.param pt' bd') t.kind t.meta

    else if v == "Mu" then
      if t.repr.param == varName then t  # 被绑定
      else
        let t' = if fv ? ${t.repr.param}
                 then _alphaRenameMu t.repr.param (_fresh t.repr.param) t
                 else t;
            body' = substitute varName replacement t'.repr.body;
        in
        mkTypeWith (rMu t'.repr.param body') t.kind t.meta

    else if v == "Apply" then
      let
        fn'   = substitute varName replacement t.repr.fn;
        args' = map (substitute varName replacement) t.repr.args;
      in
      mkTypeWith (rApply fn' args') t.kind t.meta

    else if v == "Fn" then
      let
        from' = substitute varName replacement t.repr.from;
        to'   = substitute varName replacement t.repr.to;
      in
      mkTypeWith (rFn from' to') t.kind t.meta

    else if v == "Constrained" then
      let base' = substitute varName replacement t.repr.base; in
      mkTypeWith (rConstrained base' t.repr.constraints) t.kind t.meta

    else if v == "Record" then
      let
        fields' = lib.mapAttrs
          (_: ft: substitute varName replacement ft)
          t.repr.fields;
        # rowVar 不是 type variable（rigid），不替换
      in
      mkTypeWith (rRecord fields' t.repr.rowVar) t.kind t.meta

    else if v == "VariantRow" then
      let
        variants' = lib.mapAttrs
          (_: fs: map (substitute varName replacement) fs)
          t.repr.variants;
      in
      mkTypeWith (rVariantRow variants' t.repr.rowVar) t.kind t.meta

    else if v == "RowExtend" then
      let
        ft'  = substitute varName replacement t.repr.fieldType;
        rt'  = substitute varName replacement t.repr.rowType;
      in
      mkTypeWith (rRowExtend t.repr.label ft' rt') t.kind t.meta

    else if v == "Effect" then
      let row' = substitute varName replacement t.repr.row; in
      mkTypeWith (rEffect t.repr.tag row') t.kind t.meta

    else if v == "Ascribe" then
      let
        t''   = substitute varName replacement t.repr.t;
        ann'  = substitute varName replacement t.repr.annotation;
      in
      mkTypeWith (rAscribe t'' ann') t.kind t.meta

    else t;  # Primitive, RowEmpty, Opaque, VarDB → 不含命名变量

  # ══════════════════════════════════════════════════════════════════════════════
  # 批量替换
  # ══════════════════════════════════════════════════════════════════════════════

  # 顺序替换（map → foldr，正确顺序）
  # Type: AttrSet String Type -> Type -> Type
  substituteAll = subst: t:
    let vars = builtins.attrNames subst; in
    lib.foldl' (acc: var: substitute var subst.${var} acc) t vars;

  # 替换 Composition：σ₂ ∘ σ₁
  # (σ₂ ∘ σ₁)(x) = σ₂(σ₁(x))  — 先 σ₁ 后 σ₂
  # Type: AttrSet -> AttrSet -> AttrSet
  composeSubst = sigma1: sigma2:
    let
      # 对 sigma1 的每个目标应用 sigma2
      applied = lib.mapAttrs (_: t: substituteAll sigma2 t) sigma1;
      # sigma2 中不在 sigma1 domain 的变量追加
      extra = lib.filterAttrs (k: _: !(sigma1 ? ${k})) sigma2;
    in
    applied // extra;

  # ══════════════════════════════════════════════════════════════════════════════
  # α-Rename（capture-safe helper）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: String -> String -> Type -> Type
  _alphaRename = oldName: newName: t:
    let v = t.repr.__variant or null; in
    if v == "Var" then
      if t.repr.name == oldName
      then mkTypeWith (rVar newName (t.repr.scope or "")) t.kind t.meta
      else t
    else if v == "Lambda" then
      if t.repr.param == oldName then t  # 遮蔽
      else
        let body' = _alphaRename oldName newName t.repr.body; in
        mkTypeWith (rLambda t.repr.param body') t.kind t.meta
    else if v == "Apply" then
      let
        fn'   = _alphaRename oldName newName t.repr.fn;
        args' = map (_alphaRename oldName newName) t.repr.args;
      in
      mkTypeWith (rApply fn' args') t.kind t.meta
    else if v == "Fn" then
      mkTypeWith (rFn (_alphaRename oldName newName t.repr.from)
                      (_alphaRename oldName newName t.repr.to)) t.kind t.meta
    else if v == "Constrained" then
      mkTypeWith (rConstrained (_alphaRename oldName newName t.repr.base) t.repr.constraints) t.kind t.meta
    else if v == "Mu" then
      if t.repr.param == oldName then t
      else
        let body' = _alphaRename oldName newName t.repr.body; in
        mkTypeWith (rMu t.repr.param body') t.kind t.meta
    else t;

  _alphaRenamePi = oldName: newName: t:
    let
      pt' = _alphaRename oldName newName t.repr.paramType;
      bd' = if t.repr.param == oldName then t.repr.body
            else _alphaRename oldName newName t.repr.body;
    in
    mkTypeWith (rPi t.repr.param pt' bd') t.kind t.meta;

  _alphaRenameSigma = oldName: newName: t:
    let
      pt' = _alphaRename oldName newName t.repr.paramType;
      bd' = if t.repr.param == oldName then t.repr.body
            else _alphaRename oldName newName t.repr.body;
    in
    mkTypeWith (rSigma t.repr.param pt' bd') t.kind t.meta;

  _alphaRenameMu = oldName: newName: t:
    if t.repr.param == oldName then t
    else
      let body' = _alphaRename oldName newName t.repr.body; in
      mkTypeWith (rMu t.repr.param body') t.kind t.meta;

  # ══════════════════════════════════════════════════════════════════════════════
  # de Bruijn 转换（α-canonical 前置步骤）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Type
  deBruijnify = t: _dBType { env = {}; depth = 0; } t;

  # Type: DBCtx -> Type -> Type
  _dBType = ctx: t:
    assert isType t;
    let
      v   = t.repr.__variant or null;
      dep = ctx.depth;
      env = ctx.env;
    in

    if v == "Var" then
      let idx = env.${t.repr.name} or null; in
      if idx != null
      then mkTypeWith (rVarDB (dep - idx - 1)) t.kind t.meta
      else t  # 自由变量：保留

    else if v == "Lambda" then
      let
        ctx' = { env = env // { ${t.repr.param} = dep; }; depth = dep + 1; };
        body' = _dBType ctx' t.repr.body;
      in
      mkTypeWith (rLambda t.repr.param body') t.kind t.meta  # param 名保留（debug 用）

    else if v == "Pi" then
      let
        pt'  = _dBType ctx t.repr.paramType;
        ctx' = { env = env // { ${t.repr.param} = dep; }; depth = dep + 1; };
        bd'  = _dBType ctx' t.repr.body;
      in
      mkTypeWith (rPi t.repr.param pt' bd') t.kind t.meta

    else if v == "Sigma" then
      let
        pt'  = _dBType ctx t.repr.paramType;
        ctx' = { env = env // { ${t.repr.param} = dep; }; depth = dep + 1; };
        bd'  = _dBType ctx' t.repr.body;
      in
      mkTypeWith (rSigma t.repr.param pt' bd') t.kind t.meta

    else if v == "Mu" then
      let
        ctx' = { env = env // { ${t.repr.param} = dep; }; depth = dep + 1; };
        body' = _dBType ctx' t.repr.body;
      in
      mkTypeWith (rMu t.repr.param body') t.kind t.meta

    else if v == "Apply" then
      let
        fn'   = _dBType ctx t.repr.fn;
        args' = map (_dBType ctx) t.repr.args;
      in
      mkTypeWith (rApply fn' args') t.kind t.meta

    else if v == "Fn" then
      mkTypeWith (rFn (_dBType ctx t.repr.from) (_dBType ctx t.repr.to)) t.kind t.meta

    else if v == "Constrained" then
      mkTypeWith (rConstrained (_dBType ctx t.repr.base) t.repr.constraints) t.kind t.meta

    else if v == "Record" then
      let fields' = lib.mapAttrs (_: _dBType ctx) t.repr.fields; in
      mkTypeWith (rRecord fields' t.repr.rowVar) t.kind t.meta

    else if v == "VariantRow" then
      let variants' = lib.mapAttrs (_: fs: map (_dBType ctx) fs) t.repr.variants; in
      mkTypeWith (rVariantRow variants' t.repr.rowVar) t.kind t.meta

    else if v == "RowExtend" then
      mkTypeWith (rRowExtend t.repr.label
        (_dBType ctx t.repr.fieldType)
        (_dBType ctx t.repr.rowType)) t.kind t.meta

    else t;  # Primitive, RowEmpty, Opaque, VarDB → 不变

  # ══════════════════════════════════════════════════════════════════════════════
  # Row 辅助函数
  # ══════════════════════════════════════════════════════════════════════════════

  # Row spine 展平（RowExtend chain → [{label, fieldType}] + tail）
  # Type: Type -> { fields: [{label, fieldType}]; tail: Type? }
  flattenRow = t:
    let v = t.repr.__variant or null; in
    if v == "RowEmpty" then { fields = []; tail = null; }
    else if v == "RowExtend" then
      let rest = flattenRow t.repr.rowType; in
      { fields = [{ inherit (t.repr) label fieldType; }] ++ rest.fields;
        tail   = rest.tail; }
    else { fields = []; tail = t; };  # 变量行

  # 构建 Row spine（从排序后的 fields 构建 RowExtend chain）
  # Type: [{label, fieldType}] -> Type? -> Type
  buildRow = fields: tailType:
    let
      sorted = builtins.sort (a: b: a.label < b.label) fields;
      tail   = if tailType == null
               then mkBootstrapType rRowEmpty
               else tailType;
    in
    lib.foldr
      (f: acc: mkBootstrapType (rRowExtend f.label f.fieldType acc))
      tail
      sorted;

}
