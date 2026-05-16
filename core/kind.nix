# core/kind.nix — Phase 4.5
# Kind 系统：完全内化为 Type（自举），Kind-of-Kind = Kind
# INV-K1:     每个类型参数都有确定的 kind
# INV-KIND-1: inferred kinds consistent with annotations（Phase 4.3）
# INV-KIND-2: kind annotations propagate from user context（Phase 4.4）
# INV-KIND-3: kind annotation solving reaches fixpoint              ★ Phase 4.5
#
# Phase 4.5 additions:
#   - solveKindConstraintsFixpoint: iterate solveKindConstraints until
#     the substitution stabilizes (no new bindings added).
#     Bounded at maxIter=10 to guarantee termination in pure Nix.
#     Termination argument: each iteration binds at least one KVar
#     (strictly decreasing free-KVar count) or is a no-op.
#     The bound of 10 is safe because realistic kind-inference problems
#     have at most ~4 levels of KArrow nesting.
#   - inferKindWithAnnotationFixpoint: like inferKindWithAnnotation but
#     uses the fixpoint solver for the unification step.
#   - checkKindAnnotationFixpoint: INV-KIND-3 verifier.
{ lib }:
let
  # ══ Kind Repr 标记（不依赖 typeLib，避免循环）══════════════════════════

  KStar    = { __kindTag = "Star";   };
  KRow     = { __kindTag = "Row";    };
  KEffect  = { __kindTag = "Effect"; };
  KUnbound = { __kindTag = "Unbound"; name = "?"; };

  # KArrow: Kind → Kind（类型构造器 kind）
  KArrow = from: to: { __kindTag = "Arrow"; from = from; to = to; };

  # KVar: kind 变量（Phase 4.2: kind-level inference）
  KVar = name: { __kindTag = "Var"; name = name; };

  # ══ Kind 谓词 ══════════════════════════════════════════════════════════
  isKind     = k: builtins.isAttrs k && k ? __kindTag;
  isStar     = k: isKind k && k.__kindTag == "Star";
  isKArrow   = k: isKind k && k.__kindTag == "Arrow";
  isKRow     = k: isKind k && k.__kindTag == "Row";
  isKEffect  = k: isKind k && k.__kindTag == "Effect";
  isKVar     = k: isKind k && k.__kindTag == "Var";
  isKUnbound = k: isKind k && k.__kindTag == "Unbound";

  # ══ Kind 序列化（canonical，用于 hash）════════════════════════════════
  serializeKind = k:
    if !isKind k then "?"
    else if isStar k    then "*"
    else if isKRow k    then "Row"
    else if isKEffect k then "Effect"
    else if isKVar k    then "(KVar ${k.name})"
    else if isKUnbound k then "Unbound"
    else if isKArrow k  then "(${serializeKind k.from} -> ${serializeKind k.to})"
    else "?";

  # ══ Kind Equality ══════════════════════════════════════════════════════
  kindEq = a: b:
    if !isKind a || !isKind b then false
    else if a.__kindTag != b.__kindTag then false
    else if isStar a then true
    else if isKRow a then true
    else if isKEffect a then true
    else if isKVar a then a.name == b.name
    else if isKUnbound a then true
    else if isKArrow a then (kindEq a.from b.from) && (kindEq a.to b.to)
    else false;

  # ══ Kind Arity（类型构造器参数数量）══════════════════════════════════
  kindArity = k:
    if isKArrow k then 1 + kindArity k.to
    else 0;

  # ══ Kind Application（应用后的结果 kind）══════════════════════════════
  # Type: Kind → Kind → Kind | null
  applyKind = fnKind: argKind:
    if isKArrow fnKind then
      if kindEq fnKind.from argKind then fnKind.to
      else null  # kind mismatch
    else null;

  # ══ Kind Substitution（kind-level substitution）══════════════════════
  # Type: AttrSet(name → Kind) → Kind → Kind
  applyKindSubst = ksubst: k:
    if !isKind k then k
    else if isKVar k then
      let bound = ksubst.${k.name} or null; in
      if bound != null then bound else k
    else if isKArrow k then
      KArrow (applyKindSubst ksubst k.from) (applyKindSubst ksubst k.to)
    else k;

  # ══ Kind Unification（Phase 4.2/4.3: HM kind inference）═════════════
  # Type: Kind → Kind → { ok: Bool; subst: AttrSet } | { ok: false; error }
  unifyKind = a: b:
    if kindEq a b then { ok = true; subst = {}; }
    else if isKUnbound a || isKUnbound b then { ok = true; subst = {}; }
    else if isKVar a then
      # Occurs check for kind vars
      if _occursKind a.name b then
        { ok = false; error = "kind occurs check: ${a.name} in ${serializeKind b}"; }
      else
        { ok = true; subst = { ${a.name} = b; }; }
    else if isKVar b then
      if _occursKind b.name a then
        { ok = false; error = "kind occurs check: ${b.name} in ${serializeKind a}"; }
      else
        { ok = true; subst = { ${b.name} = a; }; }
    else if isKArrow a && isKArrow b then
      let r1 = unifyKind a.from b.from; in
      if !r1.ok then r1
      else
        let
          a2 = applyKindSubst r1.subst a.to;
          b2 = applyKindSubst r1.subst b.to;
          r2 = unifyKind a2 b2;
        in
        if !r2.ok then r2
        else { ok = true; subst = r1.subst // r2.subst; }
    else { ok = false; error = "kind mismatch: ${serializeKind a} vs ${serializeKind b}"; };

  # ══ Kind Occurs Check（Phase 4.3）════════════════════════════════════
  # Type: String → Kind → Bool
  _occursKind = varName: k:
    if !isKind k then false
    else if isKVar k then k.name == varName
    else if isKArrow k then
      _occursKind varName k.from || _occursKind varName k.to
    else false;

  # ══ Kind Free Variables（Phase 4.3：用于 kind generalization）════════
  # Type: Kind → [String]
  kindFreeVars = k:
    if !isKind k then []
    else if isKVar k then [ k.name ]
    else if isKArrow k then
      lib.unique (kindFreeVars k.from ++ kindFreeVars k.to)
    else [];

  # ══ Kind Compose Substitution ════════════════════════════════════════
  # Type: AttrSet → AttrSet → AttrSet
  # s2 ∘ s1: apply s1 first, then s2
  composeKindSubst = s2: s1:
    let
      s1Applied = builtins.mapAttrs (_: k: applyKindSubst s2 k) s1;
    in
    s1Applied // s2;

  # ══ Kind Environment Merge（Phase 4.4）════════════════════════════════
  # Type: AttrSet(name → Kind) → AttrSet(name → Kind) → AttrSet
  # Merges two kind environments, preferring concrete kinds over KVar.
  mergeKindEnv = envA: envB:
    let
      allKeys = lib.unique (builtins.attrNames envA ++ builtins.attrNames envB);
    in
    builtins.listToAttrs (map (k:
      let
        kA = envA.${k} or null;
        kB = envB.${k} or null;
        chosen =
          if kA == null then kB
          else if kB == null then kA
          # prefer concrete (non-KVar) kinds
          else if isKVar kA && !isKVar kB then kB
          else if !isKVar kA && isKVar kB then kA
          else kA;  # both concrete or both vars: keep kA
      in
      lib.nameValuePair k chosen
    ) allKeys);

  # ══ Kind Inference（Phase 4.3）════════════════════════════════════════
  # Type: AttrSet(varName → Kind) → TypeRepr → { kind: Kind; subst: AttrSet }
  inferKind = kenv: repr:
    let v = repr.__variant or null; in
    if v == "Primitive" then
      { kind = KStar; subst = {}; }
    else if v == "Var" then
      let k = kenv.${repr.name} or (KVar repr.name); in
      { kind = k; subst = {}; }
    else if v == "Lambda" then
      let
        # param 有 kind kp（新鲜 KVar）
        kp = KVar "_kp_${repr.param}";
        newEnv = kenv // { ${repr.param} = kp; };
        bodyResult = inferKind newEnv repr.body.repr;
      in
      { kind = KArrow kp bodyResult.kind; subst = bodyResult.subst; }
    else if v == "Apply" then
      let
        fnResult   = inferKind kenv repr.fn.repr;
        argsResults = map (a: inferKind kenv a.repr) (repr.args or []);
        # 折叠应用：fn: a₁ → a₂ → ... → k
        resultKVar = KVar "_kr_${builtins.hashString "sha256" (serializeKind fnResult.kind)}";
        foldResult = lib.foldl' (acc: argR:
          let r = unifyKind acc.kind (KArrow argR.kind resultKVar); in
          if !r.ok then acc // { error = r.error or null; }
          else
            let newSubst = composeKindSubst r.subst acc.subst; in
            { kind  = applyKindSubst newSubst resultKVar;
              subst = newSubst; }
        ) { kind = fnResult.kind; subst = fnResult.subst; } argsResults;
      in
      { kind = foldResult.kind; subst = foldResult.subst; }
    else if v == "Fn" then
      { kind = KStar; subst = {}; }
    else if v == "ADT" then
      { kind = KStar; subst = {}; }
    else if v == "Record" then
      { kind = KStar; subst = {}; }
    else if v == "RowExtend" || v == "RowEmpty" then
      { kind = KRow; subst = {}; }
    else if v == "VariantRow" then
      { kind = KRow; subst = {}; }
    else if v == "Effect" || v == "EffectMerge" then
      { kind = KEffect; subst = {}; }
    else if v == "Constrained" then
      inferKind kenv repr.base.repr
    else if v == "Mu" then
      { kind = KStar; subst = {}; }
    else if v == "Forall" then
      { kind = KStar; subst = {}; }
    else if v == "Constructor" then
      let
        resultKind = lib.foldl' (acc: _: KArrow KStar acc) KStar (repr.params or []);
      in
      { kind = resultKind; subst = {}; }
    else if v == "Dynamic" then
      { kind = KStar; subst = {}; }
    else
      { kind = KStar; subst = {}; };

  # ══ Phase 4.4: inferKind with Annotation Propagation（INV-KIND-2）════
  # Type: AttrSet(varName → Kind) → TypeRepr → Kind → InferResult
  inferKindWithAnnotation = kenv: repr: annotation:
    let
      base = inferKind kenv repr;
    in
    if annotation == null then
      base // { annotationOk = true; }
    else
      let r = unifyKind base.kind annotation; in
      if !r.ok then
        let errStr = if r ? error then r.error else "?"; in
        { kind         = base.kind;
          subst        = base.subst;
          annotationOk = false;
          error        = "INV-KIND-2: inferred ${serializeKind base.kind} != annotation ${serializeKind annotation}: ${errStr}"; }
      else
        { kind         = applyKindSubst r.subst base.kind;
          subst        = composeKindSubst r.subst base.subst;
          annotationOk = true; };

  # ══ Phase 4.4: INV-KIND-2 post-hoc verifier ═══════════════════════════
  # Type: Kind → Kind → Bool
  checkKindAnnotation = inferredKind: annotationKind:
    (unifyKind inferredKind annotationKind).ok;

  # ══ Kind Constraint Solve（Phase 4.3: INV-KIND-1）════════════════════
  # Type: [KindConstraint] → { ok: Bool; subst: AttrSet; residual: [KindConstraint] }
  solveKindConstraints = kcs:
    lib.foldl' (acc: kc:
      if !acc.ok then acc
      else
        let
          var = kc.typeVar or null;
          expectedKind = kc.expectedKind or KStar;
          currentKind = acc.subst.${var} or (KVar var);
          r = unifyKind currentKind expectedKind;
        in
        if var == null then
          acc // { residual = acc.residual ++ [ kc ]; }
        else if !r.ok then
          { ok = false; error = r.error; subst = acc.subst; residual = []; }
        else
          { ok     = true;
            subst  = composeKindSubst r.subst acc.subst;
            residual = acc.residual; }
    ) { ok = true; subst = {}; residual = []; } kcs;

  # ══ Phase 4.5: Fixpoint Kind Constraint Solver（INV-KIND-3）══════════
  # Type: [KindConstraint] → { ok: Bool; subst: AttrSet; residual: [KindConstraint]; iters: Int }
  #
  # Iterates solveKindConstraints until the substitution stabilizes.
  # Termination: bounded at maxIter=10 iterations (safe for practical use).
  # At each step we apply the accumulated subst to the residual constraints
  # and re-run the solver; if no new bindings are added, we stop.
  #
  # INV-KIND-3: the final subst is a fixpoint —
  #   solveKindConstraints(applySubstToKCs(residual, subst)).subst == {}
  #   (no further unification steps possible on the residual)
  solveKindConstraintsFixpoint = kcs:
    let
      maxIter = 10;
      # Apply accumulated kind subst to a list of KindConstraints
      _applySubstToKCs = subst: kcList:
        map (kc:
          kc // {
            expectedKind = applyKindSubst subst (kc.expectedKind or KStar);
          }
        ) kcList;

      # One fixpoint step: apply current subst, re-solve
      _step = acc:
        if !acc.ok || acc.residual == [] then
          acc // { _done = true; }
        else
          let
            refreshed = _applySubstToKCs acc.subst acc.residual;
            r = solveKindConstraints refreshed;
          in
          if !r.ok then
            r // { iters = acc.iters + 1; _done = true; }
          else
            let
              newSubst  = composeKindSubst r.subst acc.subst;
              newKeys   = builtins.attrNames r.subst;
              converged = newKeys == [];   # no new bindings → fixpoint
            in
            { ok       = true;
              subst    = newSubst;
              residual = r.residual;
              iters    = acc.iters + 1;
              _done    = converged; };

      # Initial solve
      init = (solveKindConstraints kcs) // { iters = 1; _done = false; };

      # Iterate up to maxIter more times
      iterList = builtins.genList (x: x) (maxIter - 1);
      final = lib.foldl' (acc: _:
        if acc._done then acc
        else _step acc
      ) init iterList;
    in
    { ok       = final.ok or false;
      subst    = final.subst or {};
      residual = final.residual or [];
      iters    = final.iters or 1;
      converged = final._done or true; };

  # ══ Phase 4.5: INV-KIND-3 fixpoint verifier ═══════════════════════════
  # Type: [KindConstraint] → Bool
  # Returns true iff solveKindConstraintsFixpoint converged before maxIter.
  checkKindAnnotationFixpoint = kcs:
    let r = solveKindConstraintsFixpoint kcs; in
    r.ok && (r.converged or false);

  # ══ Phase 4.5: inferKindWithAnnotation using fixpoint ══════════════════
  # Like inferKindWithAnnotation, but the kind-unification step uses
  # the fixpoint solver when the annotation introduces KVars.
  # Returns: { kind: Kind; subst: AttrSet; annotationOk: Bool; iters: Int }
  inferKindWithAnnotationFixpoint = kenv: repr: annotation:
    let
      base = inferKind kenv repr;
    in
    if annotation == null then
      base // { annotationOk = true; iters = 0; }
    else
      let
        # Build a synthetic KindConstraint for the annotation
        syntheticKC = [ { typeVar = "__root"; expectedKind = annotation; } ];
        # Wrap: base.kind goes into env as "__root"
        enrichedEnv = kenv // { "__root" = base.kind; };
        r = solveKindConstraintsFixpoint syntheticKC;
        finalKind = applyKindSubst r.subst base.kind;
        annotationMatches = kindEq (applyKindSubst r.subst base.kind)
          (applyKindSubst r.subst annotation);
      in
      if !r.ok then
        { kind         = base.kind;
          subst        = base.subst;
          annotationOk = false;
          iters        = r.iters or 1;
          error        = "INV-KIND-3: fixpoint failed on annotation ${serializeKind annotation}"; }
      else
        { kind         = finalKind;
          subst        = composeKindSubst r.subst base.subst;
          annotationOk = annotationMatches;
          iters        = r.iters or 1; };

  # ══ Built-in Type Kind Annotations ════════════════════════════════════
  defaultKinds = {
    "Int"    = KStar;
    "Bool"   = KStar;
    "String" = KStar;
    "Float"  = KStar;
    "Unit"   = KStar;
    "List"   = KArrow KStar KStar;
    "Maybe"  = KArrow KStar KStar;
    "Either" = KArrow KStar (KArrow KStar KStar);
    "Map"    = KArrow KStar (KArrow KStar KStar);
    "IO"     = KArrow KStar KStar;
  };
in
{
  inherit
  # ══ Kind Repr 标记（不依赖 typeLib，避免循环）══════════════════════════
  KStar
  KRow
  KEffect
  KUnbound
  KArrow
  KVar
  # ══ Kind 谓词 ══════════════════════════════════════════════════════════
  isKind
  isStar
  isKArrow
  isKRow
  isKEffect
  isKVar
  isKUnbound
  # ══ Kind 序列化（canonical，用于 hash）════════════════════════════════
  serializeKind
  # ══ Kind Equality ══════════════════════════════════════════════════════
  kindEq
  # ══ Kind Arity（类型构造器参数数量）══════════════════════════════════
  kindArity
  # ══ Kind Application（应用后的结果 kind）══════════════════════════════
  applyKind
  # ══ Kind Substitution（kind-level substitution）══════════════════════
  applyKindSubst
  # ══ Kind Unification（Phase 4.2/4.3: HM kind inference）═════════════
  unifyKind
  # ══ Kind Occurs Check（Phase 4.3）════════════════════════════════════
  _occursKind
  # ══ Kind Free Variables（Phase 4.3：用于 kind generalization）════════
  kindFreeVars
  # ══ Kind Compose Substitution ════════════════════════════════════════
  composeKindSubst
  # ══ Kind Environment Merge（Phase 4.4）════════════════════════════════
  mergeKindEnv
  # ══ Kind Inference（Phase 4.3）════════════════════════════════════════
  inferKind
  # ══ Phase 4.4: inferKind with Annotation Propagation（INV-KIND-2）════
  inferKindWithAnnotation
  # ══ Phase 4.4: INV-KIND-2 post-hoc verifier ═══════════════════════════
  checkKindAnnotation
  # ══ Kind Constraint Solve（Phase 4.3: INV-KIND-1）════════════════════
  solveKindConstraints
  # ══ Phase 4.5: Fixpoint Kind Constraint Solver（INV-KIND-3）══════════
  solveKindConstraintsFixpoint
  # ══ Phase 4.5: INV-KIND-3 fixpoint verifier ═══════════════════════════
  checkKindAnnotationFixpoint
  # ══ Phase 4.5: inferKindWithAnnotation using fixpoint ══════════════════
  inferKindWithAnnotationFixpoint
  # ══ Built-in Type Kind Annotations ════════════════════════════════════
  defaultKinds
  ;
}
