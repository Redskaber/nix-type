# constraint/ir.nix — Phase 4.1
# Constraint IR：INV-6 核心（Constraint ∈ TypeRepr，不是函数/runtime）
# 所有 Constraint 是结构化数据，可参与 normalize/hash/equality
{ lib, typeLib, reprLib, kindLib, serialLib }:

let
  inherit (typeLib) isType;
  inherit (serialLib) serializeRepr canonicalHash serializeConstraint;

in rec {
  # ══ Constraint 变体构造器 ══════════════════════════════════════════════════

  # ① Equality — 类型等价约束（a ≡ b）
  mkEqConstraint = lhs: rhs: {
    __constraintTag = "Equality";
    lhs = lhs;
    rhs = rhs;
  };

  # ② Class — typeclass 约束（C a₁ ... aₙ）
  mkClassConstraint = className: args: {
    __constraintTag = "Class";
    className = className;
    args = args;
  };

  # ③ Predicate — 谓词约束（P subject）
  mkPredConstraint = predName: subject: {
    __constraintTag = "Predicate";
    predName = predName;
    subject  = subject;
  };

  # ④ Implies — 蕴含约束（premises ⊢ conclusion）
  # premises 排序保证 canonical（INV-6）
  mkImpliesConstraint = premises: conclusion:
    let
      sorted = lib.sort
        (a: b: builtins.toJSON (serializeConstraint a) < builtins.toJSON (serializeConstraint b))
        premises;
    in
    { __constraintTag = "Implies";
      premises   = sorted;
      conclusion = conclusion; };

  # ⑤ RowEquality — 行等价约束（Phase 4.0）
  mkRowEqConstraint = lhsRow: rhsRow: {
    __constraintTag = "RowEquality";
    lhsRow = lhsRow;
    rhsRow = rhsRow;
  };

  # ⑥ Refined — 精化约束（Phase 4.0）
  # { n : T | φ(n) } subject 满足谓词 predExpr
  mkRefinedConstraint = subject: predVar: predExpr: {
    __constraintTag = "Refined";
    subject  = subject;
    predVar  = predVar;
    predExpr = predExpr;
  };

  # ══ Constraint 谓词 ════════════════════════════════════════════════════════
  isConstraint     = c: builtins.isAttrs c && c ? __constraintTag;
  isEqConstraint   = c: isConstraint c && c.__constraintTag == "Equality";
  isClassConstraint = c: isConstraint c && c.__constraintTag == "Class";
  isPredConstraint = c: isConstraint c && c.__constraintTag == "Predicate";
  isImplies        = c: isConstraint c && c.__constraintTag == "Implies";
  isRowEq          = c: isConstraint c && c.__constraintTag == "RowEquality";
  isRefinedC       = c: isConstraint c && c.__constraintTag == "Refined";

  # ══ Canonical key（INV-4 on Constraints）══════════════════════════════════
  # Type: Constraint -> String
  constraintKey = c:
    builtins.hashString "sha256"
      (builtins.toJSON (serializeConstraint c));

  # ══ Constraint 规范化（structural canonical form）═════════════════════════
  # Type: Constraint -> Constraint
  normalizeConstraint = c:
    let tag = c.__constraintTag or null; in
    if tag == "Equality" then
      # 规范化：lhs.id <= rhs.id（对称性）
      let
        hA = canonicalHash c.lhs.repr;
        hB = canonicalHash c.rhs.repr;
      in
      if hA <= hB
      then mkEqConstraint c.lhs c.rhs
      else mkEqConstraint c.rhs c.lhs
    else if tag == "Class" then
      mkClassConstraint c.className (c.args or [])
    else if tag == "Predicate" then
      mkPredConstraint (c.predName or c.fn or "?") (c.subject or c.arg)
    else if tag == "Implies" then
      let
        normPremises = map normalizeConstraint (c.premises or []);
        sorted = lib.sort
          (a: b: constraintKey a < constraintKey b)
          normPremises;
      in mkImpliesConstraint sorted (normalizeConstraint c.conclusion)
    else if tag == "RowEquality" then
      mkRowEqConstraint c.lhsRow c.rhsRow
    else if tag == "Refined" then
      mkRefinedConstraint c.subject c.predVar c.predExpr
    else c;

  # ══ Constraint 去重（基于 canonical key）══════════════════════════════════
  # Type: [Constraint] -> [Constraint]
  deduplicateConstraints = cs:
    let
      normalized = map normalizeConstraint cs;
      go = seen: remaining:
        if remaining == [] then []
        else
          let
            c   = builtins.head remaining;
            rest = builtins.tail remaining;
            k   = constraintKey c;
          in
          if seen ? ${k} then go seen rest
          else [ c ] ++ go (seen // { ${k} = true; }) rest;
    in go {} normalized;

  # ══ Constraint 类型变量收集 ════════════════════════════════════════════════
  # Type: Constraint -> Set String
  constraintFreeVars = c:
    let tag = c.__constraintTag or null; in
    if tag == "Equality" then
      _typeFreeVars c.lhs // _typeFreeVars c.rhs
    else if tag == "Class" then
      lib.foldl' (acc: a: acc // _typeFreeVars a) {} (c.args or [])
    else if tag == "Predicate" then
      _typeFreeVars (c.subject or c.arg or { repr = { __variant = "?"; }; })
    else if tag == "RowEquality" then
      _typeFreeVars c.lhsRow // _typeFreeVars c.rhsRow
    else if tag == "Implies" then
      lib.foldl' (acc: p: acc // constraintFreeVars p) {} (c.premises or [])
      // constraintFreeVars c.conclusion
    else if tag == "Refined" then
      _typeFreeVars c.subject
    else {};

  # 内部：从 Type 收集自由变量名
  _typeFreeVars = t:
    if !isType t then {}
    else
      let v = t.repr.__variant or null; in
      if v == "Var" then { ${t.repr.name} = true; }
      else if v == "RowVar" then { ${t.repr.name} = true; }
      else {};  # 简化实现；完整版在 substLib.freeVars

  # ══ Constraint 包含变量检查 ════════════════════════════════════════════════
  # Type: String -> Constraint -> Bool
  constraintContainsVar = varName: c:
    (constraintFreeVars c) ? ${varName};
}
