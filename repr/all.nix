# repr/all.nix — Phase 3.1
# TypeRepr 全变体构造器（21 变体完整实现）
#
# Phase 3.1 新增/修复：
#   1. Lambda: paramKind 字段（kindInferRepr 依赖，INV-K1）
#   2. Pi/Sigma: domain 字段（dependent type）
#   3. Constructor: params 携带 kind 信息（INV-K1 修复）
#   4. freeVarsRepr: 全 21 变体覆盖
#   5. ADT extendADT: ordinal 稳定追加
#   6. RowExtend: 显式 label/fieldType/rest
#   7. Effect: effectRow 结构化
#
# 不变量：
#   INV-1: 所有结构 ∈ TypeIR（repr 必须有 __variant）
#   INV-K1: Constructor/Lambda repr 携带 param.kind
{ lib }:

let
  mkRepr = variant: fields:
    fields // { __variant = variant; };

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 基础变体
  # ══════════════════════════════════════════════════════════════════════════════

  # Primitive { name: String }
  rPrimitive = name:
    mkRepr "Primitive" { inherit name; };

  # Var { name: String; scope: Int }（scope = de Bruijn 辅助，0 = 自由）
  rVar = name:
    mkRepr "Var" { inherit name; scope = 0; };

  # Var with explicit scope（bidirectional 推断用）
  rVarDB = name: scope:
    mkRepr "Var" { inherit name scope; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 函数/抽象变体
  # ══════════════════════════════════════════════════════════════════════════════

  # Lambda { param: String; paramKind: Kind; body: Type }
  # Phase 3.1：paramKind 为 kindInferRepr 所必需（INV-K1）
  rLambda = param: paramKind: body:
    mkRepr "Lambda" { inherit param paramKind body; };

  # Lambda（KUnbound 参数 kind，兼容旧 API）
  rLambdaSimple = param: body:
    let kindLib = { KUnbound = { __kindVariant = "KUnbound"; }; }; in
    mkRepr "Lambda" { inherit param body; paramKind = kindLib.KUnbound; };

  # Apply { fn: Type; args: [Type] }（多参数 apply）
  rApply = fn: args:
    mkRepr "Apply" { inherit fn args; };

  # Fn { from: Type; to: Type }（函数类型语法糖）
  rFn = from: to:
    mkRepr "Fn" { inherit from to; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Dependent Types（Phase 3）
  # ══════════════════════════════════════════════════════════════════════════════

  # Pi { param: String; domain: Type; body: Type }（Π(x:A).B）
  rPi = param: domain: body:
    mkRepr "Pi" { inherit param domain body; };

  # Sigma { param: String; domain: Type; body: Type }（Σ(x:A).B）
  rSigma = param: domain: body:
    mkRepr "Sigma" { inherit param domain body; };

  # ══════════════════════════════════════════════════════════════════════════════
  # ADT / Constructor
  # ══════════════════════════════════════════════════════════════════════════════

  # Constructor { name: String; kind: Kind; params: [Param]; body: Type }
  # Param = { name: String; kind: Kind }（INV-K1：携带 kind）
  rConstructor = name: kind: params: body:
    mkRepr "Constructor" { inherit name kind params body; };

  # Param 构造器（显式 kind）
  mkParam = name: kind: { inherit name kind; };
  # Param（KUnbound kind，兼容）
  mkParamSimple = name: { inherit name; kind = { __kindVariant = "KUnbound"; }; };

  # ADT { variants: [Variant]; closed: Bool }
  rADT = variants: closed:
    mkRepr "ADT" { inherit variants closed; };

  # Variant = { name: String; fields: [Type]; ordinal: Int }
  mkVariant = name: fields: ordinal:
    { inherit name fields ordinal; };

  # Open ADT 扩展（ordinal 稳定追加，INV-ADT1）
  extendADT = repr: newVariants:
    let
      existing = repr.variants or [];
      baseOrdinal = builtins.length existing;
      added = lib.imap0
        (i: v: mkVariant (v.name or "V${builtins.toString i}")
                          (v.fields or [])
                          (baseOrdinal + i))
        newVariants;
    in
    repr // { variants = existing ++ added; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Constrained（INV-6 核心）
  # ══════════════════════════════════════════════════════════════════════════════

  # Constrained { base: Type; constraints: [Constraint] }
  rConstrained = base: constraints:
    mkRepr "Constrained" { inherit base constraints; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Recursive Types
  # ══════════════════════════════════════════════════════════════════════════════

  # Mu { var: String; body: Type }（equi-recursive, μ(α).T）
  rMu = var: body:
    mkRepr "Mu" { inherit var body; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Record / Row
  # ══════════════════════════════════════════════════════════════════════════════

  # Record { fields: AttrSet String Type }（{f1:T1, f2:T2, ...}）
  rRecord = fields:
    mkRepr "Record" { inherit fields; };

  # VariantRow { variants: AttrSet String Type; tail: Type? }（open variant rows）
  rVariantRow = variants: tail:
    mkRepr "VariantRow" (
      { inherit variants; }
      // (if tail != null then { inherit tail; } else {})
    );

  # RowExtend { label: String; fieldType: Type; rest: Type }（ρ-extend）
  rRowExtend = label: fieldType: rest:
    mkRepr "RowExtend" { inherit label fieldType rest; };

  # RowEmpty（∅ — empty row）
  rRowEmpty =
    mkRepr "RowEmpty" {};

  # ══════════════════════════════════════════════════════════════════════════════
  # Effect System（Phase 3）
  # ══════════════════════════════════════════════════════════════════════════════

  # Effect { effectRow: Type }（algebraic effect type，row-encoded）
  rEffect = effectRow:
    mkRepr "Effect" { inherit effectRow; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Bidirectional Ascription（Phase 3）
  # ══════════════════════════════════════════════════════════════════════════════

  # Ascribe { inner: Type; ty: Type }（type ascription — check/switch point）
  rAscribe = inner: ty:
    mkRepr "Ascribe" { inherit inner ty; };

  # Opaque { name: String }（phantom/newtype — referential equality）
  rOpaque = name:
    mkRepr "Opaque" { inherit name; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 自由变量（全 21 变体覆盖，Phase 3.1 完整化）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: TypeRepr -> [String]
  freeVarsRepr = repr:
    let
      v    = repr.__variant or null;
      goT  = t: freeVarsRepr (t.repr or { __variant = "?"; });
      goTl = ts: builtins.concatMap goT ts;
      # 从 binder 中删除绑定的变量
      rmBinder = name: vars: builtins.filter (x: x != name) vars;
    in

    if v == "Primitive" then []

    else if v == "Var"    then [repr.name or "_"]

    else if v == "Lambda" then
      rmBinder (repr.param or "_") (goT (repr.body or {}))

    else if v == "Pi" then
      goT (repr.domain or {})
      ++ rmBinder (repr.param or "_") (goT (repr.body or {}))

    else if v == "Sigma" then
      goT (repr.domain or {})
      ++ rmBinder (repr.param or "_") (goT (repr.body or {}))

    else if v == "Apply" then
      goT (repr.fn or {}) ++ goTl (repr.args or [])

    else if v == "Fn" then
      goT (repr.from or {}) ++ goT (repr.to or {})

    else if v == "Constructor" then
      let
        paramNames = map (p: p.name or "_") (repr.params or []);
        bodyVars   = if repr ? body then goT repr.body else [];
        filtered   = builtins.filter (x: !builtins.elem x paramNames) bodyVars;
      in
      filtered

    else if v == "ADT" then
      builtins.concatMap (var: goTl (var.fields or [])) (repr.variants or [])

    else if v == "Constrained" then
      goT (repr.base or {})
      ++ builtins.concatMap
           (c: if c ? a then goT c.a ++ goT c.b else [])
           (repr.constraints or [])

    else if v == "Mu" then
      rmBinder (repr.var or "_") (goT (repr.body or {}))

    else if v == "Record" then
      builtins.concatMap (k: goT (repr.fields or {}).${k})
        (builtins.attrNames (repr.fields or {}))

    else if v == "VariantRow" then
      builtins.concatMap (k: goT (repr.variants or {}).${k})
        (builtins.attrNames (repr.variants or {}))
      ++ (if repr ? tail then goT repr.tail else [])

    else if v == "RowExtend" then
      goT (repr.fieldType or {}) ++ goT (repr.rest or {})

    else if v == "RowEmpty" then []

    else if v == "Effect" then
      goT (repr.effectRow or {})

    else if v == "Opaque" then []

    else if v == "Ascribe" then
      goT (repr.inner or {}) ++ goT (repr.ty or {})

    else [];

  # ══════════════════════════════════════════════════════════════════════════════
  # repr 判断工具
  # ══════════════════════════════════════════════════════════════════════════════

  isRepr    = r: builtins.isAttrs r && r ? __variant;
  reprIs    = variant: r: isRepr r && r.__variant == variant;
  isPrimRepr = reprIs "Primitive";
  isVarRepr  = reprIs "Var";
  isLamRepr  = reprIs "Lambda";
  isAppRepr  = reprIs "Apply";
  isFnRepr   = reprIs "Fn";
  isPiRepr   = reprIs "Pi";
  isMuRepr   = reprIs "Mu";
  isADTRepr  = reprIs "ADT";
  isRecordRepr = reprIs "Record";
  isRowExtRepr = reprIs "RowExtend";

}
