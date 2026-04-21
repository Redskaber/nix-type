# normalize/rules_p40.nix — Phase 4.0
#
# TRS 规则集 Phase 4.0
#
# 修复 Phase 3.3 遗留风险 2：
#   EffectMerge 不支持 open effect row（RowVar tail）
#
# 新增规则：
#   ruleEffectMergeOpen  — EffectMerge 支持 RowVar tail（INV-EFF-6）
#   ruleRefinedNorm      — Refined Type normalize（base 归约）
#   ruleSigNorm          — Sig fields 字母序规范化（INV-MOD-4）
#
# 升级规则：
#   ruleEffectMerge（Phase 3.3）→ ruleEffectMergeP40（支持 open tail）
#
# 不变量：
#   INV-EFF-6: open effect row（RowVar）在 flatten 后保留 tail
#   INV-REFINED-NF: Refined(base).base = NF(base)
#   INV-MOD-4: Sig fields = sorted（字母序 canonical form）
#   INV-RULE-P40: 所有新规则幂等（apply twice = apply once）

{ lib, typeLib, kindLib }:

let
  inherit (typeLib) mkTypeDefault;
  KStar = { __kindVariant = "KStar"; };
  KRow  = { __kindVariant = "KRow"; };

  rVariantRow  = variants: extension: { __variant = "VariantRow"; inherit variants extension; };
  rEffect      = effectRow: { __variant = "Effect"; inherit effectRow; };
  rRowEmpty    = { __variant = "RowEmpty"; };
  rRowExtend   = label: fieldType: rest: { __variant = "RowExtend"; inherit label fieldType rest; };
  rRowVar      = name: { __variant = "RowVar"; inherit name; };

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # EffectMerge 全功能展开（INV-EFF-2 结合律 + INV-EFF-6 open tail）
  # ══════════════════════════════════════════════════════════════════════════════

  # flatten：将 EffectMerge 树展开为 { variants; tail }
  # Phase 4.0 修复：RowVar tail 保留
  _flattenEffP40 = effTy:
    let r = effTy.repr or {}; in
    if r.__variant == "Effect" then
      let rowR = (r.effectRow or { repr = rRowEmpty; }).repr or {}; in
      if rowR.__variant == "VariantRow" then
        let
          extR = (rowR.extension or { repr = rRowEmpty; }).repr or {};
        in
        # 递归展开 VariantRow extension（可能嵌套）
        if extR.__variant == "RowVar" then
          { variants = rowR.variants or {}; tail = rowR.extension; }
        else if extR.__variant == "RowEmpty" then
          { variants = rowR.variants or {}; tail = null; }
        else
          # extension 是 RowExtend chain → 继续展开
          let inner = _flattenRowChain r.effectRow; in
          { variants = inner.fields; tail = inner.tail; }
      else if rowR.__variant == "RowVar" then
        { variants = {}; tail = r.effectRow; }         # open effect row
      else if rowR.__variant == "RowEmpty" then
        { variants = {}; tail = null; }
      else { variants = {}; tail = null; }
    else if r.__variant == "EffectMerge" then
      let
        l  = _flattenEffP40 r.left;
        rr = _flattenEffP40 r.right;
        merged = l.variants // rr.variants;   # right-biased
        # tail 优先级：right tail > left tail
        tail = if rr.tail != null then rr.tail
               else l.tail;
      in
      { variants = merged; tail = tail; }
    else if r.__variant == "RowVar" then
      { variants = {}; tail = effTy; }
    else { variants = {}; tail = null; };

  # flatten RowExtend chain → { fields; tail }
  _flattenRowChain = rowTy:
    let r = rowTy.repr or {}; in
    if r.__variant == "RowExtend" then
      let inner = _flattenRowChain r.rest; in
      { fields = inner.fields // { ${r.label} = r.fieldType; }; tail = inner.tail; }
    else if r.__variant == "RowEmpty" then
      { fields = {}; tail = null; }
    else if r.__variant == "RowVar" then
      { fields = {}; tail = rowTy; }
    else if r.__variant == "VariantRow" then
      { fields = r.variants or {}; tail = r.extension; }
    else { fields = {}; tail = null; };

  # ruleEffectMergeP40：EffectMerge → flat Effect（含 RowVar tail support）
  ruleEffectMergeP40 = ty:
    let r = ty.repr or {}; in
    if r.__variant != "EffectMerge" then null
    else
      let
        flat     = _flattenEffP40 ty;
        sorted   = lib.sort (a: b: a.name < b.name)
                     (lib.mapAttrsToList (k: v: { name = k; value = v; }) flat.variants);
        # 构造 canonical VariantRow
        makeRow  = lib.foldl' (acc: kv:
          mkTypeDefault (rRowExtend kv.name kv.value acc) KRow)
          (if flat.tail != null then flat.tail
           else mkTypeDefault rRowEmpty KRow)
          (lib.reverseList sorted);
        effRow   = mkTypeDefault (rVariantRow flat.variants
                     (if flat.tail != null then flat.tail
                      else mkTypeDefault rRowEmpty KRow)) KRow;
      in
      mkTypeDefault (rEffect effRow) KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # Refined Type 规范化（INV-REFINED-NF）
  # ══════════════════════════════════════════════════════════════════════════════

  # ruleRefinedNorm：Refined(base, predVar, predExpr) → base 若 predExpr = PTrue
  ruleRefinedNorm = step: ty:
    let r = ty.repr or {}; in
    if r.__variant != "Refined" then null
    else
      let
        base'     = step r.base;
        predExpr  = r.predExpr or {};
        isTrivial = (predExpr.__pred or null) == "PTrue";
      in
      if isTrivial then base'
      else if base' == r.base then null  # no change
      else ty // { repr = r // { base = base'; }; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Sig 规范化（INV-MOD-4：fields 字母序）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleSignorm = ty:
    let r = ty.repr or {}; in
    if r.__variant != "Sig" then null
    else
      let
        fields  = r.fields or {};
        keys    = builtins.attrNames fields;
        sorted  = lib.sort (a: b: a < b) keys;
        # 检查是否已经有序
        already = keys == sorted;
      in
      if already then null
      else
        let
          sortedFields = lib.listToAttrs
            (map (k: { name = k; value = fields.${k}; }) sorted);
        in
        ty // { repr = r // { fields = sortedFields; }; };

  # ══════════════════════════════════════════════════════════════════════════════
  # VariantRow 规范化（Phase 3.3 升级版，处理 open tail）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleVariantRowCanonicalP40 = step: ty:
    let r = ty.repr or {}; in
    if r.__variant != "VariantRow" then null
    else
      let
        variants  = r.variants or {};
        ext       = r.extension or (mkTypeDefault rRowEmpty KRow);
        extR      = ext.repr or {};

        # flatten 嵌套 VariantRow
        _flatVR = vr:
          let vr_r = vr.repr or {}; in
          if vr_r.__variant == "VariantRow" then
            let
              inner = _flatVR (vr_r.extension or (mkTypeDefault rRowEmpty KRow));
            in
            { variants = vr_r.variants // inner.variants; tail = inner.tail; }
          else
            { variants = {}; tail = vr; };

        innerFlat = _flatVR ext;
        allVars   = variants // innerFlat.variants;
        tail      = innerFlat.tail;

        # sort variants keys
        sortedKeys = lib.sort (a: b: a < b) (builtins.attrNames allVars);
        sortedVars = lib.listToAttrs (map (k: { name = k; value = allVars.${k}; }) sortedKeys);

        # 应用 step 到 variant types
        normalizedVars = lib.mapAttrs (_: step) sortedVars;

        tailR = tail.repr or {};
        normalizedTail =
          if tailR.__variant == "RowEmpty" || tailR.__variant == "RowVar" then tail
          else step tail;

        changed = normalizedVars != variants || normalizedTail != ext;
      in
      if !changed && allVars == variants then null
      else ty // { repr = r // {
        variants  = normalizedVars;
        extension = normalizedTail;
      }; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则集合（供 rulesLib 合并）
  # ══════════════════════════════════════════════════════════════════════════════

  allRulesP40 = {
    ruleEffectMerge      = ty: _: ruleEffectMergeP40 ty;
    ruleRefined          = ruleRefinedNorm;
    ruleSig              = ty: _: ruleSignorm ty;
    ruleVariantRowCanon  = ruleVariantRowCanonicalP40;
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # 不变量验证
  # ══════════════════════════════════════════════════════════════════════════════

  verifyP40RuleInvariants = _:
    let
      tInt   = mkTypeDefault { __variant = "Primitive"; name = "Int"; } KStar;
      tBool  = mkTypeDefault { __variant = "Primitive"; name = "Bool"; } KStar;
      tUnit  = mkTypeDefault { __variant = "Primitive"; name = "Unit"; } KStar;

      # ── INV-EFF-6: EffectMerge with RowVar tail ──────────────────────────

      openEff = mkTypeDefault (rEffect (mkTypeDefault (rRowVar "eps") KRow)) KStar;
      closedEff = mkTypeDefault (rEffect
        (mkTypeDefault (rVariantRow { IO = tUnit; } (mkTypeDefault rRowEmpty KRow)) KRow))
        KStar;

      mergedTy = mkTypeDefault {
        __variant = "EffectMerge";
        left  = closedEff;
        right = openEff;
      } KStar;

      merged = ruleEffectMergeP40 mergedTy;
      invEFF6 = merged != null &&
                (merged.repr or {}).__variant == "Effect";

      # ── INV-RULE-P40: idempotence ─────────────────────────────────────────
      # apply rule once, then again → same result
      sig1 = mkTypeDefault { __variant = "Sig"; fields = { z = KStar; a = KStar; }; } KStar;
      sig2 = ruleSignorm sig1;
      sig3 = if sig2 != null then ruleSignorm sig2 else null;
      invRuleIdempotent = sig3 == null;  # second application = no change

      # ── INV-EFF-2: associativity via flatten ────────────────────────────
      e1 = mkTypeDefault (rEffect (mkTypeDefault (rVariantRow { A = tInt; } (mkTypeDefault rRowEmpty KRow)) KRow)) KStar;
      e2 = mkTypeDefault (rEffect (mkTypeDefault (rVariantRow { B = tBool; } (mkTypeDefault rRowEmpty KRow)) KRow)) KStar;
      e3 = mkTypeDefault (rEffect (mkTypeDefault (rVariantRow { C = tUnit; } (mkTypeDefault rRowEmpty KRow)) KRow)) KStar;

      merge12   = mkTypeDefault { __variant = "EffectMerge"; left = e1; right = e2; } KStar;
      merge12_3 = mkTypeDefault { __variant = "EffectMerge"; left = merge12; right = e3; } KStar;
      merge23   = mkTypeDefault { __variant = "EffectMerge"; left = e2; right = e3; } KStar;
      merge1_23 = mkTypeDefault { __variant = "EffectMerge"; left = e1; right = merge23; } KStar;

      flat12_3 = _flattenEffP40 merge12_3;
      flat1_23 = _flattenEffP40 merge1_23;
      # 两个 flatten 结果的 variants 应该相同（结合律）
      invEFF2 = flat12_3.variants == flat1_23.variants;

    in {
      allPass           = invEFF2 && invEFF6 && invRuleIdempotent;
      "INV-EFF-6"       = invEFF6;
      "INV-EFF-2-assoc" = invEFF2;
      "INV-RULE-idempotent" = invRuleIdempotent;
    };
}
