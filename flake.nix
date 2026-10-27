{
  description = "bunix: bun.lock as a node_modules tree, for Nix";

  # Only the checks and the formatter use these; `lib` takes the caller's
  # `pkgs`.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { config, ... }:
      {
        systems = [
          "aarch64-darwin"
          "aarch64-linux"
          "x86_64-linux"
        ];

        flake.lib.nodeModules =
          {
            pkgs,
            lock,
            name ? "node-modules",
          }:
          import ./lib/node-modules.nix { inherit pkgs lock name; };

        flake.lib.workspace =
          {
            pkgs,
            root,
            lock ? root + "/bun.lock",
            exclude ? [ ],
            name ? "node-modules",
          }:
          import ./lib/workspace.nix {
            inherit
              pkgs
              root
              lock
              exclude
              name
              ;
          };

        perSystem =
          { pkgs, ... }:
          let
            inherit (config.flake.lib) nodeModules workspace;
            fixture = nodeModules {
              inherit pkgs;
              lock = ./fixture/bun.lock;
            };
            # The fixture again, through `workspace`. It plants `.env.local`
            # at the root and in member one, which `src` drops, and
            # `.env.production` in member one, which `src` keeps.
            fixtureWorkspace = workspace {
              inherit pkgs;
              root = ./fixture;
            };
            excluding = workspace {
              inherit pkgs;
              root = ./fixture;
              exclude = [ ".env.production" ];
            };
            unsupported =
              builtins.tryEval
                (nodeModules {
                  inherit pkgs;
                  lock = ./check/unsupported-lockfile-version.lock;
                }).drvPath;
            nested =
              builtins.tryEval
                (nodeModules {
                  inherit pkgs;
                  lock = ./check/nested-workspace-member.lock;
                }).drvPath;
          in
          {
            checks = {
              # The fixture's tree: relative workspace links, an unpacked
              # registry package, and a `.bin` link whose target runs
              # through nixpkgs' node, in the root tree and in workspace
              # member two's own node_modules (its semver conflicts with
              # one's).
              tree = pkgs.runCommand "bunix-tree" { } ''
                tree=${fixture}/node_modules
                fail() { echo "bunix check: $*" >&2; exit 1; }
                version() { grep -q "\"version\": \"$2\"" "$1/package.json" || fail "$1 is not version $2"; }
                bin() {
                  [ -L "$1/.bin/semver" ] || fail "$1/.bin/semver is not a link"
                  [ "$(readlink "$1/.bin/semver")" = "../semver/bin/semver.js" ] \
                    || fail "$1/.bin/semver links to $(readlink "$1/.bin/semver")"
                  [ -x "$1/.bin/semver" ] || fail "$1/.bin/semver is not executable"
                  shebang=$(head -n 1 "$1/.bin/semver")
                  case "$shebang" in
                    "#!${builtins.storeDir}/"*/bin/node) ;;
                    *) fail "$1/.bin/semver starts with $shebang" ;;
                  esac
                }

                for member in one two; do
                  [ -L "$tree/$member" ] || fail "$member is not a link"
                  [ "$(readlink "$tree/$member")" = "../package/$member" ] \
                    || fail "$member links to $(readlink "$tree/$member")"
                done

                [ -f "$tree/semver/package.json" ] || fail "semver/package.json is missing"
                version "$tree/semver" 7.7.3
                bin "$tree"

                member=${fixture}/package/two/node_modules
                [ -f "$member/semver/package.json" ] \
                  || fail "package/two/node_modules/semver/package.json is missing"
                version "$member/semver" 6.3.1
                bin "$member"

                touch $out
              '';

              kept =
                assert fixture.passthru.kept != [ ];
                assert builtins.any (package: package.key == "semver") fixture.passthru.kept;
                assert builtins.any (package: package.key == "two/semver") fixture.passthru.kept;
                pkgs.runCommand "bunix-kept" { } "touch $out";

              members =
                assert
                  fixtureWorkspace.members == [
                    {
                      key = "one";
                      source = "package/one";
                    }
                    {
                      key = "two";
                      source = "package/two";
                    }
                  ];
                pkgs.runCommand "bunix-members" { } "touch $out";

              # `src` holds the root manifests and the member trees, without
              # local env files; `exclude` drops a name wherever it occurs.
              source = pkgs.runCommand "bunix-source" { } ''
                fail() { echo "bunix check: $*" >&2; exit 1; }
                files() { (cd "$1" && find . -type f | sort | tr '\n' ' '); }
                expected="./bun.lock ./package.json ./package/one/.env.production ./package/one/package.json ./package/two/package.json "
                [ "$(files ${fixtureWorkspace.src})" = "$expected" ] \
                  || fail "src holds $(files ${fixtureWorkspace.src})"
                [ ! -e ${excluding.src}/package/one/.env.production ] \
                  || fail "exclude kept package/one/.env.production"
                [ -f ${excluding.src}/package/one/package.json ] \
                  || fail "exclude dropped package/one/package.json"
                touch $out
              '';

              # A build through `mkDerivation`: the root tree and member
              # two's own node_modules are copied in, and each member
              # resolves its own semver.
              build = fixtureWorkspace.mkDerivation {
                pname = "bunix-build";
                version = "0.0.0";
                buildPhase = ''
                  fail() { echo "bunix check: $*" >&2; exit 1; }
                  [ -f package/two/node_modules/semver/package.json ] \
                    || fail "package/two/node_modules/semver/package.json was not copied"
                  [ -d node_modules ] && [ ! -L node_modules ] || fail "node_modules is not a copied directory"
                  [ ! -e .env.local ] || fail "src kept .env.local"
                  [ ! -e package/one/.env.local ] || fail "src kept package/one/.env.local"
                  [ -f package/one/.env.production ] || fail "src dropped package/one/.env.production"
                  bun --version > /dev/null
                  one=$(cd package/one && node -p "require('semver/package.json').version + ' ' + require('two/package.json').name")
                  [ "$one" = "7.7.3 two" ] || fail "package/one resolves $one"
                  two=$(cd package/two && node -p "require('semver/package.json').version")
                  [ "$two" = "6.3.1" ] || fail "package/two resolves semver $two"
                  node_modules/.bin/semver 1.2.3 > /dev/null || fail "node_modules/.bin/semver does not run"
                '';
                installPhase = ''
                  echo "one: semver $one; two: semver $two" > $out
                '';
              };

              # Only evaluates when building the tree for the lock throws.
              unsupported-lockfile-version =
                assert !unsupported.success;
                pkgs.runCommand "bunix-unsupported-lockfile-version" { } "touch $out";

              # A workspace member under another member is refused.
              nested-workspace-member =
                assert !nested.success;
                pkgs.runCommand "bunix-nested-workspace-member" { } "touch $out";
            };

            formatter = pkgs.nixfmt;
          };
      }
    );
}
