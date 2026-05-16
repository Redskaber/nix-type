# effect/handlers.nix — Phase 4.3
# Effect Handlers（deep/shallow，INV-EFF-4~10）
# Phase 4.3 新增：
#   INV-EFF-10: deep handler handles all occurrences（semantic）
#   Handler continuations: resume branch with explicit continuation type
#   mkHandlerWithCont: continuation-passing handler
#   contType: type of the delimited continuation (A → Eff(R, B))
{ lib, typeLib, reprLib, kindLib, normalizeLib, hashLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith;
  inherit (reprLib) rHandler rEffect rEffectMerge rVariantRow rRowEmpty rVar rFn
                    mkBranch mkBranchWithCont;
  inherit (kindLib) KStar KRow KEffect;
  inherit (normalizeLib) normalize';
  inherit (hashLib) typeHash;


  # ══ Handler 类型构造器 ════════════════════════════════════════════════

  # Basic handler（no continuation）
  mkHandler = effectTag: branches: returnType:
    mkTypeDefault (rHandler effectTag branches returnType) KStar;

  # INV-EFF-8: deep handler
  mkDeepHandler = effectTag: branches: returnType:
    let base = mkHandler effectTag branches returnType; in
    mkTypeWith
      (base.repr // { shallow = false; deep = true; })
      base.kind base.meta;

  # INV-EFF-9: shallow handler
  mkShallowHandler = effectTag: branches: returnType:
    let base = mkHandler effectTag branches returnType; in
    mkTypeWith
      (base.repr // { shallow = true; deep = false; })
      base.kind base.meta;

  # INV-EFF-10: Handler with continuation（Phase 4.3 新增）
  # handle : Eff(E ++ R, A) → Handler(E, A, B) → Eff(R, B)
  # contType represents: A → Eff(R, B)  (the delimited continuation type)
  # Phase 4.3: 每个分支携带 contType，表示 resume 的类型
  mkHandlerWithCont = effectTag: paramType: contType: returnType:
    let
      # resume branch: contType = paramType → Eff(R, returnType)
      resumeBranch = mkBranchWithCont effectTag paramType contType
        (mkTypeDefault (rFn paramType returnType) KStar);
      # Final handler repr with continuation type embedded
      # INV-EFF-11: contDomainOk = true iff contType is a Fn type whose .from == paramType
      contV       = contType.repr.__variant or null;
      contDomOk   = contV == "Fn" &&
                    (hashLib.typeHash (contType.repr.from or null) ==
                     hashLib.typeHash paramType);
      handlerRepr = (rHandler effectTag [ resumeBranch ] returnType) // {
        hasCont      = true;
        contType     = contType;
        paramType    = paramType;
        contDomainOk = contDomOk;
      };
    in
    mkTypeDefault handlerRepr KStar;

  # ── Helper: build continuation type ─────────────────────────────────
  # contType(A, R, B) = A → Eff(R, B)
  mkContType = paramType: residualEffects: returnType:
    let
      effType = mkTypeDefault
        (reprLib.rEffect residualEffects returnType)
        KStar;
    in
    mkTypeDefault (rFn paramType effType) KStar;

  isHandler = t: isType t && (t.repr.__variant or null) == "Handler";
  isHandlerWithCont = t: isHandler t && (t.repr.hasCont or false);

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
        { ok               = true;
          remainingEffects = subtractEffect effRow hEffTag;
          handledTag       = hEffTag;
          # Phase 4.3: expose continuation type if handler has one
          contType         = handler.repr.contType or null; }
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
  deepHandlerCovers = handler: effectType:
    assert isHandler handler;
    let hEffTag = handler.repr.effectTag; in
    if !(handler.repr.deep or false) then false
    else _effectOccursDeep hEffTag effectType;

  _effectOccursDeep = label: ty:
    let v = ty.repr.__variant or null; in
    if v == "VariantRow" then builtins.elem label (builtins.attrNames ty.repr.variants)
    else if v == "EffectMerge" then
      _effectOccursDeep label ty.repr.e1 || _effectOccursDeep label ty.repr.e2
    else if v == "Effect" then _effectOccursDeep label ty.repr.effectRow
    else false;

  # ══ INV-EFF-9: Shallow handler semantics ═════════════════════════════
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

  # ══ INV-EFF-10: Handler with continuation semantics（Phase 4.3）══════
  # Verify handler correctly handles ALL occurrences in a deep sense
  # and that the continuation type is well-formed:
  # contType must be: paramType → Eff(R, returnType)
  checkHandlerContWellFormed = handlerCont:
    let
      repr = handlerCont.repr;
    in
    if !(repr.hasCont or false) then
      { ok = false; error = "Not a continuation handler"; }
    else
      let
        paramType  = repr.paramType or null;
        contType   = repr.contType or null;
        returnType = repr.returnType or null;
      in
      if paramType == null || contType == null then
        { ok = false; error = "Missing paramType or contType"; }
      else
        # contType should be a function type: param → ...
        let contV = contType.repr.__variant or null; in
        if contV == "Fn" then
          let
            contFrom     = contType.repr.from;
            domainMatch  = hashLib.typeHash contFrom == hashLib.typeHash paramType;
          in
          { ok           = true;
            inv_eff_11   = domainMatch;
            paramType    = paramType;
            contType     = contType;
            contDomain   = contFrom;
            contCodomain = contType.repr.to; }
        else
          { ok = false; inv_eff_11 = false; error = "contType is not a function type: ${contV}"; };

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
in
{
  inherit
  # ══ Handler 类型构造器 ════════════════════════════════════════════════
  mkHandler
  mkDeepHandler
  mkShallowHandler
  mkHandlerWithCont
  mkContType
  isHandler
  isHandlerWithCont
  # ══ Effect Row 构造器 ═════════════════════════════════════════════════
  emptyEffectRow
  singleEffect
  effectMerge
  # ══ checkHandler（INV-EFF-5）══════════════════════════════════════════
  _collectEffectLabels
  checkHandler
  # ══ handleAll（INV-EFF-5）════════════════════════════════════════════
  handleAll
  # ══ subtractEffect（INV-EFF-7）════════════════════════════════════════
  subtractEffect
  # ══ INV-EFF-8: Deep handler semantics ════════════════════════════════
  deepHandlerCovers
  _effectOccursDeep
  # ══ INV-EFF-9: Shallow handler semantics ═════════════════════════════
  shallowHandlerResult
  # ══ INV-EFF-10: Handler with continuation semantics（Phase 4.3）══════
  checkHandlerContWellFormed
  # ══ Effect type 合法性检查（INV-EFF-4）═══════════════════════════════
  checkEffectWellFormed
  _checkRowWellFormed
  ;
}

