# core/type.nix — Phase 4.2
# TypeIR 统一宇宙：Type = { tag; id; kind; repr; meta }
# INV-1: 所有结构 ∈ TypeIR
{ lib, kindLib, metaLib }:

let
  inherit (kindLib) KStar KArrow isKind serializeKind;
  inherit (metaLib) defaultMeta isMeta;

  # ── 内部：stable id 生成 ─────────────────────────────────────────────
  # 使用 repr 的规范序列化作为 id 基础
  _reprToIdStr = repr:
    builtins.toJSON repr;

  _mkId = repr:
    builtins.hashString "sha256" (_reprToIdStr repr);

in rec {

  # ══ TypeIR 核心构造器 ══════════════════════════════════════════════════

  # Type: TypeRepr → Kind → Meta → Type
  # 完整构造（使用显式 meta）
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
  # 默认构造（使用 defaultMeta）
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
  # Type: Type → TypeRepr → Type（更新 repr，重新计算 id）
  withRepr = t: newRepr:
    assert isType t;
    mkTypeWith newRepr t.kind t.meta;

  # Type: Type → Kind → Type
  withKind = t: newKind:
    assert isType t;
    mkTypeWith t.repr newKind t.meta;

  # Type: Type → Meta → Type
  withMeta = t: newMeta:
    assert isType t;
    mkTypeWith t.repr t.kind newMeta;

  # ══ 常用原始类型（Phase 4.2 内建）════════════════════════════════════
  tPrim = name:
    mkTypeDefault { __variant = "Primitive"; name = name; } KStar;

  tInt    = tPrim "Int";
  tBool   = tPrim "Bool";
  tString = tPrim "String";
  tFloat  = tPrim "Float";
  tUnit   = tPrim "Unit";

  # ══ TypeScheme（Phase 4.2 新增：∀ quantification）════════════════════
  # TypeScheme = { __schemeTag; forall: [String]; body: Type; constraints: [Constraint] }
  # 不是 Type（不满足 INV-1），是 Type 的包装，用于泛化/实例化

  # Type: [String] → Type → [Constraint] → TypeScheme
  mkScheme = forall: body: constraints:
    {
      __schemeTag = "Scheme";
      forall      = lib.sort builtins.lessThan forall;  # canonical 顺序
      body        = body;
      constraints = constraints;
    };

  # 单态 scheme（forall []）
  monoScheme = t: mkScheme [] t [];

  isScheme = s:
    builtins.isAttrs s && (s.__schemeTag or null) == "Scheme";

  schemeForall = s: assert isScheme s; s.forall;
  schemeBody   = s: assert isScheme s; s.body;
  schemeCons   = s: assert isScheme s; s.constraints;

  # ── 自由变量提取（用于泛化）──────────────────────────────────────────
  # Type: Type → [String]
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
          fnVars = freeVars t.repr.fn;
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
      else [];
}
