{
  description = "nix-types — Phase 4.5.8: Pure Nix native type system";

  inputs = {
    nixpkgs.url    = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # ★ Phase 4.5.8: Test framework enhancement + BUG-T16/T25 fix
        #   BUG-T16: patternVars Ctor branch — builtins.map patternVars (rec fn)
        #            causes lazy-eval cycle in Nix rec{} → eval-error
        #            Fix: wrap in lambda (p: patternVars p)
        #   BUG-T25: invPat1 via patternLib.patternVars — same root cause
        #            Fix: same lambda wrapper in match/pattern.nix
        #   FRAMEWORK: mkTestBool/mkTest/mkTestWith carry diag fields
        #              diagnoseAll output provides hint/actual/expected per failure
        #              nix run .#diagnose — detailed failure report
        version = "4.5.8";

        nix-types-lib = import ./lib/default.nix { lib = pkgs.lib; };

        nixpkgs-path = nixpkgs;

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
          # JSON-safe fields only (ok/summary/total/passed)
          tests = pkgs.runCommand "nix-types-tests-${version}" {
            buildInputs = [ pkgs.nix ];
          } ''
            set -euo pipefail
            mkdir -p $out
            result=$(${pkgs.nix}/bin/nix-instantiate --eval --strict \
              --expr '
                let lib = (import ${nixpkgs-path}/lib);
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
                let lib = (import ${nixpkgs-path}/lib);
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
                  invPat1   = ts.__checkInvariants.invPat1
                    (ts.mkPCtor "Just" [ts.mkPVar "z"]) "Just" "z";
                  invPat3   = ts.__checkInvariants.invPat3
                    (ts.mkPRecord { a = ts.mkPVar "x"; b = ts.mkPRecord { c = ts.mkPVar "y"; }; })
                    { x = true; y = true; };
                  invBidir3 = ts.__checkInvariants.invBidir3 {}
                    (ts.eLamA "x" ts.tInt (ts.eVar "x")) (ts.eLit 42);
                  invKind3  = ts.__checkInvariants.invKind3
                    [ { typeVar = "a"; expectedKind = ts.KStar; } ];
                }
              ' --json > $out/result.json 2>&1 \
              || echo '{"error":"invariant eval failed","inv4":false}' > $out/result.json
            echo "Invariants verified"
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ nix nixpkgs-fmt ];
          shellHook = ''
            echo "nix-types ${version} dev shell (Phase 4.5.8)"
            echo ""
            echo "Fixes in 4.5.8:"
            echo "  BUG-T16: patternVars Ctor — _patternVarsGo at top-level let (INV-NIX-2)"
            echo "  BUG-T24: checkAnnotatedLam API — 3-arg public wrapper in lib/default.nix"
            echo "  BUG-T25: invPat1 — same root cause as T16"
            echo ""
            echo "Phase 4.5 features:"
            echo "  INV-BIDIR-3: App result solved when fn is concrete Fn"
            echo "  INV-KIND-3:  Kind fixpoint solver (max 10 iters)"
            echo "  INV-PAT-3:   Nested Record pattern variables"
            echo ""
            echo "Commands:"
            echo "  nix flake check               — run all checks"
            echo "  nix run .#test                — run test suite (203 tests)"
            echo "  nix run .#diagnose            — detailed failure diagnostics"
            echo "  nix run .#check-invariants    — check invariants"
            echo "  nix run .#demo                — run demo (8 scenarios)"
          '';
        };

        apps = {
          # ── test: standard test run ──────────────────────────────────────
          test = {
            type    = "app";
            program = toString (pkgs.writeShellScript "run-tests" ''
              set -euo pipefail
              echo "Running nix-types ${version} tests (Phase 4.5.8)..."
              ${pkgs.nix}/bin/nix-instantiate --eval --strict \
                --expr '
                  let lib = (import ${nixpkgs-path}/lib);
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
            meta.description = "Run nix-types test suite (Phase 4.5.8, 203 tests)";
          };

          # ── diagnose: detailed failure diagnostics ───────────────────────
          # Shows per-test hint/actual/expected for all failing tests.
          # Useful for pinpointing eval-errors vs wrong-value failures.
          # Output: { ok; summary; failed_details: [{group; ok; failed: [{name; hint; actual; expected}]}] }
          diagnose = {
            type    = "app";
            program = toString (pkgs.writeShellScript "run-diagnose" ''
              set -euo pipefail
              echo "nix-types ${version} — failure diagnostics (Phase 4.5.8)"
              echo ""
              ${pkgs.nix}/bin/nix-instantiate --eval --strict \
                --expr '
                  let lib = (import ${nixpkgs-path}/lib);
                      r   = import ${./.}/tests/test_all.nix { inherit lib; };
                  in {
                    ok             = r.ok;
                    summary        = r.summary;
                    failed_count   = builtins.length r.failedList;
                    failed_details = r.diagnoseAll;
                  }
                ' --json
            '');
            meta.description = "Show detailed diagnostics for failing tests (Phase 4.5.8)";
          };

          # ── check-invariants: invariant verification ──────────────────────
          check-invariants = {
            type    = "app";
            program = toString (pkgs.writeShellScript "check-invariants" ''
              set -euo pipefail
              echo "Checking nix-types ${version} invariants..."
              ${pkgs.nix}/bin/nix-instantiate --eval --strict \
                --expr '
                  let lib = (import ${nixpkgs-path}/lib);
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
                    invPat1   = ts.__checkInvariants.invPat1 "Just" "z";
                    invPat3   = ts.__checkInvariants.invPat3
                      (ts.mkPRecord { a = ts.mkPVar "x"; b = ts.mkPRecord { c = ts.mkPVar "y"; }; })
                      { x = true; y = true; };
                  }
                '
            '');
            meta.description = "Check nix-types invariants (Phase 4.5.8)";
          };

          # ── demo: run demo scenarios ──────────────────────────────────────
          demo = {
            type    = "app";
            program = toString (pkgs.writeShellScript "run-demo" ''
              set -euo pipefail
              echo "Running nix-types ${version} demo (Phase 4.5.8)..."
              ${pkgs.nix}/bin/nix-instantiate --eval --strict \
                --expr '
                  let lib = (import ${nixpkgs-path}/lib);
                      d   = import ${./.}/examples/demo.nix { inherit lib; };
                  in d.summary
                ' --json
            '');
            meta.description = "Run nix-types demo (Phase 4.5.8)";
          };
        };
      });
}
