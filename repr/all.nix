# repr/all.nix — Phase 3
# TypeRepr 全变体构造器
#
# Phase 3 新增：
#   Pi     { param; paramType; body }   — Dependent function type Π(x:A).B(x)
#   Sigma  { param; paramType; body }   — Dependent pair Σ(x:A).B(x)
#   Effect { tag; row }                 — Effect type（algebraic effects 准备）
#   Opaque { name; id }                 — 不透明类型（phantom / newtype）
#   Ascribe { t; annotation }           — 类型标注（bidirectional 需要）
#
# 修复（Phase 3）：
#   rConstructor — 修复 kind 推断（保留真实参数 kind，不统一为 KStar）
#   freeVarsRepr — 完整实现（Mu/Record/VariantRow/Pi/Sigma 全覆盖）
#   mkVariant    — ordinal 追踪（Open ADT 扩展机制）
{ lib }:

let
  mkRepr = variant: fields: { __variant = variant; } // fields;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 基础 TypeRepr 变体
  # ══════════════════════════════════════════════════════════════════════════════

  # ① Primitive — 原子类型（Int, Bool, String, Float...）
  # Type: String -> TypeRepr
  rPrimitive = name: mkRepr "Primitive" { inherit name; };

  # ② Var — 类型变量（带作用域）
  # Type: String -> String -> TypeRepr
  rVar = name: scope: mkRepr "Var" { inherit name scope; };

  # ③ VarDB — de Bruijn index 变量（α-canonical，Phase 2）
  # Type: Int -> TypeRepr
  rVarDB = index: mkRepr "VarDB" { inherit index; };

  # ④ VarScoped — 带作用域的命名变量（Phase 2）
  # Type: String -> Int -> TypeRepr（name + db index）
  rVarScoped = name: index: mkRepr "VarScoped" { inherit name index; };

  # ⑤ Lambda — 类型级 λ 抽象（表达力闭合必须）
  # Type: String -> Type -> TypeRepr
  rLambda = param: body: mkRepr "Lambda" { inherit param body; };

  # ⑥ Apply — 类型级应用（计算核心）
  # Type: Type -> [Type] -> TypeRepr
  rApply = fn: args: mkRepr "Apply" { inherit fn args; };

  # ⑦ Fn — 函数类型（NF 保留，不展开为 Lambda）
  # Type: Type -> Type -> TypeRepr
  rFn = from: to: mkRepr "Fn" { inherit from to; };

  # ⑧ Constructor — 泛型 ADT 构造器
  # params: [{name, kind}] — 保留真实 kind（Phase 3 修复 INV-K1）
  # Type: String -> Kind -> [{name,kind}] -> Type -> TypeRepr
  rConstructor = name: kind: params: body:
    mkRepr "Constructor" { inherit name kind params body; };

  # ⑨ ADT — 代数数据类型
  # Type: [Variant] -> Bool -> TypeRepr
  rADT = variants: closed:
    mkRepr "ADT" { inherit variants closed; };

  # ⑩ Constrained — 约束内嵌（INV-6 核心）
  # Type: Type -> [Constraint] -> TypeRepr
  rConstrained = base: constraints:
    mkRepr "Constrained" { inherit base constraints; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Phase 2 TypeRepr 变体（μ-types + Row Polymorphism）
  # ══════════════════════════════════════════════════════════════════════════════

  # ⑪ Mu — 递归类型（equi-recursive）
  # Type: String -> Type -> TypeRepr
  rMu = param: body: mkRepr "Mu" { inherit param body; };

  # ⑫ Record — Row-polymorphic record
  # fields: AttrSet String Type
  # rowVar: String? — open row variable（null = closed）
  # Type: AttrSet -> String? -> TypeRepr
  rRecord = fields: rowVar:
    mkRepr "Record" { inherit fields rowVar; };

  # ⑬ VariantRow — Open variant sum type（extensible union）
  # variants: AttrSet String [Type]（label → payload types）
  # rowVar: String? — open row variable
  # Type: AttrSet -> String? -> TypeRepr
  rVariantRow = variants: rowVar:
    mkRepr "VariantRow" { inherit variants rowVar; };

  # ⑭ RowExtend — Row 扩展 cons cell（用于 Row 类型的 spine）
  # Type: String -> Type -> Type -> TypeRepr
  rRowExtend = label: fieldType: rowType:
    mkRepr "RowExtend" { inherit label fieldType rowType; };

  # ⑮ RowEmpty — 封闭行终止符
  rRowEmpty = mkRepr "RowEmpty" {};

  # ══════════════════════════════════════════════════════════════════════════════
  # Phase 3 TypeRepr 变体（Dependent Types + Effects）
  # ══════════════════════════════════════════════════════════════════════════════

  # ⑯ Pi — Dependent function type Π(x:A).B(x)
  # Type: String -> Type -> Type -> TypeRepr
  rPi = param: paramType: body:
    mkRepr "Pi" { inherit param paramType body; };

  # ⑰ Sigma — Dependent pair type Σ(x:A).B(x)
  # Type: String -> Type -> Type -> TypeRepr
  rSigma = param: paramType: body:
    mkRepr "Sigma" { inherit param paramType body; };

  # ⑱ Effect — Effect type（algebraic effects，Phase 3 准备）
  # tag: String — effect 标签（e.g., "IO", "State", "Error"）
  # row: Type — effect row（VariantRow-based）
  # Type: String -> Type -> TypeRepr
  rEffect = tag: row: mkRepr "Effect" { inherit tag row; };

  # ⑲ Opaque — 不透明类型（phantom / newtype）
  # Type: String -> String -> TypeRepr
  rOpaque = name: opaqueId: mkRepr "Opaque" { inherit name; id = opaqueId; };

  # ⑳ Ascribe — 类型标注（bidirectional checking 用）
  # Type: Type -> Type -> TypeRepr
  rAscribe = t: annotation: mkRepr "Ascribe" { inherit t annotation; };

  # ══════════════════════════════════════════════════════════════════════════════
  # ADT 变体构造（Variant + Open ADT）
  # ══════════════════════════════════════════════════════════════════════════════

  # Variant = { name: String; fields: [Type]; ordinal: Int }
  # ordinal 稳定追加（Open ADT 扩展机制）
  # Type: String -> [Type] -> Int -> Variant
  mkVariant = name: fields: ordinal: { inherit name fields ordinal; };

  # 从 variant list 构建 ADT repr（ordinal 自动分配）
  # Type: [{name, fields}] -> Bool -> TypeRepr
  mkADTFromVariants = variants: closed:
    let
      indexed = lib.imap0 (i: v: mkVariant v.name (v.fields or []) i) variants;
    in
    rADT indexed closed;

  # Open ADT 扩展：追加新 variant（ordinal 稳定增长）
  # Type: TypeRepr -> {name, fields} -> TypeRepr
  extendADT = adtRepr: newVariant:
    assert adtRepr.__variant == "ADT";
    assert !(adtRepr.closed);  # 只能扩展 open ADT
    let
      nextOrdinal = builtins.length adtRepr.variants;
      v = mkVariant newVariant.name (newVariant.fields or []) nextOrdinal;
    in
    adtRepr // { variants = adtRepr.variants ++ [v]; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 自由变量收集（Phase 3：完整覆盖所有变体）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: TypeRepr -> Set String（attrset of varName -> true）
  # 注意：这里处理 TypeRepr（不是 Type），需要递归进入子 Type
  freeVarsRepr = repr:
    let
      v = repr.__variant or null;
      # 辅助：从 Type 获取 free vars（委托给 freeVarsRepr on repr）
      fvType = t: if t ? repr then freeVarsRepr t.repr else {};
      # 辅助：合并多个 fv sets
      union = sets: lib.foldl' (a: b: a // b) {} sets;
    in

    if v == "Var"         then { ${repr.name} = true; }
    else if v == "VarDB"  then {}  # de Bruijn: 无命名自由变量
    else if v == "VarScoped" then { ${repr.name} = true; }
    else if v == "Primitive" then {}
    else if v == "RowEmpty"  then {}
    else if v == "Opaque"    then {}

    else if v == "Lambda" then
      builtins.removeAttrs (fvType repr.body) [ repr.param ]

    else if v == "Pi" then
      # Π(x:A).B：x 在 B 中绑定
      union [ (fvType repr.paramType)
              (builtins.removeAttrs (fvType repr.body) [ repr.param ]) ]

    else if v == "Sigma" then
      union [ (fvType repr.paramType)
              (builtins.removeAttrs (fvType repr.body) [ repr.param ]) ]

    else if v == "Apply" then
      union ([ (fvType repr.fn) ] ++ map fvType repr.args)

    else if v == "Fn" then
      union [ (fvType repr.from) (fvType repr.to) ]

    else if v == "Constructor" then
      union ([ (fvType repr.body) ]
             ++ map (p: builtins.removeAttrs (fvType repr.body) [p.name])
                    (repr.params or []))

    else if v == "ADT" then
      union (lib.concatMap (variant: map fvType (variant.fields or [])) repr.variants)

    else if v == "Constrained" then
      fvType repr.base

    else if v == "Mu" then
      builtins.removeAttrs (fvType repr.body) [ repr.param ]

    else if v == "Record" then
      let fieldFVs = union (map fvType (builtins.attrValues repr.fields)); in
      if repr.rowVar != null
      then fieldFVs // { ${repr.rowVar} = true; }
      else fieldFVs

    else if v == "VariantRow" then
      let
        varFVs = union (lib.concatMap (fs: map fvType fs)
                        (builtins.attrValues repr.variants));
      in
      if repr.rowVar != null
      then varFVs // { ${repr.rowVar} = true; }
      else varFVs

    else if v == "RowExtend" then
      union [ (fvType repr.fieldType) (fvType repr.rowType) ]

    else if v == "Effect" then
      fvType repr.row

    else if v == "Ascribe" then
      union [ (fvType repr.t) (fvType repr.annotation) ]

    else {};  # 未知变体：保守返回空

  # ══════════════════════════════════════════════════════════════════════════════
  # 判断函数
  # ══════════════════════════════════════════════════════════════════════════════

  isRepr = r: builtins.isAttrs r && r ? __variant;

  isPrimitive  = r: isRepr r && r.__variant == "Primitive";
  isVar        = r: isRepr r && r.__variant == "Var";
  isVarDB      = r: isRepr r && r.__variant == "VarDB";
  isLambda     = r: isRepr r && r.__variant == "Lambda";
  isApply      = r: isRepr r && r.__variant == "Apply";
  isFn         = r: isRepr r && r.__variant == "Fn";
  isConstructor = r: isRepr r && r.__variant == "Constructor";
  isADT        = r: isRepr r && r.__variant == "ADT";
  isConstrained = r: isRepr r && r.__variant == "Constrained";
  isMu         = r: isRepr r && r.__variant == "Mu";
  isRecord     = r: isRepr r && r.__variant == "Record";
  isVariantRow = r: isRepr r && r.__variant == "VariantRow";
  isRowExtend  = r: isRepr r && r.__variant == "RowExtend";
  isRowEmpty   = r: isRepr r && r.__variant == "RowEmpty";
  isPi         = r: isRepr r && r.__variant == "Pi";
  isSigma      = r: isRepr r && r.__variant == "Sigma";
  isEffect     = r: isRepr r && r.__variant == "Effect";
  isOpaque     = r: isRepr r && r.__variant == "Opaque";
  isAscribe    = r: isRepr r && r.__variant == "Ascribe";

  # ── Row 辅助 ─────────────────────────────────────────────────────────────

  # Row 是否封闭（无 rowVar）
  isClosedRow = r:
    (r.__variant == "Record" || r.__variant == "VariantRow")
    && r.rowVar == null;

  # 提取 Record 字段列表（排序后，canonical）
  recordFieldsSorted = r:
    assert r.__variant == "Record";
    builtins.sort (a: b: a < b) (builtins.attrNames r.fields);

  # 构建 row spine（RowExtend chain from Record fields）
  # Type: AttrSet String Type -> Type? -> TypeRepr
  buildRowSpine = fields: tailVar:
    let
      labels = builtins.sort (a: b: a < b) (builtins.attrNames fields);
      tail   = if tailVar != null
               then { repr = rVar tailVar "row"; }  # placeholder Type
               else { repr = rRowEmpty; };
    in
    lib.foldr
      (label: rowType: { repr = rRowExtend label fields.${label} rowType; })
      tail
      labels;

}
