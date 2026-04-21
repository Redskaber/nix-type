# core/meta.nix — Phase 4.1
# MetaType：语义控制层（控制 normalize/equality/hash 行为）
# Meta 不是注释，是语义参数
{ lib }:

rec {
  # ── MetaType 结构 ─────────────────────────────────────────────────────────
  mkMeta =
    { eqStrategy   ? "structural"  # "structural" | "nominal"
    , hashStrategy ? "normalized"  # "repr" | "normalized"（INV-4 要求 normalized）
    , evalStrategy ? "lazy"        # "strict" | "lazy"
    , muPolicy     ? "equi"        # "equi" | "iso" — 递归类型展开策略
    , rowPolicy    ? "open"        # "open" | "closed" — Row 类型策略
    , bidirPolicy  ? "check"       # "check" | "infer" — 双向类型策略
    , constraints  ? []            # 默认附加约束 [Constraint]
    , phase        ? "4.1"         # 创建时的 Phase（便于迁移诊断）
    }:
    { __type       = "MetaType";
      eqStrategy   = eqStrategy;
      hashStrategy = hashStrategy;
      evalStrategy = evalStrategy;
      muPolicy     = muPolicy;
      rowPolicy    = rowPolicy;
      bidirPolicy  = bidirPolicy;
      constraints  = constraints;
      phase        = phase;
    };

  # ── 预定义 Meta 配置 ──────────────────────────────────────────────────────
  defaultMeta  = mkMeta {};
  nominalMeta  = mkMeta { eqStrategy = "nominal"; };
  strictMeta   = mkMeta { evalStrategy = "strict"; };
  isoMeta      = mkMeta { muPolicy = "iso"; };
  closedRowMeta = mkMeta { rowPolicy = "closed"; };
  inferMeta    = mkMeta { bidirPolicy = "infer"; };

  # ── Meta 语义查询 ─────────────────────────────────────────────────────────
  isNominal    = meta: (meta.eqStrategy or "structural") == "nominal";
  isStrict     = meta: (meta.evalStrategy or "lazy") == "strict";
  isEquiMu     = meta: (meta.muPolicy or "equi") == "equi";
  isOpenRow    = meta: (meta.rowPolicy or "open") == "open";
  isBidirInfer = meta: (meta.bidirPolicy or "check") == "infer";

  # ── Meta 合并（用于 Constrained 类型合并场景）────────────────────────────
  # Type: MetaType -> MetaType -> MetaType
  mergeMeta = m1: m2:
    mkMeta {
      eqStrategy   = if (m1.eqStrategy or "structural") == "nominal" then "nominal"
                     else m2.eqStrategy or "structural";
      hashStrategy = if (m1.hashStrategy or "normalized") == "repr" then "repr"
                     else m2.hashStrategy or "normalized";
      evalStrategy = if (m1.evalStrategy or "lazy") == "strict" then "strict"
                     else m2.evalStrategy or "lazy";
      muPolicy     = m1.muPolicy or "equi";
      rowPolicy    = m1.rowPolicy or "open";
      bidirPolicy  = m1.bidirPolicy or "check";
      constraints  = (m1.constraints or []) ++ (m2.constraints or []);
    };
}
