# normalize/rules.nix — Phase 4.1
# TRS 规则集（合并 Phase 1.0 ~ 4.1 所有规则）
# INV-2: 所有计算 = Rewrite(TypeIR)，可证明终止（fuel 保证）
# 注：原 rules.nix / rules_p33.nix / rules_p40.nix 已合并到此文件
{ lib, typeLib, reprLib, kindLib, substLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault;
  inherit (kindLib) KStar KArrow KRow KEffect kindInferRepr kindEq;
  inherit (reprLib)
    rLambdaK rApply rFn rConstrained rRowExtend rRecord rVariantRow
    rEffectMerge rEffect rRefined rSig
    isApply isLambda isFn isConstrained isVariantRow isRowExtend
    isRowEmpty isRecord isEffect isEffectMerge isRefined isSig;
  inherit (substLib) substitute substituteAll;

  # ── 辅助：Row spine flatten ────────────────────────────────────────────────
  # 将 RowExtend 链展开为 [(label, fieldType)] + tail
  flattenRowSpine = t:
    let v = t.repr.__variant or null; in
    if v == "RowExtend" then
      let rest = flattenRowSpine t.repr.rest; in
      { entries = [ { l = t.repr.label; ft = t.repr.fieldType; } ] ++ rest.entries;
        tail    = rest.tail; }
    else
      { entries = []; tail = t; };

  # 从排序后的 entries + tail 重建 RowExtend 链
  rebuildRowSpine = entries: tail: mkKind:
    lib.foldr
      (e: acc:
        let r = rRowExtend e.l e.ft acc; in
        mkTypeWith r mkKind typeLib.mkTypeDefault null)  # kind/meta from tail
      tail
      entries;

  # ── VariantRow flatten ────────────────────────────────────────────────────
  # 展开嵌套 VariantRow，收集所有 variant + 最终 tail
  flattenVariantRow = t:
    let v = t.repr.__variant or null; in
    if v == "VariantRow" then
      let
        ext = t.repr.extension;
        inner = if ext == null then { variants = {}; tail = null; }
                else flattenVariantRow ext;
      in
      { variants = t.repr.variants // inner.variants;
        tail     = inner.tail; }
    else
      { variants = {}; tail = t; };

  # ── EffectMerge flatten ───────────────────────────────────────────────────
  flattenEffectMerge = t:
    let v = t.repr.__variant or null; in
    if v == "EffectMerge" then
      let
        leftParts  = flattenEffectMerge t.repr.left;
        rightParts = flattenEffectMerge t.repr.right;
      in
      { labels = leftParts.labels ++ rightParts.labels;
        tail   = if leftParts.tail != null then leftParts.tail
                 else rightParts.tail; }
    else if v == "VariantRow" then
      let
        vnames = lib.sort (a: b: a < b) (builtins.attrNames (t.repr.variants or {}));
      in
      { labels = vnames;
        tail   = t.repr.extension; }
    else
      { labels = []; tail = t; };

  # ── Rule 1: β-reduction ──────────────────────────────────────────────────
  # Apply(Lambda(x, body), arg, ...) → substitute(x → arg, body) [Apply(...)]
  # INV-2: TRS 核心规则
  ruleBetaReduce = t:
    if !(isApply t.repr) then null
    else
      let fn = t.repr.fn; in
      if !(isLambda fn.repr) then null
      else
        let
          args  = t.repr.args or [];
          param = fn.repr.param;
          body  = fn.repr.body;
        in
        if args == [] then null
        else
          let
            body'    = substitute param (builtins.head args) body;
            restArgs = builtins.tail args;
          in
          if restArgs == []
          then body'
          else mkTypeWith (rApply body' restArgs) t.kind t.meta;

  # ── Rule 2: Constructor partial apply ────────────────────────────────────
  # Apply(Constructor(params, body), args) with arity check
  # INV-K1: 部分应用时 kind 不使用 KStar 兜底
  ruleConstructorPartial = t:
    if !(isApply t.repr) then null
    else
      let fn = t.repr.fn; in
      if (fn.repr.__variant or null) != "Constructor" then null
      else
        let
          params   = fn.repr.params or [];
          body     = fn.repr.body;
          args     = t.repr.args or [];
          nParams  = builtins.length params;
          nArgs    = builtins.length args;
        in
        if nArgs == 0 then null
        else if nArgs == nParams then
          # 完全应用：展开 Constructor body
          substituteAll params args body
        else if nArgs < nParams then
          # 部分应用：消耗前 nArgs 个参数，更新 params 和 kind
          let
            appliedParams  = lib.take nArgs params;
            remainParams   = lib.drop nArgs params;
            body'          = substituteAll appliedParams args body;
            resultKind     = kindInferRepr body'.repr;
            newKind = lib.foldr
              (p: acc: KArrow (p.kind or KStar) acc)
              resultKind
              (map (pname: { kind = KStar; }) remainParams);  # INV-K1 简化
            newCtor = fn.repr // { params = remainParams; body = body'; kind = newKind; };
            newCtorType = mkTypeWith newCtor newKind fn.meta;
          in mkTypeWith (rApply newCtorType []) t.kind t.meta
        else null;  # nArgs > nParams — arity error，留给 kindCheck

  # ── Rule 3: Constraint-merge ─────────────────────────────────────────────
  # Constrained(Constrained(t, c1), c2) → Constrained(t, c1 ∪ c2)
  ruleConstraintMerge = t:
    if !(isConstrained t.repr) then null
    else
      let base = t.repr.base; in
      if !(isConstrained base.repr) then null
      else
        let
          innerBase = base.repr.base;
          innerCs   = base.repr.constraints or [];
          outerCs   = t.repr.constraints or [];
        in
        mkTypeWith (rConstrained innerBase (innerCs ++ outerCs)) t.kind t.meta;

  # ── Rule 4: Constraint-float ─────────────────────────────────────────────
  # Apply(Constrained(f, cs), args) → Constrained(Apply(f, args), cs)
  ruleConstraintFloat = t:
    if !(isApply t.repr) then null
    else
      let fn = t.repr.fn; in
      if !(isConstrained fn.repr) then null
      else
        let
          innerFn = fn.repr.base;
          cs      = fn.repr.constraints or [];
          applied = mkTypeWith (rApply innerFn (t.repr.args or [])) t.kind t.meta;
        in
        mkTypeWith (rConstrained applied cs) t.kind t.meta;

  # ── Rule 5: RowExtend canonical（INV-ROW）────────────────────────────────
  # 将 RowExtend spine 按 label 字母序排序 → canonical NF
  ruleRowCanonical = t:
    if !(isRowExtend t.repr) then null
    else
      let
        spine   = flattenRowSpine t;
        entries = spine.entries;
        tail    = spine.tail;
        sorted  = lib.sort (a: b: a.l < b.l) entries;
        # 检查是否已排序
        isSorted = sorted == entries;
      in
      if isSorted then null  # 已是 canonical，无需重写
      else
        # 重建：foldr 保证 inner-most label 在最后
        let
          rebuilt = lib.foldr
            (e: acc:
              let r = rRowExtend e.l e.ft acc; in
              mkTypeWith r KRow typeLib.defaultMeta)
            tail
            sorted;
        in rebuilt;

  # ── Rule 6: Record canonical（去 null 字段）──────────────────────────────
  ruleRecordCanonical = t:
    if !(isRecord t.repr) then null
    else
      let
        fields = t.repr.fields or {};
        fnames = builtins.attrNames fields;
        # 过滤掉值为 null 的字段
        nonNull = builtins.filter (n: fields.${n} != null) fnames;
        cleaned = builtins.listToAttrs (map (n: { name = n; value = fields.${n}; }) nonNull);
        unchanged = builtins.length nonNull == builtins.length fnames;
      in
      if unchanged then null
      else mkTypeWith (rRecord cleaned) t.kind t.meta;

  # ── Rule 7: Effect canonical（VariantRow 字母序）─────────────────────────
  # INV-EFF: VariantRow variants 按 label 字母序
  ruleEffectNormalize = t:
    if !(isEffect t.repr) then null
    else
      let
        er = t.repr.effectRow;
        erv = er.repr.__variant or null;
      in
      if erv != "VariantRow" then null
      else
        let
          variants = er.repr.variants or {};
          vnames   = builtins.attrNames variants;
          sorted   = lib.sort (a: b: a < b) vnames;
          isSorted = sorted == vnames;
        in
        if isSorted then null
        else
          let
            sortedVars = builtins.listToAttrs (map (n: { name = n; value = variants.${n}; }) sorted);
            newEr = mkTypeWith (rVariantRow sortedVars er.repr.extension) er.kind er.meta;
          in mkTypeWith (rEffect newEr) t.kind t.meta;

  # ── Rule 8: VariantRow canonical（Phase 4.0）─────────────────────────────
  # INV-ROW-2: flatten nested VariantRow + sort + preserve open tail
  ruleVariantRowCanonical = t:
    if !(isVariantRow t.repr) then null
    else
      let
        flat     = flattenVariantRow t;
        allVars  = flat.variants;
        tail     = flat.tail;
        vnames   = builtins.attrNames allVars;
        sorted   = lib.sort (a: b: a < b) vnames;
        # 检查：已是 flat（extension 非 VariantRow）且 sorted
        isFlatAlready = (t.repr.extension == null)
                         || (t.repr.extension.repr.__variant or null) != "VariantRow";
        isSorted = sorted == (lib.sort (a: b: a < b) (builtins.attrNames (t.repr.variants or {})));
      in
      if isFlatAlready && isSorted then null
      else
        let
          sortedVars = builtins.listToAttrs
            (map (n: { name = n; value = allVars.${n}; }) sorted);
        in mkTypeWith (rVariantRow sortedVars tail) t.kind t.meta;

  # ── Rule 9: EffectMerge open row（Phase 4.0 INV-EFF-6）──────────────────
  # flatten + deduplicate labels + preserve RowVar tail
  ruleEffectMerge = t:
    if !(isEffectMerge t.repr) then null
    else
      let
        parts    = flattenEffectMerge t;
        labels   = parts.labels;
        tail     = parts.tail;
        # dedup（保留首次出现顺序）
        deduped  = lib.foldl'
          (acc: l: if builtins.elem l acc then acc else acc ++ [ l ])
          []
          labels;
        sorted   = lib.sort (a: b: a < b) deduped;
        # 如果 left 和 right 都已经是 VariantRow 且排好序，检查是否需要重写
        already  = (t.repr.left.repr.__variant or null) == "VariantRow"
                && (t.repr.right.repr.__variant or null) == "RowEmpty"
                || false;
      in
      if already then null
      else
        let
          # 重建成单个 VariantRow + open tail（RowVar 或 null）
          varAttrs  = builtins.listToAttrs (map (l: { name = l; value = { __variant = "EffLabel"; }; }) sorted);
          newVR = mkTypeWith (rVariantRow varAttrs tail) KEffect typeLib.defaultMeta;
        in newVR;

  # ── Rule 10: Refined base normalize（Phase 4.0）──────────────────────────
  # Refined(PTrue, ...) → base（恒真谓词消除）
  ruleRefined = t:
    if !(isRefined t.repr) then null
    else
      let pe = t.repr.predExpr; in
      let tag = pe.__predTag or pe.__variant or null; in
      if tag == "PTrue" then t.repr.base  # 恒真：精化类型退化为 base
      else if tag == "PFalse" then null   # 恒假：保留（在 solver 中报错）
      else null;  # 非平凡谓词：保留

  # ── Rule 11: Sig fields canonical（Phase 4.0 INV-MOD-4）─────────────────
  # Sig fields 按字母序排序
  ruleSig = t:
    if !(isSig t.repr) then null
    else
      let
        fields  = t.repr.fields or {};
        fnames  = builtins.attrNames fields;
        sorted  = lib.sort (a: b: a < b) fnames;
        isSorted = sorted == fnames;
      in
      if isSorted then null
      else
        let
          sortedFields = builtins.listToAttrs
            (map (n: { name = n; value = fields.${n}; }) sorted);
        in mkTypeWith (rSig sortedFields) t.kind t.meta;

  # ── 规则优先级表（决定 confluence）───────────────────────────────────────
  # 规则按优先级顺序排列，第一个成功的规则被应用
  allRules = [
    ruleBetaReduce         # P1: β-reduction（计算核心，最高优先级）
    ruleConstructorPartial # P2: Constructor 展开/部分应用
    ruleConstraintMerge    # P3: Constraint 嵌套合并
    ruleConstraintFloat    # P4: Constraint 上浮
    ruleRowCanonical       # P5: Row 字母序规范化
    ruleVariantRowCanonical# P6: VariantRow 规范化（P4.0）
    ruleEffectMerge        # P7: EffectMerge open row（P4.0）
    ruleRefined            # P8: Refined PTrue 消除（P4.0）
    ruleSig                # P9: Sig fields 排序（P4.0）
    ruleRecordCanonical    # P10: Record null 清理
    ruleEffectNormalize    # P11: Effect VariantRow 排序
  ];

  # Type: Type -> Maybe Type（null = 无规则可用，当前 t 是 NF）
  applyOneRule = t:
    let
      results = map (rule: rule t) allRules;
      firstSuccess = lib.findFirst (r: r != null) null results;
    in firstSuccess;

  # shallow NF 检查（用于 normalize 引擎）
  isNFShallow = t:
    let v = t.repr.__variant or null; in
    !(v == "Apply" && (
      (t.repr.fn.repr.__variant or null) == "Lambda" ||
      (t.repr.fn.repr.__variant or null) == "Constructor"
    )) &&
    !(isConstrained t.repr &&
      (t.repr.base.repr.__variant or null) == "Constrained");

in {
  inherit applyOneRule isNFShallow allRules
          ruleBetaReduce ruleConstructorPartial
          ruleConstraintMerge ruleConstraintFloat
          ruleRowCanonical ruleVariantRowCanonical
          ruleEffectMerge ruleRefined ruleSig
          ruleRecordCanonical ruleEffectNormalize;
}
