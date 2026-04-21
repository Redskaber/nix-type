# normalize/substitute.nix — Phase 4.1
# Capture-safe substitution（β-reduction 正确性前提）
# INV-2: 所有计算 = Rewrite(TypeIR)
# 扩展：支持 Phase 4.0 所有 TypeRepr 变体（Mu/Pi/Sigma/Effect/Refined/Sig/Struct）
{ lib, typeLib, reprLib, kindLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault stableId;
  inherit (reprLib)
    rVar rLambda rLambdaK rApply rConstructor rFn rADT rConstrained
    rMu rRecord rRowExtend rRowVar rVariantRow rPi rSigma
    rEffect rEffectMerge rOpaque rAscribe rRefined rSig rStruct rModFunctor rHandler
    isVar isLambda isApply isFn isConstrained;

  # ── 自由变量收集（Free Variable Collection）───────────────────────────────
  # Type: Type -> AttrSet(varName -> true)
  freeVars = t:
    if !isType t then {}
    else
      let v = t.repr.__variant or null; in
      if v == "Var"        then { ${t.repr.name} = true; }
      else if v == "Lambda" then
        # λ param 绑定，param 不是自由变量
        builtins.removeAttrs (freeVars t.repr.body) [ t.repr.param ]
      else if v == "Apply" then
        lib.foldl'
          (acc: arg: acc // freeVars arg)
          (freeVars t.repr.fn)
          (t.repr.args or [])
      else if v == "Fn" then
        freeVars t.repr.from // freeVars t.repr.to
      else if v == "Constrained" then freeVars t.repr.base
      else if v == "Mu" then
        # μ var 绑定
        builtins.removeAttrs (freeVars t.repr.body) [ t.repr.var ]
      else if v == "Pi" then
        freeVars t.repr.domain //
        builtins.removeAttrs (freeVars t.repr.body) [ t.repr.param ]
      else if v == "Sigma" then
        freeVars t.repr.domain //
        builtins.removeAttrs (freeVars t.repr.body) [ t.repr.param ]
      else if v == "ModFunctor" then
        builtins.removeAttrs (freeVars t.repr.body) [ t.repr.param ]
      else if v == "Record" then
        let fnames = builtins.attrNames (t.repr.fields or {}); in
        lib.foldl' (acc: n: acc // freeVars t.repr.fields.${n}) {} fnames
      else if v == "RowExtend" then
        freeVars t.repr.fieldType // freeVars t.repr.rest
      else if v == "RowVar" then { ${t.repr.name} = true; }
      else if v == "Effect" then freeVars t.repr.effectRow
      else if v == "EffectMerge" then
        freeVars t.repr.left // freeVars t.repr.right
      else if v == "Refined" then
        freeVars t.repr.base  # predVar 在 predExpr scope 中，不是 type-level free
      else {};

  # ── α-rename（避免变量捕获）──────────────────────────────────────────────
  # Type: String -> String -> Type -> Type
  rename = oldName: newName: t:
    if !isType t then t
    else
      let v = t.repr.__variant or null; in
      if v == "Var" then
        if t.repr.name == oldName
        then mkTypeDefault (rVar newName (t.repr.scope or "")) t.kind
        else t
      else if v == "Lambda" then
        if t.repr.param == oldName
        then t  # 绑定变量遮蔽，停止
        else
          let body' = rename oldName newName t.repr.body; in
          mkTypeWith (rLambdaK t.repr.param (t.repr.paramKind or kindLib.KStar) body')
                     t.kind t.meta
      else if v == "Apply" then
        let
          fn'   = rename oldName newName t.repr.fn;
          args' = map (rename oldName newName) (t.repr.args or []);
        in mkTypeWith (rApply fn' args') t.kind t.meta
      else if v == "Fn" then
        let
          from' = rename oldName newName t.repr.from;
          to'   = rename oldName newName t.repr.to;
        in mkTypeWith (rFn from' to') t.kind t.meta
      else if v == "Mu" then
        if t.repr.var == oldName then t  # μ var 绑定遮蔽
        else
          let body' = rename oldName newName t.repr.body; in
          mkTypeWith (rMu t.repr.var body') t.kind t.meta
      else if v == "Pi" then
        let
          domain' = rename oldName newName t.repr.domain;
          body'   = if t.repr.param == oldName then t.repr.body
                    else rename oldName newName t.repr.body;
        in mkTypeWith (rPi t.repr.param domain' body') t.kind t.meta
      else if v == "Sigma" then
        let
          domain' = rename oldName newName t.repr.domain;
          body'   = if t.repr.param == oldName then t.repr.body
                    else rename oldName newName t.repr.body;
        in mkTypeWith (rSigma t.repr.param domain' body') t.kind t.meta
      else t;

  # ── 主置换函数（capture-safe）────────────────────────────────────────────
  # Type: String -> Type -> Type -> Type
  # substitute varName replacement targetType
  substitute = varName: replacement: t:
    if !isType t then t
    else
      let v = t.repr.__variant or null; in

      if v == "Var" then
        if t.repr.name == varName then replacement else t

      else if v == "Lambda" then
        if t.repr.param == varName
        then t  # 绑定变量遮蔽，停止替换
        else
          let fvRepl = freeVars replacement; in
          if fvRepl ? ${t.repr.param}
          then
            # 捕获危险！先 α-rename
            let
              freshName = t.repr.param + "_fr_" +
                          builtins.substring 0 8
                            (builtins.hashString "md5" "${varName}${t.repr.param}");
              body'  = rename t.repr.param freshName t.repr.body;
              body'' = substitute varName replacement body';
            in mkTypeWith (rLambdaK freshName (t.repr.paramKind or kindLib.KStar) body'')
                          t.kind t.meta
          else
            let body' = substitute varName replacement t.repr.body; in
            mkTypeWith (rLambdaK t.repr.param (t.repr.paramKind or kindLib.KStar) body')
                       t.kind t.meta

      else if v == "Apply" then
        let
          fn'   = substitute varName replacement t.repr.fn;
          args' = map (substitute varName replacement) (t.repr.args or []);
        in mkTypeWith (rApply fn' args') t.kind t.meta

      else if v == "Fn" then
        let
          from' = substitute varName replacement t.repr.from;
          to'   = substitute varName replacement t.repr.to;
        in mkTypeWith (rFn from' to') t.kind t.meta

      else if v == "Constrained" then
        let base' = substitute varName replacement t.repr.base; in
        mkTypeWith (rConstrained base' t.repr.constraints) t.kind t.meta

      else if v == "Mu" then
        if t.repr.var == varName
        then t  # μ var 绑定遮蔽
        else
          let body' = substitute varName replacement t.repr.body; in
          mkTypeWith (rMu t.repr.var body') t.kind t.meta

      else if v == "Record" then
        let
          fnames  = builtins.attrNames (t.repr.fields or {});
          fields' = builtins.listToAttrs (map (n: {
            name  = n;
            value = substitute varName replacement t.repr.fields.${n};
          }) fnames);
        in mkTypeWith (rRecord fields') t.kind t.meta

      else if v == "RowExtend" then
        let
          ft'   = substitute varName replacement t.repr.fieldType;
          rest' = substitute varName replacement t.repr.rest;
        in mkTypeWith (rRowExtend t.repr.label ft' rest') t.kind t.meta

      else if v == "RowVar" then
        # RowVar substitution（行变量替换）
        if t.repr.name == varName then replacement else t

      else if v == "VariantRow" then
        let
          vnames    = builtins.attrNames (t.repr.variants or {});
          variants' = builtins.listToAttrs (map (n: {
            name  = n;
            value = substitute varName replacement t.repr.variants.${n};
          }) vnames);
          ext' = if t.repr.extension == null then null
                 else substitute varName replacement t.repr.extension;
        in mkTypeWith (rVariantRow variants' ext') t.kind t.meta

      else if v == "Pi" then
        let
          domain' = substitute varName replacement t.repr.domain;
          body' = if t.repr.param == varName then t.repr.body
                  else
                    let fvRepl = freeVars replacement; in
                    if fvRepl ? ${t.repr.param}
                    then
                      let
                        fresh = t.repr.param + "_pi_" +
                                builtins.substring 0 8
                                  (builtins.hashString "md5" "${varName}${t.repr.param}");
                        b' = rename t.repr.param fresh t.repr.body;
                      in substitute varName replacement b'
                    else substitute varName replacement t.repr.body;
          param' = if t.repr.param == varName then t.repr.param  # shadowed
                   else
                     let fvRepl = freeVars replacement; in
                     if fvRepl ? ${t.repr.param}
                     then t.repr.param + "_pi_" +
                          builtins.substring 0 8
                            (builtins.hashString "md5" "${varName}${t.repr.param}")
                     else t.repr.param;
        in mkTypeWith (rPi param' domain' body') t.kind t.meta

      else if v == "Sigma" then
        let
          domain' = substitute varName replacement t.repr.domain;
          body'   = if t.repr.param == varName then t.repr.body
                    else substitute varName replacement t.repr.body;
        in mkTypeWith (rSigma t.repr.param domain' body') t.kind t.meta

      else if v == "Effect" then
        let er' = substitute varName replacement t.repr.effectRow; in
        mkTypeWith (rEffect er') t.kind t.meta

      else if v == "EffectMerge" then
        let
          l' = substitute varName replacement t.repr.left;
          r' = substitute varName replacement t.repr.right;
        in mkTypeWith (rEffectMerge l' r') t.kind t.meta

      else if v == "Refined" then
        let base' = substitute varName replacement t.repr.base; in
        # predVar/predExpr 在 predicate scope，不参与 type substitution
        mkTypeWith (rRefined base' t.repr.predVar t.repr.predExpr) t.kind t.meta

      else if v == "ModFunctor" then
        if t.repr.param == varName
        then t  # module param 绑定遮蔽
        else
          let body' = substitute varName replacement t.repr.body; in
          mkTypeWith (rModFunctor t.repr.param t.repr.paramTy body') t.kind t.meta

      else t;  # Primitive, ADT, RowEmpty, Sig, Struct, Handler, Kind — 无 type vars

  # ── 批量置换 ─────────────────────────────────────────────────────────────
  # Type: [String] -> [Type] -> Type -> Type
  substituteAll = params: args: t:
    lib.foldl'
      (acc: pair: substitute pair.fst pair.snd acc)
      t
      (lib.zipListsWith (p: a: { fst = p; snd = a; }) params args);

  # ── 从 AttrSet 批量置换（subst map: varName → Type）────────────────────
  # Type: AttrSet(String -> Type) -> Type -> Type
  applySubst = substMap: t:
    let varNames = builtins.attrNames substMap; in
    lib.foldl'
      (acc: varName: substitute varName substMap.${varName} acc)
      t
      varNames;

in {
  inherit freeVars rename substitute substituteAll applySubst;
}
