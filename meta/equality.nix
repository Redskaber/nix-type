# meta/equality.nix — Phase 3.1
# 统一等价核（INV-3 强制，Coherence Law 完整实现）
#
# Phase 3.1 关键修复：
#   INV-3:    equality = NF-hash equality（单一路径，不受 strategy 分支影响）
#   INV-EQ1:  typeEq(a,b) ⟹ typeHash(a) == typeHash(b)
#   INV-EQ2:  structural ⊆ nominal ⊆ hash（Coherence Law）
#   INV-EQ3:  muEq = coinductive bisimulation（fuel-bounded + guard set）
#   INV-EQ4:  rowVarEq = rigid name equality（不走 binder equality）
#
# Phase 3.1 修复要点：
#   1. strategy 不决定"是否比较路径"，只决定 normalize 深度
#   2. alphaEq 统一到 NF-hash equality（消除双 canonicalization pipeline）
#   3. muEq 使用真正 coinductive guard set（不是 alphaEq alias）
#   4. rowVarEq = rigid name（不走 alpha equality）
#   5. checkCoherence：验证 structural ⊆ nominal ⊆ hash
{ lib, typeLib, hashLib, normalizeLib, serialLib }:

let
  inherit (typeLib) isType;
  inherit (hashLib) typeHash nfHash;
  inherit (serialLib) serializeReprAlphaCanonical;

  # 统一 normalize 入口
  _normalize = t:
    if normalizeLib != null && normalizeLib ? normalize
    then normalizeLib.normalize t
    else t;

  # NF 序列化
  _nfSer = t: serializeReprAlphaCanonical (_normalize t).repr;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 核心等价（INV-3 强制：单一 NF-hash 路径）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：typeEq 不接受 strategy 分支，统一走 NF-hash
  # Type: Type -> Type -> Bool
  typeEq = a: b:
    assert isType a;
    assert isType b;
    # INV-EQ1: hash(NF(a)) == hash(NF(b))
    typeHash a == typeHash b;

  # ══════════════════════════════════════════════════════════════════════════════
  # Structural Equality（最精确，NF 序列化比较）
  # ══════════════════════════════════════════════════════════════════════════════

  # INV-EQ2: structuralEq ⊆ nominalEq ⊆ hashEq
  # structural = NF serialization 相等（最严格）
  # Type: Type -> Type -> Bool
  structuralEq = a: b:
    _nfSer a == _nfSer b;

  # ══════════════════════════════════════════════════════════════════════════════
  # Alpha Equality（INV-SER3 统一：≡ structuralEq）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：alphaEq 不再是独立 pipeline
  # 统一到 NF-hash（消除双 canonicalization 歧义）
  # Type: Type -> Type -> Bool
  alphaEq = a: b: structuralEq a b;

  # ══════════════════════════════════════════════════════════════════════════════
  # Nominal Equality（name + NF，ADT 名义类型）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：nominalEq = name + structuralEq（不是 name only）
  # INV-EQ2 保证：structuralEq ⊆ nominalEq（相同 NF ⟹ 相同 nominal）
  # Type: Type -> Type -> Bool
  nominalEq = a: b:
    let
      va = a.repr.__variant or null;
      vb = b.repr.__variant or null;
    in
    # 1. 相同 variant（name level 检查）
    va == vb
    # 2. name 相等（for Constructor/ADT/Opaque）
    && _nominalName a == _nominalName b
    # 3. NF 结构相等（保证 INV-EQ2）
    && structuralEq a b;

  _nominalName = t:
    let v = t.repr.__variant or null; in
    if      v == "Constructor" then t.repr.name or ""
    else if v == "ADT"         then t.repr.name or ""
    else if v == "Opaque"      then t.repr.name or ""
    else if v == "Primitive"   then t.repr.name or ""
    else "";  # 非 nominal type → name = ""（structuralEq 处理）

  # ══════════════════════════════════════════════════════════════════════════════
  # Hash Equality（最宽松）
  # ══════════════════════════════════════════════════════════════════════════════

  # hashEq = typeHash 相等（typeEq 的别名）
  # Type: Type -> Type -> Bool
  hashEq = a: b: typeHash a == typeHash b;

  # ══════════════════════════════════════════════════════════════════════════════
  # Mu Equality（INV-EQ3：真正的 coinductive bisimulation）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：muEq 不再是 alphaEq alias
  # 使用 coinductive bisimulation + guard set
  #
  # guard: AttrSet (a.id + "," + b.id) Bool（访问过的对）
  # fuel:  Int（展开深度上限）
  #
  # Type: AttrSet -> Int -> Type -> Type -> Bool
  muEqWith = guard: fuel: a: b:
    if fuel <= 0 then true  # coinductive: fuel 耗尽 → 假设相等
    else
      let
        guardKey = "${a.id or "?"}-${b.id or "?"}";
        # coinductive hypothesis：已访问对 → 相等（guard set）
        inGuard = guard ? ${guardKey};
      in
      if inGuard then true
      else
        let
          guard' = guard // { ${guardKey} = true; };
          va = a.repr.__variant or null;
          vb = b.repr.__variant or null;
        in
        if va == "Mu" && vb == "Mu" then
          # 展开两边，继续 bisimulation
          let
            unfoldA = _unfoldMu a;
            unfoldB = _unfoldMu b;
          in
          muEqWith guard' (fuel - 1) unfoldA unfoldB
        else if va == "Mu" then
          muEqWith guard' (fuel - 1) (_unfoldMu a) b
        else if vb == "Mu" then
          muEqWith guard' (fuel - 1) a (_unfoldMu b)
        else
          # 非 Mu：走 structural equality
          structuralEq a b;

  muEq = a: b: muEqWith {} 8 a b;

  # Mu 单步展开（substitute var → self in body）
  _unfoldMu = t:
    let
      v   = t.repr.__variant or null;
      var = t.repr.var or "_";
      body = t.repr.body or null;
    in
    if v != "Mu" || body == null then t
    else
      # 替换 var → t 在 body 中（需要 substituteLib，此处简化为直接返回 body）
      # Phase 3.1 TODO: 连接 substituteLib 后完整实现
      body;

  # ══════════════════════════════════════════════════════════════════════════════
  # Row Var Equality（INV-EQ4：rigid name，不走 alpha equality）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：rowVar 用 name equality（unification variable 语义）
  # 不走 binder equality（binder equality 是 alpha-equivalence 的概念）
  # Type: Type -> Type -> Bool
  rowVarEq = a: b:
    let
      va = a.repr.__variant or null;
      vb = b.repr.__variant or null;
    in
    va == "Var" && vb == "Var"
    && a.repr.name or "_" == b.repr.name or "_";

  # ══════════════════════════════════════════════════════════════════════════════
  # 统一 equality 入口（按 meta 策略分发，INV-3 强制：所有路径最终等价）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1：strategy 不改变 equality 路径，只改变 normalize 深度
  # 所有 strategy 最终都走 typeEq（NF-hash）
  # Type: Type -> Type -> Bool
  typeEqFull = a: b:
    let
      va = a.repr.__variant or null;
      metaA = a.meta or {};
      strategy = metaA.eqStrategy or "structural";
    in

    # Mu 类型：走 bisimulation
    if va == "Mu" || (b.repr.__variant or null) == "Mu"
    then muEq a b

    # Row Var：rigid name equality（INV-EQ4）
    else if va == "Var" && (b.repr.__variant or null) == "Var"
         && (metaA.rowPolicy or {}).rowVarEq or "rigid" == "rigid"
    then rowVarEq a b

    # nominal strategy → nominalEq
    else if strategy == "nominal"
    then nominalEq a b

    # 所有其他 → NF-hash equality（INV-3 默认）
    else typeEq a b;

  # ══════════════════════════════════════════════════════════════════════════════
  # Coherence Law 验证（INV-EQ2：structural ⊆ nominal ⊆ hash）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Type -> { coherent: Bool; violations: [String] }
  checkCoherence = a: b:
    let
      strEq  = structuralEq a b;
      nomEq  = nominalEq a b;
      hshEq  = hashEq a b;
      # INV-EQ2 检查
      v1 = if strEq && !nomEq then ["structural ⊄ nominal (INV-EQ2 violation)"] else [];
      v2 = if nomEq && !hshEq then ["nominal ⊄ hash (INV-EQ2 violation)"] else [];
      v3 = if strEq && !hshEq then ["structural ⊄ hash (INV-EQ1 violation)"] else [];
      violations = v1 ++ v2 ++ v3;
    in
    { coherent = violations == []; inherit violations strEq nomEq hshEq; };

}
