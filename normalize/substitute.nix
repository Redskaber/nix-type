# normalize/substitute.nix — Phase 4.2
# capture-safe substitution（避免变量捕获）
# Type: String → Type → Type → Type
{ lib, typeLib, reprLib, kindLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault freeVars;
  inherit (reprLib) rVar rLambda rApply rFn rMu rConstrained rADT
                    rRecord rRowExtend rVariantRow rEffect rEffectMerge
                    rRefined rSig rStruct rModFunctor rForall rPi rSigma;
  inherit (kindLib) KStar;

  # ── fresh variable 生成（de Bruijn 风格）───────────────────────────
  _freshSuffix = used: name:
    let go = n:
      let candidate = "${name}${builtins.toString n}"; in
      if builtins.elem candidate used then go (n + 1)
      else candidate;
    in go 0;

  # ── 收集类型中所有绑定变量名 ────────────────────────────────────────
  _boundVars = t:
    if !isType t then []
    else
      let v = t.repr.__variant or null; in
      if v == "Lambda" then [ t.repr.param ] ++ _boundVars t.repr.body
      else if v == "Mu" then [ t.repr.var ] ++ _boundVars t.repr.body
      else if v == "Pi" then [ t.repr.param ] ++ _boundVars t.repr.body
      else if v == "Sigma" then [ t.repr.param ] ++ _boundVars t.repr.body
      else if v == "Forall" then t.repr.vars ++ _boundVars t.repr.body
      else if v == "Apply" then
        _boundVars t.repr.fn ++ lib.concatMap _boundVars (t.repr.args or [])
      else if v == "Fn" then _boundVars t.repr.from ++ _boundVars t.repr.to
      else if v == "Constrained" then _boundVars t.repr.base
      else [];

in rec {

  # ══ 核心 substitute（capture-safe）════════════════════════════════════
  # Type: String → Type → Type → Type
  # substitute x replacement t  →  t[x := replacement]
  substitute = x: replacement: t:
    if !isType t then t
    else
      let v = t.repr.__variant or null; in
      if v == "Var" then
        if t.repr.name == x then replacement else t
      else if v == "Lambda" then
        if t.repr.param == x then
          # x が shadow されている：再帰しない
          t
        else
          let
            # x is free in replacement → risk of capture
            fvReplacement = freeVars replacement;
            needsRename   = builtins.elem t.repr.param fvReplacement;
            param'        = if needsRename then
              _freshSuffix ([ x ] ++ fvReplacement) t.repr.param
            else t.repr.param;
            body' = if needsRename then
              # rename param → param' in body first
              substitute t.repr.param
                (mkTypeDefault (rVar param' (t.repr.body.repr.scope or ""))
                               KStar)
                t.repr.body
            else t.repr.body;
            newBody = substitute x replacement body';
            newRepr = rLambda param' newBody;
          in
          mkTypeWith newRepr t.kind t.meta
      else if v == "Apply" then
        let
          newFn   = substitute x replacement t.repr.fn;
          newArgs = map (substitute x replacement) (t.repr.args or []);
          newRepr = rApply newFn newArgs;
        in
        mkTypeWith newRepr t.kind t.meta
      else if v == "Fn" then
        let
          newFrom = substitute x replacement t.repr.from;
          newTo   = substitute x replacement t.repr.to;
          newRepr = rFn newFrom newTo;
        in
        mkTypeWith newRepr t.kind t.meta
      else if v == "Constrained" then
        let
          newBase = substitute x replacement t.repr.base;
          newRepr = rConstrained newBase t.repr.constraints;
        in
        mkTypeWith newRepr t.kind t.meta
      else if v == "Mu" then
        if t.repr.var == x then t  # shadowed
        else
          let
            fvReplacement = freeVars replacement;
            needsRename   = builtins.elem t.repr.var fvReplacement;
            var'          = if needsRename then
              _freshSuffix ([ x ] ++ fvReplacement) t.repr.var
            else t.repr.var;
            body' = if needsRename then
              substitute t.repr.var
                (mkTypeDefault (rVar var' "") KStar)
                t.repr.body
            else t.repr.body;
            newBody = substitute x replacement body';
          in
          mkTypeWith (rMu var' newBody) t.kind t.meta
      else if v == "Record" then
        let
          newFields = builtins.mapAttrs (n: ft: substitute x replacement ft) t.repr.fields;
          newRepr   = rRecord newFields;
        in
        mkTypeWith newRepr t.kind t.meta
      else if v == "RowExtend" then
        let
          newTy   = substitute x replacement t.repr.ty;
          newTail = substitute x replacement t.repr.tail;
          newRepr = rRowExtend t.repr.label newTy newTail;
        in
        mkTypeWith newRepr t.kind t.meta
      else if v == "VariantRow" then
        let
          newVariants = builtins.mapAttrs (n: vt: substitute x replacement vt) t.repr.variants;
          newTail     = if t.repr.tail != null then substitute x replacement t.repr.tail else null;
          newRepr     = rVariantRow newVariants newTail;
        in
        mkTypeWith newRepr t.kind t.meta
      else if v == "Effect" then
        let
          newRow = substitute x replacement t.repr.effectRow;
          newRes = substitute x replacement t.repr.resultType;
          newRepr = rEffect newRow newRes;
        in
        mkTypeWith newRepr t.kind t.meta
      else if v == "EffectMerge" then
        let
          newE1   = substitute x replacement t.repr.e1;
          newE2   = substitute x replacement t.repr.e2;
          newRepr = rEffectMerge newE1 newE2;
        in
        mkTypeWith newRepr t.kind t.meta
      else if v == "Refined" then
        let
          newBase = substitute x replacement t.repr.base;
          newRepr = rRefined newBase t.repr.predVar t.repr.predExpr;
        in
        mkTypeWith newRepr t.kind t.meta
      else if v == "Sig" then
        let
          newFields = builtins.mapAttrs (n: ft: substitute x replacement ft) t.repr.fields;
          newRepr   = rSig newFields;
        in
        mkTypeWith newRepr t.kind t.meta
      else if v == "Forall" then
        if builtins.elem x t.repr.vars then t  # shadowed
        else
          let
            newBody = substitute x replacement t.repr.body;
            newRepr = rForall t.repr.vars newBody;
          in
          mkTypeWith newRepr t.kind t.meta
      else t;  # Primitive, Hole, Dynamic, etc. — no subst

  # ══ 批量替换（列表）══════════════════════════════════════════════════
  # Type: [(String, Type)] → Type → Type
  substituteMany = bindings: t:
    lib.foldl' (acc: binding:
      substitute binding.name binding.ty acc
    ) t bindings;

  # ══ UnifiedSubst 应用（Phase 4.2 改进）════════════════════════════════
  # Type: UnifiedSubst → Type → Type
  applyUnifiedSubst = usubst: t:
    let
      typeBindings = usubst.typeBindings or {};
      # 按 key 长度降序排列，避免短 key 覆盖长 key
      sortedKeys = lib.sort (a: b:
        builtins.stringLength a > builtins.stringLength b
      ) (builtins.attrNames typeBindings);
    in
    lib.foldl' (acc: k:
      substitute k typeBindings.${k} acc
    ) t sortedKeys;

  # ══ 构造器参数批量替换（用于 rConstructor unfold）═════════════════════
  # Type: [String] → [Type] → Type → Type
  # 将 params[i] → args[i] 批量代入
  substituteParams = params: args: body:
    if builtins.length params != builtins.length args then body
    else
      let pairs = lib.zipListsWith (p: a: { name = p; ty = a; }) params args; in
      substituteMany pairs body;
}
