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
            # The `link_bin` lines for `check/bin-rules.lock`, whose entries
            # carry the `package.json` files of local tarballs that bun
            # 1.4.2's hoisted install linked as follows. `.bin/foo` went to
            # twobin's `b.js`: its keys are `x/foo` then `foo`, and the first
            # in lock order wins. names' keys `a:colon`, `b\back` and
            # `q/w/deep` became colon, back and deep, and `dir/`, `.` and
            # `..` were dropped. esc's `inner` (`sub/../a.js`) and `dots`
            # (`./sub//./x.js`) linked normalised, and its `up`, `abs`,
            # `drive` and `bs` targets, escstr's string target and aaa-esc's
            # `../zzz-ok/tool.js` leave their package and were dropped, so
            # `.bin/tool` went to zzz-ok. Each line lists a name's candidates
            # in link order; every file exists, so the first is bun's link.
            binLines = linkBinLines ./check/bin-rules.lock;
            # A lock's `link_bin` lines. They name only paths under `$out`, so
            # they drop the build command's context, which holds the lock's
            # tarball downloads.
            linkBinLines =
              lock:
              builtins.filter (pkgs.lib.hasPrefix "link_bin ") (
                pkgs.lib.splitString "\n" (
                  builtins.unsafeDiscardStringContext (nodeModules { inherit pkgs lock; }).buildCommand
                )
              );
          in
          {
            checks = {
              # The fixture's tree: relative workspace links, an unpacked
              # registry package, and a `.bin` link whose target runs
              # through nixpkgs' node, in the root tree and in workspace
              # member two's own node_modules (its semver conflicts with
              # one's). node-uuid and uuid both declare bin `uuid`; bun
              # links the folder name that sorts first, node-uuid.
              # `@babel/parser`'s `bin` is a string, and it is installed under
              # the aliases `@bunix/parse` and `zz-parser`: bun names each
              # link after the alias, unscoped, so there is no `parser`.
              tree = pkgs.runCommand "bunix-tree" { } ''
                tree=${fixture}/node_modules
                fail() { echo "bunix check: $*" >&2; exit 1; }
                version() { grep -q "\"version\": \"$2\"" "$1/package.json" || fail "$1 is not version $2"; }
                # bin <node_modules> <name> <link target>
                bin() {
                  [ -L "$1/.bin/$2" ] || fail "$1/.bin/$2 is not a link"
                  [ "$(readlink "$1/.bin/$2")" = "$3" ] \
                    || fail "$1/.bin/$2 links to $(readlink "$1/.bin/$2")"
                  [ -x "$1/.bin/$2" ] || fail "$1/.bin/$2 is not executable"
                  shebang=$(head -n 1 "$1/.bin/$2")
                  case "$shebang" in
                    "#!${builtins.storeDir}/"*/bin/node) ;;
                    *) fail "$1/.bin/$2 starts with $shebang" ;;
                  esac
                }

                for member in one two; do
                  [ -L "$tree/$member" ] || fail "$member is not a link"
                  [ "$(readlink "$tree/$member")" = "../package/$member" ] \
                    || fail "$member links to $(readlink "$tree/$member")"
                done

                [ -f "$tree/semver/package.json" ] || fail "semver/package.json is missing"
                version "$tree/semver" 7.7.3
                bin "$tree" semver ../semver/bin/semver.js
                bin "$tree" uuid ../node-uuid/bin/uuid
                bin "$tree" parse ../@bunix/parse/bin/babel-parser.js
                bin "$tree" zz-parser ../zz-parser/bin/babel-parser.js
                [ ! -e "$tree/.bin/parser" ] && [ ! -L "$tree/.bin/parser" ] \
                  || fail "$tree/.bin/parser exists"

                member=${fixture}/package/two/node_modules
                [ -f "$member/semver/package.json" ] \
                  || fail "package/two/node_modules/semver/package.json is missing"
                version "$member/semver" 6.3.1
                bin "$member" semver ../semver/bin/semver.js

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
                  node_modules/.bin/uuid v4 > /dev/null || fail "node_modules/.bin/uuid does not run"
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

              # `check/entry-kinds/` holds three tarballs and a lock for them.
              # The tree bun 1.4.2's hoisted install made from them is
              # `expected`; this check unpacks them with bunix's own `unpack`,
              # runs the lock's `link_bin` lines, and lists the result the
              # same way. bun writes only a tarball's regular files: no
              # symlinks (inside or outside the package), directories other
              # than a file's parents, FIFOs, devices, or hard links without
              # a body, while a pax hard link with a body, a hard link with a
              # size, contiguous and unknown entry types are files, and an
              # AppleDouble `._` entry is metadata for the next one. It drops
              # the first path component, normalises the rest with `..`
              # stopping at the package root, reads past zero blocks, and
              # creates a file with mode (permissions & 0777) | 0666, which a
              # later entry for the same path truncates. kinds' `bindir` bin
              # is a directory; it claims `.bin/dirbin` ahead of zkinds' file.
              # Its `in-link.js`, `lib-out/x.js` and `hard.js` bins were
              # symlinks or a hard link, so `.bin/inbin` went to zkinds.
              entry-kinds =
                pkgs.runCommand "bunix-entry-kinds"
                  {
                    nativeBuildInputs = [ (import ./lib/unpack.nix { inherit pkgs; }) ];
                    buildInputs = [ pkgs.nodejs ];
                  }
                  ''
                    source ${./lib/install.sh}
                    for package in edge kinds zkinds; do
                      unpack ${./check/entry-kinds}/$package.tgz node_modules/$package
                    done
                    ${pkgs.lib.concatStringsSep "\n" (linkBinLines ./check/entry-kinds/bun.lock)}
                    listing=$(cd $out/node_modules && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r f; do
                      if [ -L "$f" ]; then echo "L $f -> $(readlink "$f")"
                      elif [ -d "$f" ]; then echo "D $f"
                      else echo "F $f $(stat -c %a "$f") $(sha256sum < "$f" | cut -c1-16)"; fi
                    done)
                    diff -u ${./check/entry-kinds/expected} <(echo "$listing")
                  '';

              bin-rules =
                assert
                  binLines == [
                    "link_bin node_modules/.bin back node_modules/names/a.js ../names/a.js"
                    "link_bin node_modules/.bin colon node_modules/names/a.js ../names/a.js"
                    "link_bin node_modules/.bin deep node_modules/names/a.js ../names/a.js"
                    "link_bin node_modules/.bin dots node_modules/esc/sub/x.js ../esc/sub/x.js"
                    "link_bin node_modules/.bin foo node_modules/twobin/b.js ../twobin/b.js node_modules/twobin/a.js ../twobin/a.js"
                    "link_bin node_modules/.bin inner node_modules/esc/a.js ../esc/a.js"
                    "link_bin node_modules/.bin ok node_modules/esc/a.js ../esc/a.js"
                    "link_bin node_modules/.bin otherx node_modules/other/x.js ../other/x.js"
                    "link_bin node_modules/.bin tool node_modules/zzz-ok/tool.js ../zzz-ok/tool.js"
                  ];
                pkgs.runCommand "bunix-bin-rules" { } "touch $out";
            };

            formatter = pkgs.nixfmt;
          };
      }
    );
}
