# repr/all.nix — Phase 4.1
# TypeRepr 全变体构造器（25+ 变体）
# INV-1: 所有变体都是合法 TypeRepr
# INV-6: Constrained ∈ TypeRepr（不是外部函数）
{ lib, kindLib }:

let
  mkRepr = variant: fields: { __variant = variant; } // fields;

in rec {

  # ══ 基础变体 ══════════════════════════════════════════════════════════════

  # ① Primitive — 原子类型（Int, Bool, String, Float, ...）
  rPrimitive = name: mkRepr "Primitive" { inherit name; };

  # ② Var — 类型变量（带作用域，防止不同 scope 的同名变量混淆）
  rVar = name: scope: mkRepr "Var" {
    inherit name scope;
    kind = kindLib.KStar;  # 默认 Kind * unless overridden
  };

  # Var with explicit kind annotation
  rVarK = name: scope: kind: mkRepr "Var" { inherit name scope kind; };

  # ③ Lambda — 类型级 λ 抽象（表达力闭合必须有）
  rLambda = param: body: mkRepr "Lambda" {
    inherit param body;
    paramKind = kindLib.KStar;  # 默认参数 Kind
  };

  # Lambda with explicit parameter kind
  rLambdaK = param: paramKind: body: mkRepr "Lambda" {
    inherit param paramKind body;
  };

  # ④ Apply — 类型级应用（计算核心）
  rApply = fn: args: mkRepr "Apply" { inherit fn args; };

  # ⑤ Constructor — 泛型 ADT 构造器
  rConstructor = name: kind: params: body: mkRepr "Constructor" {
    inherit name kind params body;
  };

  # ⑥ Fn — 函数类型（INV: 不强制展开，normalize 可配置）
  rFn = from: to: mkRepr "Fn" { inherit from to; };

  # ⑦ ADT — 代数数据类型
  rADT = variants: closed: mkRepr "ADT" { inherit variants closed; };

  # ⑧ Constrained — 约束内嵌（INV-6：Constraint ∈ TypeRepr）
  rConstrained = base: constraints: mkRepr "Constrained" {
    inherit base constraints;
  };

  # ══ 递归与行变体 ══════════════════════════════════════════════════════════

  # ⑨ Mu — 等递归类型（equi-recursive）
  # μX. T  ≅  T[X ↦ μX.T]
  rMu = var: body: mkRepr "Mu" { inherit var body; };

  # ⑩ Record — 记录类型（字段名 → 类型）
  rRecord = fields: mkRepr "Record" { inherit fields; };

  # ⑪ RowExtend — 行扩展（{ label: fieldType | rest }）
  rRowExtend = label: fieldType: rest: mkRepr "RowExtend" {
    inherit label fieldType rest;
  };

  # ⑫ RowEmpty — 空行（行结束符）
  rRowEmpty = mkRepr "RowEmpty" {};

  # ⑬ RowVar — 行变量（用于行多态）
  rRowVar = name: mkRepr "RowVar" { inherit name; };

  # ⑭ VariantRow — 变体行（Effect handler 基础）
  rVariantRow = variants: extension: mkRepr "VariantRow" {
    inherit variants extension;
  };

  # ══ 依赖类型变体 ══════════════════════════════════════════════════════════

  # ⑮ Pi — 依赖函数类型（Π(x:A).B）
  rPi = param: domain: body: mkRepr "Pi" { inherit param domain body; };

  # ⑯ Sigma — 依赖积类型（Σ(x:A).B）
  rSigma = param: domain: body: mkRepr "Sigma" { inherit param domain body; };

  # ══ 效果类型变体 ══════════════════════════════════════════════════════════

  # ⑰ Effect — 效果类型（Eff(E, A)）
  rEffect = effectRow: mkRepr "Effect" { inherit effectRow; };

  # ⑱ EffectMerge — 效果合并（E1 ++ E2）
  # Phase 4.0 INV-EFF-6: open effect row support
  rEffectMerge = left: right: mkRepr "EffectMerge" { inherit left right; };

  # ══ 辅助/封装变体 ══════════════════════════════════════════════════════════

  # ⑲ Opaque — 不透明类型（sealing，用于模块系统）
  rOpaque = inner: tag: mkRepr "Opaque" { inherit inner tag; };

  # ⑳ Ascribe — 类型标注（bidir 辅助）
  rAscribe = expr: type: mkRepr "Ascribe" { inherit expr type; };

  # ══ Phase 4.0 新增变体 ════════════════════════════════════════════════════

  # ㉑ Refined — 精化类型 { n : T | φ(n) }
  # INV-SMT-1: predExpr ∈ PredExpr IR（不是 Nix 函数）
  rRefined = base: predVar: predExpr: mkRepr "Refined" {
    inherit base predVar predExpr;
  };

  # ㉒ Sig — Module 接口签名（字段名 → Type）
  # INV-MOD-4: fields 字母序规范化
  rSig = fields: mkRepr "Sig" { inherit fields; };

  # ㉓ Struct — Module 实现（Sig + impl）
  rStruct = sig: impl: mkRepr "Struct" { inherit sig impl; };

  # ㉔ ModFunctor — Module Functor（Π(M : Sig). Body）
  rModFunctor = param: paramTy: body: mkRepr "ModFunctor" {
    inherit param paramTy body;
  };

  # ㉕ Handler — Effect Handler
  # INV-EFF-4: Handler ∈ TypeRepr
  rHandler = effectTag: branches: returnType: mkRepr "Handler" {
    inherit effectTag branches returnType;
  };

  # ══ Variant 构造器（用于 ADT）═════════════════════════════════════════════

  # Type: String -> [Type] -> Int -> Variant
  mkVariant = name: fields: ordinal: {
    __type  = "Variant";
    inherit name fields ordinal;
  };

  # ══ TypeRepr 谓词 ══════════════════════════════════════════════════════════
  isRepr        = r: builtins.isAttrs r && r ? __variant;
  isPrimitive   = r: isRepr r && r.__variant == "Primitive";
  isVar         = r: isRepr r && r.__variant == "Var";
  isLambda      = r: isRepr r && r.__variant == "Lambda";
  isApply       = r: isRepr r && r.__variant == "Apply";
  isConstructor = r: isRepr r && r.__variant == "Constructor";
  isFn          = r: isRepr r && r.__variant == "Fn";
  isADT         = r: isRepr r && r.__variant == "ADT";
  isConstrained = r: isRepr r && r.__variant == "Constrained";
  isMu          = r: isRepr r && r.__variant == "Mu";
  isRecord      = r: isRepr r && r.__variant == "Record";
  isRowExtend   = r: isRepr r && r.__variant == "RowExtend";
  isRowEmpty    = r: isRepr r && r.__variant == "RowEmpty";
  isRowVar      = r: isRepr r && r.__variant == "RowVar";
  isVariantRow  = r: isRepr r && r.__variant == "VariantRow";
  isPi          = r: isRepr r && r.__variant == "Pi";
  isSigma       = r: isRepr r && r.__variant == "Sigma";
  isEffect      = r: isRepr r && r.__variant == "Effect";
  isEffectMerge = r: isRepr r && r.__variant == "EffectMerge";
  isOpaque      = r: isRepr r && r.__variant == "Opaque";
  isAscribe     = r: isRepr r && r.__variant == "Ascribe";
  isRefined     = r: isRepr r && r.__variant == "Refined";
  isSig         = r: isRepr r && r.__variant == "Sig";
  isStruct      = r: isRepr r && r.__variant == "Struct";
  isModFunctor  = r: isRepr r && r.__variant == "ModFunctor";
  isHandler     = r: isRepr r && r.__variant == "Handler";
}
