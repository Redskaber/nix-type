# normalize/rewrite.nix — Phase 3
# TRS Normalize 引擎（统一，fuel-based）
#
# Phase 3 修复（来自 nix-todo/normalize/rewrite.md）：
#   统一 step + fixpointStep + normalizeSubterms 三系统
#   → 单一 normalize 函数：先 subterms，再 top-level rules，fixpoint
#
# 语义：
#   normalize(t) = fixpoint(step(t)) until NF or fuel=0
#   step(t)      = applyOneRule(t) | normalizeSubterms(t)
#   NF           = no rule fires + all subterms in NF
#
# 不变量：
#   INV-2: normalize 终止（fuel 保证，强制）
#   INV-NF1: isNormalForm(normalize(t)) = true（fuel > 0 时）
#   INV-NF2: normalize(normalize(t)) = normalize(t)（幂等）
{ lib, reprLib, rulesLib, substLib, kindLib, typeLib }:

let
  inherit (typeLib) isType mkTypeWith mkBootstrapType;
  inherit (reprLib)
    rApply rLambda rFn rConstrained rMu rRecord rVariantRow
    rRowExtend rPi rSigma rEffect rAscribe;
  inherit (rulesLib) applyOneRule;

  # 默认参数
  _defaultFuel = 64;
  _defaultMuFuel = 8;
  _defaultEta = false;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 主入口：normalize（使用默认参数）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Type
  normalize = t: normalizeWith { fuel = _defaultFuel; muFuel = _defaultMuFuel; eta = _defaultEta; } t;

  # Type: Type -> Type（同 normalize，供 normalizeLib.normalize' 接口）
  normalize' = normalize;

  # ══════════════════════════════════════════════════════════════════════════════
  # 带参数的 normalize
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: NormConfig -> Type -> Type
  # config = { fuel: Int; muFuel: Int; eta: Bool }
  normalizeWith = config: t:
    let
      fuel   = config.fuel or _defaultFuel;
      muFuel = config.muFuel or _defaultMuFuel;
      eta    = config.eta or false;
    in
    _normalizeStep fuel muFuel eta t;

  # ══════════════════════════════════════════════════════════════════════════════
  # 内部：单步 normalize（递归 fixpoint）
  # ══════════════════════════════════════════════════════════════════════════════

  # 策略：
  #   1. 先对子项 normalize（bottom-up）
  #   2. 再对顶层应用规则
  #   3. 若有规则命中，递归（fuel-1）；否则返回

  # Type: Int -> Int -> Bool -> Type -> Type
  _normalizeStep = fuel: muFuel: eta: t:
    assert isType t;
    if fuel <= 0 then t  # 强制终止（INV-2）
    else
      let
        # Step 1：子项 normalize
        t1 = _normalizeSubterms fuel muFuel eta t;
        # Step 2：顶层规则
        result = applyOneRule muFuel eta t1;
      in
      if result == null
      then t1  # NF 到达
      else _normalizeStep (fuel - 1) muFuel eta result;  # 继续归约

  # ══════════════════════════════════════════════════════════════════════════════
  # 子项 Normalize（结构递归）
  # ══════════════════════════════════════════════════════════════════════════════

  # 只对直接子项递归，不做顶层规则（避免无限循环）
  # Type: Int -> Int -> Bool -> Type -> Type
  _normalizeSubterms = fuel: muFuel: eta: t:
    let
      v = t.repr.__variant or null;
      step = _normalizeStep (fuel - 1) muFuel eta;
    in

    if v == "Apply" then
      let
        fn'   = step t.repr.fn;
        args' = map step t.repr.args;
      in
      mkTypeWith (rApply fn' args') t.kind t.meta

    else if v == "Lambda" then
      let body' = step t.repr.body; in
      mkTypeWith (rLambda t.repr.param body') t.kind t.meta

    else if v == "Pi" then
      let
        pt' = step t.repr.paramType;
        bd' = step t.repr.body;
      in
      mkTypeWith (rPi t.repr.param pt' bd') t.kind t.meta

    else if v == "Sigma" then
      let
        pt' = step t.repr.paramType;
        bd' = step t.repr.body;
      in
      mkTypeWith (rSigma t.repr.param pt' bd') t.kind t.meta

    else if v == "Fn" then
      mkTypeWith (rFn (step t.repr.from) (step t.repr.to)) t.kind t.meta

    else if v == "Constrained" then
      let base' = step t.repr.base; in
      mkTypeWith (rConstrained base' t.repr.constraints) t.kind t.meta

    else if v == "Mu" then
      let body' = step t.repr.body; in
      mkTypeWith (rMu t.repr.param body') t.kind t.meta

    else if v == "Record" then
      let fields' = lib.mapAttrs (_: step) t.repr.fields; in
      mkTypeWith (rRecord fields' t.repr.rowVar) t.kind t.meta

    else if v == "VariantRow" then
      let variants' = lib.mapAttrs (_: fs: map step fs) t.repr.variants; in
      mkTypeWith (rVariantRow variants' t.repr.rowVar) t.kind t.meta

    else if v == "RowExtend" then
      mkTypeWith
        (rRowExtend t.repr.label (step t.repr.fieldType) (step t.repr.rowType))
        t.kind t.meta

    else if v == "Effect" then
      let row' = step t.repr.row; in
      mkTypeWith (rEffect t.repr.tag row') t.kind t.meta

    else if v == "Ascribe" then
      let
        t'   = step t.repr.t;
        ann' = step t.repr.annotation;
      in
      mkTypeWith (rAscribe t' ann') t.kind t.meta

    else t;  # Primitive, Var, VarDB, RowEmpty, Opaque → 叶节点

  # ══════════════════════════════════════════════════════════════════════════════
  # NF 检测
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Bool（浅检测：顶层无规则可命中）
  isNormalForm = t:
    let result = applyOneRule _defaultMuFuel false t; in
    result == null;

  # Type: Type -> Bool（深检测：所有子项也是 NF）
  isNormalFormDeep = t:
    isNormalForm t && _subtermsInNF t;

  _subtermsInNF = t:
    let v = t.repr.__variant or null; in
    if v == "Apply" then
      isNormalFormDeep t.repr.fn
      && lib.all isNormalFormDeep t.repr.args
    else if v == "Lambda" then isNormalFormDeep t.repr.body
    else if v == "Pi"     then isNormalFormDeep t.repr.paramType && isNormalFormDeep t.repr.body
    else if v == "Sigma"  then isNormalFormDeep t.repr.paramType && isNormalFormDeep t.repr.body
    else if v == "Fn"     then isNormalFormDeep t.repr.from && isNormalFormDeep t.repr.to
    else if v == "Constrained" then isNormalFormDeep t.repr.base
    else if v == "Mu"     then isNormalFormDeep t.repr.body
    else if v == "Record" then lib.all isNormalFormDeep (builtins.attrValues t.repr.fields)
    else if v == "VariantRow" then
      lib.all (fs: lib.all isNormalFormDeep fs) (builtins.attrValues t.repr.variants)
    else if v == "RowExtend" then
      isNormalFormDeep t.repr.fieldType && isNormalFormDeep t.repr.rowType
    else true;  # 叶节点

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind Post-Pass（normalize 后验证 kind，INV-K4）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Type（normalize + kind 验证，返回 KError 标注若失败）
  normalizeAndCheckKind = t:
    let
      nf     = normalize t;
      inferred = kindLib.kindInferRepr nf.repr;
      unified  = kindLib.kindUnify {} inferred (nf.kind or kindLib.KUnbound);
    in
    if unified.ok
    then nf  # kind 一致
    else nf // { kind = kindLib.KError "Kind mismatch after normalize: ${kindLib.serializeKind inferred} vs ${kindLib.serializeKind (nf.kind or kindLib.KUnbound)}"; };

}
