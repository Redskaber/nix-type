# normalize/unified_subst.nix — Phase 4.0
#
# 统一替换系统（UnifiedSubst）
#
# 解决 Phase 3.3 遗留风险 1：
#   type subst: AttrSet String Type  (varName → Type)
#   row  subst: AttrSet String Type  ("RowVar:name" → rowType)
#   → 两轨未统一，solver 层 rowVar binding 无法注入 constraint pipeline
#
# Phase 4.0 方案：
#   UnifiedSubst = {
#     typeBindings : AttrSet String Type    # "t:name" → Type
#     rowBindings  : AttrSet String Type    # "r:name" → RowType
#     kindBindings : AttrSet String Kind    # "k:name" → Kind
#   }
#
# 统一键前缀协议：
#   类型变量  →  "t:${name}"
#   行变量    →  "r:${name}"
#   Kind变量  →  "k:${name}"
#
# 不变量（Phase 4.0 新增）：
#   INV-US1: apply(compose(σ₂,σ₁), t) = apply(σ₂, apply(σ₁, t))
#   INV-US2: apply(id, t) = t
#   INV-US3: 键前缀 严格区分（t:/r:/k:），无命名冲突
#   INV-US4: compose 的 domain 排序稳定（确定性）
#   INV-US5: applyToConstraint = applyToType ∘ traverse（compose law）

{ lib, typeLib, kindLib, reprLib }:

let
  inherit (typeLib) mkTypeDefault;
  inherit (kindLib) KStar;
  inherit (reprLib)
    rVar rRowVar rRowExtend rRowEmpty rRecord rVariantRow
    rEffect rEffectMerge rPrimitive rLambda rApply rFn rADT
    rConstrained rMu rPi rSigma rOpaque;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # UnifiedSubst 构造器
  # ══════════════════════════════════════════════════════════════════════════════

  emptySubst = {
    typeBindings = {};
    rowBindings  = {};
    kindBindings = {};
  };

  # 单点替换构造器
  singleTypeBinding = name: ty: emptySubst // {
    typeBindings = { "t:${name}" = ty; };
  };

  singleRowBinding = name: rowTy: emptySubst // {
    rowBindings = { "r:${name}" = rowTy; };
  };

  singleKindBinding = name: k: emptySubst // {
    kindBindings = { "k:${name}" = k; };
  };

  # 合并两个 UnifiedSubst（右优先，无组合语义）
  mergeSubst = s1: s2: {
    typeBindings = s1.typeBindings // s2.typeBindings;
    rowBindings  = s1.rowBindings  // s2.rowBindings;
    kindBindings = s1.kindBindings // s2.kindBindings;
  };

  # fromLegacyTypeSubst：从旧式 AttrSet String Type 转换（varName → "t:varName"）
  fromLegacyTypeSubst = legacySubst:
    let
      keys = lib.sort (a: b: a < b) (builtins.attrNames legacySubst);
    in
    emptySubst // {
      typeBindings = lib.listToAttrs (map (k: {
        name  = "t:${k}";
        value = legacySubst.${k};
      }) keys);
    };

  # fromLegacyRowSubst：从旧式 "RowVar:name" → rowType 转换
  fromLegacyRowSubst = legacyRowSubst:
    let
      keys = lib.sort (a: b: a < b) (builtins.attrNames legacyRowSubst);
      stripPrefix = k:
        if lib.hasPrefix "RowVar:" k
        then lib.removePrefix "RowVar:" k
        else k;
    in
    emptySubst // {
      rowBindings = lib.listToAttrs (map (k: {
        name  = "r:${stripPrefix k}";
        value = legacyRowSubst.${k};
      }) keys);
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # UnifiedSubst 组合（σ₂ ∘ σ₁：先 σ₁ 后 σ₂）
  # INV-US1 保证正确性
  # ══════════════════════════════════════════════════════════════════════════════

  composeSubst = sigma2: sigma1:
    let
      # 对 sigma1 的所有值应用 sigma2
      appliedType = lib.mapAttrs (_: ty: applySubstToType sigma2 ty) sigma1.typeBindings;
      appliedRow  = lib.mapAttrs (_: ty: applySubstToRow  sigma2 ty) sigma1.rowBindings;
      appliedKind = lib.mapAttrs (_: k:  applySubstToKind sigma2 k)  sigma1.kindBindings;

      # sigma2 中不被 sigma1 domain 覆盖的额外绑定
      extraType = lib.filterAttrs (k: _: !(sigma1.typeBindings ? ${k})) sigma2.typeBindings;
      extraRow  = lib.filterAttrs (k: _: !(sigma1.rowBindings  ? ${k})) sigma2.rowBindings;
      extraKind = lib.filterAttrs (k: _: !(sigma1.kindBindings ? ${k})) sigma2.kindBindings;
    in {
      typeBindings = appliedType // extraType;
      rowBindings  = appliedRow  // extraRow;
      kindBindings = appliedKind // extraKind;
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # applySubstToType：将 UnifiedSubst 应用到 TypeIR
  # 完整结构递归（INV-US5）
  # ══════════════════════════════════════════════════════════════════════════════

  applySubstToType = subst: ty:
    if !(builtins.isAttrs ty) then ty
    else
    let
      r    = ty.repr or {};
      v    = r.__variant or null;
      go   = applySubstToType subst;
      goK  = applySubstToKind subst;
      key  = "t:${r.name or ""}";
    in
    # Var：在 typeBindings 中查找
    if v == "Var" then
      let k = "t:${r.name}"; in
      if subst.typeBindings ? ${k}
      then subst.typeBindings.${k}
      else ty
    # RowVar：在 rowBindings 中查找
    else if v == "RowVar" then
      let k = "r:${r.name}"; in
      if subst.rowBindings ? ${k}
      then subst.rowBindings.${k}
      else ty
    # Lambda：替换 body（避免捕获：param 作用域隔离）
    else if v == "Lambda" then
      let
        param' = r.param;
        # 若 param 与 typeBindings 某个 Var 同名，需要 shadow
        shadowedSubst = subst // {
          typeBindings = lib.filterAttrs (k: _: k != "t:${param'}") subst.typeBindings;
        };
        body' = applySubstToType shadowedSubst r.body;
      in
      if body' == r.body then ty
      else ty // { repr = r // { body = body'; }; }
    # Apply
    else if v == "Apply" then
      let
        fn'   = go r.fn;
        args' = map go r.args;
      in
      if fn' == r.fn && args' == r.args then ty
      else ty // { repr = r // { fn = fn'; args = args'; }; }
    # Fn
    else if v == "Fn" then
      let from' = go r.from; to' = go r.to; in
      if from' == r.from && to' == r.to then ty
      else ty // { repr = r // { from = from'; to = to'; }; }
    # Constrained
    else if v == "Constrained" then
      let
        base' = go r.base;
        cs'   = map (applySubstToConstraint subst) (r.constraints or []);
      in
      if base' == r.base && cs' == r.constraints then ty
      else ty // { repr = r // { base = base'; constraints = cs'; }; }
    # Mu：binder shadow
    else if v == "Mu" then
      let
        shadowedSubst = subst // {
          typeBindings = lib.filterAttrs (k: _: k != "t:${r.var}") subst.typeBindings;
        };
        body' = applySubstToType shadowedSubst r.body;
      in
      if body' == r.body then ty
      else ty // { repr = r // { body = body'; }; }
    # Record
    else if v == "Record" then
      let fields' = lib.mapAttrs (_: go) (r.fields or {}); in
      if fields' == r.fields then ty
      else ty // { repr = r // { fields = fields'; }; }
    # RowExtend
    else if v == "RowExtend" then
      let
        ft'   = go r.fieldType;
        rest' = go r.rest;
      in
      if ft' == r.fieldType && rest' == r.rest then ty
      else ty // { repr = r // { fieldType = ft'; rest = rest'; }; }
    # RowEmpty：不变
    else if v == "RowEmpty" then ty
    # VariantRow
    else if v == "VariantRow" then
      let
        vars' = lib.mapAttrs (_: go) (r.variants or {});
        ext'  = go (r.extension or { repr = { __variant = "RowEmpty"; }; });
      in
      if vars' == r.variants && ext' == r.extension then ty
      else ty // { repr = r // { variants = vars'; extension = ext'; }; }
    # Effect
    else if v == "Effect" then
      let effRow' = go r.effectRow; in
      if effRow' == r.effectRow then ty
      else ty // { repr = r // { effectRow = effRow'; }; }
    # EffectMerge（Phase 4.0：支持 RowVar tail）
    else if v == "EffectMerge" then
      let left' = go r.left; right' = go r.right; in
      if left' == r.left && right' == r.right then ty
      else ty // { repr = r // { left = left'; right = right'; }; }
    # Pi：domain + body，param shadow
    else if v == "Pi" then
      let
        dom'  = go r.domain;
        shadowedSubst = subst // {
          typeBindings = lib.filterAttrs (k: _: k != "t:${r.param}") subst.typeBindings;
        };
        body' = applySubstToType shadowedSubst r.body;
      in
      if dom' == r.domain && body' == r.body then ty
      else ty // { repr = r // { domain = dom'; body = body'; }; }
    # Sigma：同 Pi
    else if v == "Sigma" then
      let
        dom'  = go r.domain;
        shadowedSubst = subst // {
          typeBindings = lib.filterAttrs (k: _: k != "t:${r.param}") subst.typeBindings;
        };
        body' = applySubstToType shadowedSubst r.body;
      in
      if dom' == r.domain && body' == r.body then ty
      else ty // { repr = r // { domain = dom'; body = body'; }; }
    # Constructor
    else if v == "Constructor" then
      let
        params' = map (p: p // { kind = goK p.kind; }) (r.params or []);
        shadowedSubst = subst // {
          typeBindings = lib.foldl' (acc: p: lib.filterAttrs (k: _: k != "t:${p.name}") acc)
                           subst.typeBindings (r.params or []);
        };
        body' = applySubstToType shadowedSubst r.body;
      in
      ty // { repr = r // { params = params'; body = body'; }; }
    # ADT
    else if v == "ADT" then
      let vars' = lib.mapAttrs (_: go) (r.variants or {}); in
      if vars' == r.variants then ty
      else ty // { repr = r // { variants = vars'; }; }
    # Opaque
    else if v == "Opaque" then
      let inner' = go r.inner; in
      if inner' == r.inner then ty
      else ty // { repr = r // { inner = inner'; }; }
    # Refined（Phase 4.0 新增）
    else if v == "Refined" then
      let base' = go r.base; in
      if base' == r.base then ty
      else ty // { repr = r // { base = base'; }; }
    # Sig / Struct / Functor（Phase 4.0 新增）
    else if v == "Sig" then
      let fields' = lib.mapAttrs (_: go) (r.fields or {}); in
      if fields' == r.fields then ty
      else ty // { repr = r // { fields = fields'; }; }
    else if v == "Struct" then
      let
        sig'  = go r.sig;
        impl' = lib.mapAttrs (_: go) (r.impl or {});
      in
      ty // { repr = r // { sig = sig'; impl = impl'; }; }
    else if v == "ModFunctor" then
      let
        paramTy' = go r.paramTy;
        shadowedSubst = subst // {
          typeBindings = lib.filterAttrs (k: _: k != "t:${r.param}") subst.typeBindings;
        };
        body' = applySubstToType shadowedSubst r.body;
      in
      ty // { repr = r // { paramTy = paramTy'; body = body'; }; }
    # Primitive / unknown：不变
    else ty;

  # ══════════════════════════════════════════════════════════════════════════════
  # applySubstToRow：专门处理行类型的替换（INV-ROW-3 兼容）
  # ══════════════════════════════════════════════════════════════════════════════

  applySubstToRow = subst: rowTy:
    applySubstToType subst rowTy;

  # ══════════════════════════════════════════════════════════════════════════════
  # applySubstToKind：Kind 级别替换
  # ══════════════════════════════════════════════════════════════════════════════

  applySubstToKind = subst: k:
    let v = k.__kindVariant or null; in
    if v == "KVar" then
      let key = "k:${k.name}"; in
      if subst.kindBindings ? ${key}
      then subst.kindBindings.${key}
      else k
    else if v == "KArrow" then
      let
        from' = applySubstToKind subst k.from;
        to'   = applySubstToKind subst k.to;
      in
      if from' == k.from && to' == k.to then k
      else kindLib.KArrow from' to'
    else k;

  # ══════════════════════════════════════════════════════════════════════════════
  # applySubstToConstraint：约束内部替换（INV-US5）
  # ══════════════════════════════════════════════════════════════════════════════

  applySubstToConstraint = subst: c:
    let
      go   = applySubstToType subst;
      tag  = c.__constraintTag or null;
    in
    if tag == "Equality" then
      c // { lhs = go c.lhs; rhs = go c.rhs; }
    else if tag == "Class" then
      c // { args = map go c.args; }
    else if tag == "Predicate" then
      c // { subject = go c.subject; }
    else if tag == "Implies" then
      c // {
        premises   = map (applySubstToConstraint subst) c.premises;
        conclusion = applySubstToConstraint subst c.conclusion;
      }
    else if tag == "RowEquality" then
      c // { lhsRow = go c.lhsRow; rhsRow = go c.rhsRow; }
    else c;

  # ══════════════════════════════════════════════════════════════════════════════
  # applySubstToConstraints：批量应用（solver 入口）
  # ══════════════════════════════════════════════════════════════════════════════

  applySubstToConstraints = subst: cs:
    map (applySubstToConstraint subst) cs;

  # ══════════════════════════════════════════════════════════════════════════════
  # substFreeVars：计算替换后自由变量集合
  # ══════════════════════════════════════════════════════════════════════════════

  substDomain = subst:
    let
      tKeys = builtins.attrNames subst.typeBindings;
      rKeys = builtins.attrNames subst.rowBindings;
      kKeys = builtins.attrNames subst.kindBindings;
    in
    tKeys ++ rKeys ++ kKeys;

  substIsEmpty = subst:
    subst.typeBindings == {} &&
    subst.rowBindings  == {} &&
    subst.kindBindings == {};

  # ══════════════════════════════════════════════════════════════════════════════
  # 向后兼容适配器（供旧代码迁移）
  # ══════════════════════════════════════════════════════════════════════════════

  # legacyApplyTypeSubst：旧式 AttrSet String Type 直接应用
  legacyApplyTypeSubst = legacySubst: ty:
    let us = fromLegacyTypeSubst legacySubst; in
    applySubstToType us ty;

  # legacyApplyRowSubst：旧式 "RowVar:name" 直接应用
  legacyApplyRowSubst = legacyRowSubst: ty:
    let us = fromLegacyRowSubst legacyRowSubst; in
    applySubstToType us ty;

  # ══════════════════════════════════════════════════════════════════════════════
  # 不变量验证
  # ══════════════════════════════════════════════════════════════════════════════

  verifyUnifiedSubstInvariants = _:
    let
      tBool = mkTypeDefault (rPrimitive "Bool") KStar;
      tInt  = mkTypeDefault (rPrimitive "Int")  KStar;
      tVarA = mkTypeDefault (rVar "a" "test") KStar;
      tVarR = mkTypeDefault (rRowVar "r") kindLib.KRow;

      # INV-US2: apply(id, t) = t
      testId = applySubstToType emptySubst tInt;
      invUS2 = testId.repr.__variant == "Primitive" && testId.repr.name == "Int";

      # INV-US3: 键前缀区分
      tSubst = singleTypeBinding "a" tInt;
      rSubst = singleRowBinding  "a" tVarR;
      noConflict =
        !(tSubst.typeBindings ? "r:a") &&
        !(rSubst.rowBindings  ? "t:a");

      # INV-US1: compose 方向验证
      # σ₂ = { b → Bool }, σ₁ = { a → Var(b) }
      tVarB = mkTypeDefault (rVar "b" "test") KStar;
      s1    = singleTypeBinding "a" tVarB;
      s2    = singleTypeBinding "b" tBool;
      comp  = composeSubst s2 s1;
      # apply(s1, Var(a)) = Var(b); apply(s2, Var(b)) = Bool
      # apply(comp, Var(a)) should = Bool
      result = applySubstToType comp tVarA;
      invUS1 = result.repr.__variant == "Primitive" && result.repr.name == "Bool";

      # INV-US4: 稳定 domain ordering
      s3 = fromLegacyTypeSubst { z = tBool; a = tInt; m = tVarA; };
      keys = builtins.attrNames s3.typeBindings;
      sortedKeys = lib.sort (x: y: x < y) keys;
      invUS4 = keys == sortedKeys;

    in {
      allPass   = invUS1 && invUS2 && invUS3 && invUS4;
      "INV-US1" = invUS1;
      "INV-US2" = invUS2;
      "INV-US3" = noConflict;
      "INV-US4" = invUS4;
    };
}
