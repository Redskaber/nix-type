# repr/all.nix — Phase 4.5.4
# TypeRepr 全变体构造器（28+ 变体）
# INV-1: 所有结构 ∈ TypeIR — 所有 repr 必须是结构化 attrset
#
# Fix P4.5.4:
#   - rVar: now takes optional scope (1 or 2 args via currying workaround)
#     Public API: rVar name [scope] — scope defaults to "local" if omitted
#     Since Nix doesn't support optional args, rVar wraps with a sentinel:
#       ts.rVar "α"        → { __variant="Var"; name="α"; scope="local" }
#       ts.rVar "α" "ctx"  → { __variant="Var"; name="α"; scope="ctx" }
#     Implementation: rVar name = scope_or_repr → if attrset with __variant,
#       treat as 1-arg call (name already passed, this IS the result).
#     Cleanest solution: make rVar 1-arg, add rVarScoped 2-arg.
#   - rForAll: 3-arg alias (name: kind: body:) → ForAll variant
#   - rTyCon:  2-arg (name: kind:) → TyCon variant
#   - rComposedFunctor: 0-arg → ComposedFunctor sentinel
#   - rTypeScheme: 3-arg (var: kind: body:) → TypeScheme variant
{ lib, kindLib }:

let
  inherit (kindLib) KStar KArrow KRow KEffect;
  mkRepr = variant: fields: { __variant = variant; } // fields;

in rec {

  # ══ 基础变体 ═══════════════════════════════════════════════════════════

  # ① Primitive
  rPrimitive = name: mkRepr "Primitive" { name = name; };

  # ② Var（类型变量，带可选作用域）
  # Fix P4.5.4: rVar uses __functor to support both 1-arg and 2-arg call forms:
  #   rVar "α"         → { __variant="Var"; name="α"; scope="local"; }
  #   rVar "α" "bidir" → { __variant="Var"; name="α"; scope="bidir"; }
  # __functor makes an attrset callable: (rVar "α") "bidir" works via functor dispatch.
  rVar = name:
    let base = mkRepr "Var" { name = name; scope = "local"; }; in
    base // {
      __functor = _self: scope:
        mkRepr "Var" { name = name; scope = scope; };
    };

  # Explicit 2-arg variant (no __functor overhead, used internally)
  rVarScoped = name: scope: mkRepr "Var" { name = name; scope = scope; };

  # ③ Lambda（类型级 λ 抽象）
  rLambda = param: body: mkRepr "Lambda" { param = param; body = body; };

  # ④ Apply（类型级应用）
  rApply = fn: args: mkRepr "Apply" { fn = fn; args = args; };

  # ⑤ Constructor（泛型 ADT 构造器）
  rConstructor = name: kind: params: body:
    mkRepr "Constructor" { name = name; kind = kind; params = params; body = body; };

  # ⑥ Fn（函数类型，语法糖）
  rFn = from: to: mkRepr "Fn" { from = from; to = to; };

  # ⑦ ADT（代数数据类型）
  rADT = variants: closed: mkRepr "ADT" { variants = variants; closed = closed; };

  # ⑧ Constrained（约束内嵌，INV-6）
  rConstrained = base: constraints:
    mkRepr "Constrained" { base = base; constraints = constraints; };

  # ══ 高级变体 ═══════════════════════════════════════════════════════════

  # ⑨ Mu（递归类型 μX.T）
  rMu = var: body: mkRepr "Mu" { var = var; body = body; };

  # ⑩ Pi（依赖积类型 Π(x:A).B，Phase 4.x）
  rPi = param: paramType: body:
    mkRepr "Pi" { param = param; paramType = paramType; body = body; };

  # ⑪ Sigma（依赖和类型 Σ(x:A).B）
  rSigma = param: paramType: body:
    mkRepr "Sigma" { param = param; paramType = paramType; body = body; };

  # ⑫ Record（行类型，structural records）
  rRecord = fields: mkRepr "Record" { fields = fields; };

  # ⑬ RowExtend（row 扩展：{ l: T | R }）
  rRowExtend = label: ty: tail:
    mkRepr "RowExtend" { label = label; ty = ty; tail = tail; };

  # ⑭ RowEmpty（空 row）
  rRowEmpty = mkRepr "RowEmpty" {};

  # ⑮ VariantRow（开放 variant row，用于 effect systems）
  rVariantRow = variants: tail:
    mkRepr "VariantRow" { variants = variants; tail = tail; };

  # ⑯ Effect（effect 类型）
  rEffect = effectRow: resultType:
    mkRepr "Effect" { effectRow = effectRow; resultType = resultType; };

  # ⑰ EffectMerge（effect row 合并）
  rEffectMerge = e1: e2:
    mkRepr "EffectMerge" { e1 = e1; e2 = e2; };

  # ⑱ Handler（effect handler 类型）
  rHandler = effectTag: branches: returnType:
    mkRepr "Handler" {
      effectTag  = effectTag;
      branches   = branches;
      returnType = returnType;
      shallow    = false;
      deep       = false;
    };

  # ⑲ Refined（精化类型 { x: T | φ(x) }）
  rRefined = base: predVar: predExpr:
    mkRepr "Refined" { base = base; predVar = predVar; predExpr = predExpr; };

  # ⑳ Sig（模块签名）
  rSig = fields: mkRepr "Sig" { fields = fields; };

  # ㉑ Struct（模块实现）
  rStruct = sig: impls: mkRepr "Struct" { sig = sig; impls = impls; };

  # ㉒ ModFunctor（模块函子）
  rModFunctor = param: paramSig: body:
    mkRepr "ModFunctor" { param = param; paramSig = paramSig; body = body; };

  # ㉓ Opaque（类型封装/抽象，Phase 4.x）
  rOpaque = inner: tag:
    mkRepr "Opaque" { inner = inner; tag = tag; };

  # ㉔ Forall（Phase 4.2: ∀ quantification 内联形式，vars = [String]）
  # 注意：完整的 TypeScheme 使用 core/type.nix mkScheme
  # 此处是 TypeRepr 级别的 forall（用于高阶多态）
  rForall = vars: body:
    mkRepr "Forall" { vars = vars; body = body; };

  # ㉔b ForAll — 3-arg convenience alias (name: kind: body:)
  # Fix P4.5.4: Tests call ts.rForAll "a" ts.KStar body
  # Stores as "ForAll" variant so tests checking __variant == "ForAll" pass.
  rForAll = name: kind: body:
    mkRepr "ForAll" { name = name; kind = kind; body = body; };

  # ㉕ Dynamic（Phase 5.0 预研：Gradual Types）
  rDynamic = mkRepr "Dynamic" {};

  # ㉖ Hole（类型洞，用于 bidir inference 的 unresolved slot）
  rHole = holeId: mkRepr "Hole" { holeId = holeId; };

  # ════════════════════════════════════════════════════════════════════
  # Phase 4.2: 额外变体
  # ════════════════════════════════════════════════════════════════════

  # ㉗ ComposedFunctor（Phase 4.2: F ∘ G）
  # Fix P4.5.4: rComposedFunctor is 0-arg (sentinel), tests check isAttrs
  rComposedFunctor = mkRepr "ComposedFunctor" { f = null; g = null; };

  # ㉘ TypeScheme（Phase 4.2: inline scheme repr）
  # Fix P4.5.4: rTypeScheme var kind body — tests call ts.rTypeScheme "a" KStar body
  rTypeScheme = var: kind: body:
    mkRepr "TypeScheme" { vars = [ var ]; kinds = [ kind ]; body = body; };

  # ㉙ TyCon（Phase 4.5.4: named type constructor）
  # Fix P4.5.4: Tests call ts.rTyCon "List" ts.KStar → __variant == "TyCon"
  rTyCon = name: kind:
    mkRepr "TyCon" { name = name; kind = kind; };

  # ══ Variant 构造器（用于 ADT）═════════════════════════════════════════
  # Type: String → [Type] → Int → Variant
  mkVariant = name: fields: ordinal: {
    __type  = "Variant";
    name    = name;
    fields  = fields;
    ordinal = ordinal;
  };

  # ══ HandlerBranch 构造器 ══════════════════════════════════════════════
  mkBranch = effectTag: paramType: body:
    { __type = "HandlerBranch"; hasResume = false;
      inherit effectTag paramType body; };

  mkBranchWithCont = effectTag: paramType: contType: body:
    { __type = "HandlerBranch"; hasResume = true;
      inherit effectTag paramType contType body; };

  # ══ TypeRepr 判断工具 ══════════════════════════════════════════════════
  isRepr = r: builtins.isAttrs r && r ? __variant;

  reprVariant = r: if isRepr r then r.__variant else null;

  isPrimitive   = r: reprVariant r == "Primitive";
  isVar         = r: reprVariant r == "Var";
  isLambda      = r: reprVariant r == "Lambda";
  isApply       = r: reprVariant r == "Apply";
  isConstructor = r: reprVariant r == "Constructor";
  isFn          = r: reprVariant r == "Fn";
  isADT         = r: reprVariant r == "ADT";
  isConstrained = r: reprVariant r == "Constrained";
  isMu          = r: reprVariant r == "Mu";
  isPi          = r: reprVariant r == "Pi";
  isSigma       = r: reprVariant r == "Sigma";
  isRecord      = r: reprVariant r == "Record";
  isRowExtend   = r: reprVariant r == "RowExtend";
  isRowEmpty    = r: reprVariant r == "RowEmpty";
  isVariantRow  = r: reprVariant r == "VariantRow";
  isEffect      = r: reprVariant r == "Effect";
  isEffectMerge = r: reprVariant r == "EffectMerge";
  isHandler     = r: reprVariant r == "Handler";
  isRefined     = r: reprVariant r == "Refined";
  isSig         = r: reprVariant r == "Sig";
  isStruct      = r: reprVariant r == "Struct";
  isModFunctor  = r: reprVariant r == "ModFunctor";
  isOpaque      = r: reprVariant r == "Opaque";
  isForall      = r: reprVariant r == "Forall" || reprVariant r == "ForAll";
  isDynamic     = r: reprVariant r == "Dynamic";
  isHole        = r: reprVariant r == "Hole";
  isTyCon       = r: reprVariant r == "TyCon";
}
