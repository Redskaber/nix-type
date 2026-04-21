# normalize/rewrite.nix — Phase 4.1
# TRS 主引擎：fuel-based 强制终止
# INV-2: 所有计算 = Rewrite(TypeIR)
# INV-3: normalize 结果唯一（confluence 由规则顺序保证）
{ lib, typeLib, reprLib, rulesLib, kindLib }:

let
  inherit (typeLib) isType mkTypeWith;
  inherit (rulesLib) applyOneRule isNFShallow;
  inherit (reprLib)
    rLambdaK rApply rFn rConstrained rConstructor rRecord rRowExtend
    rVariantRow rEffect rEffectMerge rMu rPi rSigma rOpaque rAscribe
    rRefined rSig rStruct rModFunctor rHandler;

  # ── 深度规范化主函数 ──────────────────────────────────────────────────────
  # Type: Int -> Type -> Type
  # fuel: 最大重写步骤数（INV-2 终止性保证）
  normalize = fuel: t:
    if !isType t then t
    else if fuel <= 0 then t  # ⚠️ fuel 耗尽，返回当前形式
    else
      # Step 1: 尝试顶层规则
      let topResult = applyOneRule t; in
      if topResult != null
      then normalize (fuel - 1) topResult  # 应用规则，继续
      else
        # Step 2: 顶层无规则，递归规范化子项
        normalizeSubterms fuel t;

  # ── 子项递归规范化 ────────────────────────────────────────────────────────
  # 子项规范化后，重新尝试顶层规则（子项可能解锁新规则）
  normalizeSubterms = fuel: t:
    let
      v    = t.repr.__variant or null;
      fuel1 = fuel - 1;
    in

    if v == "Lambda" then
      let body' = normalize fuel1 t.repr.body; in
      mkTypeWith (rLambdaK t.repr.param (t.repr.paramKind or kindLib.KStar) body')
                 t.kind t.meta

    else if v == "Apply" then
      let
        fn'   = normalize fuel1 t.repr.fn;
        args' = map (normalize fuel1) (t.repr.args or []);
        t'    = mkTypeWith (rApply fn' args') t.kind t.meta;
        # 子项规范化后重新尝试顶层
        top   = applyOneRule t';
      in
      if top != null then normalize fuel1 top else t'

    else if v == "Fn" then
      let
        from' = normalize fuel1 t.repr.from;
        to'   = normalize fuel1 t.repr.to;
      in mkTypeWith (rFn from' to') t.kind t.meta

    else if v == "Constrained" then
      let base' = normalize fuel1 t.repr.base; in
      mkTypeWith (rConstrained base' t.repr.constraints) t.kind t.meta

    else if v == "Constructor" then
      let body' = normalize fuel1 t.repr.body; in
      mkTypeWith (rConstructor t.repr.name t.repr.kind t.repr.params body')
                 t.kind t.meta

    else if v == "Record" then
      let
        fnames  = builtins.attrNames (t.repr.fields or {});
        fields' = builtins.listToAttrs (map (n: {
          name  = n;
          value = normalize fuel1 t.repr.fields.${n};
        }) fnames);
      in mkTypeWith (rRecord fields') t.kind t.meta

    else if v == "RowExtend" then
      let
        ft'   = normalize fuel1 t.repr.fieldType;
        rest' = normalize fuel1 t.repr.rest;
        t'    = mkTypeWith (rRowExtend t.repr.label ft' rest') t.kind t.meta;
        top   = applyOneRule t';
      in if top != null then normalize fuel1 top else t'

    else if v == "VariantRow" then
      let
        vnames    = builtins.attrNames (t.repr.variants or {});
        variants' = builtins.listToAttrs (map (n: {
          name  = n;
          value = normalize fuel1 t.repr.variants.${n};
        }) vnames);
        ext' = if t.repr.extension == null then null
               else normalize fuel1 t.repr.extension;
        t'   = mkTypeWith (rVariantRow variants' ext') t.kind t.meta;
        top  = applyOneRule t';
      in if top != null then normalize fuel1 top else t'

    else if v == "Mu" then
      # equi-recursive: 不展开 μ（避免无限 fuel 消耗）
      # 仅规范化 body 一层
      let body' = normalize fuel1 t.repr.body; in
      mkTypeWith (rMu t.repr.var body') t.kind t.meta

    else if v == "Effect" then
      let er' = normalize fuel1 t.repr.effectRow; in
      mkTypeWith (rEffect er') t.kind t.meta

    else if v == "EffectMerge" then
      let
        l'  = normalize fuel1 t.repr.left;
        r'  = normalize fuel1 t.repr.right;
        t'  = mkTypeWith (rEffectMerge l' r') t.kind t.meta;
        top = applyOneRule t';
      in if top != null then normalize fuel1 top else t'

    else if v == "Pi" then
      let
        domain' = normalize fuel1 t.repr.domain;
        body'   = normalize fuel1 t.repr.body;
      in mkTypeWith (rPi t.repr.param domain' body') t.kind t.meta

    else if v == "Sigma" then
      let
        domain' = normalize fuel1 t.repr.domain;
        body'   = normalize fuel1 t.repr.body;
      in mkTypeWith (rSigma t.repr.param domain' body') t.kind t.meta

    else if v == "Refined" then
      let base' = normalize fuel1 t.repr.base; in
      let t' = mkTypeWith (rRefined base' t.repr.predVar t.repr.predExpr) t.kind t.meta; in
      let top = applyOneRule t'; in
      if top != null then normalize fuel1 top else t'

    else if v == "Opaque" then
      let inner' = normalize fuel1 t.repr.inner; in
      mkTypeWith (rOpaque inner' t.repr.tag) t.kind t.meta

    else if v == "Ascribe" then
      let expr' = normalize fuel1 t.repr.expr; in
      mkTypeWith (rAscribe expr' t.repr.type) t.kind t.meta

    else if v == "Sig" then
      let
        fnames  = builtins.attrNames (t.repr.fields or {});
        fields' = builtins.listToAttrs (map (n: {
          name  = n;
          value = normalize fuel1 t.repr.fields.${n};
        }) fnames);
        t'  = mkTypeWith (rSig fields') t.kind t.meta;
        top = applyOneRule t';
      in if top != null then normalize fuel1 top else t'

    else if v == "Struct" then
      let
        sig' = normalize fuel1 t.repr.sig;
        inames = builtins.attrNames (t.repr.impl or {});
        impl' = builtins.listToAttrs (map (n: {
          name  = n;
          value = normalize fuel1 t.repr.impl.${n};
        }) inames);
      in mkTypeWith (rStruct sig' impl') t.kind t.meta

    else if v == "ModFunctor" then
      let
        paramTy' = normalize fuel1 t.repr.paramTy;
        body'    = normalize fuel1 t.repr.body;
      in mkTypeWith (rModFunctor t.repr.param paramTy' body') t.kind t.meta

    else if v == "Handler" then
      let
        branches' = map (b:
          b // { body = normalize fuel1 b.body; }
        ) (t.repr.branches or []);
        rt' = normalize fuel1 t.repr.returnType;
      in mkTypeWith (rHandler t.repr.effectTag branches' rt') t.kind t.meta

    else t;  # Primitive, Var, ADT, RowEmpty, RowVar, Kind — 已是 NF

  # ── 公开 API ──────────────────────────────────────────────────────────────

  # 默认 fuel（1000 步，足应付实际类型表达式）
  defaultFuel = 1000;

  # Type: Type -> Type  (使用默认 fuel)
  normalize' = normalize defaultFuel;

  # Type: Int -> Type -> Type  (自定义 fuel)
  normalizeWithFuel = normalize;

  # Type: Type -> Bool  (浅层 NF 检查)
  isNormalForm = t:
    isNFShallow t && _normSubtermsCheck t;

  _normSubtermsCheck = t:
    let v = t.repr.__variant or null; in
    if v == "Lambda" then isNormalForm t.repr.body
    else if v == "Apply" then
      isNormalForm t.repr.fn && lib.all isNormalForm (t.repr.args or [])
    else if v == "Fn" then
      isNormalForm t.repr.from && isNormalForm t.repr.to
    else if v == "Constrained" then isNormalForm t.repr.base
    else true;

in {
  inherit normalize normalize' normalizeWithFuel isNormalForm;
}
