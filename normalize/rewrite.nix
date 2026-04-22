# normalize/rewrite.nix — Phase 4.2
# TRS 主引擎（fuel-based，保证终止）
# INV-2: 所有计算 = Rewrite(TypeIR)，fuel 保证终止
# INV-3: 结果 = NormalForm（无可归约子项）
{ lib, typeLib, reprLib, kindLib, substLib, rulesLib }:

let
  inherit (typeLib) isType mkTypeWith;
  inherit (rulesLib) applyFirstRule allRules;

in rec {

  # ══ 默认 fuel 常量 ════════════════════════════════════════════════════
  DEFAULT_FUEL = 1000;
  DEEP_FUEL    = 3000;  # 深度嵌套类型

  # ══ 核心 normalize（fuel-controlled）════════════════════════════════
  # Type: Int → Type → Type
  normalizeWithFuel = fuel: t:
    if fuel <= 0 then t
    else if !isType t then t
    else
      # Step 1: 递归 normalize 子项
      let t1 = _normalizeChildren (fuel - 1) t; in
      # Step 2: 应用规则（outermost-first strategy）
      let r = applyFirstRule t1; in
      if r == null then t1
      else normalizeWithFuel (fuel - 1) r.result;

  # ── 子项递归（structural recursion）────────────────────────────────
  _normalizeChildren = fuel: t:
    if !isType t || fuel <= 0 then t
    else
      let
        v     = t.repr.__variant or null;
        go    = normalizeWithFuel (fuel - 1);
        goR   = f: mkTypeWith f t.kind t.meta;
      in
      if v == "Lambda" then
        goR { __variant = "Lambda"; param = t.repr.param; body = go t.repr.body; }
      else if v == "Apply" then
        goR { __variant = "Apply"; fn = go t.repr.fn; args = map go (t.repr.args or []); }
      else if v == "Fn" then
        goR { __variant = "Fn"; from = go t.repr.from; to = go t.repr.to; }
      else if v == "Constrained" then
        goR { __variant = "Constrained"; base = go t.repr.base; constraints = t.repr.constraints; }
      else if v == "Mu" then
        goR { __variant = "Mu"; var = t.repr.var; body = go t.repr.body; }
      else if v == "Record" then
        goR { __variant = "Record"; fields = builtins.mapAttrs (n: f: go f) t.repr.fields; }
      else if v == "RowExtend" then
        goR { __variant = "RowExtend"; label = t.repr.label; ty = go t.repr.ty; tail = go t.repr.tail; }
      else if v == "VariantRow" then
        goR { __variant = "VariantRow";
              variants = builtins.mapAttrs (n: vt: go vt) t.repr.variants;
              tail = if t.repr.tail != null then go t.repr.tail else null; }
      else if v == "Effect" then
        goR { __variant = "Effect"; effectRow = go t.repr.effectRow; resultType = go t.repr.resultType; }
      else if v == "EffectMerge" then
        goR { __variant = "EffectMerge"; e1 = go t.repr.e1; e2 = go t.repr.e2; }
      else if v == "Refined" then
        goR { __variant = "Refined"; base = go t.repr.base; predVar = t.repr.predVar; predExpr = t.repr.predExpr; }
      else if v == "Sig" then
        goR { __variant = "Sig"; fields = builtins.mapAttrs (n: f: go f) t.repr.fields; }
      else if v == "Struct" then
        goR { __variant = "Struct"; sig = go t.repr.sig;
              impls = builtins.mapAttrs (n: i: go i) t.repr.impls; }
      else if v == "ModFunctor" then
        goR { __variant = "ModFunctor"; param = t.repr.param;
              paramSig = go t.repr.paramSig; body = go t.repr.body; }
      else if v == "Forall" then
        goR { __variant = "Forall"; vars = t.repr.vars; body = go t.repr.body; }
      else if v == "Pi" then
        goR { __variant = "Pi"; param = t.repr.param;
              paramType = go t.repr.paramType; body = go t.repr.body; }
      else if v == "Sigma" then
        goR { __variant = "Sigma"; param = t.repr.param;
              paramType = go t.repr.paramType; body = go t.repr.body; }
      else t;  # Primitive, Var, Hole, Dynamic — leaves

  # ══ Public API ════════════════════════════════════════════════════════

  # Type: Type → Type（default fuel = 1000）
  normalize' = normalizeWithFuel DEFAULT_FUEL;

  # Type: Type → Type（deep, fuel = 3000）
  normalizeDeep = normalizeWithFuel DEEP_FUEL;

  # ══ 标准化检查（已经是 NF？）═════════════════════════════════════════
  # Type: Type → Bool
  isNormalForm = t:
    if !isType t then true
    else applyFirstRule t == null;

  # ══ Constraint normalize（规范化约束，用于 solver）════════════════════
  # INV-SOL1: 等价约束规范化（对称性 + NF hash）
  # Type: Constraint → Constraint
  normalizeConstraint = c:
    if !builtins.isAttrs c then c
    else
      let tag = c.__constraintTag or null; in
      if tag == "Equality" then
        let
          lhsN = normalize' c.lhs;
          rhsN = normalize' c.rhs;
          # canonical: smaller hash first
          lhsH = builtins.hashString "sha256" (builtins.toJSON lhsN);
          rhsH = builtins.hashString "sha256" (builtins.toJSON rhsN);
        in
        if lhsH <= rhsH then c // { lhs = lhsN; rhs = rhsN; }
        else c // { lhs = rhsN; rhs = lhsN; }
      else if tag == "Class" then
        c // { args = map normalize' c.args; }
      else if tag == "RowEquality" then
        c // { lhsRow = normalize' c.lhsRow; rhsRow = normalize' c.rhsRow; }
      else if tag == "Refined" then
        c // { subject = normalize' c.subject; }
      else c;

  # ══ Constraint 去重 ════════════════════════════════════════════════════
  # Type: [Constraint] → [Constraint]
  deduplicateConstraints = cs:
    let
      withKeys = map (c: { k = builtins.toJSON c; v = c; }) cs;
      uniq = lib.foldl' (acc: x:
        if builtins.elem x.k acc.seen
        then acc
        else { seen = acc.seen ++ [x.k]; result = acc.result ++ [x.v]; }
      ) { seen = []; result = []; } withKeys;
    in
    uniq.result;
}
