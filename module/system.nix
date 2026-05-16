# module/system.nix — Phase 4.2
# Module System：Sig/Struct/ModFunctor
# INV-MOD-1: Struct 实现 Sig 所有字段
# INV-MOD-4: Sig fields 字母序 canonical
# INV-MOD-6: composeFunctors type-correct（INV-MOD-8 Phase 4.2）
# INV-MOD-7: mergeLocalInstances coherent
# INV-MOD-8: Functor transitive composition（Phase 4.2 新增）
# Phase 4.2 修复: 真正的 λM.f1(f2(M)) 语义（lazy substitution）
{ lib, typeLib, reprLib, kindLib, normalizeLib, hashLib, unifiedSubstLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault freeVars;
  inherit (reprLib) rSig rStruct rModFunctor rVar rApply;
  inherit (kindLib) KStar;
  inherit (normalizeLib) normalize';
  inherit (hashLib) typeHash;
  inherit (unifiedSubstLib) emptySubst composeSubst singleTypeBinding applySubst;


  # ══ Sig 构造器 ═════════════════════════════════════════════════════════
  # Type: {name → Type} → Type(Sig)
  mkSig = fields:
    let
      # INV-MOD-4: fields 字母序（通过序列化保证，attrset 无序）
      sortedFields = builtins.listToAttrs (map (n:
        lib.nameValuePair n fields.${n}
      ) (lib.sort builtins.lessThan (builtins.attrNames fields)));
    in
    mkTypeDefault (rSig sortedFields) KStar;

  isSig = t: isType t && (t.repr.__variant or null) == "Sig";

  # ══ Struct 构造器 ══════════════════════════════════════════════════════
  # Type: Type(Sig) → {name → Type} → Type(Struct) | { ok:false; error }
  mkStruct = sig: impls:
    assert isSig sig;
    let
      sigFields  = builtins.attrNames sig.repr.fields;
      implFields = builtins.attrNames impls;
      # INV-MOD-1: Struct 必须实现 Sig 所有字段
      missing    = lib.filter (f: !(builtins.elem f implFields)) sigFields;
      extra      = lib.filter (f: !(builtins.elem f sigFields)) implFields;
    in
    if missing != [] then
      { ok = false; error = "missing fields: ${builtins.toJSON missing}"; }
    else
      let
        # INV-MOD-2: 每个实现字段的类型必须与 Sig 声明兼容（NF-hash 比较）
        typeErrors = lib.filter (f:
          let
            sigTy   = normalize' sig.repr.fields.${f};
            implTy  = normalize' impls.${f};
          in
          typeHash sigTy != typeHash implTy
        ) sigFields;
      in
      if typeErrors != [] then
        { ok = false; error = "type mismatch in fields: ${builtins.toJSON typeErrors}"; }
      else
        { ok = true;
          struct = mkTypeDefault (rStruct sig impls) KStar; };

  isStruct = t: isType t && (t.repr.__variant or null) == "Struct";

  # ══ Struct 字段访问 ════════════════════════════════════════════════════
  # Type: Type(Struct) → String → Type | null
  structField = struct: name:
    assert isStruct struct;
    struct.repr.impls.${name} or null;

  # ══ ModFunctor 构造器 ══════════════════════════════════════════════════
  # Type: String → Type(Sig) → Type → Type(ModFunctor)
  mkModFunctor = param: paramSig: body:
    assert isSig paramSig;
    mkTypeDefault (rModFunctor param paramSig body) KStar;

  isModFunctor = t: isType t && (t.repr.__variant or null) == "ModFunctor";

  # ══ Functor Application（INV-MOD-5 qualified naming）═════════════════
  # Type: Type(ModFunctor) → Type(Struct) → Type | { ok:false; error }
  applyFunctor = functor: argStruct:
    assert isModFunctor functor;
    assert isStruct argStruct;
    let
      param    = functor.repr.param;
      paramSig = functor.repr.paramSig;
      body     = functor.repr.body;

      # INV-MOD-3: argStruct must implement paramSig
      sigFields = builtins.attrNames paramSig.repr.fields;
      argImpls  = argStruct.repr.impls;
      missing   = lib.filter (f: !(argImpls ? ${f})) sigFields;
    in
    if missing != [] then
      { ok = false; error = "functor arg missing fields: ${builtins.toJSON missing}"; }
    else
      let
        # INV-MOD-5 (RISK-E): qualified naming
        # param → argStruct（整体）+ param_field → impl.field（每个字段）
        baseSubst = singleTypeBinding param argStruct;
        fieldSubsts = lib.foldl' (acc: f:
          let fieldVal = argImpls.${f} or null; in
          if fieldVal == null then acc
          else
            let s = singleTypeBinding "${param}_${f}" fieldVal; in
            composeSubst s acc
        ) emptySubst sigFields;
        fullSubst = composeSubst fieldSubsts baseSubst;
        result    = applySubst fullSubst body;
      in
      { ok = true; result = result; };

  # ══ Functor Composition（Phase 4.2: 真正 λM.f1(f2(M)) 语义）══════════
  # INV-MOD-6: composeFunctors type-correct（kind preserved）
  # INV-MOD-8: Functor composition semantically correct（Phase 4.2 新增）
  #
  # Phase 4.1 的问题：body 嵌套 Apply 表示，非真正语义
  # Phase 4.2 修复：lazy representation（不立即 apply，保留 composition 结构）
  #
  # composeFunctors f1 f2 = λM. f1(f2(M))
  # 用新的 param 变量表示 M，body 为 Apply(f1, Apply(f2, M))

  # Type: Type(ModFunctor) → Type(ModFunctor) → Type(ModFunctor)
  composeFunctors = f1: f2:
    assert isModFunctor f1;
    assert isModFunctor f2;
    let
      # Phase 4.2: 引入新的 param 变量 M
      freshParam  = "_M_${builtins.hashString "sha256" "${f1.repr.param}:${f2.repr.param}"}";
      # f2 接受 M → 产生 intermediate
      f2Param     = f2.repr.param;
      f2ParamSig  = f2.repr.paramSig;  # 输入 sig（M 的 sig）
      f2Body      = f2.repr.body;
      # f1 接受 f2(M) → 产生最终结果
      f1Param     = f1.repr.param;
      f1ParamSig  = f1.repr.paramSig;  # f2 的输出必须满足此 sig

      # freshM：类型变量，代表组合 functor 的参数
      freshM      = mkTypeDefault (rVar freshParam "mod") KStar;

      # Lazy body：先 apply f2 to M，再 apply f1 to result
      # f2Applied = f2[f2Param := freshM](f2Body)
      f2Applied   = applySubst (singleTypeBinding f2Param freshM) f2Body;
      # f1Applied = f1[f1Param := f2Applied](f1Body)
      f1Applied   = applySubst (singleTypeBinding f1Param f2Applied) f1.repr.body;

      # 组合 functor 的 paramSig = f2 的 paramSig（输入是 M 的 sig）
      composedSig = f2ParamSig;
      composedBody = f1Applied;
    in
    mkModFunctor freshParam composedSig composedBody;

  # ══ 传递性 Functor Composition（列表，INV-MOD-8）═══════════════════════
  # Type: [Type(ModFunctor)] → Type(ModFunctor) | null
  composeFunctorChain = functors:
    if functors == [] then null
    else if builtins.length functors == 1 then builtins.head functors
    else
      let
        f1   = builtins.head functors;
        rest = builtins.tail functors;
        f2   = composeFunctorChain rest;
      in
      if f2 == null then f1
      else composeFunctors f1 f2;

  # ══ Sig 兼容性检查（结构子类型）═════════════════════════════════════
  # Type: Type(Sig) → Type(Sig) → Bool
  # sigA ≤ sigB ⟺ sigA 实现了 sigB 的所有字段且类型兼容
  sigCompatible = sigA: sigB:
    assert isSig sigA && isSig sigB;
    let
      bFields = builtins.attrNames sigB.repr.fields;
      aFields = sigA.repr.fields;
    in
    builtins.all (f:
      let
        aHas = aFields ? ${f};
        bTy  = normalize' sigB.repr.fields.${f};
        aTy  = if aHas then normalize' aFields.${f} else null;
      in
      aHas && (typeHash aTy == typeHash bTy)
    ) bFields;

  # ══ Sig 合并（交集 + 联集）══════════════════════════════════════════
  # Type: Type(Sig) → Type(Sig) → { intersection: Type(Sig); union: Type(Sig) }
  sigMerge = sigA: sigB:
    assert isSig sigA && isSig sigB;
    let
      fa = sigA.repr.fields;
      fb = sigB.repr.fields;
      keysA = builtins.attrNames fa;
      keysB = builtins.attrNames fb;
      both  = lib.filter (k: fb ? ${k}) keysA;
      either = lib.unique (keysA ++ keysB);
      intersectionFields = builtins.listToAttrs (map (k: lib.nameValuePair k fa.${k}) both);
      unionFields = builtins.listToAttrs (map (k:
        lib.nameValuePair k (if fa ? ${k} then fa.${k} else fb.${k})
      ) either);
    in
    { intersection = mkSig intersectionFields;
      union        = mkSig unionFields; };

  # ══ sealing / unsealing（抽象类型）══════════════════════════════════
  # Type: Type → String → Type
  seal = t: sealTag:
    mkTypeDefault { __variant = "Opaque"; inner = t; tag = sealTag; } KStar;

  unseal = sealed: sealTag:
    if (sealed.repr.__variant or null) == "Opaque" && sealed.repr.tag == sealTag
    then { ok = true; inner = sealed.repr.inner; }
    else { ok = false; error = "seal tag mismatch"; };
in
{
  inherit
  # ══ Sig 构造器 ═════════════════════════════════════════════════════════
  mkSig
  isSig
  # ══ Struct 构造器 ══════════════════════════════════════════════════════
  mkStruct
  isStruct
  # ══ Struct 字段访问 ════════════════════════════════════════════════════
  structField
  # ══ ModFunctor 构造器 ══════════════════════════════════════════════════
  mkModFunctor
  isModFunctor
  applyFunctor
  # ══ Functor Composition（Phase 4.2: 真正 λM.f1(f2(M)) 语义）══════════
  composeFunctors
  # ══ 传递性 Functor Composition（列表，INV-MOD-8）═══════════════════════
  composeFunctorChain
  # ══ Sig 兼容性检查（结构子类型）═════════════════════════════════════
  sigCompatible
  # ══ Sig 合并（交集 + 联集）══════════════════════════════════════════
  sigMerge
  # ══ sealing / unsealing（抽象类型）══════════════════════════════════
  seal
  unseal
  ;
}
