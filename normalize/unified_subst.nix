# normalize/unified_subst.nix — Phase 4.2
# UnifiedSubst: type + row + kind 统一替换
# INV-US1: compose law (f ∘ g)(x) = f(g(x))
# INV-US3: 键前缀不冲突 t:/r:/k:
{ lib, typeLib, reprLib, kindLib, substLib }:

let
  inherit (typeLib) isType mkTypeWith;
  inherit (kindLib) applyKindSubst;
  inherit (substLib) substitute applyUnifiedSubst;

in rec {

  # ══ UnifiedSubst 构造器 ════════════════════════════════════════════════
  # { typeBindings: {name → Type}; rowBindings: {name → Type}; kindBindings: {name → Kind} }

  emptySubst = {
    typeBindings = {};
    rowBindings  = {};
    kindBindings = {};
  };

  # Type: String → Type → UnifiedSubst
  singleTypeBinding = name: t:
    emptySubst // { typeBindings = { ${name} = t; }; };

  # Type: String → Type → UnifiedSubst
  singleRowBinding = name: r:
    emptySubst // { rowBindings = { ${name} = r; }; };

  # Type: String → Kind → UnifiedSubst
  singleKindBinding = name: k:
    emptySubst // { kindBindings = { ${name} = k; }; };

  # ══ Subst 判断 ═════════════════════════════════════════════════════════
  isSubst = s:
    builtins.isAttrs s &&
    s ? typeBindings && s ? rowBindings && s ? kindBindings;

  isEmpty = s:
    isSubst s &&
    builtins.attrNames s.typeBindings == [] &&
    builtins.attrNames s.rowBindings  == [] &&
    builtins.attrNames s.kindBindings == [];

  # ══ Subst 组合（INV-US1: compose law）════════════════════════════════
  # composeSubst f g: 先应用 g，再应用 f
  # (f ∘ g)(t) = f(g(t))
  composeSubst = f: g:
    let
      # 将 f 应用到 g 的 typeBindings 的每个值
      newTypeBindings =
        (builtins.mapAttrs (n: t:
          _applySubstToType f t
        ) g.typeBindings)
        //
        # f 中 g 没有的绑定保留
        (lib.filterAttrs (n: v: !(g.typeBindings ? ${n})) f.typeBindings);

      newRowBindings =
        (builtins.mapAttrs (n: r:
          _applySubstToType f r
        ) g.rowBindings)
        //
        (lib.filterAttrs (n: v: !(g.rowBindings ? ${n})) f.rowBindings);

      newKindBindings =
        (builtins.mapAttrs (n: k:
          applyKindSubst f.kindBindings k
        ) g.kindBindings)
        //
        (lib.filterAttrs (n: v: !(g.kindBindings ? ${n})) f.kindBindings);
    in
    {
      typeBindings = newTypeBindings;
      rowBindings  = newRowBindings;
      kindBindings = newKindBindings;
    };

  # ── 内部：将 subst 应用到 type ───────────────────────────────────────
  _applySubstToType = usubst: t:
    if !isType t then t
    else
      let
        # 先 apply typeBindings 中的绑定
        typeBindings = usubst.typeBindings or {};
        rowBindings  = usubst.rowBindings or {};
        v            = t.repr.__variant or null;
      in
      if v == "Var" then
        let bound = typeBindings.${t.repr.name} or null; in
        if bound != null then bound else t
      else
        # 递归 apply 到子项
        applyUnifiedSubst usubst t;

  # ══ Subst 应用（主 API）═══════════════════════════════════════════════
  # Type: UnifiedSubst → Type → Type
  applySubst = usubst: t:
    if isEmpty usubst then t
    else _applySubstToType usubst t;

  # ══ Constraint 上的 Subst 应用 ════════════════════════════════════════
  # Type: UnifiedSubst → Constraint → Constraint
  applySubstToConstraint = usubst: c:
    if !builtins.isAttrs c then c
    else
      let tag = c.__constraintTag or null; in
      if tag == "Equality" then
        c // { lhs = applySubst usubst c.lhs; rhs = applySubst usubst c.rhs; }
      else if tag == "Class" then
        c // { args = map (applySubst usubst) c.args; }
      else if tag == "RowEquality" then
        c // { lhsRow = applySubst usubst c.lhsRow; rhsRow = applySubst usubst c.rhsRow; }
      else if tag == "Predicate" then
        c // { subject = applySubst usubst c.subject; }
      else if tag == "Refined" then
        c // { subject = applySubst usubst c.subject; }
      else if tag == "Implies" then
        c // {
          premises   = map (applySubstToConstraint usubst) c.premises;
          conclusion = applySubstToConstraint usubst c.conclusion;
        }
      else c;

  # Type: UnifiedSubst → [Constraint] → [Constraint]
  applySubstToConstraints = usubst: cs:
    if isEmpty usubst then cs
    else map (applySubstToConstraint usubst) cs;

  # ══ Legacy compat（Phase 4.0 API）════════════════════════════════════
  # Type: {name→Type} → UnifiedSubst
  fromLegacyTypeSubst = ts:
    emptySubst // { typeBindings = ts; };

  # Type: {name→Type} → UnifiedSubst
  fromLegacyRowSubst = rs:
    emptySubst // { rowBindings = rs; };

  # ══ Subst 域（用于 occurs check）═════════════════════════════════════
  substDomain = s:
    builtins.attrNames s.typeBindings ++
    builtins.attrNames s.rowBindings ++
    builtins.attrNames s.kindBindings;

  # ══ Subst 上的 vars（值域的自由变量）════════════════════════════════
  substRange = s:
    let typeVars = lib.concatMap (typeLib.freeVars) (builtins.attrValues s.typeBindings);
        rowVars  = lib.concatMap (typeLib.freeVars) (builtins.attrValues s.rowBindings);
    in lib.unique (typeVars ++ rowVars);
}
