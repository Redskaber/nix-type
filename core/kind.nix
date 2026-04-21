# core/kind.nix — Phase 3
# Kind 系统（Phase 3 扩展：KRow, KEffect, 完全纯函数 kindUnify）
#
# Phase 3 新增：
#   KRow   — Row kind（支持 Row Polymorphism 的 kind 层）
#   KEffect — Effect kind（Effect System 准备）
#   kindUnify — 完全纯函数，无 mutation（INV-K4 强化）
#   kindSubst — Kind 层变量替换
#   kindNormalize — Kind NF（消除 KVar 链）
#
# 不变量：
#   INV-K1: kindCheck(t) = KStar → t 是值类型
#   INV-K2: kindCheck(t) = KArrow(a,b) → t 是类型构造器
#   INV-K3: KUnbound 仅出现在推断过程中，最终结果不含 KUnbound
#   INV-K4: kindUnify 纯函数，不 mutate（Phase 2 修复，Phase 3 强化）
#   INV-K5: kindNormalize 消除所有 KVar 链（chase）
#   INV-K6: KRow / KEffect 扩展不破坏 KStar/KArrow 不变量
{ lib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 构造器（完整变体集）
  # ══════════════════════════════════════════════════════════════════════════════

  # Kind: * — 具体类型（值类型）
  KStar = { __kindVariant = "KStar"; };

  # Kind: k₁ → k₂ — 类型构造器 kind
  # Type: Kind -> Kind -> Kind
  KArrow = from: to: { __kindVariant = "KArrow"; inherit from to; };

  # Kind: 行类型 kind（Row Polymorphism 专用）
  # Row :: KRow，Record :: KRow → KStar
  KRow = { __kindVariant = "KRow"; };

  # Kind: Effect kind（Phase 3 Effect System 准备）
  # Effect :: KEffect，Eff :: KEffect → KStar → KStar
  KEffect = { __kindVariant = "KEffect"; };

  # Kind: 类型变量（推断过程中的占位符）
  # Type: String -> Kind
  KVar = name: { __kindVariant = "KVar"; inherit name; };

  # Kind: 未绑定（待推断，构造时默认）
  KUnbound = { __kindVariant = "KUnbound"; };

  # Kind: 错误（kind 检查失败）
  # Type: String -> Kind
  KError = message: { __kindVariant = "KError"; inherit message; };

  # ── 常用 Kind 别名 ────────────────────────────────────────────────────────

  # * → *（Functor, Maybe, List...）
  KStar1 = KArrow KStar KStar;

  # * → * → *（Either, Pair...）
  KStar2 = KArrow KStar (KArrow KStar KStar);

  # (* → *) → *（Higher-Order 1）
  KHO1   = KArrow (KArrow KStar KStar) KStar;

  # KRow → *（Record 构造器）
  KRowToStar = KArrow KRow KStar;

  # KEffect → * → *（Eff 类型构造器）
  KEffToStarToStar = KArrow KEffect (KArrow KStar KStar);

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 判断函数
  # ══════════════════════════════════════════════════════════════════════════════

  isKind    = k: builtins.isAttrs k && k ? __kindVariant;
  isStar    = k: isKind k && k.__kindVariant == "KStar";
  isArrow   = k: isKind k && k.__kindVariant == "KArrow";
  isRow     = k: isKind k && k.__kindVariant == "KRow";
  isEffect  = k: isKind k && k.__kindVariant == "KEffect";
  isKVar    = k: isKind k && k.__kindVariant == "KVar";
  isUnbound = k: isKind k && k.__kindVariant == "KUnbound";
  isKError  = k: isKind k && k.__kindVariant == "KError";

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 序列化（用于 hash + equality）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Kind -> String（确定性序列化）
  serializeKind = k:
    let v = k.__kindVariant or null; in
    if      v == "KStar"    then "*"
    else if v == "KArrow"   then "(${serializeKind k.from}->${serializeKind k.to})"
    else if v == "KRow"     then "#row"
    else if v == "KEffect"  then "#eff"
    else if v == "KVar"     then "?K${k.name}"
    else if v == "KUnbound" then "_K"
    else if v == "KError"   then "!K(${k.message or "?"})"
    else "?kind";

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 等价性（结构相等，消除 KVar）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Kind -> Kind -> Bool（纯函数，INV-K4）
  kindEq = a: b:
    let
      va = a.__kindVariant or null;
      vb = b.__kindVariant or null;
    in
    if va != vb then false
    else if va == "KStar"   then true
    else if va == "KRow"    then true
    else if va == "KEffect" then true
    else if va == "KUnbound" then true  # unbound = 任意（待推断）
    else if va == "KArrow"  then kindEq a.from b.from && kindEq a.to b.to
    else if va == "KVar"    then a.name == b.name
    else if va == "KError"  then a.message == b.message
    else false;

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 变量替换（KSubst）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet String Kind -> Kind -> Kind
  kindSubst = subst: k:
    let v = k.__kindVariant or null; in
    if      v == "KStar"    then k
    else if v == "KRow"     then k
    else if v == "KEffect"  then k
    else if v == "KUnbound" then k
    else if v == "KError"   then k
    else if v == "KVar"     then subst.${k.name} or k
    else if v == "KArrow"   then
      KArrow (kindSubst subst k.from) (kindSubst subst k.to)
    else k;

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind Unification（纯函数，返回 substitution，INV-K4）
  # ══════════════════════════════════════════════════════════════════════════════

  # 结果类型：{ ok: Bool; subst: AttrSet; error: String? }
  # Type: AttrSet -> Kind -> Kind -> { ok: Bool; subst: AttrSet; error?: String }
  kindUnify = subst: a: b:
    let
      # 先 chase（消除 KVar 链）
      a' = kindNormalize subst a;
      b' = kindNormalize subst b;
      va = a'.__kindVariant or null;
      vb = b'.__kindVariant or null;
    in

    # 完全相等
    if kindEq a' b' then { ok = true; subst = subst; }

    # KVar(n) ~ b：绑定 n → b（occur check）
    else if va == "KVar" then
      if _kindOccurs a'.name b'
      then { ok = false; subst = subst; error = "Kind occur check: ${a'.name} in ${serializeKind b'}"; }
      else { ok = true; subst = subst // { ${a'.name} = b'; }; }

    # a ~ KVar(n)：对称
    else if vb == "KVar" then
      if _kindOccurs b'.name a'
      then { ok = false; subst = subst; error = "Kind occur check: ${b'.name} in ${serializeKind a'}"; }
      else { ok = true; subst = subst // { ${b'.name} = a'; }; }

    # KUnbound ~ k：unbound 接受任意
    else if va == "KUnbound" then { ok = true; subst = subst; }
    else if vb == "KUnbound" then { ok = true; subst = subst; }

    # KArrow ~ KArrow：结构递归统一
    else if va == "KArrow" && vb == "KArrow" then
      let r1 = kindUnify subst a'.from b'.from; in
      if !r1.ok
      then r1
      else kindUnify r1.subst a'.to b'.to

    # 失败
    else {
      ok    = false;
      subst = subst;
      error = "Kind mismatch: ${serializeKind a'} vs ${serializeKind b'}";
    };

  # ── Occur Check（防止无限 Kind）─────────────────────────────────────────
  _kindOccurs = name: k:
    let v = k.__kindVariant or null; in
    if v == "KVar"   then k.name == name
    else if v == "KArrow" then _kindOccurs name k.from || _kindOccurs name k.to
    else false;

  # ── KVar 链 Chase（normalize KVar bindings）──────────────────────────────
  # Type: AttrSet -> Kind -> Kind
  kindNormalize = subst: k:
    let v = k.__kindVariant or null; in
    if v == "KVar" then
      let bound = subst.${k.name} or null; in
      if bound != null && !kindEq bound k
      then kindNormalize subst bound
      else k
    else if v == "KArrow" then
      KArrow (kindNormalize subst k.from) (kindNormalize subst k.to)
    else k;

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 推断（从 TypeRepr 结构推断 Kind）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: TypeRepr -> Kind（结构性推断，不依赖 typeLib 避免循环）
  kindInferRepr = repr:
    let v = repr.__variant or repr.__kindVariant or null; in

    # Kind 变体直接返回自身 kind（Kind 的 kind 是 Kind — 自指）
    if v == "KStar" || v == "KArrow" || v == "KRow" || v == "KEffect"
      || v == "KVar" || v == "KUnbound" || v == "KError"
    then KStar  # Kind :: KStar（kind-of-kind = KStar by convention）

    else if v == "Primitive" then KStar

    else if v == "Var" then KUnbound  # 待推断

    else if v == "Lambda" then
      # λ(x:k₁). body : k₁ → kindOf(body)
      KArrow KUnbound (kindInferRepr repr.body.repr)

    else if v == "Apply" then
      # fn : k₁ → k₂，结果 : k₂
      let fk = kindInferRepr repr.fn.repr; in
      if fk.__kindVariant or null == "KArrow"
      then fk.to
      else KUnbound

    else if v == "Fn" then KStar  # A → B :: *

    else if v == "Constructor" then repr.kind or KUnbound

    else if v == "ADT" then KStar

    else if v == "Constrained" then kindInferRepr repr.base.repr

    else if v == "Mu" then KStar  # μ(x.T) :: *（equi-recursive value type）

    else if v == "Record" then KStar  # {f:T,...} :: *

    else if v == "VariantRow" then KStar  # variant row :: *

    else if v == "RowExtend" then KRow   # row extension :: KRow

    else if v == "RowEmpty" then KRow    # ∅ :: KRow

    else if v == "Effect" then KEffect   # Phase 3: Effect :: KEffect

    else if v == "Pi" then KStar         # Phase 3: Π(x:A).B :: *

    else KUnbound;

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind 检查（verify Type has expected Kind）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Kind -> { ok: Bool; error?: String }
  kindCheck = t: expectedKind:
    let
      actualKind = t.kind or KUnbound;
      v = actualKind.__kindVariant or null;
    in
    if v == "KUnbound" then
      # unbound → 接受（待后续推断）
      { ok = true; }
    else if v == "KError" then
      { ok = false; error = "KError: ${actualKind.message or "?"}"; }
    else
      let unified = kindUnify {} actualKind expectedKind; in
      if unified.ok
      then { ok = true; }
      else { ok = false; error = "Kind check failed: expected ${serializeKind expectedKind}, got ${serializeKind actualKind}. ${unified.error or ""}"; };

}
