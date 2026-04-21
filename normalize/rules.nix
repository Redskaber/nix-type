# normalize/rules.nix — Phase 3.2
# TRS 规则集（完整 Row canonical + Effect normalize 委托）
#
# Phase 3.2 新增：
#   P3.2-5: ruleRowCanonical 完整 RowExtend spine sort（label 字母序）
#   P3.2-6: ruleEffectNormalize 委托 row form（Effect = VariantRow）
#   ruleRecordCanonical：Record 字段键排序（序列化层已保证，此处 repr 层同步）
#
# Phase 3.1 继承：
#   三路 fuel：betaFuel / depthFuel / muFuel（INV-NF）
#   Constructor-partial kind：真实 param.kind（INV-K1）
#   Pi-reduction 完整
#
# 规则应用策略：innermost-leftmost（INV-NF2 幂等性依赖）
{ lib, typeLib, reprLib, substLib, kindLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith withRepr;
  inherit (kindLib) KStar KUnbound KArrow kindInferRepr;
  inherit (reprLib) rPrimitive rVar rLambda rApply rFn rADT rConstrained
                   rRowEmpty rRowExtend;
  inherit (substLib) substitute substituteAll;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 三路 fuel 结构（INV-NF）
  # ══════════════════════════════════════════════════════════════════════════════

  mkFuel = beta: depth: mu:
    { inherit beta depth mu; };

  defaultFuel = mkFuel 128 256 32;
  minimalFuel = mkFuel 8   16  4;
  deepFuel    = mkFuel 256 512 64;

  hasBeta  = fuel: (fuel.beta  or 0) > 0;
  hasDepth = fuel: (fuel.depth or 0) > 0;
  hasMu    = fuel: (fuel.mu    or 0) > 0;

  consumeBeta  = fuel: fuel // { beta  = (fuel.beta  or 0) - 1; };
  consumeDepth = fuel: fuel // { depth = (fuel.depth or 0) - 1; };
  consumeMu    = fuel: fuel // { mu    = (fuel.mu    or 0) - 1; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则链（innermost-leftmost 顺序应用）
  # ══════════════════════════════════════════════════════════════════════════════

  # 所有规则按优先级排列：
  # β/Pi/Constrained-float 优先（语义等价规则）
  # Row canonical 次之（规范化规则）
  # Mu unfold 最后（展开规则，需 muFuel）
  allRules = [
    ruleBetaReduce        # Apply(Lambda(p,b), arg) → b[p↦arg]
    rulePiReduce          # Apply(Pi(p,A,B), arg) → B[p↦arg]
    ruleConstructorFull   # Apply(Constructor(n,k,ps,b), args) → b[ps↦args]
    ruleConstructorPartial # Constructor partial application kind fix
    ruleConstrainedFloat  # Apply(Constrained(f,cs), arg) → Constrained(Apply(f,arg), cs)
    ruleRowCanonical      # RowExtend chain → sorted by label（Phase 3.2 完整）
    ruleRecordCanonical   # Record field sort（冗余，序列化已保证，此处 repr 对齐）
    ruleEffectNormalize   # Effect row canonicalization（Phase 3.2）
    ruleMuUnfold          # μ(α).T → T[α↦μ(α).T]（muFuel）
    ruleFnDesugar         # Fn → Lambda（默认关闭）
  ];

  # 依次尝试所有规则，返回第一个成功的结果
  # Type: Fuel -> Type -> { changed: Bool; type: Type }
  applyRules = fuel: t:
    let
      go = rules:
        if rules == [] then { changed = false; type = t; }
        else
          let
            rule = builtins.head rules;
            rest = builtins.tail rules;
            r    = rule fuel t;
          in
          if r.changed then r
          else go rest;
    in
    go allRules;

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE β-reduction（Apply(Lambda(p,b), arg) → b[p↦arg]）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleBetaReduce = fuel: t:
    if !hasBeta fuel then { changed = false; type = t; }
    else
      let repr = t.repr; in
      if repr.__variant or null != "Apply" then { changed = false; type = t; }
      else
        let
          fn   = repr.fn or null;
          args = repr.args or [];
        in
        if fn == null || args == [] then { changed = false; type = t; }
        else
          let fnRepr = fn.repr or {}; in
          if fnRepr.__variant or null != "Lambda" then { changed = false; type = t; }
          else
            let
              param = fnRepr.param or "_";
              body  = fnRepr.body or fn;
              arg   = builtins.head args;
              rest  = builtins.tail args;
              reduced = substitute param arg body;
            in
            # 若还有剩余 args，构造 Apply(reduced, rest)
            if rest == []
            then { changed = true; type = reduced; }
            else { changed = true;
                   type = withRepr t (repr // { fn = reduced; args = rest; }); };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Pi-reduction（Apply(Pi(p,A,B), arg) → B[p↦arg]）
  # ══════════════════════════════════════════════════════════════════════════════

  rulePiReduce = fuel: t:
    if !hasBeta fuel then { changed = false; type = t; }
    else
      let repr = t.repr; in
      if repr.__variant or null != "Apply" then { changed = false; type = t; }
      else
        let fn = repr.fn or null; in
        if fn == null then { changed = false; type = t; }
        else
          let fnRepr = fn.repr or {}; in
          if fnRepr.__variant or null != "Pi" then { changed = false; type = t; }
          else
            let
              param = fnRepr.param or "_";
              body  = fnRepr.body or fn;
              arg   = builtins.head (repr.args or []);
              rest  = builtins.tail (repr.args or []);
              reduced = substitute param arg body;
            in
            if rest == []
            then { changed = true; type = reduced; }
            else { changed = true;
                   type = withRepr t (repr // { fn = reduced; args = rest; }); };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Constructor-full application（INV-K1）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleConstructorFull = fuel: t:
    if !hasBeta fuel then { changed = false; type = t; }
    else
      let repr = t.repr; in
      if repr.__variant or null != "Apply" then { changed = false; type = t; }
      else
        let fn = repr.fn or null; in
        if fn == null then { changed = false; type = t; }
        else
          let fnRepr = fn.repr or {}; in
          if fnRepr.__variant or null != "Constructor" then { changed = false; type = t; }
          else
            let
              params = fnRepr.params or [];
              args   = repr.args or [];
              body   = fnRepr.body or null;
            in
            if body == null then { changed = false; type = t; }
            else if builtins.length args < builtins.length params
            then { changed = false; type = t; }  # partial application: handled by ruleConstructorPartial
            else if builtins.length args == builtins.length params
            then
              # full application: substitute all params
              let
                subst = lib.listToAttrs
                  (lib.imap0 (i: p: { name = p.name or "_"; value = builtins.elemAt args i; })
                   params);
                reduced = substituteAll subst body;
              in
              { changed = true; type = reduced; }
            else
              # over-application: apply params, return Apply of result
              let
                appliedArgs = lib.take (builtins.length params) args;
                extraArgs   = lib.drop (builtins.length params) args;
                subst = lib.listToAttrs
                  (lib.imap0 (i: p: { name = p.name or "_"; value = builtins.elemAt appliedArgs i; })
                   params);
                reduced = substituteAll subst body;
              in
              { changed = true;
                type = withRepr t (repr // { fn = reduced; args = extraArgs; }); };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Constructor-partial（INV-K1：正确 kind 推断）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleConstructorPartial = fuel: t:
    if !hasBeta fuel then { changed = false; type = t; }
    else
      let repr = t.repr; in
      if repr.__variant or null != "Apply" then { changed = false; type = t; }
      else
        let fn = repr.fn or null; in
        if fn == null then { changed = false; type = t; }
        else
          let fnRepr = fn.repr or {}; in
          if fnRepr.__variant or null != "Constructor" then { changed = false; type = t; }
          else
            let
              params = fnRepr.params or [];
              args   = repr.args or [];
              body   = fnRepr.body or null;
            in
            if body == null || builtins.length args >= builtins.length params
            then { changed = false; type = t; }
            else
              let
                appliedN    = builtins.length args;
                remainParams = lib.drop appliedN params;
                # INV-K1 修复：使用 param 的真实 kind（不假设 KStar）
                # kind of partial application = KArrow(remaining param kinds..., resultKind)
                resultKind = kindInferRepr (fnRepr.body or fn).repr;
                newKind = lib.foldr
                  (p: acc: KArrow (p.kind or KStar) acc)
                  resultKind
                  remainParams;
                newFn = fn // { kind = newKind; };
              in
              { changed = true;
                type = withRepr t (repr // { fn = newFn; }); };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Constrained float
  # ══════════════════════════════════════════════════════════════════════════════

  ruleConstrainedFloat = fuel: t:
    let repr = t.repr; in
    if repr.__variant or null != "Apply" then { changed = false; type = t; }
    else
      let fn = repr.fn or null; in
      if fn == null then { changed = false; type = t; }
      else
        let fnRepr = fn.repr or {}; in
        if fnRepr.__variant or null != "Constrained" then { changed = false; type = t; }
        else
          let
            inner = fnRepr.base or fn;
            cs    = fnRepr.constraints or [];
            newApply = withRepr t (repr // { fn = inner; });
            floated  = withRepr t {
              __variant   = "Constrained";
              base        = newApply;
              constraints = cs;
            };
          in
          { changed = true; type = floated; };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Row canonical（Phase 3.2：完整 RowExtend spine sort）
  #
  # 语义：RowExtend 链代表行类型 { l₁: T₁ | { l₂: T₂ | ... | tail } }
  # 规范形式：按 label 字母序排列，使不同顺序的 row 有相同 normal form
  #
  # 算法：
  #   1. 展开 RowExtend 链，收集 (label, fieldType) 对 + tail
  #   2. 按 label 字母序排序
  #   3. 重建 RowExtend 链（最右 = tail）
  #   4. 若顺序已是规范 → no change
  # ══════════════════════════════════════════════════════════════════════════════

  ruleRowCanonical = fuel: t:
    let repr = t.repr; in
    if repr.__variant or null != "RowExtend" then { changed = false; type = t; }
    else
      let
        # 展开 RowExtend 链
        # 返回 { fields: [{label; fieldType}]; tail: Type | null }
        unspine = ty:
          let r = ty.repr; in
          if r.__variant or null != "RowExtend"
          then { fields = []; tail = ty; }
          else
            let
              inner = unspine (r.rest or ty);
            in
            { fields = [ { label = r.label or ""; fieldType = r.fieldType or ty; } ]
                       ++ inner.fields;
              tail   = inner.tail; };

        spined = unspine t;
        fields = spined.fields;
        tail   = spined.tail;

        # 检查是否已按字母序排列
        labels = map (f: f.label) fields;
        sortedLabels = lib.sort lib.lessThan labels;
        alreadySorted = labels == sortedLabels;
      in
      if alreadySorted
      then { changed = false; type = t; }
      else
        let
          # 按 label 排序 fields
          sortedFields = lib.sort (a: b: a.label < b.label) fields;

          # 重建 RowExtend 链（右折叠）
          rebuilt = lib.foldr
            (f: acc:
              mkTypeDefault
                { __variant  = "RowExtend";
                  label      = f.label;
                  fieldType  = f.fieldType;
                  rest       = acc; }
                t.kind)
            (if tail != null then tail
             else mkTypeDefault { __variant = "RowEmpty"; } t.kind)
            sortedFields;
        in
        { changed = true; type = rebuilt; };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Record canonical（字段 repr 层排序，与序列化层对齐）
  #
  # Nix AttrSet 本身无顺序，serialize 已保证字母序；
  # 此规则确保 repr 层的 Record 在 normalize 流水线中有明确顺序语义
  # Phase 3.2：确保 fields 不含 null 值（defensive clean）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleRecordCanonical = fuel: t:
    let repr = t.repr; in
    if repr.__variant or null != "Record" then { changed = false; type = t; }
    else
      let
        fields = repr.fields or {};
        # 过滤 null field（防御性：不应存在，但保留语义健壮性）
        cleanFields = lib.filterAttrs (_: v: v != null) fields;
        changed = builtins.attrNames cleanFields != builtins.attrNames fields;
      in
      if !changed
      then { changed = false; type = t; }
      else { changed = true; type = withRepr t (repr // { fields = cleanFields; }); };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Effect normalize（Phase 3.2：委托 row canonical）
  #
  # 语义：Effect = EffectTag + EffectRow
  # EffectRow 本质是 VariantRow（effect handler 的 variant 集合）
  # 规范化：effectRow 内部的 VariantRow 按名字字母序排列
  # ══════════════════════════════════════════════════════════════════════════════

  ruleEffectNormalize = fuel: t:
    let repr = t.repr; in
    if repr.__variant or null != "Effect" then { changed = false; type = t; }
    else
      let
        effectRow = repr.effectRow or null;
      in
      if effectRow == null then { changed = false; type = t; }
      else
        let
          erRepr = effectRow.repr or {};
          erVariant = erRepr.__variant or null;
        in
        if erVariant != "VariantRow" then { changed = false; type = t; }
        else
          let
            variants = erRepr.variants or {};
            keys     = builtins.attrNames variants;
            sortedKeys = lib.sort lib.lessThan keys;
            alreadySorted = keys == sortedKeys;
          in
          if alreadySorted
          then { changed = false; type = t; }
          else
            # 重建 VariantRow 保证 key 顺序（Nix attrSet 本身无序，序列化层处理）
            # 此规则标记 changed=true 触发 hash 重算
            let
              sortedVariants = lib.listToAttrs
                (map (k: { name = k; value = variants.${k}; }) sortedKeys);
              newEffectRow = withRepr effectRow
                (erRepr // { variants = sortedVariants; });
            in
            { changed = true;
              type = withRepr t (repr // { effectRow = newEffectRow; }); };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Fn-desugar（Phase 3.2：仍默认关闭，bidir check 依赖 Fn repr）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleFnDesugar = fuel: t:
    { changed = false; type = t; };

  # ══════════════════════════════════════════════════════════════════════════════
  # RULE Mu-unfold（equi-recursive，muFuel 独立计数）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleMuUnfold = fuel: t:
    if !hasMu fuel then { changed = false; type = t; }
    else
      let
        repr = t.repr;
        var  = repr.var or "_";
        body = repr.body or null;
      in
      if repr.__variant or null != "Mu" || body == null
      then { changed = false; type = t; }
      else
        let
          fuel'    = consumeMu fuel;
          unfolded = substitute var t body;
        in
        { changed = true; type = unfolded; };

  # ══════════════════════════════════════════════════════════════════════════════
  # NF 检查（参数化，INV-NF2）
  # ══════════════════════════════════════════════════════════════════════════════

  isNF = t:
    let r = applyRules defaultFuel t; in
    !r.changed;

}
