# constraint/ir.nix — Phase 4.3
# Constraint IR：INV-6（Constraint ∈ TypeRepr，结构化 IR）
# 所有 Constraint 是 attrset（可参与 normalize/hash/equality）
# Fix P4.3: mkImpliesConstraint 排序改用 serializeConstraint（而非 builtins.toJSON）
#           避免 Constraint 中内嵌 Type 对象触发 "cannot convert function to JSON"
{ lib, serialLib }:

let
  inherit (serialLib) serializeConstraint;

in rec {

  # ══ Constraint 变体构造器 ══════════════════════════════════════════════

  # ① Equality — a ≡ b
  mkEqConstraint = lhs: rhs: {
    __constraintTag = "Equality";
    lhs = lhs;
    rhs = rhs;
  };

  # ② Class — C a₁...aₙ（typeclass 约束）
  mkClassConstraint = className: args: {
    __constraintTag = "Class";
    className = className;
    args = args;
  };

  # ③ Predicate — 谓词约束
  mkPredConstraint = predName: subject: {
    __constraintTag = "Predicate";
    predName = predName;
    subject  = subject;
  };

  # ④ Implies — premises ⊢ conclusion（premises canonical 排序）
  # Fix P4.3: 使用 serializeConstraint 而非 builtins.toJSON 排序
  #   builtins.toJSON 会递归碰触 Type 对象中的函数字段
  mkImpliesConstraint = premises: conclusion:
    let
      sorted = lib.sort (a: b:
        serializeConstraint a < serializeConstraint b
      ) premises;
    in
    { __constraintTag = "Implies"; premises = sorted; conclusion = conclusion; };

  # ⑤ RowEquality — row 等价约束
  mkRowEqConstraint = lhsRow: rhsRow: {
    __constraintTag = "RowEquality";
    lhsRow = lhsRow;
    rhsRow = rhsRow;
  };

  # ⑥ Refined — 精化约束（Phase 4.x）
  mkRefinedConstraint = subject: predVar: predExpr: {
    __constraintTag = "Refined";
    subject  = subject;
    predVar  = predVar;
    predExpr = predExpr;
  };

  # ════════════════════════════════════════════════════════════════════
  # Phase 4.2 新增 Constraints
  # ════════════════════════════════════════════════════════════════════

  # ⑦ Scheme Constraint（TypeScheme 实例化约束）
  # scheme ≥ type（type 是 scheme 的一个实例）
  mkSchemeConstraint = scheme: ty: {
    __constraintTag = "Scheme";
    scheme = scheme;
    ty     = ty;
  };

  # ⑧ KindConstraint（Phase 4.2: kind-level unification）
  mkKindConstraint = typeVar: expectedKind: {
    __constraintTag = "Kind";
    typeVar      = typeVar;
    expectedKind = expectedKind;
  };

  # ⑨ InstanceConstraint（更明确的 instance 查询）
  mkInstanceConstraint = className: types: {
    __constraintTag = "Instance";
    className = className;
    types     = types;
  };

  # ══ PredExpr 构造器（Refined Types 用）════════════════════════════════
  mkPTrue  = { __predTag = "PTrue"; };
  mkPFalse = { __predTag = "PFalse"; };
  mkPLit   = value: { __predTag = "PLit"; value = value; };
  mkPVar   = name: { __predTag = "PVar"; name = name; };
  mkPCmp   = op: lhs: rhs: { __predTag = "PCmp"; op = op; lhs = lhs; rhs = rhs; };
  mkPAnd   = lhs: rhs: { __predTag = "PAnd"; lhs = lhs; rhs = rhs; };
  mkPOr    = lhs: rhs: { __predTag = "POr"; lhs = lhs; rhs = rhs; };
  mkPNot   = body: { __predTag = "PNot"; body = body; };

  # ══ Constraint 谓词 ════════════════════════════════════════════════════
  isConstraint = c:
    builtins.isAttrs c && c ? __constraintTag;

  isEqConstraint      = c: isConstraint c && c.__constraintTag == "Equality";
  isClassConstraint   = c: isConstraint c && c.__constraintTag == "Class";
  isPredConstraint    = c: isConstraint c && c.__constraintTag == "Predicate";
  isImpliesConstraint = c: isConstraint c && c.__constraintTag == "Implies";
  isRowEqConstraint   = c: isConstraint c && c.__constraintTag == "RowEquality";
  isRefinedConstraint = c: isConstraint c && c.__constraintTag == "Refined";
  isSchemeConstraint  = c: isConstraint c && c.__constraintTag == "Scheme";
  isKindConstraint    = c: isConstraint c && c.__constraintTag == "Kind";
  isInstanceConstraint = c: isConstraint c && c.__constraintTag == "Instance";

  # ══ Constraint key（用于去重）══════════════════════════════════════════
  constraintKey = c: serializeConstraint c;

  # ══ 合并 Constraint 列表（去重）═══════════════════════════════════════
  mergeConstraints = cs1: cs2:
    let
      all  = cs1 ++ cs2;
      keys = map constraintKey all;
      uniq = lib.foldl' (acc: x:
        if builtins.elem x.k acc.seen
        then acc
        else { seen = acc.seen ++ [x.k]; result = acc.result ++ [x.v]; }
      ) { seen = []; result = []; }
        (lib.zipListsWith (k: v: { k = k; v = v; }) keys all);
    in
    uniq.result;
}
