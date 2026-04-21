# core/type.nix — Phase 4.1
# 统一 Type 结构：三位一体 { id; kind; repr; meta }
# INV-1: 所有结构 ∈ TypeIR
# INV-4: id = Hash(serialize(NormalForm))（hash-consing）
{ lib, kindLib, metaLib }:

let
  # ── 内部序列化（用于 stable id 生成，不依赖 serialLib 避免循环）────────
  _serializeReprForId = repr:
    let v = repr.__variant or null; in
    # 最小序列化，仅用于 id 生成（canonical 是关键）
    if v == "Primitive" then "P:${repr.name}"
    else if v == "Var"  then "V:${repr.name}:${repr.scope or ""}"
    else if v == "Kind" then "K:${repr.form.tag or "?"}"
    else builtins.toJSON repr;

  # ── 内部构造器 ────────────────────────────────────────────────────────────
  # Type: String -> TypeRepr -> Kind -> MetaType -> Type
  mkType = id: repr: kind: meta: {
    __type = "Type";
    tag    = "Type";      # 向后兼容
    id     = id;          # canonical stable identity（hash-consing key）
    repr   = repr;        # TypeRepr — 语义核
    kind   = kind;        # Kind（Kind 本身也是 Type，自指）
    meta   = meta;        # MetaType — 控制语义行为
  };

  # stable id：基于 repr 的 sha256（构造顺序无关）
  # Type: TypeRepr -> String
  stableId = repr:
    builtins.hashString "sha256" (_serializeReprForId repr);

in rec {
  # ── 公开构造器 ────────────────────────────────────────────────────────────

  # Type: TypeRepr -> Kind -> MetaType -> Type
  mkTypeWith = repr: kind: meta:
    mkType (stableId repr) repr kind meta;

  # 使用默认 Meta（structural/normalized/lazy）
  # Type: TypeRepr -> Kind -> Type
  mkTypeDefault = repr: kind:
    mkTypeWith repr kind metaLib.defaultMeta;

  # Bootstrap 构造器（kind = null，用于 Kind 系统自举）
  # Type: TypeRepr -> Type
  mkBootstrapType = repr:
    mkType (stableId repr) repr null metaLib.defaultMeta;

  # ── 类型判断 ─────────────────────────────────────────────────────────────
  # Type: Any -> Bool
  isType = t:
    builtins.isAttrs t
      && (t.__type or t.tag or null) == "Type";

  # Type: Type -> String
  reprVariant = t:
    assert isType t;
    t.repr.__variant or "?";

  # ── 工具函数 ─────────────────────────────────────────────────────────────
  # Type: Type -> String (stable id，供外部使用)
  typeId = t:
    assert isType t; t.id;

  # Type: Type -> TypeRepr
  typeRepr = t:
    assert isType t; t.repr;

  # Type: Type -> Kind
  typeKind = t:
    assert isType t; t.kind;

  # Type: Type -> MetaType
  typeMeta = t:
    assert isType t; t.meta;

  # ── 类型更新（不可变 update）─────────────────────────────────────────────
  # Type: Type -> TypeRepr -> Type  (更新 repr，重新生成 id)
  withRepr = t: repr:
    mkTypeWith repr t.kind t.meta;

  # Type: Type -> Kind -> Type
  withKind = t: kind:
    mkType t.id t.repr kind t.meta;

  # Type: Type -> MetaType -> Type
  withMeta = t: meta:
    mkType t.id t.repr t.kind meta;

  # ── 导出 stableId（供 serialize 模块使用）────────────────────────────────
  inherit stableId;
}
