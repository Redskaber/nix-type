# effect/handlers.nix — Phase 4.1
# Effect Handler 系统（algebraic effects）
# INV-EFF-4: Handler ∈ TypeRepr
# INV-EFF-5: checkHandler 类型安全
# INV-EFF-6: EffectMerge 支持 open RowVar tail（由 rules.nix 规范化）
# INV-EFF-7: subtractEffect 精确消除
# INV-EFF-8: deep handler = handle all occurrences（Phase 4.1）
# INV-EFF-9: shallow handler = handle first only（Phase 4.1）
{ lib, typeLib, reprLib, kindLib, normalizeLib, hashLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith;
  inherit (reprLib)
    rHandler rVariantRow rEffect rEffectMerge rRowEmpty rRowVar
    isEffect isEffectMerge isVariantRow isRowEmpty isRowVar;
  inherit (kindLib) KStar KEffect KRow;
  inherit (normalizeLib) normalize';
  inherit (hashLib) typeHash;

in rec {

  # ══ Effect Label 构造器 ════════════════════════════════════════════════════

  mkEffectLabel = name: paramType: returnType:
    { __type = "EffectLabel";
      inherit name paramType returnType; };

  # ══ Handler Branch 构造器 ═════════════════════════════════════════════════

  mkBranch = effectTag: paramType: body:
    { __type = "HandlerBranch";
      inherit effectTag paramType body; };

  # Phase 4.1: Branch with continuation（INV-EFF-8/9）
  mkBranchWithCont = effectTag: paramType: contType: body:
    { __type    = "HandlerBranch";
      hasResume = true;
      inherit effectTag paramType contType body; };

  # ══ Handler 类型构造器 ════════════════════════════════════════════════════

  # Type: String -> [Branch] -> Type -> Type
  mkHandler = effectTag: branches: returnType:
    mkTypeDefault (rHandler effectTag branches returnType) KStar;

  # Deep handler（处理所有 occurrence，INV-EFF-8）
  mkDeepHandler = effectTag: branches: returnType:
    let base = mkHandler effectTag branches returnType; in
    mkTypeWith
      (base.repr // { shallow = false; deep = true; })
      base.kind base.meta;

  # Shallow handler（仅处理第一次 occurrence，INV-EFF-9）
  mkShallowHandler = effectTag: branches: returnType:
    let base = mkHandler effectTag branches returnType; in
    mkTypeWith
      (base.repr // { shallow = true; deep = false; })
      base.kind base.meta;

  # ══ Effect Row 构造器 ═════════════════════════════════════════════════════

  # Empty effect row（纯计算）
  emptyEffectRow = mkTypeDefault rRowEmpty KRow;

  # Effect row with one effect
  singleEffect = name: ty:
    mkTypeDefault (rVariantRow { ${name} = ty; } null) KRow;

  # Effect row extension（E ++ E'）
  effectMerge = e1: e2:
    mkTypeDefault (rEffectMerge e1 e2) KEffect;

  # ══ checkHandler（INV-EFF-5）══════════════════════════════════════════════

  # Type: Type -> Type -> { ok: Bool; remainingEffects: Type; error?: String }
  # 检查 handler 是否能处理 effectType
  checkHandler = handler: effectType:
    let
      handlerTag = handler.repr.__variant or null;
    in
    if handlerTag != "Handler" then
      { ok = false; error = "Not a Handler type"; }
    else
      let
        hEffTag = handler.repr.effectTag;
        effRow  = if (effectType.repr.__variant or null) == "Effect"
                  then effectType.repr.effectRow
                  else effectType;
        effVars = _collectEffectLabels effRow;
      in
      if builtins.elem hEffTag effVars then
        { ok              = true;
          remainingEffects = subtractEffect effRow hEffTag;
          handledTag       = hEffTag; }
      else
        { ok    = false;
          error = "Handler for '${hEffTag}' but effect row contains: ${builtins.toJSON effVars}"; };

  # ══ handleAll（INV-EFF-5）════════════════════════════════════════════════

  # Type: [Type(Handler)] -> Type -> { ok: Bool; residualEffects: Type }
  # 用一组 handler 处理 effectType，返回残余 effects
  handleAll = handlers: effectType:
    lib.foldl'
      (acc: handler:
        if !acc.ok then acc
        else
          let r = checkHandler handler acc.remainingEffects; in
          if r.ok then acc // { remainingEffects = r.remainingEffects; }
          else acc  # 该 handler 不匹配，继续
      )
      { ok = true;
        remainingEffects = effectType; }
      handlers;

  # ══ subtractEffect（INV-EFF-7）════════════════════════════════════════════

  # Type: Type(EffectRow) -> String -> Type(EffectRow)
  # 从 effect row 中移除指定 effect label
  subtractEffect = effectRow: label:
    let v = effectRow.repr.__variant or null; in
    if v == "VariantRow" then
      let
        variants = effectRow.repr.variants or {};
        ext      = effectRow.repr.extension;
        removed  = builtins.removeAttrs variants [ label ];
      in
      mkTypeDefault (rVariantRow removed ext) KRow

    else if v == "EffectMerge" then
      let
        l' = subtractEffect effectRow.repr.left label;
        r' = subtractEffect effectRow.repr.right label;
      in
      mkTypeDefault (rEffectMerge l' r') KEffect

    else effectRow;  # RowEmpty, RowVar — 无法 subtract

  # ══ 辅助：收集 Effect labels ══════════════════════════════════════════════

  _collectEffectLabels = effectRow:
    let v = effectRow.repr.__variant or null; in
    if v == "VariantRow" then
      builtins.attrNames (effectRow.repr.variants or {})
    else if v == "EffectMerge" then
      _collectEffectLabels effectRow.repr.left ++
      _collectEffectLabels effectRow.repr.right
    else [];

  # ══ Effect 包含检查 ═══════════════════════════════════════════════════════

  containsEffect = effectRow: label:
    builtins.elem label (_collectEffectLabels effectRow);

  # ══ Continuation Type（Phase 4.1，INV-EFF-8）════════════════════════════

  # Continuation: (A → Eff(R, B))
  mkContType = resultType: effType:
    { __variant    = "Cont";
      result       = resultType;
      eff          = effType;
    };
}
