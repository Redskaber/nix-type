{
  description = "Pure Nix native type system — Phase 4.1";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs    = nixpkgs.legacyPackages.${system};
        nixLib  = pkgs.lib;

        # ── 核心类型系统 lib ───────────────────────────────────────────────
        typeSystem = import ./lib/default.nix { lib = nixLib; };

        # ── 版本 + Meta 信息 ──────────────────────────────────────────────
        meta = typeSystem.meta;

        # ── Tests runner（纯 Nix eval，不依赖外部工具）──────────────────
        testResults = import ./tests/test_all.nix { lib = nixLib; };

        # ── derivation helpers ─────────────────────────────────────────────
        runNixEval = name: expr:
          pkgs.runCommand name {} ''
            result=$(${pkgs.nix}/bin/nix-instantiate --eval --strict \
              --expr '${expr}' 2>&1) || true
            echo "$result" > $out
          '';

      in {

        # ══ lib（system-specific）════════════════════════════════════════════
        lib = typeSystem;

        # ══ Checks（nix flake check）═════════════════════════════════════════
        checks = {

          # ── 不变量验证（纯 Nix eval）────────────────────────────────────
          invariants = pkgs.runCommand "nix-types-invariants-p41" {
            buildInputs = [ pkgs.nix ];
          } ''
            set -euo pipefail

            result=$(nix-instantiate --eval --strict --expr '
              let
                lib = (import ${nixpkgs}/lib);
                ts  = import ${./.}/lib/default.nix { inherit lib; };

                # INV-1: 所有结构 ∈ TypeIR
                inv1 = ts.isType (ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar);

                # INV-4: typeEq ⟹ hash eq
                inv4 =
                  let
                    t1 = ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar;
                    t2 = ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar;
                  in ts.typeEq t1 t2 && ts.typeHash t1 == ts.typeHash t2;

                # INV-6: Constraint ∈ TypeRepr
                inv6 =
                  let
                    tInt = ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar;
                    c    = ts.mkEqConstraint tInt tInt;
                  in c ? __constraintTag;

                # INV-SOL5: worklist requeue (Phase 4.1)
                invSol5 =
                  let
                    tInt  = ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar;
                    tVar  = ts.mkTypeDefault (ts.rVar "α" "t") ts.KStar;
                    c1    = ts.mkEqConstraint tVar tInt;
                    r     = ts.solveSimple [ c1 ];
                  in r.ok;

                # INV-MOD-4: Sig fields sorted
                invMod4 =
                  let
                    sig    = ts.mkSig { z = ts.mkTypeDefault (ts.rPrimitive "Bool") ts.KStar;
                                        a = ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar; };
                    fields = ts.sigFields sig;
                    names  = builtins.attrNames fields;
                    sorted = lib.sort (a: b: a < b) names;
                  in names == sorted;

                allOk = inv1 && inv4 && inv6 && invSol5 && invMod4;
              in allOk
            ' 2>&1)

            if [ "$result" = "true" ]; then
              echo "All invariants passed" > $out
            else
              echo "INVARIANT FAILURE: $result"
              exit 1
            fi
          '';

          # ── 测试套件验证 ─────────────────────────────────────────────────
          tests = pkgs.runCommand "nix-types-tests-p41" {
            buildInputs = [ pkgs.nix ];
          } ''
            set -euo pipefail

            result=$(nix-instantiate --eval --strict --expr '
              let
                lib = (import ${nixpkgs}/lib);
                r   = import ${./.}/tests/test_all.nix { inherit lib; };
              in
              { ok = r.ok; passed = r.passed; failed = r.failed; total = r.total; }
            ' 2>&1)

            echo "Test result: $result"

            # 检查 ok = true
            if echo "$result" | grep -q '"ok":true\|ok = true'; then
              echo "All tests passed" > $out
            elif echo "$result" | grep -q 'ok = true'; then
              echo "All tests passed" > $out
            else
              echo "TESTS FAILED: $result"
              exit 1
            fi
          '';

          # ── Phase 4.1 专项验证 ───────────────────────────────────────────
          phase41-specific = pkgs.runCommand "nix-types-p41-checks" {
            buildInputs = [ pkgs.nix ];
          } ''
            set -euo pipefail

            result=$(nix-instantiate --eval --strict --expr '
              let
                lib = (import ${nixpkgs}/lib);
                ts  = import ${./.}/lib/default.nix { inherit lib; };

                tInt  = ts.mkTypeDefault (ts.rPrimitive "Int")  ts.KStar;
                tBool = ts.mkTypeDefault (ts.rPrimitive "Bool") ts.KStar;

                # RISK-A fix: canDischarge returns true only when impl != null
                riskA =
                  ts.canDischarge {} ts.emptyDB
                    (ts.mkClassConstraint "Eq" [ tInt ]);

                # RISK-B fix: instanceKey NF-hash stable
                riskB =
                  let
                    k1 = ts.instanceLib._instanceKey "Eq" [ tInt ];
                    k2 = ts.instanceLib._instanceKey "Eq"
                          [ ts.mkTypeDefault (ts.rPrimitive "Int") ts.KStar ];
                  in k1 == k2;

                # RISK-D fix: cacheNormalize writes both
                riskD =
                  let
                    r = ts.cacheNormalize ts.emptyQueryDB {} "tid" tInt [];
                  in r ? queryDB && r ? memo && r.memo ? "tid";

                # RISK-E fix: applyFunctor qualified naming
                riskE =
                  let
                    sig = ts.mkSig { t = tInt; };
                    f   = ts.mkModFunctor "M" sig
                            (ts.mkTypeDefault (ts.rVar "M" "func") ts.KStar);
                    arg = ts.mkStruct sig { t = tInt; };
                    r   = ts.applyFunctor f arg;
                  in r.ok;

                # INV-QK-SCHEMA: validateQueryKey
                schema =
                  ts.queryLib.validateQueryKey "norm:abc" &&
                  !(ts.queryLib.validateQueryKey "bad:abc");

                # INV-SMT-5: checkRefinedSubtype with oracle
                smt5 =
                  let
                    sub = ts.mkRefined tInt "n"
                            (ts.mkPCmp "gt" (ts.mkPVar "n") (ts.mkPLit 0));
                    sup = ts.mkRefined tInt "n"
                            (ts.mkPCmp "ge" (ts.mkPVar "n") (ts.mkPLit 0));
                    r   = ts.checkRefinedSubtype sub sup (_: "unsat");
                  in r.ok;

                allOk = riskA && riskB && riskD && riskE && schema && smt5;
              in allOk
            ' 2>&1)

            if [ "$result" = "true" ]; then
              echo "All Phase 4.1 specific checks passed" > $out
            else
              echo "PHASE 4.1 CHECK FAILURE: $result"
              exit 1
            fi
          '';
        };

        # ══ packages ═════════════════════════════════════════════════════════
        packages = {
          default = pkgs.runCommand "nix-types-${meta.version}" {} ''
            mkdir -p $out/lib $out/share/nix-types
            cp -r ${./.}/. $out/share/nix-types/
            cat > $out/lib/nix-types.nix <<'EOF'
# nix-types — ${meta.version}
# Usage: import /path/to/nix-types/lib/nix-types.nix { inherit lib; }
{ lib }: import ${./.}/lib/default.nix { inherit lib; }
EOF
            echo "${meta.version}" > $out/share/nix-types/VERSION
          '';

          # 文档包（tests + README）
          docs = pkgs.runCommand "nix-types-docs-${meta.version}" {} ''
            mkdir -p $out
            cp ${./.}/README.md $out/
            cp ${./.}/ARCHITECTURE.md $out/
            cp ${./.}/TODO-Phase4.md $out/
          '';
        };

        # ══ devShells ════════════════════════════════════════════════════════
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ nix nixpkgs-fmt ];
          shellHook = ''
            echo "nix-types ${meta.version} dev shell"
            echo "Run: nix flake check"
          '';
        };

        # ══ apps（convenience commands）══════════════════════════════════════
        apps = {
          test = {
            type    = "app";
            program = toString (pkgs.writeShellScript "run-tests" ''
              set -euo pipefail
              echo "Running nix-types ${meta.version} tests..."
              ${pkgs.nix}/bin/nix-instantiate --eval --strict \
                --expr '
                  let lib = (import ${nixpkgs}/lib);
                      r   = import ${./.}/tests/test_all.nix { inherit lib; };
                  in "Passed: ''${builtins.toString r.passed} / ''${builtins.toString r.total}"
                '
            '');
          };

          check-invariants = {
            type    = "app";
            program = toString (pkgs.writeShellScript "check-invariants" ''
              set -euo pipefail
              echo "Checking type system invariants..."
              ${pkgs.nix}/bin/nix-instantiate --eval --strict \
                --expr '
                  let lib = (import ${nixpkgs}/lib);
                      ts  = import ${./.}/lib/default.nix { inherit lib; };
                  in ts.meta
                ' --json
            '');
          };
        };

      }
    ) // {
      # ── System-independent outputs ─────────────────────────────────────────

      # lib overlay（可被其他 flake 引用）
      overlays.default = final: prev: {
        nix-types = import ./lib/default.nix { lib = final.lib; };
      };

      # NixOS module
      nixosModules.default = { lib, config, ... }: {
        options.nix-types = {
          enable = lib.mkEnableOption "nix-types type system library";
        };
        config = lib.mkIf config.nix-types.enable {
          environment.systemPackages = [
            (import ./lib/default.nix { inherit lib; })
          ];
        };
      };
    };
}
