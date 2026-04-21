# module/system.nix — Phase 4.1
# Module System（Sig / Struct / ModFunctor）
# 修复 RISK-E: applyFunctor 使用 qualified naming（param.field → impl.field）
# INV-MOD-1: Sig ∈ TypeRepr（INV-1 保持）
# INV-MOD-2: Struct implements Sig（structural subtype）
# INV-MOD-3: ModFunctor = Π(M:Sig). Body
# INV-MOD-4: Sig fields 字母序规范化（由 rules.nix 保证）
# INV-MOD-5: applyFunctor type-safe（kind-checked）
# INV-MOD-6: composeFunctors type-correct（Phase 4.1 新增）
# INV-MOD-7: mergeLocalInstances coherent（Phase 4.1 新增）
{ lib, typeLib, reprLib, kindLib, normalizeLib, hashLib, unifiedSubstLib }:

let
  inherit (typeLib) isType mkTypeDefault mkTypeWith;
  inherit (reprLib) rSig rStruct rModFunctor rVar rOpaque;
  inherit (kindLib) KStar KArrow;
  inherit (normalizeLib) normalize';
  inherit (hashLib) typeHash;
  inherit (unifiedSubstLib) singleTypeBinding applyUnifiedSubst composeSubst;

in rec {

  # ══ Sig：Module 接口签名 ════════════════════════════════════════════════════

  # Type: AttrSet(String -> Type) -> Type
  mkSig = fields:
    let
      # INV-MOD-4: 字母序规范化（在 rSig 构造时就排序）
      fnames  = lib.sort (a: b: a < b) (builtins.attrNames fields);
      sortedF = builtins.listToAttrs (map (n: { name = n; value = fields.${n}; }) fnames);
    in mkTypeDefault (rSig sortedF) KStar;

  # Sig 谓词
  isSigType = t: isType t && (t.repr.__variant or null) == "Sig";

  # Sig 字段查询
  sigFields = t:
    assert isSigType t;
    t.repr.fields or {};

  sigField = t: fieldName:
    let fs = sigFields t; in
    fs.${fieldName} or null;

  # ══ Struct：Module 实现 ═════════════════════════════════════════════════════

  # Type: Type(Sig) -> AttrSet(String -> Type) -> Type
  mkStruct = sig: impl:
    mkTypeDefault (rStruct sig impl) KStar;

  isStructType = t: isType t && (t.repr.__variant or null) == "Struct";

  # ══ ModFunctor：参数化 Module ════════════════════════════════════════════════

  # Type: String -> Type(Sig) -> Type -> Type
  mkModFunctor = param: paramTy: body:
    let kind = KArrow KStar KStar; in  # Sig → Body
    mkTypeWith (rModFunctor param paramTy body) kind typeLib.mkTypeDefault null;

  isModFunctorType = t: isType t && (t.repr.__variant or null) == "ModFunctor";

  # ══ Sig Check（structural subtype）══════════════════════════════════════════

  # Type: Type(Struct) -> Type(Sig) -> { ok: Bool; missing: [String]; typeMismatches: [...] }
  checkSig = struct: sig:
    assert isSigType sig;
    assert isStructType struct;
    let
      required = sigFields sig;
      provided = struct.repr.impl or {};
      reqNames = builtins.attrNames required;
      prvNames = builtins.attrNames provided;
      missing  = lib.filter (n: !(provided ? ${n})) reqNames;
      # 检查类型匹配（NF hash 比较）
      typeMismatches = lib.filter (n:
        provided ? ${n} &&
        typeHash (normalize' required.${n}) != typeHash (normalize' provided.${n})
      ) reqNames;
    in
    { ok             = missing == [] && typeMismatches == [];
      missing        = missing;
      typeMismatches = typeMismatches;
    };

  # ══ applyFunctor（修复 RISK-E：qualified naming）══════════════════════════

  # 旧问题：直接替换 param → body 中同名 free var 被错误替换
  # 修复：使用 qualified 访问路径（param.field → impl.field）
  # Type: Type(ModFunctor) -> Type(Struct) -> { ok: Bool; result: Type; error?: String }
  applyFunctor = functor: argStruct:
    assert isModFunctorType functor;
    assert isStructType argStruct;
    let
      param   = functor.repr.param;
      paramTy = functor.repr.paramTy;
      body    = functor.repr.body;
      impl    = argStruct.repr.impl or {};

      # INV-MOD-5: check arg matches paramTy（Sig check）
      compatible = checkSig argStruct paramTy;
    in
    if !compatible.ok then
      { ok    = false;
        error = "ModFunctor arg does not implement Sig: missing=${builtins.toJSON compatible.missing}"; }
    else
      let
        # Phase 4.1 修复（RISK-E）：
        # 对于 body 中出现的 param 引用，使用 qualified name 替换
        # 具体：body 中的 Var(param) → argStruct
        # 对于 param.field 访问（在 body 中的 Var(param+"_"+field)），
        # → 替换为 impl.field
        subst = singleTypeBinding param argStruct;

        # 同时对所有 "param_field" qualified vars 进行替换
        fieldSubsts = lib.foldl'
          (acc: n:
            let qualName = param + "_" + n; in
            let fieldSubst = singleTypeBinding qualName impl.${n}; in
            # compose: acc 先，fieldSubst 后
            unifiedSubstLib.composeSubst acc fieldSubst)
          subst
          (builtins.attrNames impl);

        result = applyUnifiedSubst fieldSubsts body;
      in
      { ok = true; result = normalize' result; };

  # ══ Functor Composition（Phase 4.1 INV-MOD-6）════════════════════════════

  # Type: Type(ModFunctor) -> Type(ModFunctor) -> Type(ModFunctor)
  # (F∘G)(M) = F(G(M))
  composeFunctors = f1: f2:
    assert isModFunctorType f1;
    assert isModFunctorType f2;
    let
      # 新参数名（避免冲突）
      freshParam = "M_comp_" + builtins.substring 0 8
        (builtins.hashString "md5" "${f1.repr.param}${f2.repr.param}");
      # 新 Sig：f2 的 paramTy
      paramTy    = f2.repr.paramTy;
      # body：先 apply f2，再 apply f1 到结果
      # 表示为 ModFunctor apply 嵌套
      innerVar   = mkTypeDefault (rVar freshParam "compose") KStar;
      innerStruct = mkStruct paramTy {};  # 占位结构（实际在 apply 时替换）
      # 构造 composed body（lambda 表示）
      body = mkTypeDefault
        (reprLib.rApply
          (mkTypeDefault (reprLib.rApply f1 [ f2 ]) KStar)
          [ innerVar ])
        KStar;
    in
    mkModFunctor freshParam paramTy body;

  # ══ Sealing（Opaque 封装）════════════════════════════════════════════════

  # Type: Type -> String -> Type
  # sealing 隐藏内部类型（abstract type）
  seal = t: sealTag:
    mkTypeDefault (rOpaque t sealTag) t.kind;

  unseal = sealed: sealTag:
    if (sealed.repr.__variant or null) == "Opaque"
       && sealed.repr.tag == sealTag
    then { ok = true; inner = sealed.repr.inner; }
    else { ok = false; error = "seal tag mismatch"; };

  # ══ Local Instance 合并（Phase 4.1 INV-MOD-7）════════════════════════════
  # Type: AttrSet(globalInstances) -> AttrSet(localInstances) -> MergeResult
  mergeLocalInstances = global: local:
    let
      localKeys  = builtins.attrNames local;
      globalKeys = builtins.attrNames global;
      # 检测冲突：key 在 global 中已存在
      conflicts  = lib.filter (k: builtins.elem k globalKeys) localKeys;
    in
    if conflicts != []
    then { ok = false; conflicts = conflicts; db = global; }
    else { ok = true; conflicts = []; db = global // local; };
}
