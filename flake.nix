{
  description = ''
    nix-types — 纯 Nix 原生强类型系统
    Phase 4.0: UnifiedSubst + Refined Types (SMT Bridge) + Module System
             + Effect Handlers + QueryKey Incremental Pipeline

    类 Rust 编译器增量管道（Salsa-style QueryKey）· canonical-hash · TRS 归约引擎
    System Fω + Dependent Types + Row Polymorphism + Effect System
    + Bidirectional Checking + Equi-Recursive Bisimulation

    Phase 4.0 新增：
      - UnifiedSubst（type+row+kind 统一替换，解决 Phase 3.3 遗留风险）
      - Refined Types（Liquid Types，PredExpr IR，SMT Bridge，static eval）
      - Module System（Sig/Struct/Functor，checkSig，sealing，subtyping）
      - Effect Handlers（algebraic effects，checkHandler，handleAll）
      - QueryKey DB（Salsa-style BFS 失效，精确 dep tracking，cycle detection）

    适用于：Nix 配置类型验证、嵌入式 DSL 类型推断、元编程类型反射
  '';

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs   = nixpkgs.legacyPackages.${system};
        nixLib = pkgs.lib;

        # ── 核心类型系统 lib ──────────────────────────────────────────────────
        typeSystem = import ./lib/default.nix { lib = nixLib; };

        # ── 版本 + 元信息 ─────────────────────────────────────────────────────
        meta = {
          name        = "nix-types";
          version     = "4.0.0";
          phase       = "4.0";
          description = "Pure Nix native type system — Phase 4.0";
          license     = "MIT";
          homepage    = "https://github.com/yourorg/nix-types";

          # 能力矩阵（Phase 4.0）
          capabilities = {
            # Phase 3.x
            kindSystem          = true;
            systemFomega        = true;
            dependentTypes      = true;
            rowPolymorphism     = true;
            effectSystem        = true;
            equiRecursive       = true;
            bidirectional       = true;
            constraintSolver    = true;
            instanceDB          = true;
            patternMatching     = true;
            incrementalGraph    = true;
            memoization         = true;
            openRowUnification  = true;
            effectRowMerge      = true;
            variantRowCanonical = true;
            # Phase 4.0 NEW
            refinedTypes        = true;   # Liquid Types / SMT bridge
            moduleSystem        = true;   # Sig / Struct / Functor
            effectHandlers      = true;   # algebraic effects dispatch
            unifiedSubst        = true;   # type + row + kind subst unified
            queryKeyIncremental = true;   # Salsa-style fine-grained cache
          };
        };

      in {

        # ── lib（system-specific）─────────────────────────────────────────────
        lib = typeSystem;

        # ── Checks（nix flake check）─────────────────────────────────────────
        checks = {
          # Phase 4.0 不变量验证
          invariants = pkgs.runCommand "nix-types-invariants-p40" {} ''
            result=$(${pkgs.nix}/bin/nix-instantiate --eval --strict \
              --expr '(import ${./.}/lib/default.nix { lib = import ${pkgs.path}/lib; }).verifyInvariants {}' \
              2>&1)
            echo "Result: $result"
            if echo "$result" | grep -q '"allPass":true\|allPass = true'; then
              echo "✅ Phase 4.0 invariants pass"
              touch $out
            else
              echo "❌ Phase 4.0 invariants FAILED"
              exit 1
            fi
          '';

          # Phase 4.0 专项测试
          tests-phase40 = pkgs.runCommand "nix-types-tests-p40" {} ''
            result=$(${pkgs.nix}/bin/nix-instantiate --eval --strict \
              ${./.}/tests/test_phase40.nix 2>&1)
            echo "Result: $result"
            if echo "$result" | grep -q '"allPass":true\|allPass = true'; then
              echo "✅ Phase 4.0 tests pass"
              touch $out
            else
              echo "❌ Phase 4.0 tests FAILED"
              exit 1
            fi
          '';
        };

        # ── Packages ─────────────────────────────────────────────────────────
        packages = {
          default = pkgs.runCommand "nix-types-p40" {
            passthru = {
              inherit meta;
              lib = typeSystem;
            };
          } ''
            mkdir -p $out/lib
            cp -r ${./.}/lib $out/
            cp -r ${./.}/core $out/
            cp -r ${./.}/repr $out/
            cp -r ${./.}/normalize $out/
            cp -r ${./.}/constraint $out/
            cp -r ${./.}/refined $out/
            cp -r ${./.}/module $out/
            cp -r ${./.}/effect $out/
            cp -r ${./.}/runtime $out/
            cp -r ${./.}/meta $out/
            cp -r ${./.}/incremental $out/
            cp -r ${./.}/match $out/
            cp -r ${./.}/bidir $out/
            cp ${./.}/README.md $out/
            cp ${./.}/ARCHITECTURE.md $out/
            touch $out
          '';
        };

        # ── DevShell ─────────────────────────────────────────────────────────
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ nix nixpkgs-fmt ];
          shellHook = ''
            echo "nix-types Phase 4.0 development shell"
            echo "Run: nix-instantiate --eval --strict lib/default.nix"
          '';
        };

      }) // {

    # ── system-agnostic factory（推荐 library 使用）────────────────────────
    libFactory = { lib }: import ./lib/default.nix { inherit lib; };

    # ── 机器可读 API 目录 ────────────────────────────────────────────────────
    exportInfo = (import ./lib/default.nix { lib = (import <nixpkgs> {}).lib; }).exportInfo;

  };
}
