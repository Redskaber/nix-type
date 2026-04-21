# core/meta.nix — Phase 3.1
# MetaType 语义控制层（Coherence Law 强制）
#
# Phase 3.1 修复：
#   1. INV-3 强化：strategy 不影响 equality 判断路径，只影响 normalization 深度
#   2. 移除 strategy 分支导致的 INV-EQ1 违反
#   3. muPolicy / rowPolicy / effectPolicy / bidirPolicy 完整定义
#   4. validateMeta 增强（coherence law 一致性检查）
#
# 核心原则：
#   所有 equality 归一到 single canonical NF（INV-3 强制）
#   strategy 只影响 normalize 深度/展开策略，不影响比较路径
{ lib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Equality Strategy（Phase 3.1：纯注释性，不改变 equality 路径）
  # ══════════════════════════════════════════════════════════════════════════════
  # 注意：Phase 3.1 核心修复 —— 所有 equality 最终都走 NF-hash 比较
  # strategy 只决定 normalize 时的展开深度策略（不决定是否比较）

  EqStrategy = {
    structural  = "structural";  # NF 比较（最精确，默认）
    nominal     = "nominal";     # name + NF（ADT 名义类型）
    referential = "referential"; # hash 相等即相等（最宽松）
  };

  HashStrategy = {
    normalized = "normalized";  # NF-hash（默认，INV-4 要求）
    repr       = "repr";        # raw repr hash（仅内部快速路径）
  };

  EvalStrategy = {
    lazy   = "lazy";    # 惰性求值（默认）
    strict = "strict";  # 严格求值
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Mu Policy（equi-recursive bisimulation 控制）
  # ══════════════════════════════════════════════════════════════════════════════

  MuPolicy = {
    # bisimulation 燃料（展开深度上限）
    fuel         = 8;
    # 启用 coinductive bisimulation（guard set 保护）
    coinductive  = true;
    # guard set：已访问对 (a.id, b.id) → coinductive hypothesis
    guardEnabled = true;
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Row Policy（rowVar equality domain 修正，INV-EQ4）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：rowVar 不走 alphaEq（binder equality）
  # 而走 rigid var equality（unification variable 语义）
  RowPolicy = {
    # "rigid"   → rowVar 用 name equality
    # "unified" → rowVar 走 unification（最灵活）
    rowVarEq  = "rigid";
    # row field 排序策略（canonical lexicographic）
    fieldSort = "lexicographic";
    # 允许 structural row extension
    openRows  = true;
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind Check Policy
  # ══════════════════════════════════════════════════════════════════════════════

  KindCheckPolicy = {
    mode           = "strict";    # "strict" | "lenient"
    postNormalize  = true;        # normalize 后验证 kind 一致性
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Effect Policy（Phase 3：Row-based algebraic effects）
  # ══════════════════════════════════════════════════════════════════════════════

  EffectPolicy = {
    encoding   = "row";   # "row" | "set"
    defaultRow = null;    # 默认 effect row（null = 纯函数）
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Bidirectional Policy（Pierce/Turner 风格）
  # ══════════════════════════════════════════════════════════════════════════════

  BidirPolicy = {
    enabled      = true;
    subsumption  = "strict";  # "coercive" | "strict"
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Normalize Policy（Phase 3.1 新增：统一化 normalize 策略）
  # ══════════════════════════════════════════════════════════════════════════════

  NormalizePolicy = {
    # β-reduction 燃料
    betaFuel      = 64;
    # 深度限制
    depthFuel     = 32;
    # Mu 展开燃料（独立于 bisimulation fuel）
    muFuel        = 8;
    # eta reduction 是否启用（Phase 3.1：保守关闭）
    etaEnabled    = false;
    # innermost / outermost reduction strategy
    strategy      = "innermost";
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # MetaType 构造器
  # ══════════════════════════════════════════════════════════════════════════════

  defaultMeta = {
    __metaTag       = "MetaType";
    eqStrategy      = EqStrategy.structural;
    hashStrategy    = HashStrategy.normalized;
    evalStrategy    = EvalStrategy.lazy;
    muPolicy        = MuPolicy;
    rowPolicy       = RowPolicy;
    kindCheckPolicy = KindCheckPolicy;
    effectPolicy    = EffectPolicy;
    bidirPolicy     = BidirPolicy;
    normalizePolicy = NormalizePolicy;
    constraints     = [];   # 内嵌约束（INV-6）
    opaque          = false;
    label           = null;
    phase           = 3;
  };

  nominalMeta = defaultMeta // {
    eqStrategy = EqStrategy.nominal;
    opaque     = true;
  };

  opaqueMeta = defaultMeta // {
    eqStrategy = EqStrategy.referential;
    opaque     = true;
  };

  recursiveMeta = defaultMeta // {
    muPolicy = MuPolicy // { fuel = 16; coinductive = true; };
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # MetaType 判断与验证
  # ══════════════════════════════════════════════════════════════════════════════

  isMeta = m:
    builtins.isAttrs m && (m.__metaTag or null) == "MetaType";

  # MetaType 验证（Phase 3.1：coherence law 一致性检查）
  # Type: MetaType -> { ok: Bool; violations: [String] }
  validateMeta = m:
    let
      violations =
        (if !(isMeta m) then ["not a MetaType"] else [])
        ++
        # INV-3 coherence：strategy 合法值
        (let s = m.eqStrategy or null; in
         if !builtins.elem s [EqStrategy.structural EqStrategy.nominal EqStrategy.referential]
         then ["invalid eqStrategy: ${builtins.toString s}"]
         else [])
        ++
        # nominal 必须 opaque
        (if (m.eqStrategy or null) == EqStrategy.nominal && !(m.opaque or false)
         then ["nominal eq without opaque=true — possible coherence break"]
         else [])
        ++
        # referential + constraints = 语义矛盾
        (if (m.eqStrategy or null) == EqStrategy.referential
            && builtins.length (m.constraints or []) > 0
         then ["referential eq with constraints — constraints ignored in referential mode"]
         else []);
    in
    { ok = builtins.length violations == 0; inherit violations; };

  # ══════════════════════════════════════════════════════════════════════════════
  # MetaType 工具
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: MetaType -> MetaType -> MetaType（合并两个 Meta，保守合并）
  mergeMeta = a: b:
    defaultMeta // {
      eqStrategy   = if a.eqStrategy == EqStrategy.referential
                        || b.eqStrategy == EqStrategy.referential
                     then EqStrategy.referential
                     else if a.eqStrategy == EqStrategy.nominal
                             || b.eqStrategy == EqStrategy.nominal
                     then EqStrategy.nominal
                     else EqStrategy.structural;
      constraints  = (a.constraints or []) ++ (b.constraints or []);
      opaque       = (a.opaque or false) || (b.opaque or false);
      label        = a.label or b.label;
    };

  # Type: MetaType -> [Constraint] -> MetaType
  addConstraints = m: cs:
    m // { constraints = (m.constraints or []) ++ cs; };

  # 获取 normalize 燃料
  getBetaFuel = m:
    (m.normalizePolicy or NormalizePolicy).betaFuel or 64;
  getMuFuel = m:
    (m.muPolicy or MuPolicy).fuel or 8;
}
