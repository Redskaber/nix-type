# refined/types.nix — Phase 4.2
# Refined Types（PredExpr IR + smtOracle）
# INV-SMT-1~6 全覆盖
{ lib, typeLib, reprLib, kindLib, hashLib, normalizeLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith;
  inherit (reprLib) rRefined rPrimitive;
  inherit (kindLib) KStar;
  inherit (normalizeLib) normalize';
  inherit (hashLib) typeHash;

in rec {

  # ══ PredExpr 构造器 ════════════════════════════════════════════════════
  mkPTrue  = { __predTag = "PTrue"; };
  mkPFalse = { __predTag = "PFalse"; };
  mkPLit   = v: { __predTag = "PLit"; value = v; };
  mkPVar   = n: { __predTag = "PVar"; name = n; };
  mkPCmp   = op: lhs: rhs: { __predTag = "PCmp"; op = op; lhs = lhs; rhs = rhs; };
  mkPAnd   = l: r: { __predTag = "PAnd"; lhs = l; rhs = r; };
  mkPOr    = l: r: { __predTag = "POr"; lhs = l; rhs = r; };
  mkPNot   = b: { __predTag = "PNot"; body = b; };

  isPredExpr = pe: builtins.isAttrs pe && pe ? __predTag;

  # ══ Refined 类型构造器 ════════════════════════════════════════════════
  # { x: T | φ(x) }
  # Type: Type → String → PredExpr → Type
  mkRefined = base: predVar: predExpr:
    mkTypeDefault (rRefined base predVar predExpr) KStar;

  isRefined = t: isType t && (t.repr.__variant or null) == "Refined";

  refinedBase    = t: assert isRefined t; t.repr.base;
  refinedPredVar = t: assert isRefined t; t.repr.predVar;
  refinedPredExp = t: assert isRefined t; t.repr.predExpr;

  # ══ Static PredExpr Evaluation ════════════════════════════════════════
  # INV-SMT-2: PTrue → 退化为 base
  # INV-SMT-3: PFalse → empty type（永远无法满足）
  # INV-SMT-6: trivial cases skip SMT
  staticEvalPred = predVar: predExpr: value:
    let tag = predExpr.__predTag or null; in
    if tag == "PTrue"  then { ok = true; result = true;  trivial = true; }
    else if tag == "PFalse" then { ok = true; result = false; trivial = true; }
    else if tag == "PLit" then
      { ok = true; result = (predExpr.value == value); trivial = true; }
    else if tag == "PAnd" then
      let
        l = staticEvalPred predVar predExpr.lhs value;
        r = staticEvalPred predVar predExpr.rhs value;
      in
      if l.ok && r.ok then
        { ok = true; result = l.result && r.result; trivial = l.trivial && r.trivial; }
      else { ok = false; trivial = false; }
    else if tag == "POr" then
      let
        l = staticEvalPred predVar predExpr.lhs value;
        r = staticEvalPred predVar predExpr.rhs value;
      in
      if l.ok then
        if l.result then { ok = true; result = true; trivial = l.trivial; }
        else if r.ok then { ok = true; result = r.result; trivial = r.trivial; }
        else { ok = false; trivial = false; }
      else { ok = false; trivial = false; }
    else if tag == "PNot" then
      let inner = staticEvalPred predVar predExpr.body value; in
      if inner.ok then { ok = true; result = !inner.result; trivial = inner.trivial; }
      else { ok = false; trivial = false; }
    else
      # PCmp, PVar → non-trivial, defer to SMT
      { ok = false; trivial = false; };

  # ══ SMT Oracle 接口（INV-SMT-5/6）══════════════════════════════════════
  # 当 staticEvalPred 无法判定时，调用外部 SMT solver
  # 在纯 Nix 中，smtOracle 是用户提供的函数（或 stub）
  # INV-SMT-5: checkRefinedSubtype sound（当 SMT 返回 true 时正确）
  # INV-SMT-6: trivial cases skip SMT

  # Type: PredExpr → { discharged: Bool; reason: String; smt: Bool }
  # smtOracle: 外部提供（纯 Nix 中是 stub）
  defaultSmtOracle = predVar: predExpr:
    # stub：在 Nix 中无法调用外部 z3，返回 residual
    { discharged = false; reason = "smt-residual"; smt = true;
      query = _predExprToSmtLib predVar predExpr; };

  # INV-SMT-5: 精化子类型检查
  # Type: Type(Refined) → Type(Refined) → SmtOracle → Bool
  checkRefinedSubtype = subTy: superTy: smtOracle:
    if !isRefined subTy || !isRefined superTy then
      # 非精化类型：使用普通类型等价
      typeHash (normalize' subTy) == typeHash (normalize' superTy)
    else
      let
        subBase  = normalize' (refinedBase subTy);
        superBase = normalize' (refinedBase superTy);
      in
      # 基础类型必须兼容
      if typeHash subBase != typeHash superBase then false
      else
        let
          subPred   = refinedPredExp subTy;
          superPred = refinedPredExp superTy;
          # INV-SMT-6: trivial cases skip SMT
          subStatic   = staticEvalPred (refinedPredVar subTy) subPred null;
          superStatic = staticEvalPred (refinedPredVar superTy) superPred null;
        in
        if superStatic.ok && superStatic.result then true  # super = ⊤
        else if subStatic.ok && !subStatic.result then true  # sub = ⊥
        else
          # Non-trivial: 调用 SMT oracle 检查 subPred ⊢ superPred
          let
            smtResult = smtOracle
              (refinedPredVar subTy) subPred
              (refinedPredVar superTy) superPred;
          in
          smtResult.discharged;

  # ══ PredExpr → SMT-LIB2 转换（供外部 oracle 使用）════════════════════
  _predExprToSmtLib = var: pe:
    let tag = pe.__predTag or null; in
    if tag == "PTrue"  then "true"
    else if tag == "PFalse" then "false"
    else if tag == "PLit"   then builtins.toJSON pe.value
    else if tag == "PVar"   then pe.name
    else if tag == "PCmp"   then
      "(${pe.op} ${_predExprToSmtLib var pe.lhs} ${_predExprToSmtLib var pe.rhs})"
    else if tag == "PAnd"   then
      "(and ${_predExprToSmtLib var pe.lhs} ${_predExprToSmtLib var pe.rhs})"
    else if tag == "POr"    then
      "(or ${_predExprToSmtLib var pe.lhs} ${_predExprToSmtLib var pe.rhs})"
    else if tag == "PNot"   then
      "(not ${_predExprToSmtLib var pe.body})"
    else "?";

  # ══ Refined 类型规范化（INV-SMT-2）════════════════════════════════════
  # { x: T | ⊤ } → T
  normalizeRefined = t:
    if !isRefined t then t
    else
      let pe = refinedPredExp t; in
      if (pe.__predTag or null) == "PTrue" then refinedBase t
      else t;

  # ══ 常用精化类型 ══════════════════════════════════════════════════════
  # { n: Int | n > 0 }
  tPositiveInt =
    mkRefined
      (mkTypeDefault (rPrimitive "Int") KStar)
      "n"
      (mkPCmp ">" (mkPVar "n") (mkPLit 0));

  # { n: Int | n >= 0 }
  tNonNegInt =
    mkRefined
      (mkTypeDefault (rPrimitive "Int") KStar)
      "n"
      (mkPCmp ">=" (mkPVar "n") (mkPLit 0));

  # { s: String | s != "" }
  tNonEmptyString =
    mkRefined
      (mkTypeDefault (rPrimitive "String") KStar)
      "s"
      (mkPCmp "!=" (mkPVar "s") (mkPLit ""));
}
