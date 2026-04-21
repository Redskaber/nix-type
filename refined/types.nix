# refined/types.nix — Phase 4.0
#
# Refined Types（Liquid Types / SMT Bridge）
#
# 设计原则：
#   - Predicate ∈ TypeRepr（INV-6 强化，INV-SMT-1）
#   - smtBridge 无副作用（nix string only，INV-SMT-2）
#   - solver residual = SMT obligations（INV-SMT-3）
#   - Refined = { n : T | φ(n) }，其中 φ 是谓词 IR
#
# TypeRepr 新增变体：
#   Refined { base; predVar; predExpr }  # { n : base | predExpr[predVar ↦ n] }
#
# 谓词 IR（PredExpr）：
#   PredExpr = PTrue | PFalse
#             | PAnd { left; right }
#             | POr  { left; right }
#             | PNot { body }
#             | PCmp { op; lhs; rhs }  # op ∈ {gt, lt, ge, le, eq, neq}
#             | PVar { name }           # 自由变量（指向约束 context）
#             | PLit { value }          # 字面量
#             | PApp { fn; args }       # 外部谓词名 + 参数
#
# SMT 输出格式：SMTLIB2（字符串，可传给 z3 / cvc5）
#
# 不变量（Phase 4.0 SMT）：
#   INV-SMT-1: Refined ∈ TypeRepr（不是外部系统）
#   INV-SMT-2: smtBridge 返回纯 string（无 builtins.exec）
#   INV-SMT-3: 无法 discharge 的谓词 → residual list（不静默 OK）
#   INV-SMT-4: predExpr 序列化确定性（用于 hash / equality）

{ lib, typeLib, kindLib, reprLib, hashLib }:

let
  inherit (typeLib) mkTypeDefault mkTypeWith;
  inherit (kindLib) KStar;
  inherit (reprLib) rPrimitive rConstrained;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # PredExpr IR
  # ══════════════════════════════════════════════════════════════════════════════

  PTrue  = { __pred = "PTrue"; };
  PFalse = { __pred = "PFalse"; };

  PAnd = left: right: { __pred = "PAnd"; inherit left right; };
  POr  = left: right: { __pred = "POr";  inherit left right; };
  PNot = body:        { __pred = "PNot"; inherit body; };

  PCmp = op: lhs: rhs: { __pred = "PCmp"; inherit op lhs rhs; };
  # 便捷比较器
  PGt  = PCmp "gt";
  PLt  = PCmp "lt";
  PGe  = PCmp "ge";
  PLe  = PCmp "le";
  PEq  = PCmp "eq";
  PNeq = PCmp "neq";

  PVar = name: { __pred = "PVar"; inherit name; };
  PLit = value: { __pred = "PLit"; inherit value; };
  PApp = fn: args: { __pred = "PApp"; inherit fn args; };

  # ── 谓词变量替换（predVar → 具体 name）──────────────────────────────────────

  substPredVar = oldName: newName: pred:
    let v = pred.__pred or null; in
    if v == "PVar" && pred.name == oldName
    then PVar newName
    else if v == "PAnd" then PAnd (substPredVar oldName newName pred.left)
                                  (substPredVar oldName newName pred.right)
    else if v == "POr"  then POr  (substPredVar oldName newName pred.left)
                                  (substPredVar oldName newName pred.right)
    else if v == "PNot" then PNot (substPredVar oldName newName pred.body)
    else if v == "PCmp" then PCmp pred.op
                                  (substPredVar oldName newName pred.lhs)
                                  (substPredVar oldName newName pred.rhs)
    else if v == "PApp" then PApp pred.fn (map (substPredVar oldName newName) pred.args)
    else pred;

  # ══════════════════════════════════════════════════════════════════════════════
  # Refined TypeRepr 构造器
  # ══════════════════════════════════════════════════════════════════════════════

  rRefined = base: predVar: predExpr: {
    __variant = "Refined";
    inherit base predVar predExpr;
  };

  # 便捷构造：{ n : T | φ }
  mkRefined = baseType: predVar: predExpr:
    mkTypeDefault (rRefined baseType predVar predExpr) KStar;

  # 常用 Refined 类型
  mkPosInt = _:
    let
      tInt = mkTypeDefault (rPrimitive "Int") KStar;
    in
    mkRefined tInt "n" (PGt (PVar "n") (PLit 0));

  mkNonNegInt = _:
    let tInt = mkTypeDefault (rPrimitive "Int") KStar; in
    mkRefined tInt "n" (PGe (PVar "n") (PLit 0));

  mkBoundedInt = lo: hi:
    let tInt = mkTypeDefault (rPrimitive "Int") KStar; in
    mkRefined tInt "n" (PAnd
      (PGe (PVar "n") (PLit lo))
      (PLe (PVar "n") (PLit hi)));

  mkNonEmpty = baseListType:
    mkRefined baseListType "xs" (PGt (PApp "length" [PVar "xs"]) (PLit 0));

  # ══════════════════════════════════════════════════════════════════════════════
  # PredExpr 序列化（确定性，用于 hash，INV-SMT-4）
  # ══════════════════════════════════════════════════════════════════════════════

  serializePred = pred:
    let v = pred.__pred or null; in
    if v == null    then "?pred"
    else if v == "PTrue"  then "T"
    else if v == "PFalse" then "F"
    else if v == "PVar"   then "v:${pred.name}"
    else if v == "PLit"   then "l:${builtins.toString pred.value}"
    else if v == "PNot"   then "~(${serializePred pred.body})"
    else if v == "PAnd"   then "(&(${serializePred pred.left},${serializePred pred.right}))"
    else if v == "POr"    then "(|(${serializePred pred.left},${serializePred pred.right}))"
    else if v == "PCmp"   then "(${pred.op}:${serializePred pred.lhs}:${serializePred pred.rhs})"
    else if v == "PApp"   then "${pred.fn}(${lib.concatStringsSep "," (map serializePred pred.args)})"
    else "?p";

  # ══════════════════════════════════════════════════════════════════════════════
  # SMT 生成（SMTLIB2 格式，INV-SMT-2：纯 string）
  # ══════════════════════════════════════════════════════════════════════════════

  # 谓词 → SMTLIB2 表达式
  predToSMT = pred:
    let v = pred.__pred or null; in
    if v == "PTrue"  then "true"
    else if v == "PFalse" then "false"
    else if v == "PVar"   then pred.name
    else if v == "PLit"   then builtins.toString pred.value
    else if v == "PNot"   then "(not ${predToSMT pred.body})"
    else if v == "PAnd"   then "(and ${predToSMT pred.left} ${predToSMT pred.right})"
    else if v == "POr"    then "(or ${predToSMT pred.left} ${predToSMT pred.right})"
    else if v == "PCmp"   then
      let
        smtOp = if pred.op == "gt"  then ">"
           else if pred.op == "lt"  then "<"
           else if pred.op == "ge"  then ">="
           else if pred.op == "le"  then "<="
           else if pred.op == "eq"  then "="
           else if pred.op == "neq" then "distinct"
           else "?op";
      in
      "(${smtOp} ${predToSMT pred.lhs} ${predToSMT pred.rhs})"
    else if v == "PApp" then
      "(${pred.fn} ${lib.concatStringsSep " " (map predToSMT pred.args)})"
    else "?pred";

  # Refined 约束 → SMT declare + assert + check-sat
  refinedConstraintToSMT = varDecl: predVar: predExpr: baseSort:
    let
      smtSort = if baseSort == "Int" then "Int"
           else if baseSort == "Bool" then "Bool"
           else if baseSort == "String" then "String"
           else "Int";  # fallback
      body = substPredVar predVar varDecl predExpr;
    in
    lib.concatStringsSep "\n" [
      "(declare-const ${varDecl} ${smtSort})"
      "(assert (not ${predToSMT body}))"
      "(check-sat)"
    ];

  # smtBridge：将 residual refined constraints 转成 SMT 脚本（INV-SMT-3）
  smtBridge = residuals:
    let
      header = [
        "; nix-types SMT residuals"
        "(set-logic LIA)"
      ];
      bodies = lib.imap0 (i: c:
        let
          r       = (c.subject or { repr = {}; }).repr or {};
          base    = r.base or {};
          baseR   = base.repr or {};
          baseSort = baseR.name or "Int";
          predVar  = r.predVar  or "x";
          predExpr = r.predExpr or PTrue;
        in
        refinedConstraintToSMT "x${builtins.toString i}" predVar predExpr baseSort
      ) residuals;
      footer = [ "(exit)" ];
    in
    lib.concatStringsSep "\n" (header ++ bodies ++ footer);

  # ══════════════════════════════════════════════════════════════════════════════
  # Refined 约束 IR（INV-SMT-1：ConstraintTag = "Refined"）
  # ══════════════════════════════════════════════════════════════════════════════

  mkRefinedConstraint = subject: predVar: predExpr: {
    __constraintTag = "Refined";
    inherit subject predVar predExpr;
  };

  # ── Refined 约束 solver step ─────────────────────────────────────────────────

  # 简单静态求值（常量折叠）：可 discharge 的 trivial predicates
  staticEvalPred = pred:
    let v = pred.__pred or null; in
    if v == "PTrue"  then { known = true;  value = true; }
    else if v == "PFalse" then { known = true;  value = false; }
    else if v == "PNot" then
      let inner = staticEvalPred pred.body; in
      if inner.known then { known = true; value = !inner.value; }
      else { known = false; value = null; }
    else if v == "PAnd" then
      let
        l = staticEvalPred pred.left;
        r = staticEvalPred pred.right;
      in
      if l.known && !l.value then { known = true; value = false; }    # short-circuit
      else if r.known && !r.value then { known = true; value = false; }
      else if l.known && r.known  then { known = true; value = l.value && r.value; }
      else { known = false; value = null; }
    else if v == "POr" then
      let
        l = staticEvalPred pred.left;
        r = staticEvalPred pred.right;
      in
      if l.known && l.value then { known = true; value = true; }
      else if r.known && r.value then { known = true; value = true; }
      else if l.known && r.known then { known = true; value = l.value || r.value; }
      else { known = false; value = null; }
    else if v == "PCmp" then
      let
        lEval = staticEvalPred pred.lhs;
        rEval = staticEvalPred pred.rhs;
      in
      if lEval.known && rEval.known then
        let
          lv = lEval.value;
          rv = rEval.value;
          result = if pred.op == "gt"  then lv > rv
              else if pred.op == "lt"  then lv < rv
              else if pred.op == "ge"  then lv >= rv
              else if pred.op == "le"  then lv <= rv
              else if pred.op == "eq"  then lv == rv
              else if pred.op == "neq" then lv != rv
              else false;
        in
        { known = true; value = result; }
      else { known = false; value = null; }
    else { known = false; value = null; };

  # 尝试 discharge Refined constraint
  # Result: { discharged: Bool; residual: Constraint? }
  tryDischargeRefined = c:
    if c.__constraintTag or null != "Refined" then
      { discharged = false; residual = c; }
    else
      let result = staticEvalPred c.predExpr; in
      if result.known && result.value then
        { discharged = true; residual = null; }
      else if result.known && !result.value then
        { discharged = false; residual = c; error = "predicate statically false"; }
      else
        { discharged = false; residual = c; };  # → SMT bridge

  # ══════════════════════════════════════════════════════════════════════════════
  # 子类型检查：Refined subtyping
  # { n : T | φ } <: { n : T | ψ } ↔ ∀n:T. φ(n) → ψ(n)（SMT 残差）
  # ══════════════════════════════════════════════════════════════════════════════

  refinedSubtypeObligation = sub: sup:
    let
      subR = sub.repr or {};
      supR = sup.repr or {};
    in
    if subR.__variant != "Refined" || supR.__variant != "Refined" then
      { trivial = true; }
    else
      let
        # rename supPredVar to match subPredVar for implication
        phi  = subR.predExpr;
        psi  = substPredVar supR.predVar subR.predVar supR.predExpr;
        # obligation: ¬(φ → ψ) = φ ∧ ¬ψ should be UNSAT
        obligation = PAnd phi (PNot psi);
      in {
        trivial    = false;
        predVar    = subR.predVar;
        obligation = obligation;
        smtScript  = refinedConstraintToSMT subR.predVar subR.predVar obligation
                       (subR.base.repr.name or "Int");
      };

  # ══════════════════════════════════════════════════════════════════════════════
  # 不变量验证
  # ══════════════════════════════════════════════════════════════════════════════

  verifyRefinedInvariants = _:
    let
      tInt     = mkTypeDefault (rPrimitive "Int") KStar;
      posInt   = mkPosInt {};
      # INV-SMT-1: Refined ∈ TypeRepr
      invSMT1  = posInt.repr.__variant == "Refined";

      # INV-SMT-4: serialize deterministic
      s1 = serializePred (PGt (PVar "n") (PLit 0));
      s2 = serializePred (PGt (PVar "n") (PLit 0));
      invSMT4  = s1 == s2;

      # INV-SMT-2: smtBridge = pure string
      rc = mkRefinedConstraint posInt "n" (PGt (PVar "n") (PLit 0));
      smt = smtBridge [ rc ];
      invSMT2  = builtins.isString smt;

      # staticEval trivial cases
      trueDischarge  = tryDischargeRefined (mkRefinedConstraint tInt "n" PTrue);
      invSMT3a = trueDischarge.discharged == true;

      falseDischarge = tryDischargeRefined (mkRefinedConstraint tInt "n" PFalse);
      invSMT3b = falseDischarge.discharged == false;

    in {
      allPass   = invSMT1 && invSMT2 && invSMT3a && invSMT3b && invSMT4;
      "INV-SMT-1" = invSMT1;
      "INV-SMT-2" = invSMT2;
      "INV-SMT-3a" = invSMT3a;
      "INV-SMT-3b" = invSMT3b;
      "INV-SMT-4" = invSMT4;
    };
}
