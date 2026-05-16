# core/type.nix — Phase 4.3
# TypeIR 统一宇宙：Type = { tag; id; kind; repr; meta }
# INV-1: 所有结构 ∈ TypeIR
# Fix P4.3: _reprToIdStr 改用 serializeRepr（而非 builtins.toJSON）
#           避免含内嵌 Type 对象的 repr 触发 "cannot convert function to JSON"
{ lib, kindLib, metaLib, serialLib }:

let
  inherit (kindLib) KStar KArrow isKind serializeKind;
  inherit (metaLib) defaultMeta isMeta;
  inherit (serialLib) serializeRepr;

  # ── 内部：stable id 生成（Fix P4.3: canonical serialization）────────
  # CRITICAL: must use serializeRepr, NOT builtins.toJSON
  # builtins.toJSON fails on attrsets containing Type objects (with id/kind fields
  # that embed more Types). serializeRepr produces a pure string deterministically.
  _mkId = repr:
    builtins.hashString "sha256" (serializeRepr repr);


  # ══ TypeIR 核心构造器 ══════════════════════════════════════════════════

  # Type: TypeRepr → Kind → Meta → Type
  mkTypeWith = repr: kind: meta:
    assert builtins.isAttrs repr;
    assert isKind kind || kind == null;
    assert isMeta meta;
    {
      tag  = "Type";
      id   = _mkId repr;
      kind = if kind == null then KStar else kind;
      repr = repr;
      meta = meta;
    };

  # Type: TypeRepr → Kind → Type
  mkTypeDefault = repr: kind:
    mkTypeWith repr kind defaultMeta;

  # ══ TypeIR 谓词 ════════════════════════════════════════════════════════
  isType = t:
    builtins.isAttrs t
    && (t.tag or null) == "Type"
    && t ? id && t ? kind && t ? repr && t ? meta;

  # ══ TypeIR 解构 ════════════════════════════════════════════════════════
  typeRepr = t: assert isType t; t.repr;
  typeKind = t: assert isType t; t.kind;
  typeMeta = t: assert isType t; t.meta;
  typeId   = t: assert isType t; t.id;

  # ══ TypeIR 更新（保持 id 语义）════════════════════════════════════════
  withRepr = t: newRepr:
    assert isType t;
    mkTypeWith newRepr t.kind t.meta;

  withKind = t: newKind:
    assert isType t;
    mkTypeWith t.repr newKind t.meta;

  withMeta = t: newMeta:
    assert isType t;
    mkTypeWith t.repr t.kind newMeta;

  # ══ 常用原始类型 ════════════════════════════════════════════════════════
  tPrim = name:
    mkTypeDefault { __variant = "Primitive"; name = name; } KStar;

  tInt    = tPrim "Int";
  tBool   = tPrim "Bool";
  tString = tPrim "String";
  tFloat  = tPrim "Float";
  tUnit   = tPrim "Unit";

  # ══ TypeScheme（∀ quantification）════════════════════════════════════
  # TypeScheme = { __schemeTag; forall: [String]; body: Type; constraints: [Constraint] }
  # 不是 Type（不满足 INV-1），是 Type 的包装，用于泛化/实例化

  mkScheme = forall: body: constraints:
    {
      __schemeTag = "Scheme";
      forall      = lib.sort builtins.lessThan forall;
      body        = body;
      constraints = constraints;
    };

  monoScheme = t: mkScheme [] t [];

  isScheme = s:
    builtins.isAttrs s && (s.__schemeTag or null) == "Scheme";

  schemeForall = s: assert isScheme s; s.forall;
  schemeBody   = s: assert isScheme s; s.body;
  schemeCons   = s: assert isScheme s; s.constraints;

  # ── 自由变量提取（用于泛化）──────────────────────────────────────────
  freeVars = t:
    if !isType t then []
    else
      let v = t.repr.__variant or null; in
      if v == "Var" then [ t.repr.name ]
      else if v == "Lambda" then
        let inner = freeVars t.repr.body; in
        lib.filter (n: n != t.repr.param) inner
      else if v == "Apply" then
        let
          fnVars  = freeVars t.repr.fn;
          argVars = lib.concatMap freeVars (t.repr.args or []);
        in
        lib.unique (fnVars ++ argVars)
      else if v == "Fn" then
        lib.unique (freeVars t.repr.from ++ freeVars t.repr.to)
      else if v == "Constrained" then
        freeVars t.repr.base
      else if v == "Mu" then
        let inner = freeVars t.repr.body; in
        lib.filter (n: n != t.repr.var) inner
      else if v == "Forall" then
        let inner = freeVars t.repr.body; in
        lib.filter (n: !(builtins.elem n t.repr.vars)) inner
      else if v == "Record" then
        lib.unique (lib.concatMap freeVars (builtins.attrValues t.repr.fields))
      else if v == "RowExtend" then
        lib.unique (freeVars t.repr.ty ++ freeVars t.repr.tail)
      else if v == "VariantRow" then
        let
          varFvs  = lib.concatMap freeVars (builtins.attrValues t.repr.variants);
          tailFvs = if t.repr.tail != null then freeVars t.repr.tail else [];
        in
        lib.unique (varFvs ++ tailFvs)
      else [];
in
{
  inherit
  # ══ TypeIR 核心构造器 ══════════════════════════════════════════════════
  mkTypeWith
  mkTypeDefault
  # ══ TypeIR 谓词 ════════════════════════════════════════════════════════
  isType
  # ══ TypeIR 解构 ════════════════════════════════════════════════════════
  typeRepr
  typeKind
  typeMeta
  typeId
  # ══ TypeIR 更新（保持 id 语义）════════════════════════════════════════
  withRepr
  withKind
  withMeta
  # ══ 常用原始类型 ════════════════════════════════════════════════════════
  tPrim
  tInt
  tBool
  tString
  tFloat
  tUnit
  # ══ TypeScheme（∀ quantification）════════════════════════════════════
  mkScheme
  monoScheme
  isScheme
  schemeForall
  schemeBody
  schemeCons
  freeVars
  ;
}
