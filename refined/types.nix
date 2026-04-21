# refined/types.nix — Phase 4.1
# Refined Types（精化类型）
# 新增：smtOracle 接口（修复 RISK 风险 2：Refined subtype 自动化）
# INV-SMT-1: PredExpr ∈ IR（不是 Nix 函数）
# INV-SMT-2: staticEval 健全（PTrue/PFalse/常量折叠）
# INV-SMT-3: smtBridge 生成标准 SMTLIB2
# INV-SMT-4: Refined constraint ∈ TypeRepr（INV-6 保持）
# INV-SMT-5: checkRefinedSubtype sound（Phase 4.1 新增）
# INV-SMT-6: trivial cases never sent to SMT
{ lib, typeLib, reprLib, kindLib, hashLib, normalizeLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith;
  inherit (reprLib) rRefined rConstrained;
  inherit (kindLib) KStar;

in rec {

  # ══ PredExpr IR（谓词语言，INV-SMT-1）════════════════════════════════════

  mkPTrue  = { __predTag = "PTrue"; };
  mkPFalse = { __predTag = "PFalse"; };

  mkPAnd   = left: right:
    # 短路优化
    if left.__predTag or null == "PFalse" || right.__predTag or null == "PFalse"
    then mkPFalse
    else if left.__predTag or null == "PTrue" then right
    else if right.__predTag or null == "PTrue" then left
    else { __predTag = "PAnd"; inherit left right; };

  mkPOr    = left: right:
    if left.__predTag or null == "PTrue" || right.__predTag or null == "PTrue"
    then mkPTrue
    else if left.__predTag or null == "PFalse" then right
    else if right.__predTag or null == "PFalse" then left
    else { __predTag = "POr"; inherit left right; };

  mkPNot   = body:
    if body.__predTag or null == "PTrue"  then mkPFalse
    else if body.__predTag or null == "PFalse" then mkPTrue
    else { __predTag = "PNot"; inherit body; };

  mkPCmp   = op: lhs: rhs: { __predTag = "PCmp"; inherit op lhs rhs; };

  mkPVar   = name: { __predTag = "PVar"; inherit name; };
  mkPLit   = value: { __predTag = "PLit"; inherit value; };
  mkPApp   = fn: args: { __predTag = "PApp"; inherit fn args; };

  # ── 谓词谓词 ─────────────────────────────────────────────────────────────
  isPred    = p: builtins.isAttrs p && p ? __predTag;
  isPTrue   = p: isPred p && p.__predTag == "PTrue";
  isPFalse  = p: isPred p && p.__predTag == "PFalse";
  isPVar    = p: isPred p && p.__predTag == "PVar";
  isPLit    = p: isPred p && p.__predTag == "PLit";

  # ══ Refined Type 构造器 ════════════════════════════════════════════════════

  # { n : T | φ(n) }
  mkRefined = base: predVar: predExpr:
    mkTypeDefault (rRefined base predVar predExpr) KStar;

  # 快捷构造：正整数类型
  mkPositiveInt = intType:
    mkRefined intType "n" (mkPCmp "gt" (mkPVar "n") (mkPLit 0));

  # 快捷构造：非负整数类型
  mkNonNegInt = intType:
    mkRefined intType "n" (mkPCmp "ge" (mkPVar "n") (mkPLit 0));

  # ══ Static Evaluation（INV-SMT-2）═════════════════════════════════════════
  # Type: PredExpr -> { discharged: Bool; residual: Bool; simplExpr: PredExpr }
  staticEvalPred = p:
    let tag = p.__predTag or null; in
    if tag == "PTrue"  then { discharged = true;  residual = false; simplExpr = p; }
    else if tag == "PFalse" then { discharged = false; residual = false; simplExpr = p; }
    else if tag == "PAnd" then
      let
        l = staticEvalPred p.left;
        r = staticEvalPred p.right;
      in
      if !l.discharged && !l.residual then  # l is statically false
        { discharged = false; residual = false; simplExpr = mkPFalse; }
      else if !r.discharged && !r.residual then  # r is statically false
        { discharged = false; residual = false; simplExpr = mkPFalse; }
      else if l.discharged && !l.residual && r.discharged && !r.residual then
        { discharged = true; residual = false; simplExpr = mkPTrue; }
      else
        { discharged = false; residual = true;
          simplExpr = mkPAnd l.simplExpr r.simplExpr; }
    else if tag == "POr" then
      let
        l = staticEvalPred p.left;
        r = staticEvalPred p.right;
      in
      if l.discharged && !l.residual then
        { discharged = true; residual = false; simplExpr = mkPTrue; }
      else if r.discharged && !r.residual then
        { discharged = true; residual = false; simplExpr = mkPTrue; }
      else
        { discharged = false; residual = true;
          simplExpr = mkPOr l.simplExpr r.simplExpr; }
    else if tag == "PNot" then
      let b = staticEvalPred p.body; in
      if b.discharged && !b.residual then
        { discharged = false; residual = false; simplExpr = mkPFalse; }
      else if !b.discharged && !b.residual then
        { discharged = true; residual = false; simplExpr = mkPTrue; }
      else
        { discharged = false; residual = true; simplExpr = mkPNot b.simplExpr; }
    else if tag == "PCmp" then
      let
        lTag = p.lhs.__predTag or null;
        rTag = p.rhs.__predTag or null;
      in
      if lTag == "PLit" && rTag == "PLit" then
        let
          lv = p.lhs.value;
          rv = p.rhs.value;
          op = p.op;
          res = if op == "eq"  then lv == rv
                else if op == "neq" then lv != rv
                else if op == "lt"  then lv < rv
                else if op == "le"  then lv <= rv
                else if op == "gt"  then lv > rv
                else if op == "ge"  then lv >= rv
                else false;
        in { discharged = res; residual = false; simplExpr = p; }
      else
        { discharged = false; residual = true; simplExpr = p; }
    else
      # PVar, PApp → SMT residual（INV-SMT-2: 无法静态求值）
      { discharged = false; residual = true; simplExpr = p; };

  # ══ SMTLIB2 Bridge（INV-SMT-3: 标准格式输出）═════════════════════════════

  # Type: PredExpr -> String
  predToSMT = p:
    let tag = p.__predTag or null; in
    if tag == "PTrue"  then "true"
    else if tag == "PFalse" then "false"
    else if tag == "PAnd"  then "(and ${predToSMT p.left} ${predToSMT p.right})"
    else if tag == "POr"   then "(or ${predToSMT p.left} ${predToSMT p.right})"
    else if tag == "PNot"  then "(not ${predToSMT p.body})"
    else if tag == "PVar"  then p.name
    else if tag == "PLit"  then builtins.toString p.value
    else if tag == "PCmp"  then
      let
        op = if p.op == "eq"  then "="
             else if p.op == "neq" then "(not (= ${predToSMT p.lhs} ${predToSMT p.rhs}))"
             else if p.op == "lt"  then "<"
             else if p.op == "le"  then "<="
             else if p.op == "gt"  then ">"
             else if p.op == "ge"  then ">="
             else "?";
      in
      if p.op == "neq" then op  # 已经是完整的 SMT 表达式
      else "(${op} ${predToSMT p.lhs} ${predToSMT p.rhs})"
    else if tag == "PApp"  then
      "(${p.fn} ${lib.concatStringsSep " " (map predToSMT (p.args or []))})"
    else "?";

  # Type: String -> Type -> PredExpr -> String  (声明 predVar 的 SMTLIB2 类型)
  _smtDeclare = predVar: baseType: predExpr:
    let
      smtSort = let n = baseType.repr.name or "?"; in
        if n == "Int" || n == "Nat" then "Int"
        else if n == "Bool" then "Bool"
        else "Int";  # 默认 Int
    in
    "(declare-const ${predVar} ${smtSort})\n";

  # Type: [{ subject; predVar; predExpr }] -> String
  smtBridge = refinedConstraints:
    let
      decls = lib.concatMapStrings (c:
        _smtDeclare c.predVar (c.subject or { repr = { name = "Int"; }; }) c.predExpr
      ) refinedConstraints;
      asserts = lib.concatMapStrings (c:
        "(assert ${predToSMT c.predExpr})\n"
      ) refinedConstraints;
    in
    "(set-logic LIA)\n" + decls + asserts + "(check-sat)\n";

  # ══ Phase 4.1: Refined Subtype 自动化（INV-SMT-5）════════════════════════

  # Refined subtype obligation：
  # { n : T | φ(n) } <: { n : T | ψ(n) }
  # ⟺ ∀n. φ(n) → ψ(n)（i.e., φ ∧ ¬ψ 不可满足）
  # Type: Type -> Type -> RefinedSubtypeObligation
  refinedSubtypeObligation = sub: sup:
    let
      subRepr = sub.repr;
      supRepr = sup.repr;
      sameBase = builtins.toJSON subRepr.base.repr ==
                 builtins.toJSON supRepr.base.repr;
    in
    if !sameBase then
      { ok = false; trivial = false; smtScript = "";
        error = "Refined subtype: base types differ"; }
    else
      let
        # 统一 predVar
        predVar  = subRepr.predVar;
        phiExpr  = subRepr.predExpr;
        # ψ 可能使用不同 predVar，需替换
        psiVar   = supRepr.predVar;
        psiExpr  = if psiVar == predVar then supRepr.predExpr
                   else _substPredVar psiVar predVar supRepr.predExpr;
        # INV-SMT-6: 平凡情况不发送给 SMT
        trivial  = isPTrue psiExpr
                || (builtins.toJSON phiExpr == builtins.toJSON psiExpr);
      in
      if trivial then
        { ok = true; trivial = true; smtScript = "";
          obligation = { predVar = predVar; phi = phiExpr; psi = psiExpr; }; }
      else
        # 生成 SMTLIB2：验证 ∀n. φ(n) → ψ(n)
        # 等价于：∃n. φ(n) ∧ ¬ψ(n) 不可满足
        let
          script =
            "(set-logic LIA)\n" +
            "(declare-const ${predVar} Int)\n" +
            "(assert (and ${predToSMT phiExpr} (not ${predToSMT psiExpr})))\n" +
            "(check-sat)\n";
        in
        { ok        = false;  # 需要 SMT oracle 才能确定
          trivial   = false;
          smtScript = script;
          obligation = { predVar = predVar; phi = phiExpr; psi = psiExpr; };
        };

  # ── Phase 4.1: smtOracle 接口（INV-SMT-5 修复 RISK-风险2）───────────────
  # smtOracle: String -> String（"sat" | "unsat" | "unknown"）
  # 用户提供 oracle 函数（可调用 z3/cvc5 等）
  # Type: Type -> Type -> (String -> String) -> CheckResult
  checkRefinedSubtype = sub: sup: smtOracle:
    let
      subV = sub.repr.__variant or null;
      supV = sup.repr.__variant or null;
    in
    if subV != "Refined" || supV != "Refined" then
      { ok = false; error = "checkRefinedSubtype: both types must be Refined"; }
    else
      let obl = refinedSubtypeObligation sub sup; in
      if obl.ok or false then
        { ok = true; trivial = true; }  # 平凡成立
      else if obl.error or null != null then
        { ok = false; error = obl.error; }
      else
        let
          smtResult = smtOracle obl.smtScript;
        in
        if smtResult == "unsat" then
          { ok = true; trivial = false; witness = "SMT: unsat"; }
        else if smtResult == "sat" then
          { ok = false; trivial = false;
            error = "Refined subtype failed (SMT: sat — counterexample exists)"; }
        else
          { ok = false; trivial = false;
            error = "Refined subtype unknown (SMT: ${smtResult})"; };

  # ── 谓词变量替换（用于 predVar 统一）────────────────────────────────────
  _substPredVar = oldVar: newVar: p:
    let tag = p.__predTag or null; in
    if tag == "PVar" && p.name == oldVar then mkPVar newVar
    else if tag == "PAnd" then
      mkPAnd (_substPredVar oldVar newVar p.left)
             (_substPredVar oldVar newVar p.right)
    else if tag == "POr" then
      mkPOr (_substPredVar oldVar newVar p.left)
            (_substPredVar oldVar newVar p.right)
    else if tag == "PNot" then
      mkPNot (_substPredVar oldVar newVar p.body)
    else if tag == "PCmp" then
      mkPCmp p.op (_substPredVar oldVar newVar p.lhs) (_substPredVar oldVar newVar p.rhs)
    else if tag == "PApp" then
      mkPApp p.fn (map (_substPredVar oldVar newVar) (p.args or []))
    else p;
}
