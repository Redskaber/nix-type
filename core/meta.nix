# core/meta.nix — Phase 4.3
# MetaType：语义控制层（不只是 metadata，控制 normalize/equality/hash 行为）
{ lib }:

rec {
  # ══ MetaType 默认值 ════════════════════════════════════════════════════
  defaultMeta = {
    eqStrategy   = "structural";  # "structural" | "nominal" | "alpha"
    hashStrategy = "normalized";  # "repr" | "normalized"
    evalStrategy = "strict";      # "strict" | "lazy"
    muPolicy     = "guardset";    # "guardset" | "bisim-congruence" (Phase 4.3)
    rowPolicy    = "canonical";   # "canonical" | "raw"
    bidirPolicy  = "check";       # "check" | "infer" | "synth"
    schemePolicy = "generalize";  # "generalize" | "mono"
    kindPolicy   = "infer";       # "infer" | "check" (Phase 4.3)
    constraints  = [];            # 附加约束列表
    annotations  = {};            # 任意用户标注（不影响语义）
  };

  # ══ MetaType 构造器 ════════════════════════════════════════════════════
  mkMeta = overrides: defaultMeta // overrides;

  nominalMeta = mkMeta { eqStrategy = "nominal"; };
  lazyMeta    = mkMeta { evalStrategy = "lazy"; muPolicy = "bisim-congruence"; };
  schemeMeta  = mkMeta { schemePolicy = "generalize"; };
  opaqueMeta  = mkMeta { eqStrategy = "nominal"; hashStrategy = "repr"; };

  # Phase 4.3: bisim-congruence meta（up-to congruence Mu unification）
  bisimMeta   = mkMeta { muPolicy = "bisim-congruence"; };

  # ══ MetaType 谓词 ══════════════════════════════════════════════════════
  isMeta       = m: builtins.isAttrs m && m ? eqStrategy;
  isNominal    = m: isMeta m && m.eqStrategy == "nominal";
  isStructural = m: isMeta m && m.eqStrategy == "structural";
  isLazy       = m: isMeta m && m.evalStrategy == "lazy";
  isScheme     = m: isMeta m && m.schemePolicy == "generalize";
  # Phase 4.3: bisim congruence predicate
  isBisimCongruence = m: isMeta m && (m.muPolicy or "guardset") == "bisim-congruence";

  # ══ MetaType 合并 ══════════════════════════════════════════════════════
  mergeMeta = m1: m2:
    let
      base = m1 // m2;
      mergedConstraints = m1.constraints ++ m2.constraints;
    in
    base // { constraints = mergedConstraints; };
}
