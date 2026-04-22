# core/meta.nix — Phase 4.2
# MetaType：语义控制层（不只是 metadata，控制 normalize/equality/hash 行为）
{ lib }:

rec {
  # ══ MetaType 默认值 ════════════════════════════════════════════════════
  defaultMeta = {
    eqStrategy   = "structural";  # "structural" | "nominal" | "alpha"
    hashStrategy = "normalized";  # "repr" | "normalized"
    evalStrategy = "strict";      # "strict" | "lazy"
    muPolicy     = "guardset";    # "guardset" | "bisim" (Phase 4.3)
    rowPolicy    = "canonical";   # "canonical" | "raw"
    bidirPolicy  = "check";       # "check" | "infer" | "synth"
    schemePolicy = "generalize";  # "generalize" | "mono" (Phase 4.2)
    constraints  = [];            # 附加约束列表
    annotations  = {};            # 任意用户标注（不影响语义）
  };

  # ══ MetaType 构造器 ════════════════════════════════════════════════════
  mkMeta = overrides: defaultMeta // overrides;

  # 名义类型 meta（nominal equality：相同 id 才相等）
  nominalMeta = mkMeta { eqStrategy = "nominal"; };

  # 懒惰求值 meta（用于 Mu 类型展开控制）
  lazyMeta = mkMeta { evalStrategy = "lazy"; };

  # TypeScheme meta（Phase 4.2：泛型方案）
  schemeMeta = mkMeta { schemePolicy = "generalize"; };

  # Opaque / abstract meta（隐藏内部结构）
  opaqueMeta = mkMeta { eqStrategy = "nominal"; hashStrategy = "repr"; };

  # ══ MetaType 谓词 ══════════════════════════════════════════════════════
  isMeta = m: builtins.isAttrs m && m ? eqStrategy;
  isNominal    = m: isMeta m && m.eqStrategy == "nominal";
  isStructural = m: isMeta m && m.eqStrategy == "structural";
  isLazy       = m: isMeta m && m.evalStrategy == "lazy";
  isScheme     = m: isMeta m && m.schemePolicy == "generalize";

  # ══ MetaType 合并（Phase 4.2：Module 合并用）══════════════════════════
  # Type: Meta → Meta → Meta
  # 右边优先（后者覆盖前者），但约束合并
  mergeMeta = m1: m2:
    let
      base = m1 // m2;
      mergedConstraints = m1.constraints ++ m2.constraints;
    in
    base // { constraints = mergedConstraints; };
}
