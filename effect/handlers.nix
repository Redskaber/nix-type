# effect/handlers.nix — Phase 4.2
# Effect Handlers（deep/shallow，INV-EFF-4~9）
{ lib, typeLib, reprLib, kindLib, normalizeLib, hashLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith;
  inherit (reprLib) rHandler rEffect rEffectMerge rVariantRow rRowEmpty rVar
                    mkBranch mkBranchWithCont;
  inherit (kindLib) KStar KRow KEffect;
  inherit (normalizeLib) normalize';
  inherit (hashLib) typeHash;

in rec {

  # ══ Handler 类型构造器 ════════════════════════════════════════════════
  mkHandler = effectTag: branches: returnType:
    mkTypeDefault (rHandler effectTag branches returnType) KStar;

  # INV-EFF-8: deep handler 处理所有 occurrence
  mkDeepHandler = effectTag: branches: returnType:
    let base = mkHandler effectTag branches returnType; in
    mkTypeWith
      (base.repr // { shallow = false; deep = true; })
      base.kind base.meta;

  # INV-EFF-9: shallow handler 仅处理第一次 occurrence
  mkShallowHandler = effectTag: branches: returnType:
    let base = mkHandler effectTag branches returnType; in
    mkTypeWith
      (base.repr // { shallow = true; deep = false; })
      base.kind base.meta;

  isHandler = t: isType t && (t.repr.__variant or null) == "Handler";

  # ══ Effect Row 构造器 ═════════════════════════════════════════════════
  emptyEffectRow = mkTypeDefault rRowEmpty KRow;

  singleEffect = name: ty:
    mkTypeDefault (rVariantRow { ${name} = ty; } null) KRow;

  effectMerge = e1: e2:
    mkTypeDefault (rEffectMerge e1 e2) KEffect;

  # ══ checkHandler（INV-EFF-5）══════════════════════════════════════════
  _collectEffectLabels = row:
    let v = row.repr.__variant or null; in
    if v == "VariantRow" then builtins.attrNames row.repr.variants
    else if v == "EffectMerge" then
      _collectEffectLabels row.repr.e1 ++ _collectEffectLabels row.repr.e2
    else if v == "Var" then [ "RowVar:${row.repr.name}" ]
    else [];

  # Type: Type(Handler) → Type(Effect) → { ok: Bool; remainingEffects: Type; error? }
  checkHandler = handler: effectType:
    let handlerTag = handler.repr.__variant or null; in
    if handlerTag != "Handler" then
      { ok = false; error = "Not a Handler type"; }
    else
      let
        hEffTag = handler.repr.effectTag;
        effRow  =
          if (effectType.repr.__variant or null) == "Effect"
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

  # ══ handleAll（INV-EFF-5）════════════════════════════════════════════
  handleAll = handlers: effectType:
    lib.foldl' (acc: handler:
      if !acc.ok then acc
      else
        let r = checkHandler handler acc.remainingEffects; in
        if r.ok then acc // { remainingEffects = r.remainingEffects; }
        else acc
    ) { ok = true; remainingEffects = effectType; } handlers;

  # ══ subtractEffect（INV-EFF-7）════════════════════════════════════════
  subtractEffect = row: label:
    let v = row.repr.__variant or null; in
    if v == "VariantRow" then
      let
        newVariants = lib.filterAttrs (n: _: n != label) row.repr.variants;
      in
      mkTypeDefault (rVariantRow newVariants row.repr.tail) KRow
    else if v == "EffectMerge" then
      mkTypeDefault (rEffectMerge
        (subtractEffect row.repr.e1 label)
        (subtractEffect row.repr.e2 label)) KEffect
    else row;

  # ══ INV-EFF-8: Deep handler semantics ════════════════════════════════
  # deep handler 处理 effectType 中所有出现的 hEffTag
  deepHandlerCovers = handler: effectType:
    assert isHandler handler;
    let hEffTag = handler.repr.effectTag; in
    if !(handler.repr.deep or false) then false
    else
      # 检查 effectType 中是否有 hEffTag 出现（任意深度）
      _effectOccursDeep hEffTag effectType;

  _effectOccursDeep = label: ty:
    let v = ty.repr.__variant or null; in
    if v == "VariantRow" then builtins.elem label (builtins.attrNames ty.repr.variants)
    else if v == "EffectMerge" then
      _effectOccursDeep label ty.repr.e1 || _effectOccursDeep label ty.repr.e2
    else if v == "Effect" then _effectOccursDeep label ty.repr.effectRow
    else false;

  # ══ INV-EFF-9: Shallow handler semantics ═════════════════════════════
  # shallow handler 只处理第一次出现
  shallowHandlerResult = handler: effectType:
    assert isHandler handler;
    let
      hEffTag   = handler.repr.effectTag;
      remaining = subtractEffect effectType hEffTag;
    in
    if !(handler.repr.shallow or false) then
      { ok = false; error = "Not a shallow handler"; }
    else
      { ok = true; firstOccurrence = hEffTag; remaining = remaining; };

  # ══ Effect type 合法性检查（INV-EFF-4）═══════════════════════════════
  checkEffectWellFormed = t:
    let v = t.repr.__variant or null; in
    if v == "Effect" then
      let rowOk = _checkRowWellFormed t.repr.effectRow; in
      if !rowOk.ok then rowOk
      else { ok = true; }
    else if v == "EffectMerge" then
      let
        r1 = checkEffectWellFormed t.repr.e1;
        r2 = checkEffectWellFormed t.repr.e2;
      in
      if !r1.ok then r1 else if !r2.ok then r2 else { ok = true; }
    else { ok = true; };

  _checkRowWellFormed = row:
    let v = row.repr.__variant or null; in
    if v == "VariantRow" || v == "RowEmpty" || v == "Var" then { ok = true; }
    else if v == "EffectMerge" then
      let
        r1 = _checkRowWellFormed row.repr.e1;
        r2 = _checkRowWellFormed row.repr.e2;
      in
      if !r1.ok then r1 else if !r2.ok then r2 else { ok = true; }
    else { ok = false; error = "invalid effect row: ${v}"; };
}
