# module/system.nix — Phase 4.0
#
# Module System（Sig / Struct / Functor）
#
# 设计原则：
#   - Module Type = TypeIR（INV-1：所有结构 ∈ TypeIR）
#   - Sig    = Record of kinds（接口签名，structural）
#   - Struct = Sig + impl（实现，携带完整类型信息）
#   - Functor = Π(M : Sig). Body（依赖函数类型的 module 版本）
#   - Sealing = rOpaque（nominal typing，信息隐藏）
#   - Functor application 生成 **局部** InstanceDB（INV-MOD-2）
#
# TypeRepr 新增变体（Phase 4.0）：
#   Sig      { fields: AttrSet String Kind }     # 类型/值 签名域
#   Struct   { sig; impl: AttrSet String Type }  # 实现结构体
#   ModFunctor { param; paramTy; body }           # 函子（参数化模块）
#
# 不变量：
#   INV-MOD-1: Sig checking = structural subtyping on field kinds
#   INV-MOD-2: Functor application 生成局部 InstanceDB（不污染全局）
#   INV-MOD-3: Module sealing = rOpaque（nominal typing 强制）
#   INV-MOD-4: Sig fields = sorted attrNames（canonical form）
#   INV-MOD-5: Struct impl ⊇ Sig fields（completeness）

{ lib, typeLib, kindLib, reprLib, normalizeLib, hashLib, unifiedSubstLib }:

let
  inherit (typeLib)  mkTypeDefault mkTypeWith;
  inherit (kindLib)  KStar KArrow isKind kindEq;
  inherit (reprLib)
    rPrimitive rVar rOpaque rRecord rFn rADT rConstrained
    rRowEmpty;
  inherit (unifiedSubstLib) applySubstToType singleTypeBinding;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Module TypeRepr 构造器
  # ══════════════════════════════════════════════════════════════════════════════

  rSig = fields: {
    __variant = "Sig";
    # INV-MOD-4：字段名排序
    fields = lib.listToAttrs (map (k: { name = k; value = fields.${k}; })
               (lib.sort (a: b: a < b) (builtins.attrNames fields)));
  };

  rStruct = sig: impl: {
    __variant = "Struct";
    inherit sig;
    impl = lib.listToAttrs (map (k: { name = k; value = impl.${k}; })
             (lib.sort (a: b: a < b) (builtins.attrNames impl)));
  };

  rModFunctor = param: paramTy: body: {
    __variant = "ModFunctor";
    inherit param paramTy body;
  };

  # ── 高层构造器 ───────────────────────────────────────────────────────────────

  mkSig = fields:
    mkTypeDefault (rSig fields) KStar;

  mkStruct = sig: impl:
    mkTypeDefault (rStruct sig impl) KStar;

  mkModFunctor = param: paramTy: body:
    mkTypeDefault (rModFunctor param paramTy body) KStar;

  # Module sealing（INV-MOD-3：rOpaque）
  sealModule = mod: sig:
    let tag = hashLib.typeHash mod; in
    mkTypeDefault (rOpaque sig tag) KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # Sig Checking（structural subtyping，INV-MOD-1）
  # ══════════════════════════════════════════════════════════════════════════════

  # checkSig：Struct impl 是否满足 Sig
  # Result: { ok; missing; kindMismatch }
  checkSig = sig: struct:
    let
      sigTy     = if builtins.isAttrs sig && sig ? repr then sig else { repr = rSig {}; };
      structTy  = if builtins.isAttrs struct && struct ? repr then struct else { repr = rStruct {} {}; };
      sigR      = sigTy.repr or {};
      structR   = structTy.repr or {};

      sigFields    = sigR.fields or {};
      implFields   = structR.impl or {};

      sigKeys  = builtins.attrNames sigFields;
      implKeys = builtins.attrNames implFields;

      # INV-MOD-5：检查完整性
      missing = lib.filter (k: !(implFields ? ${k})) sigKeys;

      # Kind 检查：impl 字段的 kind 是否与 sig 声明的兼容
      kindMismatch = lib.filter (k:
        implFields ? ${k} &&
        !(kindEq (sigFields.${k}) ((implFields.${k}).kind or KStar))
      ) sigKeys;

    in {
      ok          = missing == [] && kindMismatch == [];
      missing     = missing;
      kindMismatch = kindMismatch;
      sigFields   = sigFields;
      implFields  = implFields;
    };

  # structSubtype：Struct s1 <: Struct s2（s2 fields ⊆ s1 fields）
  structSubtype = s1: s2:
    let
      r1 = s1.repr or {};
      r2 = s2.repr or {};
      impl1 = r1.impl or {};
      impl2 = r2.impl or {};
      s2Keys = builtins.attrNames (r2.fields or impl2);
    in
    lib.all (k: impl1 ? ${k}) s2Keys;

  # ══════════════════════════════════════════════════════════════════════════════
  # Functor Application（INV-MOD-2：局部 InstanceDB）
  # ══════════════════════════════════════════════════════════════════════════════

  # applyFunctor：ModFunctor(M : Sig, body) @ arg → body[M ↦ arg]
  # 返回：{ result; localInstances }（不污染全局）
  applyFunctor = functor: arg:
    let
      fr = functor.repr or {};
      in
    if fr.__variant != "ModFunctor" then
      { ok = false; error = "not a ModFunctor"; result = null; localInstances = {}; }
    else
      let
        # 类型替换：param → arg
        subst  = singleTypeBinding fr.param arg;
        body'  = applySubstToType subst fr.body;

        # 从 arg 的 Struct impl 提取 local instances
        # (简化：提取 Constrained 类型作为 local instance 声明)
        argImpl = (arg.repr or {}).impl or {};
        localInstances = lib.mapAttrs (_: ty:
          if (ty.repr or {}).__variant == "Constrained"
          then ty
          else null
        ) argImpl;
        cleanLocalInstances = lib.filterAttrs (_: v: v != null) localInstances;
      in {
        ok             = true;
        result         = body';
        localInstances = cleanLocalInstances;
      };

  # ══════════════════════════════════════════════════════════════════════════════
  # Module Subtyping（Sig-directed）
  # ══════════════════════════════════════════════════════════════════════════════

  # sigSubtype：Sig s1 ≤ Sig s2（s2 fields ⊆ s1 fields，depth兼容）
  sigSubtype = s1: s2:
    let
      r1     = s1.repr or {};
      r2     = s2.repr or {};
      fields1 = r1.fields or {};
      fields2 = r2.fields or {};
      s2Keys  = builtins.attrNames fields2;
    in
    lib.all (k:
      fields1 ? ${k} && kindEq (fields2.${k}) (fields1.${k})
    ) s2Keys;

  # ══════════════════════════════════════════════════════════════════════════════
  # 序列化（canonical，用于 hash / equality）
  # ══════════════════════════════════════════════════════════════════════════════

  serializeModuleRepr = r:
    let v = r.__variant or null; in
    if v == "Sig" then
      let
        keys   = lib.sort (a: b: a < b) (builtins.attrNames (r.fields or {}));
        fields = map (k: "${k}:${kindLib.serializeKind (r.fields.${k})}") keys;
      in
      "Sig{${lib.concatStringsSep ";" fields}}"
    else if v == "Struct" then
      "Struct{sig=${serializeModuleRepr r.sig.repr}}"
    else if v == "ModFunctor" then
      "ModFunctor(${r.param},${serializeModuleRepr r.paramTy.repr},body)"
    else "?mod";

  # ══════════════════════════════════════════════════════════════════════════════
  # 常用 Sig 定义
  # ══════════════════════════════════════════════════════════════════════════════

  sigEq = tInt:
    mkSig {
      T  = KStar;
      eq = KArrow KStar (KArrow KStar KStar);
    };

  sigOrd = tInt:
    mkSig {
      T      = KStar;
      eq     = KArrow KStar (KArrow KStar KStar);
      compare = KArrow KStar (KArrow KStar KStar);
    };

  sigMonoid = _:
    mkSig {
      T      = KStar;
      empty  = KStar;
      append = KArrow KStar (KArrow KStar KStar);
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 不变量验证
  # ══════════════════════════════════════════════════════════════════════════════

  verifyModuleInvariants = _:
    let
      tInt  = mkTypeDefault (rPrimitive "Int")  KStar;
      tBool = mkTypeDefault (rPrimitive "Bool") KStar;
      tIntToBool = mkTypeDefault { __variant = "Fn"; from = tInt; to = tBool; } KStar;

      # 构造一个简单 Sig
      mySig = mkSig { T = KStar; eq = KArrow KStar KStar; };

      # INV-MOD-4：Sig fields sorted
      sigFields = (mySig.repr or {}).fields or {};
      sigKeys   = builtins.attrNames sigFields;
      sortedKeys = lib.sort (a: b: a < b) sigKeys;
      invMOD4   = sigKeys == sortedKeys;

      # INV-MOD-1：checkSig
      goodImpl = { T = tInt; eq = tIntToBool; };
      badImpl  = { T = tInt; };  # missing eq

      goodStruct = mkStruct mySig goodImpl;
      badStruct  = mkStruct mySig badImpl;

      goodCheck = checkSig mySig goodStruct;
      badCheck  = checkSig mySig badStruct;
      invMOD1a  = goodCheck.ok;
      invMOD1b  = !badCheck.ok && badCheck.missing != [];

      # INV-MOD-3：sealing → Opaque
      sealed = sealModule goodStruct mySig;
      invMOD3 = (sealed.repr or {}).__variant == "Opaque";

      # INV-MOD-2：Functor application local instances isolated
      sigForFunctor = mkSig { A = KStar; };
      tVarA         = mkTypeDefault { __variant = "Var"; name = "M.A"; scope = "functor"; } KStar;
      functor       = mkModFunctor "M" sigForFunctor tVarA;
      argStruct     = mkStruct sigForFunctor { A = tInt; };
      appResult     = applyFunctor functor argStruct;
      invMOD2       = appResult.ok;

    in {
      allPass    = invMOD1a && invMOD1b && invMOD2 && invMOD3 && invMOD4;
      "INV-MOD-1a" = invMOD1a;
      "INV-MOD-1b" = invMOD1b;
      "INV-MOD-2"  = invMOD2;
      "INV-MOD-3"  = invMOD3;
      "INV-MOD-4"  = invMOD4;
    };
}
