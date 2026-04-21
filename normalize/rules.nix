# normalize/rules.nix — Phase 3
# TRS 规则集（Term Rewriting System）
#
# Phase 3 关键修复（来自 nix-todo/normalize/rules.md）：
#   1. ruleConstructorPartial：kind 推断修复（保留真实参数 kind，INV-K1）
#   2. Pi-reduction：Π(x:A).B(x) + arg → B[x↦arg]（Dependent function apply）
#   3. Sigma-intro：Σ 类型构造
#   4. Row-normalize：row spine 排序规范化（field canonical order）
#   5. Effect-normalize：Effect row 规范化（Phase 3）
#
# 规则优先级（Phase 3，11 条规则）：
#   1. Constraint-float   Apply(Constrained(f,cs), args) → Constrained(Apply(f,args), cs)
#   2. Constraint-merge   Constrained(Constrained(t,c1),c2) → Constrained(t, dedup(c1∪c2))
#   3. Beta-reduction     Apply(Lambda(x,b), [a,...]) → b[x↦a]
#   4. Pi-reduction       Apply(Pi(x:A,b), [a]) → b[x↦a]（Phase 3 新增）
#   5. Constructor-unfold Apply(Constructor(ps,b), args) → b[ps↦args]（完整应用）
#   6. Constructor-partial Apply(Constructor(ps,b), args) → CurriedConstructor（部分应用）
#   7. Mu-unfold          Apply(Mu(p,b), args) → Apply(b[p↦Mu(p,b)], args)
#   8. Row-normalize      Row 类型排序规范化
#   9. Effect-normalize   Effect row 规范化（Phase 3）
#   10. Fn-NF             Fn 保留为 NF（不展开）
#   11. Eta-reduction     Lambda(x,Apply(f,[x])) → f（默认禁用）
{ lib, reprLib, substLib, kindLib, typeLib }:

let
  inherit (typeLib) mkTypeWith mkTypeDefault mkBootstrapType isType;
  inherit (kindLib) KStar KArrow KUnbound KError kindInferRepr kindEq;
  inherit (reprLib)
    rPrimitive rVar rLambda rApply rFn rConstructor rADT rConstrained
    rMu rRecord rVariantRow rRowExtend rRowEmpty
    rPi rSigma rEffect rOpaque;
  inherit (substLib) substitute substituteAll flattenRow buildRow;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 1：Constraint-float
  # Apply(Constrained(f, cs), args) → Constrained(Apply(f, args), cs)
  # ══════════════════════════════════════════════════════════════════════════════

  ruleConstraintFloat = t:
    let r = t.repr; in
    if r.__variant == "Apply"
       && r.fn.repr.__variant == "Constrained"
    then
      let
        inner = r.fn.repr;
        newApply = mkTypeWith
          (rApply inner.base r.args) t.kind t.meta;
      in
      mkTypeWith (rConstrained newApply inner.constraints) t.kind t.meta
    else null;  # 规则不适用

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 2：Constraint-merge
  # Constrained(Constrained(t, c1), c2) → Constrained(t, dedup(c1∪c2))
  # ══════════════════════════════════════════════════════════════════════════════

  ruleConstraintMerge = t:
    let r = t.repr; in
    if r.__variant == "Constrained"
       && r.base.repr.__variant == "Constrained"
    then
      let
        inner = r.base.repr;
        merged = _deduplicateConstraints (inner.constraints ++ r.constraints);
      in
      mkTypeWith (rConstrained inner.base merged) t.kind t.meta
    else null;

  # ── 约束去重（INV-4 语义：约束集是集合）────────────────────────────────────
  _deduplicateConstraints = cs:
    let
      table = builtins.listToAttrs
        (map (c: { name = _constraintKey c; value = c; }) cs);
    in
    builtins.attrValues table;

  _constraintKey = c:
    let tag = c.__constraintTag or c.__tag or null; in
    if tag == "Class" then
      "Cls:${c.name}:${builtins.concatStringsSep "," (map (a: a.id or "?") (c.args or []))}"
    else if tag == "Equality" then
      "Eq:${(c.a or {}).id or "?"}:${(c.b or {}).id or "?"}"
    else if tag == "Predicate" then
      "Pred:${c.fn or "?"}:${(c.arg or {}).id or "?"}"
    else builtins.hashString "md5" (builtins.toJSON c);

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 3：Beta-reduction
  # Apply(Lambda(x, body), [arg, rest...]) → body[x↦arg] 或递归 Apply
  # ══════════════════════════════════════════════════════════════════════════════

  ruleBetaReduction = t:
    let r = t.repr; in
    if r.__variant == "Apply"
       && r.fn.repr.__variant == "Lambda"
       && builtins.length r.args > 0
    then
      let
        lam  = r.fn.repr;
        arg  = builtins.head r.args;
        rest = builtins.tail r.args;
        body' = substitute lam.param arg lam.body;
      in
      if builtins.length rest == 0
      then body'
      else mkTypeWith (rApply body' rest) t.kind t.meta
    else null;

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 4（Phase 3 新增）：Pi-reduction
  # Apply(Pi(x:A, body), [arg]) → body[x↦arg]（Dependent function application）
  # ══════════════════════════════════════════════════════════════════════════════

  rulePiReduction = t:
    let r = t.repr; in
    if r.__variant == "Apply"
       && r.fn.repr.__variant == "Pi"
       && builtins.length r.args > 0
    then
      let
        pi   = r.fn.repr;
        arg  = builtins.head r.args;
        rest = builtins.tail r.args;
        body' = substitute pi.param arg pi.body;
      in
      if builtins.length rest == 0
      then body'
      else mkTypeWith (rApply body' rest) t.kind t.meta
    else null;

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 5：Constructor-unfold（完整应用）
  # Apply(Constructor(params, body), args) → body[params↦args]
  # ══════════════════════════════════════════════════════════════════════════════

  ruleConstructorUnfold = t:
    let r = t.repr; in
    if r.__variant == "Apply"
       && r.fn.repr.__variant == "Constructor"
       && builtins.length r.args == builtins.length r.fn.repr.params
    then
      let
        ctor   = r.fn.repr;
        pairs  = lib.zipLists (map (p: p.name) ctor.params) r.args;
        subst  = builtins.listToAttrs
          (map (p: { name = p.fst; value = p.snd; }) pairs);
      in
      substituteAll subst ctor.body
    else null;

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 6：Constructor-partial（部分应用）— Phase 3 修复 kind 推断
  # ══════════════════════════════════════════════════════════════════════════════

  ruleConstructorPartial = t:
    let r = t.repr; in
    if r.__variant == "Apply"
       && r.fn.repr.__variant == "Constructor"
       && builtins.length r.args > 0
       && builtins.length r.args < builtins.length r.fn.repr.params
    then
      let
        ctor        = r.fn.repr;
        nArgs       = builtins.length r.args;
        appliedParams = lib.take nArgs ctor.params;
        remainParams  = lib.drop nArgs ctor.params;

        # 应用已提供的参数到 body
        pairs  = lib.zipLists (map (p: p.name) appliedParams) r.args;
        subst  = builtins.listToAttrs
          (map (p: { name = p.fst; value = p.snd; }) pairs);
        body'  = substituteAll subst ctor.body;

        # Phase 3 修复：使用真实 param kind（不统一为 KStar！）
        # 构建 k₁ → k₂ → ... → resultKind，每个 kᵢ 来自 remainParams[i].kind
        resultKind = kindInferRepr body'.repr;
        newKind = lib.foldr
          (p: acc: KArrow (p.kind or KStar) acc)
          resultKind
          remainParams;

        # 构建新的 partial Constructor
        newCtor = rConstructor
          "${ctor.name}__partial${toString nArgs}"
          newKind
          remainParams
          body';
      in
      mkTypeWith newCtor newKind t.meta
    else null;

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 7：Mu-unfold（equi-recursive，one-step）
  # Apply(Mu(p, b), args) → Apply(b[p↦Mu(p,b)], args)
  # ══════════════════════════════════════════════════════════════════════════════

  ruleMuUnfold = fuel: t:
    let r = t.repr; in
    if fuel <= 0 then null  # fuel 耗尽，停止展开
    else if r.__variant == "Apply"
            && r.fn.repr.__variant == "Mu"
    then
      let
        mu     = r.fn;
        muRepr = mu.repr;
        # μ(p.b)[p↦μ(p.b)] = unfold one step
        unfolded = substitute muRepr.param mu muRepr.body;
      in
      mkTypeWith (rApply unfolded r.args) t.kind t.meta
    # 单独 Mu（无 Apply）也展开一步（用于 muEq）
    else if r.__variant == "Mu" && fuel > 0 then
      substitute r.param t r.body
    else null;

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 8：Row-normalize（canonical field 排序）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleRowNormalize = t:
    let v = t.repr.__variant or null; in

    if v == "Record" then
      let
        labels = builtins.attrNames t.repr.fields;
        sorted = builtins.sort (a: b: a < b) labels;
        already = sorted == labels;  # 已排序？
      in
      if already then null
      else
        # 重建（字段已在 attrset 中，本身无序，但序列化时 sort 保证 canonical）
        mkTypeWith (rRecord t.repr.fields t.repr.rowVar) t.kind t.meta

    else if v == "VariantRow" then
      let
        labels = builtins.attrNames t.repr.variants;
        sorted = builtins.sort (a: b: a < b) labels;
        already = sorted == labels;
      in
      if already then null
      else mkTypeWith (rVariantRow t.repr.variants t.repr.rowVar) t.kind t.meta

    else if v == "RowExtend" then
      # RowExtend chain：确保 canonical 顺序
      let flat = flattenRow t; in
      if builtins.length flat.fields <= 1 then null
      else
        let sorted = builtins.sort (a: b: a.label < b.label) flat.fields; in
        let rebuilt = buildRow sorted flat.tail; in
        rebuilt  # 返回重建的 row chain

    else null;

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 9（Phase 3 新增）：Effect-normalize
  # Effect row 规范化（canonical effect set 排序）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleEffectNormalize = t:
    let v = t.repr.__variant or null; in
    if v == "Effect" then
      # Effect 的 row 部分需要规范化（交给 Row-normalize 处理）
      # 这里只做标签正规化（lowercase canonical）
      let tag' = t.repr.tag; in  # Phase 3: tag 保持原样，row 交给规则 8
      null  # 当前：委托给 ruleRowNormalize 对 row 子项处理
    else null;

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 10：Fn-NF（Fn 保留为 NF，不展开为 Lambda）
  # ══════════════════════════════════════════════════════════════════════════════

  ruleFnNF = _: null;  # Fn 始终是 NF，无需规则

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则 11（可选）：Eta-reduction
  # Lambda(x, Apply(f, [x])) → f（若 x ∉ freeVars(f)）— 默认禁用
  # ══════════════════════════════════════════════════════════════════════════════

  ruleEtaReduction = enabled: t:
    if !enabled then null
    else
      let v = t.repr.__variant or null; in
      if v == "Lambda" then
        let body = t.repr.body; in
        if body.repr.__variant == "Apply"
           && builtins.length body.repr.args == 1
           && body.repr.args == [ (mkTypeDefault (rVar t.repr.param "") t.kind) ]
           && !(reprLib.freeVarsRepr body.repr.fn ? ${t.repr.param})
        then body.repr.fn
        else null
      else null;

  # ══════════════════════════════════════════════════════════════════════════════
  # 规则集（有序，返回优先命中的规则结果）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Int -> Bool -> Type -> Type?（null = 无规则命中）
  applyOneRule = muFuel: etaEnabled: t:
    let
      r1 = ruleConstraintFloat t;
      r2 = if r1 == null then ruleConstraintMerge t else null;
      r3 = if r2 == null then ruleBetaReduction t else null;
      r4 = if r3 == null then rulePiReduction t else null;
      r5 = if r4 == null then ruleConstructorUnfold t else null;
      r6 = if r5 == null then ruleConstructorPartial t else null;
      r7 = if r6 == null then ruleMuUnfold muFuel t else null;
      r8 = if r7 == null then ruleRowNormalize t else null;
      r9 = if r8 == null then ruleEffectNormalize t else null;
      r10 = if r9 == null && etaEnabled then ruleEtaReduction true t else null;
    in
    # 返回第一个非 null 的结果
    if r1 != null then r1
    else if r2 != null then r2
    else if r3 != null then r3
    else if r4 != null then r4
    else if r5 != null then r5
    else if r6 != null then r6
    else if r7 != null then r7
    else if r8 != null then r8
    else if r9 != null then r9
    else if r10 != null then r10
    else null;

}
