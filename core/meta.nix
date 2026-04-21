# core/meta.nix — Phase 3
# MetaType 语义控制层
#
# Phase 3 关键修复：
#   1. equality coherence law — 单一 canonical equality strategy（修复 INV-3 violation）
#   2. muPolicy — equi-recursive bisimulation 深度控制
#   3. rowPolicy — rowVar equality domain 修正
#   4. effectPolicy — Effect System 策略（Phase 3 新增）
#   5. bidirPolicy — Bidirectional checking 策略（Phase 3 新增）
#
# 核心原则（Phase 3）：
#   所有 equality 最终归一到 single canonical normal form（INV-3 强制）
#   不允许 multi-equality-semantics 并存而无 coherence law
{ lib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Equality Strategy（Phase 3：单一 canonical，coherence law 强制）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3 Equality Coherence Law：
  #   所有 equality 路径必须满足：
  #     structuralEq(a,b) = true → nominalEq(a,b) = true（结构蕴含 nominal）
  #     nominalEq(a,b) = true   → hashEq(a,b) = true（nominal 蕴含 hash）
  #   即：structural ⊆ nominal ⊆ hash（不允许反向）
  #
  # 实现：统一走 NF-hash equality，strategy 只影响 normalization 深度

  EqStrategy = {
    # 结构相等（NF 比较，最精确）— 默认
    structural = "structural";
    # 名义相等（name + structure，用于 ADT nominal typing）
    nominal    = "nominal";
    # 引用相等（hash 相等 → 相等，最宽松）
    referential = "referential";
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Hash Strategy
  # ══════════════════════════════════════════════════════════════════════════════

  HashStrategy = {
    # 基于 NF repr 的 canonical hash（默认，INV-4 要求）
    normalized = "normalized";
    # 基于 raw repr 的 hash（仅用于内部快速路径，不对外）
    repr       = "repr";
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Eval Strategy
  # ══════════════════════════════════════════════════════════════════════════════

  EvalStrategy = {
    lazy   = "lazy";    # 惰性求值（默认）
    strict = "strict";  # 严格求值
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Mu Policy（Phase 3：equi-recursive bisimulation 控制）
  # ══════════════════════════════════════════════════════════════════════════════

  MuPolicy = {
    # 展开深度限制（bisimulation fuel）
    fuel    = 8;
    # 是否启用 coinductive bisimulation（Phase 3 新增）
    coinductive = true;
    # bisimulation guard：已访问对 (a.id, b.id) → 视为相等（coinductive assumption）
    guardEnabled = true;
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Row Policy（Phase 3：rowVar equality domain 修正）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3 修复：rowVar 不走 alphaEq（binder equality），而走 rigid var equality
  RowPolicy = {
    # "rigid"   → rowVar 用 name equality（unification variable）
    # "unified" → rowVar 走 unification（最灵活）
    rowVarEq = "rigid";
    # row field 排序策略（canonical）
    fieldSort = "lexicographic";
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Kind Check Policy
  # ══════════════════════════════════════════════════════════════════════════════

  KindCheckPolicy = {
    # "strict"  → kind mismatch = error
    # "lenient" → kind mismatch = warning（Phase 1 compat）
    mode    = "strict";
    # 是否在 normalize 后验证 kind 一致性
    postNormalize = true;
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Effect Policy（Phase 3 新增）
  # ══════════════════════════════════════════════════════════════════════════════

  EffectPolicy = {
    # "row"     → Effect 用 Row Polymorphism 编码（Koka 风格）
    # "set"     → Effect 用集合（Haskell mtl 近似）
    encoding  = "row";
    # 默认 effect row（空 = 纯函数）
    defaultRow = null;
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Bidirectional Policy（Phase 3 新增）
  # ══════════════════════════════════════════════════════════════════════════════

  BidirPolicy = {
    # 是否启用 bidirectional type checking
    enabled = true;
    # subsumption 模式："coercive" | "strict"
    subsumption = "strict";
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # MetaType 构造器
  # ══════════════════════════════════════════════════════════════════════════════

  # 默认 Meta（所有 Phase 3 策略默认值）
  defaultMeta = {
    __metaTag     = "MetaType";
    eqStrategy    = EqStrategy.structural;
    hashStrategy  = HashStrategy.normalized;
    evalStrategy  = EvalStrategy.lazy;
    muPolicy      = MuPolicy;
    rowPolicy     = RowPolicy;
    kindCheckPolicy = KindCheckPolicy;
    effectPolicy  = EffectPolicy;
    bidirPolicy   = BidirPolicy;
    # 内嵌约束（Constrained 的补充，INV-6 支持）
    constraints   = [];
    # 不透明标记（nominal typing）
    opaque        = false;
    # 调试标签
    label         = null;
    # Phase 追踪
    phase         = 3;
  };

  # Nominal Meta（ADT name-based equality）
  nominalMeta = defaultMeta // {
    eqStrategy = EqStrategy.nominal;
    opaque     = true;
  };

  # Opaque Meta（黑盒类型）
  opaqueMeta = defaultMeta // {
    eqStrategy = EqStrategy.referential;
    opaque     = true;
  };

  # Recursive Meta（equi-recursive 类型，muFuel 控制展开）
  recursiveMeta = defaultMeta // {
    muPolicy = MuPolicy // { fuel = 16; };
  };

  # Row Meta（Row 类型专用）
  rowMeta = defaultMeta // {
    rowPolicy = RowPolicy // { rowVarEq = "rigid"; };
  };

  # Effect Meta（Effect 类型专用，Phase 3）
  effectMeta = defaultMeta // {
    effectPolicy = EffectPolicy // { encoding = "row"; };
  };

  # ── MetaType 谓词 ──────────────────────────────────────────────────────────
  isMeta       = m: builtins.isAttrs m && (m.__metaTag or null) == "MetaType";
  isNominal    = m: isMeta m && m.eqStrategy == EqStrategy.nominal;
  isOpaque     = m: isMeta m && m.opaque;
  isRecursive  = m: isMeta m && m.muPolicy.coinductive or false;

  # ── Meta 合并（覆盖策略）─────────────────────────────────────────────────
  # Type: MetaType -> MetaType -> MetaType
  mergeMeta = base: override:
    base // override // {
      __metaTag   = "MetaType";
      constraints = (base.constraints or []) ++ (override.constraints or []);
    };

  # ── Meta 验证（Phase 3 coherence check）──────────────────────────────────
  # Type: MetaType -> { ok: Bool; violations: [String] }
  validateMeta = m:
    let
      violations =
        (if !(isMeta m) then ["not a MetaType"] else [])
        ++
        # Coherence Law：nominal + not opaque = 警告（允许但建议 opaque）
        (if (m.eqStrategy or null) == EqStrategy.nominal && !(m.opaque or false)
         then ["nominal eq without opaque flag — consider setting opaque=true"]
         else [])
        ++
        # referential + constraints = 警告（约束在 referential 下无意义）
        (if (m.eqStrategy or null) == EqStrategy.referential
            && builtins.length (m.constraints or []) > 0
         then ["referential eq with constraints — constraints ignored in referential mode"]
         else []);
    in
    { ok = builtins.length violations == 0; inherit violations; };

}
