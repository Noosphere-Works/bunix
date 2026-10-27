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

        perSystem =
          { pkgs, ... }:
          let
            inherit (config.flake.lib) nodeModules;
            fixture = nodeModules {
              inherit pkgs;
              lock = ./fixture/bun.lock;
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
