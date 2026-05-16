# tests/match/diagnose_pat.nix
#   nix-instantiate --eval --strict tests/match/diagnose_pat.nix
#
# 逐步暴露 patternVars 失败的精确位置。
let
  lib = (import <nixpkgs> {}).lib;
  ts  = import ../../lib/default.nix { inherit lib; };

  p = ts.mkPCtor "Some" [ (ts.mkPVar "x") ];

  # 直接导入 patternLib，绕过 lib/default.nix 的 alias
  patternLib = import ../../match/pattern.nix {
    inherit lib;
    typeLib  = import ../../core/type.nix {
      inherit lib;
      kindLib   = import ../../core/kind.nix { inherit lib; };
      metaLib   = import ../../core/meta.nix { inherit lib; };
      serialLib = import ../../meta/serialize.nix {
        inherit lib;
        kindLib = import ../../core/kind.nix { inherit lib; };
      };
    };
    reprLib  = import ../../repr/all.nix {
      inherit lib;
      kindLib = import ../../core/kind.nix { inherit lib; };
    };
    kindLib  = import ../../core/kind.nix { inherit lib; };
  };

  p2 = patternLib.mkPCtor "Some" [ (patternLib.mkPVar "x") ];

in {
  # 1. 检查 ts.mkPCtor / ts.mkPVar 构造出的结构
  p_tag              = p.__patTag;
  p_has_fields       = p ? fields;
  p_fields_is_list   = builtins.isList p.fields;
  p_fields_length    = builtins.length p.fields;
  field0_type        = builtins.typeOf (builtins.head p.fields);
  field0_patTag      = (builtins.head p.fields).__patTag or "MISSING";
  field0_name        = (builtins.head p.fields).name    or "MISSING";

  # 2. ts.patternVars 结果（通过 lib/default.nix alias）
  ts_patternVars     = ts.patternVars p;

  # 3. patternLib.patternVars 直接结果（绕过 lib/default.nix）
  direct_patternVars = patternLib.patternVars p2;

  # 4. ts.mkPVar 和 patternLib.mkPVar 是否同一对象
  mkPVar_tag_ts      = (ts.mkPVar "x").__patTag or "MISSING";
  mkPVar_tag_direct  = (patternLib.mkPVar "x").__patTag or "MISSING";

  # 5. ts.patternVars 是否就是 patternLib.patternVars
  same_fn = ts.patternVars == patternLib.patternVars;
}

