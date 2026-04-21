# core/type.nix — Phase 3.1
# TypeIR 统一结构（Type/Kind/Meta 三位一体）
#
# Phase 3.1 强化：
#   INV-T1: t.kind ≠ null → KUnbound（construction-safe）
#   INV-T2: t.id = H(serializeAlpha(repr))（不依赖 toJSON）
#   INV-T3: isType 四字段必备
#   INV-T4: withKind(t, null) → KUnbound（totality）
#   新增：   mkTypeConstrained（内嵌约束）
#            withId（手动 id，用于 hash-consing）
#            TypeEnv（类型环境：变量名 → Type 映射）
{ lib, kindLib, metaLib, serialLib }:

let
  inherit (kindLib) KUnbound KStar isKind serializeKind kindNormalize;
  inherit (metaLib) defaultMeta isMeta;

  # α-canonical 序列化（INV-T2 依赖）
  _serialize = repr:
    if serialLib != null && serialLib ? serializeReprAlphaCanonical
    then serialLib.serializeReprAlphaCanonical repr
    else
      # bootstrap fallback：仅用于 serialLib 尚未加载时
      "bootstrap:${repr.__variant or "?"}";

  # stableId（INV-T2）
  stableId = repr:
    builtins.hashString "sha256" (_serialize repr);

  # 核心构造器（所有公开构造器必须经此）
  _mkType = id: repr: kind: meta:
    let
      safeKind = if kind == null then KUnbound
                 else if isKind kind then kind
                 else KUnbound;
      safeMeta = if isMeta meta then meta else defaultMeta;
    in {
      tag   = "Type";
      id    = id;
      repr  = repr;
      kind  = safeKind;
      meta  = safeMeta;
      phase = safeMeta.phase or 3;
    };

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 公开构造器
  # ══════════════════════════════════════════════════════════════════════════════

  # 完整构造器
  mkTypeWith = repr: kind: meta:
    _mkType (stableId repr) repr kind meta;

  # 默认 meta 构造器
  mkTypeDefault = repr: kind:
    mkTypeWith repr kind defaultMeta;

  # bootstrap 构造器（Kind 系统自举）
  mkBootstrapType = repr:
    _mkType (stableId repr) repr KUnbound defaultMeta;

  # 带约束构造器（INV-6：Constrained ∈ TypeRepr）
  mkTypeConstrained = repr: kind: constraints:
    let
      meta' = defaultMeta // { constraints = constraints; };
    in
    mkTypeWith repr kind meta';

  # 低阶构造器（id 由调用方提供，用于 hash-consing）
  mkType = id: repr: kind: meta:
    _mkType id repr kind meta;

  # ══════════════════════════════════════════════════════════════════════════════
  # Lens 风格类型变换
  # ══════════════════════════════════════════════════════════════════════════════

  # 修改 repr（重新计算 id）
  withRepr = t: repr:
    _mkType (stableId repr) repr t.kind t.meta;

  # 修改 kind（INV-T4：null → KUnbound）
  withKind = t: kind:
    let safeKind = if kind == null then KUnbound
                   else if isKind kind then kind
                   else KUnbound; in
    t // { kind = safeKind; };

  # 修改 meta
  withMeta = t: meta:
    t // { meta = if isMeta meta then meta else defaultMeta; };

  # 追加约束到 meta（不修改 repr）
  withConstraints = t: cs:
    let meta' = t.meta // { constraints = (t.meta.constraints or []) ++ cs; }; in
    t // { meta = meta'; };

  # 手动设置 id（用于 hash-consing，谨慎使用）
  withId = t: id:
    t // { id = id; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 类型判断
  # ══════════════════════════════════════════════════════════════════════════════

  # INV-T3
  isType = t:
    builtins.isAttrs t
    && (t.tag or null) == "Type"
    && t ? id
    && t ? repr
    && t ? kind
    && t ? meta;

  isTypeStrict = t:
    isType t
    && builtins.isString t.id
    && builtins.isAttrs t.repr
    && isKind t.kind
    && isMeta t.meta;

  # ══════════════════════════════════════════════════════════════════════════════
  # 访问器
  # ══════════════════════════════════════════════════════════════════════════════

  reprOf   = t: assert isType t; t.repr;
  kindOf   = t: assert isType t; t.kind;
  metaOf   = t: assert isType t; t.meta;
  idOf     = t: assert isType t; t.id;
  phaseOf  = t: t.phase or 3;
  labelOf  = t: t.meta.label or null;
  reprVariant = t: assert isType t; t.repr.__variant or "?";

  # ══════════════════════════════════════════════════════════════════════════════
  # TypeEnv（类型环境：变量名 → Type）
  # ══════════════════════════════════════════════════════════════════════════════

  emptyEnv = {};
  extendEnv = env: name: t: env // { ${name} = t; };
  lookupEnv = env: name: env.${name} or null;
  envNames  = env: builtins.attrNames env;

  # ══════════════════════════════════════════════════════════════════════════════
  # 验证
  # ══════════════════════════════════════════════════════════════════════════════

  validateType = t:
    let
      violations =
        (if !isType t      then ["not a Type"] else [])
        ++ (if isType t && !isKind t.kind   then ["kind is not valid Kind"] else [])
        ++ (if isType t && !isMeta t.meta   then ["meta is not valid MetaType"] else [])
        ++ (if isType t && !builtins.isString t.id  then ["id is not String"] else [])
        ++ (if isType t && !builtins.isAttrs t.repr then ["repr is not AttrSet"] else []);
    in
    { ok = builtins.length violations == 0; inherit violations; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 调试
  # ══════════════════════════════════════════════════════════════════════════════

  showType = t:
    if !isType t then "<not-a-type>"
    else
      "${t.repr.__variant or "?"}[${serializeKind t.kind}]@${builtins.substring 0 8 t.id}";

  debugType = t:
    if !isType t then { error = "not a Type"; }
    else {
      id      = t.id;
      repr    = t.repr.__variant or "?";
      kind    = serializeKind t.kind;
      phase   = t.phase or 3;
      meta    = { eq = t.meta.eqStrategy or "?"; hash = t.meta.hashStrategy or "?"; };
    };

  # bootstrap KindType（Kind 作为 Type 自举）
  kindTypeBootstrap =
    mkBootstrapType { __variant = "Primitive"; name = "Kind"; };

  inherit stableId;
}
