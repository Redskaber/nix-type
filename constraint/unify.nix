# constraint/unify.nix — Phase 3.2
# Robinson Unification（完整 bisimulation-based Mu + freeVarsRepr 集成）
#
# Phase 3.2 新增/修复：
#   P3.2-2: _unifyMu bisimulation（guard set + fuel，真正 equi-recursive）
#   P3.2-4: _applySubstType 完整递归（全 TypeRepr 变体覆盖）
#   overlap partial unification（INV-I2 辅助，供 instanceLib 使用）
#
# 不变量继承（Phase 3.1）：
#   INV-U4: Lambda unify → serializeReprAlphaCanonical 比较
#   INV-EQ4: rowVar unify → rigid name check
#   occur check: 完整（防止无限类型）
#
# bisimulation 语义（Equi-recursive）：
#   _unifyMu 使用 guardSet 记录"正在比较的 (a.id, b.id) 对"
#   若 (a.id, b.id) 已在 guard 中 → 假设成立（coinductive step）
#   展开一步：μ(α).T → T[α↦μ(α).T]，再递归比较 body
#   muFuel 控制最大展开深度（防止 divergence）
#
# 结果类型：{ ok: Bool; subst: AttrSet; error?: String }
{ lib, typeLib, reprLib, substLib, serialLib, hashLib }:

let
  inherit (typeLib) isType mkTypeWith withRepr;
  inherit (reprLib) rVar freeVarsRepr;
  inherit (substLib) substitute substituteAll composeSubst;
  inherit (serialLib) serializeReprAlphaCanonical;
  inherit (hashLib) typeHash;

  # ── 内部工具 ──────────────────────────────────────────────────────────────────

  # zipLists：对齐两个列表为 pair 列表（index-based）
  _zipLists = xs: ys:
    lib.imap0 (i: x: { a = x; b = builtins.elemAt ys i; }) xs;

  # 默认 bisimulation fuel（防 diverge）
  _defaultMuFuel = 32;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 公共入口
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> Type -> Type -> { ok; subst; error? }
  unify = subst: a: b:
    unifyWith {} subst a b;

  # binders: AttrSet String Bool（当前 binder 集合，区分 bound/free var）
  # Type: AttrSet -> AttrSet -> Type -> Type -> { ok; subst; error? }
  unifyWith = binders: subst: a: b:
    _unifyCore {} binders subst a b;

  # ══════════════════════════════════════════════════════════════════════════════
  # 核心 Unification（带 guardSet for bisimulation）
  # ══════════════════════════════════════════════════════════════════════════════

  # guardSet: AttrSet String Bool  — "id_a:id_b" 形式的 bisimulation 对
  # Type: GuardSet -> Binders -> Subst -> Type -> Type -> { ok; subst; error? }
  _unifyCore = guardSet: binders: subst: a: b:
    let
      a' = _applySubstTypeFull subst a;
      b' = _applySubstTypeFull subst b;
      va = a'.repr.__variant or null;
      vb = b'.repr.__variant or null;
    in

    # 1. 相同 hash → 直接成功（INV-EQ1）
    if typeHash a' == typeHash b'
    then { ok = true; inherit subst; }

    # 2. a' = free Var → bind
    else if va == "Var" && !(binders ? ${a'.repr.name or ""})
    then _bindVar subst (a'.repr.name or "") b'

    # 3. b' = free Var → bind（对称）
    else if vb == "Var" && !(binders ? ${b'.repr.name or ""})
    then _bindVar subst (b'.repr.name or "") a'

    # 4. 类型构造器不同 → fail
    else if va != vb
    then { ok = false; inherit subst; error = "type mismatch: ${va} vs ${vb}"; }

    # 5. 按 variant 分派
    else if va == "Primitive"
    then _unifyPrimitive subst a' b'

    else if va == "Fn"
    then _unifyFn guardSet binders subst a' b'

    else if va == "Apply"
    then _unifyApply guardSet binders subst a' b'

    else if va == "Lambda"
    then _unifyLambda guardSet binders subst a' b'

    else if va == "Pi"
    then _unifyBinder "Pi" guardSet binders subst a' b'

    else if va == "Sigma"
    then _unifyBinder "Sigma" guardSet binders subst a' b'

    else if va == "Constructor"
    then _unifyConstructor guardSet binders subst a' b'

    else if va == "Mu"
    then _unifyMu guardSet binders subst a' b' _defaultMuFuel

    else if va == "Record"
    then _unifyRecord guardSet binders subst a' b'

    else if va == "RowExtend"
    then _unifyRowExtend guardSet binders subst a' b'

    else if va == "VariantRow"
    then _unifyVariantRow guardSet binders subst a' b'

    else if va == "Effect"
    then _unifyEffect guardSet binders subst a' b'

    else if va == "Constrained"
    # Constrained: unify base（constraints 不参与 unification）
    then _unifyCore guardSet binders subst
           (a'.repr.base or a') (b'.repr.base or b')

    else if va == "ADT"
    then _unifyADT guardSet binders subst a' b'

    else
    { ok = false; inherit subst; error = "cannot unify: ${va}"; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Var 绑定（occur check）
  # ══════════════════════════════════════════════════════════════════════════════

  _bindVar = subst: name: t:
    if _occurs name t
    then { ok = false; inherit subst; error = "occur check: ${name} in ${t.id or "?"}"; }
    else { ok = true; subst = subst // { ${name} = t; }; };

  _occurs = name: t:
    builtins.elem name (freeVarsRepr t.repr);

  # ══════════════════════════════════════════════════════════════════════════════
  # 基本变体统一
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyPrimitive = subst: a: b:
    if a.repr.name or "" == b.repr.name or ""
    then { ok = true; inherit subst; }
    else { ok = false; inherit subst;
           error = "primitive mismatch: ${a.repr.name or "?"} vs ${b.repr.name or "?"}"; };

  _unifyFn = guardSet: binders: subst: a: b:
    let r1 = _unifyCore guardSet binders subst (a.repr.from or a) (b.repr.from or b); in
    if !r1.ok then r1
    else _unifyCore guardSet binders r1.subst (a.repr.to or a) (b.repr.to or b);

  _unifyApply = guardSet: binders: subst: a: b:
    let
      argsA = a.repr.args or [];
      argsB = b.repr.args or [];
    in
    if builtins.length argsA != builtins.length argsB
    then { ok = false; inherit subst;
           error = "Apply arity: ${builtins.toString (builtins.length argsA)} vs ${builtins.toString (builtins.length argsB)}"; }
    else
      let r1 = _unifyCore guardSet binders subst (a.repr.fn or a) (b.repr.fn or b); in
      if !r1.ok then r1
      else
        lib.foldl'
          (acc: pair:
            if !acc.ok then acc
            else _unifyCore guardSet binders acc.subst pair.a pair.b)
          r1
          (_zipLists argsA argsB);

  # ══════════════════════════════════════════════════════════════════════════════
  # Lambda / Pi / Sigma（binder 处理，INV-U4）
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyLambda = guardSet: binders: subst: a: b:
    let
      paramA = a.repr.param or "_";
      paramB = b.repr.param or "_";
      bodyA  = a.repr.body or a;
      bodyB  = b.repr.body or b;
      # alpha-rename b's param to a's param before unifying bodies
      renamedBodyB =
        if paramA == paramB then bodyB
        else substitute paramB
          (mkTypeWith { __variant = "Var"; name = paramA; scope = 0; } b.kind b.meta)
          bodyB;
    in
    _unifyCore guardSet (binders // { ${paramA} = true; }) subst bodyA renamedBodyB;

  # 统一处理 Pi / Sigma（相同语义：带 domain 的 binder）
  _unifyBinder = tag: guardSet: binders: subst: a: b:
    let
      paramA  = a.repr.param or "_";
      paramB  = b.repr.param or "_";
      domA    = a.repr.domain or a;
      domB    = b.repr.domain or b;
      bodyA   = a.repr.body or a;
      bodyB   = b.repr.body or b;
      r1      = _unifyCore guardSet binders subst domA domB;
      fresh   = paramA;
      renamedB =
        if paramA == paramB then bodyB
        else substitute paramB
          (mkTypeWith { __variant = "Var"; name = fresh; scope = 0; } b.kind b.meta)
          bodyB;
    in
    if !r1.ok then r1
    else _unifyCore guardSet (binders // { ${fresh} = true; }) r1.subst bodyA renamedB;

  # ══════════════════════════════════════════════════════════════════════════════
  # Constructor
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyConstructor = guardSet: binders: subst: a: b:
    if a.repr.name or "" != b.repr.name or ""
    then { ok = false; inherit subst;
           error = "Constructor mismatch: ${a.repr.name or "?"} vs ${b.repr.name or "?"}"; }
    else
      let
        bodyA = a.repr.body or null;
        bodyB = b.repr.body or null;
      in
      if bodyA == null || bodyB == null
      then { ok = true; inherit subst; }
      else _unifyCore guardSet binders subst bodyA bodyB;

  # ══════════════════════════════════════════════════════════════════════════════
  # Mu Unification — Phase 3.2：真正的 bisimulation（guard set + fuel）
  #
  # 语义：μ-types 是 equi-recursive（定义相等 ≡ coinductive bisimulation）
  # 算法：
  #   1. 构造 guardKey = "${a.id}:${b.id}"
  #   2. 若已在 guardSet 中 → 假设成立（coinductive hypothesis）
  #   3. 否则，将 guardKey 加入 guardSet
  #   4. 展开双方 Mu 一步：μ(α).T → T[α↦μ(α).T]
  #   5. 递归比较展开后的 body（带 guardSet 防止 loop）
  #   6. muFuel 耗尽 → conservative fail（更好：模拟 up-to congruence）
  #
  # 正确性：
  #   - guardSet 使算法对互相递归的 Mu-type 对是终止的
  #   - 最大展开深度由 muFuel 控制（防止无限展开）
  #   - coinductive hypothesis 对 equi-recursive semantics 是 sound 的
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: GuardSet -> Binders -> Subst -> Type -> Type -> Int -> { ok; subst; error? }
  _unifyMu = guardSet: binders: subst: a: b: muFuel:
    let
      # bisimulation key：规范化对（小 id 在前）
      idA = a.id or (typeHash a);
      idB = b.id or (typeHash b);
      guardKey =
        if idA <= idB
        then "${idA}:${idB}"
        else "${idB}:${idA}";
    in

    # coinductive hypothesis：若此对已在 guard 中 → 假设 ok（成立）
    if guardSet ? ${guardKey}
    then { ok = true; inherit subst; }

    # fuel 耗尽：保守 fail（不展开）
    else if muFuel <= 0
    then
      # 最后尝试 alpha-canonical 比较
      let
        serA = serializeReprAlphaCanonical a.repr;
        serB = serializeReprAlphaCanonical b.repr;
      in
      if serA == serB
      then { ok = true; inherit subst; }
      else { ok = false; inherit subst;
             error = "Mu unification: fuel exhausted, structural mismatch"; }

    else
      let
        guardSet' = guardSet // { ${guardKey} = true; };
        varA = a.repr.var or "_";
        varB = b.repr.var or "_";
        bodyA = a.repr.body or null;
        bodyB = b.repr.body or null;
      in
      if bodyA == null || bodyB == null
      then { ok = false; inherit subst; error = "Mu: missing body"; }
      else
        let
          # 展开 a：μ(α).T_a → T_a[α↦μ(α).T_a]
          unfoldedA = substitute varA a bodyA;
          # 展开 b：μ(β).T_b → T_b[β↦μ(β).T_b]
          unfoldedB = substitute varB b bodyB;
        in
        # 比较展开后的结果（同一 guard set）
        # 注意：可能两个 unfold 都不是 Mu（已完全展开），也可能仍是 Mu
        # 递归调用 _unifyCore（它会自动再次分派到 _unifyMu 若仍是 Mu）
        _unifyMuBodies guardSet' binders subst unfoldedA unfoldedB (muFuel - 1);

  # 比较展开后的 Mu body（辅助，避免递归 _unifyMu 无限展开）
  _unifyMuBodies = guardSet: binders: subst: unfoldedA: unfoldedB: muFuel:
    let
      vA = unfoldedA.repr.__variant or null;
      vB = unfoldedB.repr.__variant or null;
    in
    # 若展开后两者都是 Mu，再递归 _unifyMu（带减少的 fuel）
    if vA == "Mu" && vB == "Mu"
    then _unifyMu guardSet binders subst unfoldedA unfoldedB muFuel
    # 否则：正常 _unifyCore（已展开到非 Mu 层）
    else _unifyCore guardSet binders subst unfoldedA unfoldedB;

  # ══════════════════════════════════════════════════════════════════════════════
  # Record unification
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyRecord = guardSet: binders: subst: a: b:
    let
      fieldsA = a.repr.fields or {};
      fieldsB = b.repr.fields or {};
      rowVarA = a.repr.rowVar or null;
      rowVarB = b.repr.rowVar or null;
      keysA   = lib.sort lib.lessThan (builtins.attrNames fieldsA);
      keysB   = lib.sort lib.lessThan (builtins.attrNames fieldsB);
    in
    # closed record: keys 必须相同
    if rowVarA == null && rowVarB == null then
      if keysA != keysB
      then { ok = false; inherit subst;
             error = "Record fields: [${builtins.concatStringsSep "," keysA}] vs [${builtins.concatStringsSep "," keysB}]"; }
      else
        lib.foldl'
          (acc: k:
            if !acc.ok then acc
            else _unifyCore guardSet binders acc.subst fieldsA.${k} fieldsB.${k})
          { ok = true; inherit subst; }
          keysA
    # open record: rowVar 必须 unify
    else if rowVarA != null && rowVarB != null then
      # Phase 3.2: rigid rowVar equality（INV-EQ4）
      if rowVarA == rowVarB
      then
        # same rowVar: fields must match
        if keysA != keysB
        then { ok = false; inherit subst; error = "Open record fields mismatch (same rowVar)"; }
        else
          lib.foldl'
            (acc: k:
              if !acc.ok then acc
              else _unifyCore guardSet binders acc.subst fieldsA.${k} fieldsB.${k})
            { ok = true; inherit subst; }
            keysA
      else
        # different rowVars: attempt row unification (structural extension check)
        _unifyOpenRecords guardSet binders subst a b
    else
      { ok = false; inherit subst;
        error = "Record open/closed mismatch: rowVarA=${builtins.toString (rowVarA != null)} rowVarB=${builtins.toString (rowVarB != null)}"; };

  # Open record unification：一个字段集是另一个的子集 + rowVar binding
  _unifyOpenRecords = guardSet: binders: subst: a: b:
    let
      fieldsA = a.repr.fields or {};
      fieldsB = b.repr.fields or {};
      rowVarA = a.repr.rowVar or null;
      rowVarB = b.repr.rowVar or null;
      keysA   = lib.sort lib.lessThan (builtins.attrNames fieldsA);
      keysB   = lib.sort lib.lessThan (builtins.attrNames fieldsB);
      commonKeys = builtins.filter (k: fieldsB ? ${k}) keysA;
      extraKeysA  = builtins.filter (k: !(fieldsB ? ${k})) keysA;
      extraKeysB  = builtins.filter (k: !(fieldsA ? ${k})) keysB;
    in
    # 先统一公共字段
    let
      r1 = lib.foldl'
        (acc: k:
          if !acc.ok then acc
          else _unifyCore guardSet binders acc.subst fieldsA.${k} fieldsB.${k})
        { ok = true; inherit subst; }
        commonKeys;
    in
    if !r1.ok then r1
    else
      # 尝试将 extraKeys 对应绑定到对方的 rowVar
      # Phase 3.2 简化：若双方 extraKeys 都为空且 rowVars 可 bind → ok
      if extraKeysA == [] && extraKeysB == []
      then r1  # 完全匹配（不同 rowVar 名，但字段相同）
      else
        # 有额外字段：尝试 rowVar 绑定（简化：仅处理单方向 extra）
        # 完整 row unification 是 Phase 4 目标
        { ok = false; subst = r1.subst;
          error = "Open record: extra fields [${builtins.concatStringsSep "," extraKeysA}] / [${builtins.concatStringsSep "," extraKeysB}] - full row unification is Phase 4"; };

  # ══════════════════════════════════════════════════════════════════════════════
  # RowExtend unification
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyRowExtend = guardSet: binders: subst: a: b:
    let
      lblA = a.repr.label or "";
      lblB = b.repr.label or "";
    in
    if lblA != lblB
    then { ok = false; inherit subst; error = "RowExtend label: ${lblA} vs ${lblB}"; }
    else
      let r1 = _unifyCore guardSet binders subst
                 (a.repr.fieldType or a) (b.repr.fieldType or b); in
      if !r1.ok then r1
      else _unifyCore guardSet binders r1.subst (a.repr.rest or a) (b.repr.rest or b);

  # ══════════════════════════════════════════════════════════════════════════════
  # VariantRow unification
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyVariantRow = guardSet: binders: subst: a: b:
    let
      varsA = a.repr.variants or {};
      varsB = b.repr.variants or {};
      tailA = a.repr.tail or null;
      tailB = b.repr.tail or null;
      keysA = lib.sort lib.lessThan (builtins.attrNames varsA);
      keysB = lib.sort lib.lessThan (builtins.attrNames varsB);
    in
    if keysA != keysB
    then { ok = false; inherit subst;
           error = "VariantRow: [${builtins.concatStringsSep "," keysA}] vs [${builtins.concatStringsSep "," keysB}]"; }
    else
      let
        r1 = lib.foldl'
          (acc: k:
            if !acc.ok then acc
            else _unifyCore guardSet binders acc.subst varsA.${k} varsB.${k})
          { ok = true; inherit subst; }
          keysA;
      in
      if !r1.ok then r1
      else if tailA == null && tailB == null then r1
      else if tailA != null && tailB != null
      then _unifyCore guardSet binders r1.subst tailA tailB
      else { ok = false; subst = r1.subst; error = "VariantRow: tail open/closed mismatch"; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Effect unification
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyEffect = guardSet: binders: subst: a: b:
    if a.repr.effectTag or "" != b.repr.effectTag or ""
    then { ok = false; inherit subst;
           error = "Effect tag: ${a.repr.effectTag or "?"} vs ${b.repr.effectTag or "?"}"; }
    else
      _unifyCore guardSet binders subst
        (a.repr.effectRow or a) (b.repr.effectRow or b);

  # ══════════════════════════════════════════════════════════════════════════════
  # ADT unification
  # ══════════════════════════════════════════════════════════════════════════════

  _unifyADT = guardSet: binders: subst: a: b:
    let
      varsA = a.repr.variants or [];
      varsB = b.repr.variants or [];
    in
    if builtins.length varsA != builtins.length varsB
    then { ok = false; inherit subst;
           error = "ADT variant count: ${builtins.toString (builtins.length varsA)} vs ${builtins.toString (builtins.length varsB)}"; }
    else
      lib.foldl'
        (acc: pair:
          if !acc.ok then acc
          else if pair.a.name or "" != pair.b.name or ""
          then { ok = false; subst = acc.subst;
                 error = "ADT variant name: ${pair.a.name or "?"} vs ${pair.b.name or "?"}"; }
          else
            lib.foldl'
              (acc2: fp:
                if !acc2.ok then acc2
                else _unifyCore guardSet binders acc2.subst fp.a fp.b)
              acc
              (_zipLists (pair.a.fields or []) (pair.b.fields or [])))
        { ok = true; inherit subst; }
        (_zipLists varsA varsB);

  # ══════════════════════════════════════════════════════════════════════════════
  # Phase 3.2：_applySubstType 完整递归（全 TypeRepr 变体）
  # 这是 Phase 3.1 的关键限制修复：之前只处理顶层 Var
  # 现在：完整递归到所有 TypeRepr 子节点
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: AttrSet -> Type -> Type
  _applySubstTypeFull = subst: t:
    if subst == {} then t
    else
      let
        repr = t.repr;
        v    = repr.__variant or null;
        goT  = _applySubstTypeFull subst;
      in

      # Var：尝试直接替换（follow chain）
      if v == "Var" then
        let
          name  = repr.name or "_";
          bound = subst.${name} or null;
        in
        if bound != null
        then _applySubstTypeFull subst bound  # follow substitution chain
        else t  # free: no binding

      # leaf nodes
      else if v == "Primitive" || v == "RowEmpty" || v == "Opaque"
      then t

      # recursive cases: rebuild repr with substituted subterms
      else if v == "Lambda"
      then withRepr t (repr // {
        body = goT (repr.body or t);
      })

      else if v == "Pi" || v == "Sigma"
      then withRepr t (repr // {
        domain = goT (repr.domain or t);
        body   = goT (repr.body or t);
      })

      else if v == "Apply"
      then withRepr t (repr // {
        fn   = goT (repr.fn or t);
        args = map goT (repr.args or []);
      })

      else if v == "Fn"
      then withRepr t (repr // {
        from = goT (repr.from or t);
        to   = goT (repr.to or t);
      })

      else if v == "Mu"
      then withRepr t (repr // {
        body = goT (repr.body or t);
      })

      else if v == "Constructor"
      then withRepr t (repr // {
        body = if repr ? body && repr.body != null then goT repr.body else repr.body or null;
      })

      else if v == "ADT"
      then withRepr t (repr // {
        variants = map (var: var // { fields = map goT (var.fields or []); })
                       (repr.variants or []);
      })

      else if v == "Record"
      then withRepr t (repr // {
        fields = builtins.mapAttrs (_: goT) (repr.fields or {});
      })

      else if v == "VariantRow"
      then withRepr t (repr // {
        variants = builtins.mapAttrs (_: goT) (repr.variants or {});
        tail = if repr.tail or null != null then goT repr.tail else null;
      })

      else if v == "RowExtend"
      then withRepr t (repr // {
        fieldType = goT (repr.fieldType or t);
        rest      = goT (repr.rest or t);
      })

      else if v == "Effect"
      then withRepr t (repr // {
        effectRow = goT (repr.effectRow or t);
      })

      else if v == "Constrained"
      then withRepr t (repr // {
        base        = goT (repr.base or t);
        constraints = map (_applySubstToConstraint subst) (repr.constraints or []);
      })

      else if v == "Ascribe"
      then withRepr t (repr // {
        inner = goT (repr.inner or t);
        ty    = goT (repr.ty or t);
      })

      else t;  # unknown variant: pass through

  # Constraint 内部的 Type 也需替换
  _applySubstToConstraint = subst: c:
    let
      goT = _applySubstTypeFull subst;
      tag = c.__constraintTag or null;
    in
    if tag == "Class"
    then c // { args = map goT (c.args or []); }
    else if tag == "Equality"
    then c // { a = goT (c.a or c); b = goT (c.b or c); }
    else if tag == "Predicate"
    then c // { arg = if c ? arg && c.arg != null then goT c.arg else c.arg or null; }
    else if tag == "Implies"
    then c // {
      premises   = map (_applySubstToConstraint subst) (c.premises or []);
      conclusion = _applySubstToConstraint subst (c.conclusion or c);
    }
    else c;

  # ══════════════════════════════════════════════════════════════════════════════
  # Phase 3.2：Partial Unification（INV-I2 overlap detection 辅助）
  # 用于判断两个 TypeRepr 是否"可能统一"（conservative overlap check）
  #
  # 语义：
  #   partialUnify a b → { overlaps: Bool; subst?: AttrSet; partial?: Bool }
  #   overlaps = true  → 两者在某个 substitution 下可以统一
  #   partial  = true  → 统一成功但存在剩余约束
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Type -> { overlaps: Bool; subst?: AttrSet }
  partialUnify = a: b:
    let result = unify {} a b; in
    if result.ok
    then { overlaps = true; subst = result.subst; partial = false; }
    else
      # conservative overlap：检查顶层 variant 是否匹配
      let
        va = a.repr.__variant or null;
        vb = b.repr.__variant or null;
      in
      {
        overlaps =
          # Var 总是可能 overlap（绑定后可成立）
          va == "Var" || vb == "Var"
          # 相同 Constructor 名可能 overlap
          || (va == "Constructor" && vb == "Constructor"
              && a.repr.name or "" == b.repr.name or "")
          # 相同 Primitive 可能 overlap（完全匹配时已 unify 成功）
          || (va == "Primitive" && vb == "Primitive"
              && a.repr.name or "" == b.repr.name or "")
          # ADT / Record / Fn 结构相同时可能 overlap
          || (va == vb && builtins.elem va ["Fn" "Apply" "Mu" "ADT" "Record"]);
        partial = false;
      };

  # ══════════════════════════════════════════════════════════════════════════════
  # 便捷入口（带新鲜变量供给）
  # ══════════════════════════════════════════════════════════════════════════════

  # unify with a fresh (empty) subst
  unifyFresh = a: b: unify {} a b;

}
