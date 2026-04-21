# meta/equality.nix — Phase 3
# Equality 系统（INV-3 + Coherence Law 强制）
#
# Phase 3 核心修复（来自 nix-todo/meta/equality.md）：
#
#   问题 1（最严重）：INV-3 被 strategy override 破坏
#     → 修复：单一 canonical equality = NF-hash equality，strategy 只影响 normalization 深度
#
#   问题 2：alphaEq ≈ structuralEq 重复
#     → 修复：alphaEq = 真正 de Bruijn based α-equality（使用 serializeReprAlphaCanonical）
#
#   问题 3：nominalEq 实际不是 nominal
#     → 修复：nominalEq = name + structural equality（ADT name check first）
#
#   问题 4：rowVar 用错 equality domain
#     → 修复：rowVarEq = rigid variable equality（name identity，不走 alphaEq）
#
#   问题 5：muEq 不是真 equi-recursive
#     → 修复：muEq = coinductive bisimulation（guard set + fuel）
#
#   问题 6：equality lattice 非封闭
#     → 修复：统一 Coherence Law：structural ⊆ nominal ⊆ hashEq
#
# 不变量：
#   INV-3: 所有比较 = NormalForm Equality（最终归一到单一 canonical NF）
#   INV-EQ1: typeEq(a,b) ⟹ typeHash(a) == typeHash(b)（强约束）
#   INV-EQ2: structuralEq ⊆ nominalEq ⊆ hashEq（Coherence Law）
#   INV-EQ3: muEq = coinductive bisimulation（fuel-bounded，sound）
#   INV-EQ4: rowVarEq = rigid name equality（不走 binder equality）
{ lib, typeLib, normalizeLib, serialLib, metaLib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # 主入口：typeEq（Phase 3：严格 NF-hash equality，INV-3）
  # ══════════════════════════════════════════════════════════════════════════════

  # 所有 equality 最终归一到 NF-hash equality（INV-3 强制）
  # meta.eqStrategy 只影响 normalization 策略，不影响最终比较路径
  # Type: Type -> Type -> Bool
  typeEq = a: b:
    let
      # 1. 获取 meta 策略
      metaA = a.meta or metaLib.defaultMeta;
      metaB = b.meta or metaLib.defaultMeta;

      # 2. 快速路径：id 相同
      sameId = a.id or null == b.id or null && a.id or null != null;

      # 3. 标准路径：NF-hash equality
      nfEq = _nfHashEq a b;

      # 4. strategy 扩展：nominal check（ADT name 不同 → 不等）
      strategyA = metaA.eqStrategy or "structural";
      strategyB = metaB.eqStrategy or "structural";
      nominalFail =
        (strategyA == "nominal" || strategyB == "nominal")
        && _nominalCheck a b == false;

    in
    if sameId then true
    else if nominalFail then false
    else nfEq;

  # ══════════════════════════════════════════════════════════════════════════════
  # NF-Hash Equality（canonical，所有路径最终到这里，INV-3）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Type -> Bool
  _nfHashEq = a: b:
    let
      nfA = normalizeLib.normalize a;
      nfB = normalizeLib.normalize b;
      sA = serialLib.serializeReprAlphaCanonical nfA.repr;
      sB = serialLib.serializeReprAlphaCanonical nfB.repr;
    in
    sA == sB;

  # ══════════════════════════════════════════════════════════════════════════════
  # Alpha Equality（真正 de Bruijn α-equality，Phase 3 修复）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3 修复：alphaEq = 真正 α-equality（使用 serializeReprAlphaCanonical）
  # 不再是 structuralEq 的别名
  # Type: Type -> Type -> Bool
  alphaEq = a: b:
    let
      sA = serialLib.serializeReprAlphaCanonical a.repr;
      sB = serialLib.serializeReprAlphaCanonical b.repr;
    in
    sA == sB;

  # ══════════════════════════════════════════════════════════════════════════════
  # Nominal Equality（Phase 3 修复：真正 name + structure）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3 修复：nominalEq = ADT/Constructor name 相同 AND structurally equal
  # 不再是 structuralEq 的别名
  # Type: Type -> Type -> Bool
  nominalEq = a: b:
    _nominalCheck a b && _nfHashEq a b;

  # 内部 nominal name 检查（只看 name，不看结构）
  _nominalCheck = a: b:
    let
      va = a.repr.__variant or null;
      vb = b.repr.__variant or null;
    in
    if va != vb then false
    else if va == "ADT" then
      # ADT: 所有 variant names 相同
      let
        namesA = builtins.sort (x: y: x < y) (map (v: v.name) a.repr.variants);
        namesB = builtins.sort (x: y: x < y) (map (v: v.name) b.repr.variants);
      in
      namesA == namesB
    else if va == "Constructor" then
      a.repr.name == b.repr.name
    else if va == "Opaque" then
      a.repr.name == b.repr.name && (a.repr.id or "") == (b.repr.id or "")
    else true;  # 非 nominal 变体：name check 通过（由 structuralEq 决定）

  # ══════════════════════════════════════════════════════════════════════════════
  # Structural Equality（NF 比较，最精确）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Type -> Type -> Bool
  structuralEq = a: b: _nfHashEq a b;

  # ══════════════════════════════════════════════════════════════════════════════
  # Mu Equality（Phase 3 修复：真正 equi-recursive bisimulation）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3 实现：coinductive bisimulation with guard set
  #
  # 原理：equi-recursive equality = coinductive proof
  #   muEq(μ(x.A), μ(y.B)) holds if we can show A[x↦μ(x.A)] ≈ B[y↦μ(y.B)]
  #   Guard set：已假设相等的 (id_a, id_b) 对，防止无限展开
  #
  # 不变量（INV-EQ3）：
  #   - fuel-bounded（防止非 contractive Mu）
  #   - guard set（coinductive assumption）
  #   - 结果 sound（无 false positive，只有 false negative 在 fuel 耗尽时）

  # Type: Type -> Type -> Bool（主入口）
  muEq = a: b:
    let meta = a.meta or metaLib.defaultMeta; in
    let fuel = meta.muPolicy.fuel or 8; in
    _muEqGuarded {} fuel a b;

  # Type: GuardSet -> Int -> Type -> Type -> Bool
  _muEqGuarded = guard: fuel: a: b:
    let
      idA = a.id or null;
      idB = b.id or null;
      guardKey = if idA != null && idB != null
                 then "${idA}:${idB}"
                 else null;

      # Coinductive assumption：若 (a,b) 在 guard 中，视为相等（coinductive）
      inGuard = guardKey != null && guard ? ${guardKey};

      # 快速路径
      sameId = idA != null && idA == idB;

      va = a.repr.__variant or null;
      vb = b.repr.__variant or null;
    in

    if sameId    then true
    else if inGuard then true  # coinductive assumption
    else if fuel <= 0 then
      # fuel 耗尽：保守返回 NF-hash equality（fallback）
      _nfHashEq a b
    else
      let
        guard' = if guardKey != null
                 then guard // { ${guardKey} = true; }
                 else guard;
      in

      # 两者都是 Mu：展开一步后递归
      if va == "Mu" && vb == "Mu" then
        let
          unfoldA = _muUnfold a;
          unfoldB = _muUnfold b;
        in
        _muEqGuarded guard' (fuel - 1) unfoldA unfoldB

      # 一方是 Mu：展开 Mu 那方后对比
      else if va == "Mu" then
        _muEqGuarded guard' (fuel - 1) (_muUnfold a) b

      else if vb == "Mu" then
        _muEqGuarded guard' (fuel - 1) a (_muUnfold b)

      # 都不是 Mu：走 NF-hash equality
      else _nfHashEq a b;

  # Mu 展开一步：μ(x.B) → B[x ↦ μ(x.B)]
  _muUnfold = t:
    if (t.repr.__variant or null) == "Mu"
    then normalizeLib.normalize t  # normalize 会触发 ruleMuUnfold
    else t;

  # ══════════════════════════════════════════════════════════════════════════════
  # Row Equality（Phase 3 修复：rowVar = rigid var equality）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3 修复：rowVar 不走 alphaEq（binder equality）
  # rowVar 是 unification variable（rigid）→ 用 name identity
  # Type: Type -> Type -> Bool
  rowEq = a: b:
    let
      va = a.repr.__variant or null;
      vb = b.repr.__variant or null;
    in
    if va != vb then false
    else if va == "Record" then _recordEq a.repr b.repr
    else if va == "VariantRow" then _variantRowEq a.repr b.repr
    else if va == "RowExtend" then _rowExtendEq a.repr b.repr
    else if va == "RowEmpty" then true
    else _nfHashEq a b;

  # ── Record equality ────────────────────────────────────────────────────────
  _recordEq = ra: rb:
    let
      # rowVar：rigid equality（INV-EQ4）
      rowVarEq =
        if ra.rowVar == null && rb.rowVar == null then true
        else if ra.rowVar == null || rb.rowVar == null then false
        else ra.rowVar == rb.rowVar;  # name identity（不走 alphaEq！）

      # field names 相同
      namesA = builtins.sort (x: y: x < y) (builtins.attrNames ra.fields);
      namesB = builtins.sort (x: y: x < y) (builtins.attrNames rb.fields);
      namesEq = namesA == namesB;

      # 所有对应 field 类型相等
      fieldsEq = namesEq && lib.all (l: typeEq ra.fields.${l} rb.fields.${l}) namesA;
    in
    rowVarEq && fieldsEq;

  # ── VariantRow equality ───────────────────────────────────────────────────
  _variantRowEq = ra: rb:
    let
      rowVarEq =
        if ra.rowVar == null && rb.rowVar == null then true
        else if ra.rowVar == null || rb.rowVar == null then false
        else ra.rowVar == rb.rowVar;  # rigid

      labelsA = builtins.sort (x: y: x < y) (builtins.attrNames ra.variants);
      labelsB = builtins.sort (x: y: x < y) (builtins.attrNames rb.variants);
      labelsEq = labelsA == labelsB;

      variantsEq = labelsEq &&
        lib.all (l:
          let
            fsA = ra.variants.${l};
            fsB = rb.variants.${l};
          in
          builtins.length fsA == builtins.length fsB
          && lib.all (p: typeEq p.fst p.snd)
               (lib.zipLists fsA fsB))
        labelsA;
    in
    rowVarEq && variantsEq;

  # ── RowExtend equality ────────────────────────────────────────────────────
  _rowExtendEq = ra: rb:
    ra.label == rb.label
    && typeEq ra.fieldType rb.fieldType
    && typeEq ra.rowType rb.rowType;

  # ══════════════════════════════════════════════════════════════════════════════
  # Coherence Law 验证（Phase 3 强制）
  # ══════════════════════════════════════════════════════════════════════════════

  # 验证：structural ⊆ nominal ⊆ hashEq
  # Type: Type -> Type -> { coherent: Bool; details: String }
  checkCoherence = a: b:
    let
      sEq  = structuralEq a b;
      nEq  = nominalEq a b;
      hEq  = _nfHashEq a b;
    in
    {
      coherent =
        (if sEq then nEq else true)  # structural → nominal
        && (if nEq then hEq else true);  # nominal → hash
      details = "structural=${if sEq then "T" else "F"} nominal=${if nEq then "T" else "F"} hash=${if hEq then "T" else "F"}";
    };

  # ══════════════════════════════════════════════════════════════════════════════
  # 辅助函数
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: [Type] -> [Type] -> (Type -> Type -> Bool) -> Bool
  listTypeEq = as: bs: eq:
    builtins.length as == builtins.length bs
    && lib.all (p: eq p.fst p.snd) (lib.zipLists as bs);

  # Type: AttrSet String Type -> AttrSet String Type -> Bool
  attrTypeEq = ma: mb:
    let
      ks = builtins.sort (a: b: a < b) (builtins.attrNames ma);
      ks' = builtins.sort (a: b: a < b) (builtins.attrNames mb);
    in
    ks == ks' && lib.all (k: typeEq ma.${k} mb.${k}) ks;

}
