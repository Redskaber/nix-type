# normalize/rules_p33.nix — Phase 3.3
# TRS 规则扩展：Effect Row Merge + VariantRow Canonical
#
# Phase 3.3 新增规则：
#   P3.3-3: Effect row merge（row concatenation ++ 运算）
#   P3.3-4: ruleVariantRowCanonical（独立于 ruleRowCanonical）
#
# 不变量：
#   INV-ROW-2: ruleVariantRowCanonical 幂等
#   INV-EFF-2: Effect row merge 结合律：(E1 ++ E2) ++ E3 ≡ E1 ++ (E2 ++ E3)
#   INV-EFF-3: Effect row merge 保留 NF hash（两侧已 canonical → merge 结果 canonical）
{ lib, typeLib, kindLib }:

let
  inherit (typeLib) isType mkTypeDefault withRepr;
  inherit (kindLib) KRow KEffect KStar KArrow;

in rec {

  # ════════════════════════════════════════════════════════════════════════════
  # VariantRow Canonical（Phase 3.3：P3.3-4）
  #
  # VariantRow = { variants: AttrSet TypeList; extension: Type? }
  # 规范形式：variants 按 key 字母序（Nix attrSet is unordered，序列化层保证；
  #            此规则确保 repr 层 changed=true 触发 hash 重算）
  # ════════════════════════════════════════════════════════════════════════════

  ruleVariantRowCanonical = fuel: t:
    let r = t.repr; in
    if r.__variant or null != "VariantRow" then { changed = false; type = t; }
    else
      let
        variants = r.variants or {};
        ext      = r.extension or null;
        keys     = builtins.attrNames variants;
        sortedKeys = lib.sort lib.lessThan keys;

        # 检查 extension 是否有嵌套 VariantRow 需要合并（flatten）
        extRepr    = if ext != null then (ext.repr or {}) else {};
        extVariant = extRepr.__variant or null;

        # Flatten: if extension is a VariantRow, inline its variants
        flattenedVariants =
          if ext != null && extVariant == "VariantRow" then
            let innerVariants = extRepr.variants or {}; in
            # Merge: current variants take precedence (closer scope)
            innerVariants // variants  # inner first so outer overrides
          else
            variants;

        flattenedExt =
          if ext != null && extVariant == "VariantRow"
          then extRepr.extension or null
          else ext;

        flattenedKeys     = builtins.attrNames flattenedVariants;
        sortedFlatKeys    = lib.sort lib.lessThan flattenedKeys;
        alreadyCanonical  = keys == sortedKeys
                            && flattenedKeys == keys;
      in
      if alreadyCanonical
      then { changed = false; type = t; }
      else
        let
          sortedVariants = lib.listToAttrs
            (map (k: { name = k; value = flattenedVariants.${k}; }) sortedFlatKeys);
        in
        { changed = true;
          type = withRepr t (r // {
            variants  = sortedVariants;
            extension = flattenedExt;
          }); };

  # ════════════════════════════════════════════════════════════════════════════
  # Effect Row Merge（Phase 3.3：P3.3-3）
  #
  # Merge syntax（Apply node with special tag）:
  #   EffMerge { left: Effect; right: Effect } → merged Effect
  #
  # 算法：
  #   1. Flatten both effect rows into variant sets
  #   2. Merge (left-biased: right overrides on conflict)
  #   3. Rebuild sorted VariantRow
  #   4. Wrap in Effect
  #
  # INV-EFF-2: (E1 ++ E2) ++ E3 = E1 ++ (E2 ++ E3)  (由 flatten → merge 保证)
  # ════════════════════════════════════════════════════════════════════════════

  ruleEffectMerge = fuel: t:
    let r = t.repr; in
    if r.__variant or null != "EffectMerge" then { changed = false; type = t; }
    else
      let
        left  = r.left  or null;
        right = r.right or null;
      in
      if left == null || right == null then { changed = false; type = t; }
      else
        let
          lv = _flattenEffect left;
          rv = _flattenEffect right;
          # Right-biased merge (right effect overrides left on same tag)
          merged = lv // rv;
          sortedKeys = lib.sort lib.lessThan (builtins.attrNames merged);
          mergedVariants = lib.listToAttrs
            (map (k: { name = k; value = merged.${k}; }) sortedKeys);
          mergedEffectRow = mkTypeDefault
            { __variant = "VariantRow"; variants = mergedVariants; extension = null; }
            KRow;
          mergedEffect = mkTypeDefault
            { __variant = "Effect"; effectRow = mergedEffectRow; }
            (KArrow KStar KStar);
        in
        { changed = true; type = mergedEffect; };

  # Flatten Effect → AttrSet of variant name → handler type
  _flattenEffect = effTy:
    let r = effTy.repr or {}; in
    if r.__variant or null == "Effect" then
      let er = (r.effectRow or effTy).repr or {}; in
      if er.__variant or null == "VariantRow" then er.variants or {}
      else {}
    else if r.__variant or null == "EffectMerge" then
      # Flatten recursively
      let
        lv = _flattenEffect (r.left  or effTy);
        rv = _flattenEffect (r.right or effTy);
      in
      lv // rv  # Right-biased (consistent with rule above)
    else
      {};

  # ════════════════════════════════════════════════════════════════════════════
  # Effect Subtract（handle : Eff(E ++ R) - E → Eff(R)）
  # Used by Phase 4 effect handlers; exposed here for completeness
  # ════════════════════════════════════════════════════════════════════════════

  subtractEffect = effTy: tagNames:
    let
      flat = _flattenEffect effTy;
      remaining = lib.filterAttrs (k: _: !builtins.elem k tagNames) flat;
      sortedKeys = lib.sort lib.lessThan (builtins.attrNames remaining);
      sortedVariants = lib.listToAttrs
        (map (k: { name = k; value = remaining.${k}; }) sortedKeys);
      newRow = mkTypeDefault
        { __variant = "VariantRow"; variants = sortedVariants; extension = null; }
        KRow;
    in
    mkTypeDefault { __variant = "Effect"; effectRow = newRow; } (KArrow KStar KStar);

  # ════════════════════════════════════════════════════════════════════════════
  # Constructor helpers for Effect rows
  # ════════════════════════════════════════════════════════════════════════════

  # mkEffect : AttrSet -> Type (Effect with given variant handlers)
  mkEffect = variants:
    let
      sortedKeys = lib.sort lib.lessThan (builtins.attrNames variants);
      sortedVariants = lib.listToAttrs
        (map (k: { name = k; value = variants.${k}; }) sortedKeys);
      effRow = mkTypeDefault
        { __variant = "VariantRow"; variants = sortedVariants; extension = null; }
        KRow;
    in
    mkTypeDefault { __variant = "Effect"; effectRow = effRow; } (KArrow KStar KStar);

  # mergeEffects : Type -> Type -> Type
  # Creates an EffectMerge node (normalized by ruleEffectMerge)
  mergeEffects = e1: e2:
    mkTypeDefault { __variant = "EffectMerge"; left = e1; right = e2; } (KArrow KStar KStar);

  # pureEffect : empty effect row
  pureEffect = mkEffect {};

}
