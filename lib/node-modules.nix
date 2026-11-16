# `pkgs`: the nixpkgs the tree is built with; its host platform is the
# platform bun installs for. `root`: the workspace root, holding the root
# `package.json`. `lock`: the path of its `bun.lock`. `name`: the derivation
# name.
{
  pkgs,
  root,
  lock,
  name,
}:
let
  # `bun.lock` as the hoisted `node_modules` tree bun writes for the host
  # platform of `pkgs`, with no network access at build time: what crane's
  # `vendorCargoDeps` is to `Cargo.lock`.
  #
  # bun writes the tree itself. The lock is read at evaluation time (no
  # import-from-derivation), and every registry tarball it could install on
  # the host is a `fetchurl` pinned by the lock's own integrity hash. The
  # build serves those tarballs on 127.0.0.1 (`serve.js`) as the registry
  # and runs `bun install --frozen-lockfile --linker hoisted
  # --ignore-scripts` over the lock and the workspace's `package.json`
  # files. A frozen install asks the registry only for tarballs, never for
  # package metadata, so the lock is all bun needs.
  #
  # The tree is `$out/node_modules`, one level below `$out`, because Node
  # and Bun resolve a package's own imports from its real path, walking up
  # through directories literally named `node_modules`. A member's own
  # `node_modules`, where bun gives it one, is under the member's source
  # directory: `$out/package/app/node_modules`. Workspace members are
  # relative links (`node_modules/app -> ../package/app`) that only resolve
  # inside the project, so a build copies the tree in rather than linking
  # it, which also keeps its store path out of what the build writes.
  #
  # The files `.bin` links point at get their `#!/usr/bin/env node` line
  # patched to nixpkgs' `nodejs`: Nix sandboxes have no `/usr/bin/env`, and
  # `bun <bin>` runs `.bin` entries through their shebangs.
  inherit (pkgs) lib;
  inherit (builtins)
    elemAt
    fromJSON
    head
    isList
    isString
    length
    match
    ;

  hostPlatform = pkgs.stdenv.hostPlatform;

  fail = message: throw "bunix: ${message}";

  # bun.lock is JSON plus trailing commas. Drop each comma that only
  # precedes a closing bracket; `builtins.split` returns the captured
  # bracket as a list.
  parsed = fromJSON (
    lib.concatMapStrings (part: if isList part then head part else part) (
      builtins.split ",([[:space:]]*[]}])" (builtins.readFile lock)
    )
  );

  # Bun 1.4 writes 2, or 3 when `overrides` holds scoped rules; `packages`
  # rows have the same shape from 1 on.
  packages =
    if
      lib.elem (parsed.lockfileVersion or null) [
        1
        2
        3
      ]
    then
      parsed.packages
    else
      fail "unsupported lockfileVersion ${toString (parsed.lockfileVersion or "missing")} in bun.lock";

  # Bun's names for process.platform and process.arch, which `bun install
  # --os --cpu` takes.
  osNames = [
    "aix"
    "android"
    "darwin"
    "freebsd"
    "linux"
    "openbsd"
    "sunos"
    "win32"
  ];
  cpuNames = [
    "arm"
    "arm64"
    "ia32"
    "mips"
    "mipsel"
    "ppc"
    "ppc64"
    "s390"
    "s390x"
    "x32"
    "x64"
  ];

  hostOs =
    if hostPlatform.isDarwin then
      "darwin"
    else if hostPlatform.isLinux then
      "linux"
    else
      fail "unsupported host platform ${hostPlatform.system}";
  hostCpu =
    if hostPlatform.isAarch64 then
      "arm64"
    else if hostPlatform.isx86_64 then
      "x64"
    else
      fail "unsupported host platform ${hostPlatform.system}";

  # Bun's `Negatable` rules for a package's own `os` or `cpu` field: no
  # field allows everything; "none" (what bun writes for values it does not
  # know, such as wasm32) allows nothing; names allow those names; "!name"
  # removes a name from whatever is allowed. It only decides which tarballs
  # Nix fetches; bun decides what it installs from them.
  allows =
    names: current: value:
    let
      tokens = lib.toList value;
      negated = lib.filter (lib.hasPrefix "!") tokens;
      positive = lib.filter (token: !lib.hasPrefix "!" token && token != "") tokens;
      added = lib.filter (token: lib.elem token names) positive;
      removed = lib.filter (token: lib.elem token names) (map (lib.removePrefix "!") negated);
      wildcard = lib.elem "any" positive;
      unknown = lib.any (token: token != "any" && !lib.elem token names) positive;
    in
    if added == [ ] && removed == [ ] then
      wildcard || !unknown
    else
      (added == [ ] || wildcard || lib.elem current added) && !lib.elem current removed;

  unscoped = packageName: lib.last (lib.splitString "/" packageName);

  isVersion = resolution: match "[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.+-]*)?" resolution != null;

  registryUrl = "https://registry.npmjs.org/";

  describe =
    key: entry:
    let
      spec = head entry;
      parts = match "(@?[^@]+)@(.*)" spec;
      packageName = elemAt parts 0;
      resolution = elemAt parts 1;
    in
    if parts == null then
      fail "cannot parse \"${spec}\" (lock key ${key})"
    else if lib.hasPrefix "workspace:" resolution then
      {
        inherit key;
        kind = "workspace";
        source = lib.removePrefix "workspace:" resolution;
      }
    else if isVersion resolution && length entry == 4 then
      let
        registry = elemAt entry 1;
        integrity = elemAt entry 3;
      in
      {
        inherit key;
        kind = "npm";
        name = packageName;
        version = resolution;
        meta = elemAt entry 2;
        # The tarball's path under the registry, which bun asks the local
        # registry for.
        path =
          if registry == "" then
            "${packageName}/-/${unscoped packageName}-${resolution}.tgz"
          else
            # Bun writes the full tarball URL when it is not under the
            # default registry, and fetches that URL itself.
            fail
              "${packageName}@${resolution} (lock key ${key}) comes from ${registry}; only packages from ${registryUrl} are supported";
        integrity =
          if isString integrity && integrity != "" then
            integrity
          else
            fail "${packageName}@${resolution} (lock key ${key}) has no integrity hash";
      }
    else
      fail "${packageName} (lock key ${key}) resolves to \"${resolution}\"; only registry packages and workspace members are supported, not git, github, file, link or tarball sources";

  described = lib.mapAttrs describe packages;

  # Every workspace member in the lock, by lock key. The source is relative
  # to the root, as in the lock.
  members = map (
    package:
    let
      inherit (package) key source;
    in
    if
      lib.hasPrefix "/" source
      || lib.any (part: part == "" || part == "." || part == "..") (lib.splitString "/" source)
    then
      fail "workspace member ${key} has source \"${source}\"; a workspace needs member sources relative to the root and inside it"
    else
      { inherit key source; }
  ) (lib.filter (package: package.kind == "workspace") (lib.attrValues described));

  # The tarballs bun may ask for on this host: every registry entry not
  # bundled inside its parent's tarball whose own os/cpu fields admit the
  # host. bun leaves out more (packages only an excluded package needs)
  # and asks for none outside this set. One tarball can sit at several lock
  # keys.
  tarballs = lib.attrValues (
    lib.listToAttrs (
      map
        (package: {
          name = package.path;
          value = package;
        })
        (
          lib.filter (
            package:
            package.kind == "npm"
            && !(package.meta.bundled or false)
            && allows osNames hostOs (package.meta.os or [ ])
            && allows cpuNames hostCpu (package.meta.cpu or [ ])
          ) (lib.attrValues described)
        )
    )
  );

  registry = pkgs.linkFarm "${name}-registry" (
    map (package: {
      name = package.path;
      path = pkgs.fetchurl {
        name = "${lib.replaceStrings [ "@" "/" ] [ "" "+" ] package.name}-${package.version}.tgz";
        url = registryUrl + package.path;
        hash = package.integrity;
      };
    }) tarballs
  );

  # The manifests a frozen install reads: the root's and each member's
  # `package.json`, at their places in the workspace.
  manifests = [ "package.json" ] ++ map (member: "${member.source}/package.json") members;
in
# Every entry is classified, so an unsupported source fails on every
# system, including entries this host never fetches.
assert lib.all (package: package.kind == "npm" || package.kind == "workspace") (
  lib.attrValues described
);
pkgs.stdenvNoCC.mkDerivation {
  inherit name;

  nativeBuildInputs = [ pkgs.bun ];
  # Resolves `#!/usr/bin/env node` in bin targets (patchShebangs --host).
  buildInputs = [ pkgs.nodejs ];

  # The registry listens on 127.0.0.1, which macOS's sandbox blocks unless
  # the build asks for local networking.
  __darwinAllowLocalNetworking = true;

  buildCommand = ''
    export HOME=$TMPDIR BUN_INSTALL_CACHE_DIR=$TMPDIR/bun-cache
    mkdir -p "$out"
    cd "$out"
    cp ${lock} bun.lock
    ${lib.concatMapStrings (manifest: ''
      mkdir -p "$(dirname ${lib.escapeShellArg manifest})"
      cp ${root + "/${manifest}"} ${lib.escapeShellArg manifest}
    '') manifests}

    bun ${./serve.js} ${registry} "$TMPDIR/port" &
    server=$!
    while [ ! -s "$TMPDIR/port" ]; do
      kill -0 $server || { echo "bunix: the local registry did not start" >&2; exit 1; }
      sleep 0.1
    done
    BUN_CONFIG_REGISTRY="http://127.0.0.1:$(cat "$TMPDIR/port")/" bun install \
      --frozen-lockfile --linker hoisted --ignore-scripts --backend copyfile \
      --no-progress --no-summary --os ${hostOs} --cpu ${hostCpu}
    kill $server

    rm bun.lock
    ${lib.concatMapStrings (manifest: ''
      rm ${lib.escapeShellArg manifest}
      rmdir -p --ignore-fail-on-non-empty "$(dirname ${lib.escapeShellArg manifest})" 2> /dev/null || true
    '') manifests}

    # Bin targets inside the tree; a workspace member's bins point into the
    # project, which is not here.
    targets=()
    while IFS= read -r -d "" link; do
      target=$(readlink -f "$link")
      if [ -f "$target" ] && [[ $target == "$out"/* ]]; then
        targets+=("$target")
      fi
    done < <(find "$out" -path '*/node_modules/.bin/*' -type l -print0)
    if [ ''${#targets[@]} -gt 0 ]; then
      patchShebangs --host "''${targets[@]}" > /dev/null
    fi
  '';

  passthru = {
    inherit members registry;
    lockPackages = described;
  };
}
