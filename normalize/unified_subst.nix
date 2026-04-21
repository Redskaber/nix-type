# normalize/unified_subst.nix — Phase 4.1
# UnifiedSubst：统一替换系统（type + row + kind）
# INV-US1: compose law 成立
# INV-US2: apply idempotent（apply ∘ apply = apply）
# INV-US3: 前缀不冲突（t: vs r: vs k:）
# INV-US4: fromLegacy 转换保持语义
# INV-US5: empty 是左右单位元
{ lib, typeLib, kindLib, reprLib, substLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault;
  inherit (kindLib) isKind;
  inherit (substLib) substitute applySubst freeVars;

  # ── 前缀常量（INV-US3）────────────────────────────────────────────────────
  TYPE_PREFIX = "t:";
  ROW_PREFIX  = "r:";
  KIND_PREFIX = "k:";

  # ── UnifiedSubst 构造器 ────────────────────────────────────────────────────
  # { typeBindings: "t:${name}" -> Type
  # , rowBindings:  "r:${name}" -> Type(Row)
  # , kindBindings: "k:${name}" -> Kind
  # }
  emptySubst = {
    typeBindings = {};
    rowBindings  = {};
    kindBindings = {};
  };

  mkSubst = typeB: rowB: kindB: {
    typeBindings = typeB;
    rowBindings  = rowB;
    kindBindings = kindB;
  };

  # ── 单条 binding 构造器 ───────────────────────────────────────────────────
  # Type: String -> Type -> UnifiedSubst
  singleTypeBinding = varName: ty:
    mkSubst { ${TYPE_PREFIX + varName} = ty; } {} {};

  singleRowBinding = rowVarName: rowTy:
    mkSubst {} { ${ROW_PREFIX + rowVarName} = rowTy; } {};

  singleKindBinding = kindVarName: k:
    mkSubst {} {} { ${KIND_PREFIX + kindVarName} = k; };

  # ── Subst 应用（apply type subst to Type）────────────────────────────────
  # INV-US1: applyTypeSubst(compose(s1,s2), t) = applyTypeSubst(s2, applyTypeSubst(s1, t))
  applyTypeSubst = subst: t:
    if !isType t then t
    else
      let
        # 从 typeBindings 提取 varName -> Type 映射
        typeB  = subst.typeBindings or {};
        tkeys  = builtins.attrNames typeB;
        # 去掉前缀 "t:"
        varMap = builtins.listToAttrs (map (k: {
          name  = builtins.substring (builtins.stringLength TYPE_PREFIX) (-1) k;
          value = typeB.${k};
        }) tkeys);
      in
      applySubst varMap t;

  # Row subst 应用
  applyRowSubst = subst: t:
    if !isType t then t
    else
      let
        rowB   = subst.rowBindings or {};
        rkeys  = builtins.attrNames rowB;
        varMap = builtins.listToAttrs (map (k: {
          name  = builtins.substring (builtins.stringLength ROW_PREFIX) (-1) k;
          value = rowB.${k};
        }) rkeys);
      in
      applySubst varMap t;

  # 完整 UnifiedSubst 应用（先 type，再 row）
  applyUnifiedSubst = subst: t:
    let
      t1 = applyTypeSubst subst t;
      t2 = applyRowSubst  subst t1;
    in t2;

  # ── Constraint 应用 ────────────────────────────────────────────────────────
  applySubstToType = subst: t: applyUnifiedSubst subst t;

  applySubstToConstraint = subst: c:
    let tag = c.__constraintTag or c.__tag or null; in
    if tag == "Equality" then
      c // { lhs = applySubstToType subst c.lhs;
             rhs = applySubstToType subst c.rhs; }
    else if tag == "Class" then
      c // { args = map (applySubstToType subst) (c.args or []); }
    else if tag == "Predicate" then
      c // { subject = applySubstToType subst (c.subject or c.arg); }
    else if tag == "RowEquality" then
      c // { lhsRow = applySubstToType subst c.lhsRow;
             rhsRow = applySubstToType subst c.rhsRow; }
    else if tag == "Implies" then
      c // { premises   = map (applySubstToConstraint subst) (c.premises or []);
             conclusion = applySubstToConstraint subst c.conclusion; }
    else if tag == "Refined" then
      c // { subject = applySubstToType subst c.subject; }
    else c;  # 未知 tag，原样返回

  applySubstToConstraints = subst: cs:
    map (applySubstToConstraint subst) cs;

  # ── Compose（INV-US1 核心）────────────────────────────────────────────────
  # compose(s1, s2).apply(t) = s2.apply(s1.apply(t))
  # 实现：s2 的 bindings 中对 value 应用 s1，再合并
  composeSubst = s1: s2:
    let
      # s2 中所有 type bindings 的 value，用 s1 替换
      s2TypeKeys = builtins.attrNames (s2.typeBindings or {});
      newTypeB   = builtins.listToAttrs (map (k: {
        name  = k;
        value = applyTypeSubst s1 s2.typeBindings.${k};
      }) s2TypeKeys);

      # s2 中所有 row bindings 的 value，用 s1 替换
      s2RowKeys = builtins.attrNames (s2.rowBindings or {});
      newRowB   = builtins.listToAttrs (map (k: {
        name  = k;
        value = applyRowSubst s1 s2.rowBindings.${k};
      }) s2RowKeys);

      # s2 kind bindings（kind subst 独立，不互相依赖）
      newKindB = s2.kindBindings or {};

      # 合并：s2 优先（s2 的 binding 覆盖 s1 中相同 key）
      mergedTypeB = (s1.typeBindings or {}) // newTypeB;
      mergedRowB  = (s1.rowBindings  or {}) // newRowB;
      mergedKindB = (s1.kindBindings or {}) // newKindB;
    in
    mkSubst mergedTypeB mergedRowB mergedKindB;

  # ── Legacy 转换（从旧格式迁移）───────────────────────────────────────────
  # INV-US4: 语义保持

  # 从 AttrSet(String -> Type) 转为 UnifiedSubst（类型替换部分）
  fromLegacyTypeSubst = legacySubst:
    let
      keys     = builtins.attrNames legacySubst;
      typeB    = builtins.listToAttrs (map (k: {
        name  = TYPE_PREFIX + k;
        value = legacySubst.${k};
      }) keys);
    in mkSubst typeB {} {};

  # 从 AttrSet(String -> Type) 转为 UnifiedSubst（行替换部分）
  fromLegacyRowSubst = legacyRowSubst:
    let
      keys  = builtins.attrNames legacyRowSubst;
      rowB  = builtins.listToAttrs (map (k: {
        name  = ROW_PREFIX + k;
        value = legacyRowSubst.${k};
      }) keys);
    in mkSubst {} rowB {};

  # 提取 type bindings 为旧格式（向后兼容）
  toLegacyTypeSubst = subst:
    let
      typeB = subst.typeBindings or {};
      keys  = builtins.attrNames typeB;
    in
    builtins.listToAttrs (map (k: {
      name  = builtins.substring (builtins.stringLength TYPE_PREFIX) (-1) k;
      value = typeB.${k};
    }) keys);

  toLegacyRowSubst = subst:
    let
      rowB  = subst.rowBindings or {};
      keys  = builtins.attrNames rowB;
    in
    builtins.listToAttrs (map (k: {
      name  = builtins.substring (builtins.stringLength ROW_PREFIX) (-1) k;
      value = rowB.${k};
    }) keys);

  # ── Subst 查询 ────────────────────────────────────────────────────────────
  lookupType = subst: varName:
    let k = TYPE_PREFIX + varName; in
    if subst.typeBindings ? ${k} then subst.typeBindings.${k} else null;

  lookupRow = subst: rowVarName:
    let k = ROW_PREFIX + rowVarName; in
    if subst.rowBindings ? ${k} then subst.rowBindings.${k} else null;

  # ── Subst 元信息 ──────────────────────────────────────────────────────────
  isEmptySubst = subst:
    builtins.attrNames (subst.typeBindings or {}) == [] &&
    builtins.attrNames (subst.rowBindings  or {}) == [] &&
    builtins.attrNames (subst.kindBindings or {}) == [];

  substSize = subst:
    builtins.length (builtins.attrNames (subst.typeBindings or {})) +
    builtins.length (builtins.attrNames (subst.rowBindings  or {})) +
    builtins.length (builtins.attrNames (subst.kindBindings or {}));

  # ── Phase 4.1: QueryKey schema validation ────────────────────────────────
  # INV-QK-SCHEMA: 所有 key 通过 mkQueryKey 构造，格式固定
  validSubstKeyPrefixes = [ TYPE_PREFIX ROW_PREFIX KIND_PREFIX ];

  validateSubstKey = key:
    lib.any (pfx: lib.hasPrefix pfx key) validSubstKeyPrefixes;

in {
  inherit emptySubst mkSubst
          singleTypeBinding singleRowBinding singleKindBinding
          applyTypeSubst applyRowSubst applyUnifiedSubst
          applySubstToType applySubstToConstraint applySubstToConstraints
          composeSubst
          fromLegacyTypeSubst fromLegacyRowSubst
          toLegacyTypeSubst toLegacyRowSubst
          lookupType lookupRow
          isEmptySubst substSize
          validateSubstKey;
}
