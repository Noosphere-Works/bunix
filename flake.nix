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
          in
          {
            checks = {
              # The fixture's tree: relative workspace links, an unpacked
              # registry package, and a `.bin` link whose target runs
              # through nixpkgs' node.
              tree = pkgs.runCommand "bunix-tree" { } ''
                tree=${fixture}/node_modules
                fail() { echo "bunix check: $*" >&2; exit 1; }

                for member in one two; do
                  [ -L "$tree/$member" ] || fail "$member is not a link"
                  [ "$(readlink "$tree/$member")" = "../package/$member" ] \
                    || fail "$member links to $(readlink "$tree/$member")"
                done

                [ -f "$tree/semver/package.json" ] || fail "semver/package.json is missing"

                [ -L "$tree/.bin/semver" ] || fail ".bin/semver is not a link"
                [ "$(readlink "$tree/.bin/semver")" = "../semver/bin/semver.js" ] \
                  || fail ".bin/semver links to $(readlink "$tree/.bin/semver")"
                [ -x "$tree/.bin/semver" ] || fail ".bin/semver is not executable"
                shebang=$(head -n 1 "$tree/.bin/semver")
                case "$shebang" in
                  "#!${builtins.storeDir}/"*/bin/node) ;;
                  *) fail ".bin/semver starts with $shebang" ;;
                esac

                touch $out
              '';

              kept =
                assert fixture.passthru.kept != [ ];
                assert builtins.any (package: package.name == "semver") fixture.passthru.kept;
                pkgs.runCommand "bunix-kept" { } "touch $out";

              # Only evaluates when building the tree for the lock throws.
              unsupported-lockfile-version =
                assert !unsupported.success;
                pkgs.runCommand "bunix-unsupported-lockfile-version" { } "touch $out";
            };

            formatter = pkgs.nixfmt;
          };
      }
    );
}
