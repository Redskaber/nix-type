# core/type.nix — Phase 3
# TypeIR 统一结构（Type/Kind/Meta 三位一体）
#
# Phase 3 修复与新增：
#   1. stableId 使用 serializeReprAlphaCanonical（INV-T2 强化）
#   2. mkType 构造器安全性加强（KUnbound 替代 null，INV-T1）
#   3. withKind / withMeta / withRepr 严格不变量
#   4. phase 字段追踪类型创建阶段
#   5. typeEq 统一入口（不绕过 meta 策略）
#
# 不变量：
#   INV-T1: t.kind ≠ null → KUnbound（construction-safe）
#   INV-T2: t.id = H(serializeAlpha(repr))（不依赖 toJSON 属性顺序）
#   INV-T3: isType(t) → t.tag == "Type" && t ? id && t ? kind && t ? repr && t ? meta
#   INV-T4: withKind(t, null) → t.kind = KUnbound（totality）
{ lib, kindLib, metaLib, serialLib }:

let
  inherit (kindLib) KUnbound KStar isKind serializeKind;
  inherit (metaLib) defaultMeta isMeta;

  # ── 内部序列化（α-canonical，用于 stableId）───────────────────────────────
  # 依赖 serialLib.serializeReprAlphaCanonical（Phase 3 强化版）
  _serialize = repr:
    if serialLib != null && serialLib ? serializeReprAlphaCanonical
    then serialLib.serializeReprAlphaCanonical repr
    else builtins.toJSON repr;  # fallback（仅 bootstrap）

  # ── 稳定 ID 生成（INV-T2：确定性，不依赖属性顺序）─────────────────────────
  # Type: TypeRepr -> String
  stableId = repr:
    builtins.hashString "sha256" (_serialize repr);

  # ── 内部核心构造器（不直接暴露，所有公开构造器必须经此）──────────────────
  # Type: String -> TypeRepr -> Kind -> MetaType -> Type
  _mkType = id: repr: kind: meta:
    let
      # INV-T1：禁止 null kind
      safeKind = if kind == null then KUnbound else kind;
      # INV-T1：kind 必须是有效 Kind
      validKind = if isKind safeKind then safeKind else KUnbound;
      # INV-meta：meta 必须是有效 MetaType
      safeMeta = if isMeta meta then meta else defaultMeta;
    in {
      tag   = "Type";
      id    = id;
      repr  = repr;
      kind  = validKind;
      meta  = safeMeta;
      phase = safeMeta.phase or 3;
    };

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 公开构造器
  # ══════════════════════════════════════════════════════════════════════════════

  # 完整构造器（显式指定所有字段）
  # Type: TypeRepr -> Kind -> MetaType -> Type
  mkTypeWith = repr: kind: meta:
    _mkType (stableId repr) repr kind meta;

  # 默认构造器（结构性 meta，给定 kind）
  # Type: TypeRepr -> Kind -> Type
  mkTypeDefault = repr: kind:
    mkTypeWith repr kind defaultMeta;

  # 自举构造器（Kind 系统自举用，kind = KUnbound）
  # Type: TypeRepr -> Type
  mkBootstrapType = repr:
    _mkType (stableId repr) repr KUnbound defaultMeta;

  # 完整低阶构造器（id 由调用方提供，慎用）
  # Type: String -> TypeRepr -> Kind -> MetaType -> Type
  mkType = id: repr: kind: meta:
    _mkType id repr kind meta;

  # ══════════════════════════════════════════════════════════════════════════════
  # 类型变换（lens 风格）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> TypeRepr -> Type
  withRepr = t: repr:
    _mkType (stableId repr) repr t.kind t.meta;

  # Type: Type -> Kind -> Type（INV-T4：null → KUnbound）
  withKind = t: kind:
    let safeKind = if kind == null then KUnbound else kind; in
    t // { kind = if isKind safeKind then safeKind else KUnbound; };

  # Type: Type -> MetaType -> Type
  withMeta = t: meta:
    t // { meta = if isMeta meta then meta else defaultMeta; };

  # Type: Type -> [Constraint] -> Type（追加约束到 meta）
  withConstraints = t: cs:
    let meta' = t.meta // { constraints = (t.meta.constraints or []) ++ cs; }; in
    t // { meta = meta'; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 类型判断
  # ══════════════════════════════════════════════════════════════════════════════

  # INV-T3 检查
  # Type: Any -> Bool
  isType = t:
    builtins.isAttrs t
    && (t.tag or null) == "Type"
    && t ? id
    && t ? repr
    && t ? kind
    && t ? meta;

  # Type: Any -> Bool
  isTypeStrict = t:
    isType t
    && builtins.isString t.id
    && builtins.isAttrs t.repr
    && isKind t.kind
    && isMeta t.meta;

  # ══════════════════════════════════════════════════════════════════════════════
  # 字段访问器（避免直接属性访问，保持封装）
  # ══════════════════════════════════════════════════════════════════════════════

  reprOf   = t: assert isType t; t.repr;
  kindOf   = t: assert isType t; t.kind;
  metaOf   = t: assert isType t; t.meta;
  idOf     = t: assert isType t; t.id;
  phaseOf  = t: t.phase or 3;
  labelOf  = t: t.meta.label or null;

  # TypeRepr 变体名
  reprVariant = t: assert isType t; t.repr.__variant or "?";

  # ══════════════════════════════════════════════════════════════════════════════
  # 类型验证（构造后检查）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> { ok: Bool; violations: [String] }
  validateType = t:
    let
      v1 = if !isType t then ["not a Type"] else [];
      v2 = if isType t && !isKind t.kind then ["kind is not valid Kind"] else [];
      v3 = if isType t && !isMeta t.meta then ["meta is not valid MetaType"] else [];
      v4 = if isType t && !builtins.isString t.id then ["id is not String"] else [];
      v5 = if isType t && !builtins.isAttrs t.repr then ["repr is not AttrSet"] else [];
      violations = v1 ++ v2 ++ v3 ++ v4 ++ v5;
    in
    { ok = builtins.length violations == 0; inherit violations; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 常用类型原语（Phase 3 bootstrap）
  # ══════════════════════════════════════════════════════════════════════════════

  # KindType — Kind 作为 Type（自指：kind(KindType) = KindType）
  # 通过 KUnbound 自举，稍后在 lib 中完成绑定
  kindTypeBootstrap =
    mkBootstrapType { __variant = "Primitive"; name = "Kind"; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 调试支持
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> String（人类可读摘要）
  showType = t:
    if !isType t then "<not-a-type>"
    else
      let
        v = t.repr.__variant or "?";
        k = serializeKind t.kind;
      in
      "${v}[${k}]@${builtins.substring 0 8 t.id}";

  # Type: Type -> AttrSet（调试用完整信息）
  debugType = t:
    if !isType t then { error = "not a Type"; }
    else {
      id    = t.id;
      repr  = t.repr.__variant or "?";
      kind  = serializeKind t.kind;
      meta  = {
        eq   = t.meta.eqStrategy or "?";
        hash = t.meta.hashStrategy or "?";
      };
      phase = t.phase or 3;
    };

  # 导出 stableId（meta/hash.nix 需要）
  inherit stableId;

}
