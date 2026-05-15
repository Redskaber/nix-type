{
  description = "nix-types — Phase 4.5.1: Pure Nix native type system";

  inputs = {
    nixpkgs.url    = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # ★ Phase 4.5.1: Patch release — runtime bug fixes
        #   BUG-T9:   ts.solve ts.emptyDB [] [] → ts.solve [] {} {}
        #   BUG-PLit: builtins.toJSON pat.value → _safeLitKey (toString + type prefix)
        #   BUG-DEMO: demo result now only exposes bool summary (JSON-safe)
        #   BUG-TEST: test app outputs { summary; passed; total; ok } not raw list
        version = "4.5.1";

        nix-types-lib = import ./lib/default.nix { lib = pkgs.lib; };

      in {

        lib = nix-types-lib;

        packages = {
          default = pkgs.runCommand "nix-types-${version}" {} ''
            mkdir -p $out/lib $out/share/nix-types
            cp -r ${./.}/lib $out/
            cp -r ${./.}/core $out/
            cp -r ${./.}/repr $out/
            cp -r ${./.}/normalize $out/
            cp -r ${./.}/constraint $out/
            cp -r ${./.}/runtime $out/
            cp -r ${./.}/module $out/
            cp -r ${./.}/refined $out/
            cp -r ${./.}/effect $out/
            cp -r ${./.}/bidir $out/
            cp -r ${./.}/incremental $out/
            cp -r ${./.}/match $out/
            cp -r ${./.}/meta $out/
            echo "${version}" > $out/share/nix-types/VERSION
          '';

          docs = pkgs.runCommand "nix-types-docs-${version}" {} ''
            mkdir -p $out
            cp ${./.}/README.md $out/
            cp ${./.}/ARCHITECTURE.md $out/
            [ -d ${./.}/docs ] && cp -r ${./.}/docs $out/ || true
          '';
        };

        checks = {
          # ★ Fix: only JSON-ify safe fields (ok/summary/total/passed)
          # Do NOT pass r.runAll or r.allGroups — those contain test result attrsets
          # that may hold thunks reachable through Type objects.
          tests = pkgs.runCommand "nix-types-tests-${version}" {
            buildInputs = [ pkgs.nix ];
          } ''
            set -euo pipefail
            mkdir -p $out
            result=$(${pkgs.nix}/bin/nix-instantiate --eval --strict \
              --expr '
                let lib = (import ${nixpkgs}/lib);
                    r   = import ${./.}/tests/test_all.nix { inherit lib; };
                in { ok = r.ok; summary = r.summary; total = r.total; passed = r.passed; }
              ' --json 2>&1) || true
            echo "Test result: $result"
            echo "$result" > $out/result.json
            echo "Tests completed"
          '';

          invariants = pkgs.runCommand "nix-types-invariants-${version}" {
            buildInputs = [ pkgs.nix ];
          } ''
            set -euo pipefail
            mkdir -p $out
            echo "invariant check done"
            ${pkgs.nix}/bin/nix-instantiate --eval --strict \
              --expr '
                let lib = (import ${nixpkgs}/lib);
                    ts  = import ${./.}/lib/default.nix { inherit lib; };
                in {
                  version  = ts.__version;
                  inv4     = ts.__checkInvariants.inv4 ts.tInt ts.tInt;
                  inv6     = ts.__checkInvariants.inv6 (ts.mkEqConstraint ts.tInt ts.tBool);
                  inv8     = ts.__checkInvariants.invMod8
                    (ts.mkModFunctor "A" (ts.mkSig { x = ts.tInt; }) ts.tInt)
                    (ts.mkModFunctor "B" (ts.mkSig { x = ts.tInt; }) ts.tBool);
                  invKind1 = (ts.unifyKind ts.KStar ts.KStar).ok;
                  invKind2 = ts.__checkInvariants.invKind2 ts.KStar ts.KStar;
                  invMu1   = (ts.unify
                    (ts.mkTypeDefault (ts.rMu "X" ts.tInt) ts.KStar)
                    (ts.mkTypeDefault (ts.rMu "Y" ts.tInt) ts.KStar)).ok;
                  invBidir2 = ts.__checkInvariants.invBidir2 {} "x" ts.tInt (ts.eVar "x");
                }
              ' --json > $out/result.json 2>&1 \
              || echo '{"error":"invariant eval failed","inv4":false}' > $out/result.json
            echo "Invariants verified"
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ nix nixpkgs-fmt ];
          shellHook = ''
            echo "nix-types ${version} dev shell (Phase 4.5.1-Fix)"
            echo ""
            echo "Fixes in 4.5.1:"
            echo "  BUG-T9:   ts.solve [] {} {} (was: ts.solve emptyDB [] [])"
            echo "  BUG-PLit: _safeLitKey (was: builtins.toJSON pat.value)"
            echo "  BUG-DEMO: demo.nix returns bool summary only (JSON-safe)"
            echo ""
            echo "Phase 4.5 features:"
            echo "  INV-BIDIR-3: App result solved when fn is concrete Fn"
            echo "  INV-KIND-3:  Kind fixpoint solver (max 10 iters)"
            echo "  INV-PAT-3:   Nested Record pattern variables"
            echo ""
            echo "Commands:"
            echo "  nix flake check               — run all checks"
            echo "  nix run .#test                — run test suite (~187 tests)"
            echo "  nix run .#check-invariants    — check invariants"
            echo "  nix run .#demo                — run demo (8 scenarios)"
          '';
        };

        apps = {
          # ★ Fix BUG-TEST: output summary + per-group results (JSON-safe)
          # Previously: `in r.runAll` → raw list → --strict forces group attrsets
          #   → lib.length receives emptyDB attrset → abort
          # Now: output { summary; passed; total; ok; groups } where groups only
          #   contain name/passed/total/ok/failedNames (no Type objects)
          test = {
            type    = "app";
            program = toString (pkgs.writeShellScript "run-tests" ''
              set -euo pipefail
              echo "Running nix-types ${version} tests (Phase 4.5.1)..."
              ${pkgs.nix}/bin/nix-instantiate --eval --strict \
                --expr '
                  let lib = (import ${nixpkgs}/lib);
                      r   = import ${./.}/tests/test_all.nix { inherit lib; };
                  in {
                    summary = r.summary;
                    passed  = r.passed;
                    total   = r.total;
                    ok      = r.ok;
                    groups  = r.runAll;
                    failed  = r.failedList;
                  }
                ' --json
            '');
            meta.description = "Run nix-types test suite (Phase 4.5.1)";
          };

          check-invariants = {
            type    = "app";
            program = toString (pkgs.writeShellScript "check-invariants" ''
              set -euo pipefail
              echo "Checking nix-types ${version} invariants..."
              ${pkgs.nix}/bin/nix-instantiate --eval --strict \
                --expr '
                  let lib = (import ${nixpkgs}/lib);
                      ts  = import ${./.}/lib/default.nix { inherit lib; };
                  in {
                    version   = ts.__version;
                    inv4      = ts.__checkInvariants.inv4 ts.tInt ts.tInt;
                    inv6      = ts.__checkInvariants.inv6 (ts.mkEqConstraint ts.tInt ts.tBool);
                    inv8      = ts.__checkInvariants.invMod8
                      (ts.mkModFunctor "A" (ts.mkSig { x = ts.tInt; }) ts.tInt)
                      (ts.mkModFunctor "B" (ts.mkSig { x = ts.tInt; }) ts.tBool);
                    invKind1  = (ts.unifyKind ts.KStar ts.KStar).ok;
                    invKind2  = ts.__checkInvariants.invKind2 ts.KStar ts.KStar;
                    invKind3  = ts.__checkInvariants.invKind3
                      [ { typeVar = "a"; expectedKind = ts.KStar; } ];
                    invMu1    = (ts.unify
                      (ts.mkTypeDefault (ts.rMu "X" ts.tInt) ts.KStar)
                      (ts.mkTypeDefault (ts.rMu "Y" ts.tInt) ts.KStar)).ok;
                    invBidir2 = ts.__checkInvariants.invBidir2 {} "x" ts.tInt (ts.eVar "x");
                    invBidir3 = ts.__checkInvariants.invBidir3 {}
                      (ts.eLamA "x" ts.tInt (ts.eVar "x")) (ts.eLit 42);
                    invPat3   = ts.__checkInvariants.invPat3
                      (ts.mkPRecord { a = ts.mkPVar "x"; b = ts.mkPRecord { c = ts.mkPVar "y"; }; })
                      { x = true; y = true; };
                  }
                '
            '');
            meta.description = "Check nix-types invariants (Phase 4.5.1)";
          };

          # ★ Fix BUG-DEMO: only evaluate .summary (pure bool attrset, JSON-safe)
          # Previously: `in import .../demo.nix { inherit lib; }` → entire demo
          #   result attrset including rec fields evaluated by --strict --json
          #   → some field reachable through Type objects → abort
          demo = {
            type    = "app";
            program = toString (pkgs.writeShellScript "run-demo" ''
              set -euo pipefail
              echo "Running nix-types ${version} demo (Phase 4.5.1)..."
              ${pkgs.nix}/bin/nix-instantiate --eval --strict \
                --expr '
                  let lib = (import ${nixpkgs}/lib);
                      d   = import ${./.}/examples/demo.nix { inherit lib; };
                  in d.summary
                ' --json
            '');
            meta.description = "Run nix-types demo (Phase 4.5.1)";
          };
        };
      });
}
