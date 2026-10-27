# `pkgs`: the nixpkgs the tree is built with; its host platform picks the
# optional native packages. `lock`: the path of a `bun.lock`. `name`: the
# derivation name.
{
  pkgs,
  lock,
  name,
}:
let
  # `bun.lock` as the hoisted `node_modules` tree bun's hoisted linker
  # would write for the host platform of `pkgs`, with no network access at
  # build time: what crane's `vendorCargoDeps` is to `Cargo.lock`.
  #
  # The tree is `$out/node_modules`, one level below `$out`, because Node
  # and Bun resolve a package's own imports from its real path, walking up
  # through directories literally named `node_modules`. Workspace members
  # are relative links (`node_modules/app -> ../package/app`)
  # that only resolve inside the project, so a build copies the tree in
  # rather than linking it, which also keeps its store path out of what the
  # build writes.
  #
  # The lock is read at evaluation time (no import-from-derivation). Every
  # registry tarball is a `fetchurl` pinned by the lock's own integrity
  # hash, and the tree changes exactly when the lock does. No lifecycle
  # scripts run. The files `.bin` links point at get their
  # `#!/usr/bin/env node` line patched to nixpkgs' `nodejs`: Nix sandboxes
  # have no `/usr/bin/env`, and `bun <bin>` runs `.bin` entries through
  # their shebangs. Everything else is byte-identical to the tarballs.
  inherit (pkgs) lib;
  inherit (builtins)
    elemAt
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
  parsed = builtins.fromJSON (
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

  # Bun's names for process.platform and process.arch.
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

  # Bun's `Negatable` rules: no field allows everything; "none" (what bun
  # writes for values it does not know, such as wasm32) allows nothing;
  # names allow those names; "!name" removes a name from whatever is
  # allowed.
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

  # "@scope/a/b/@other/c" -> [ "@scope/a" "b" "@other/c" ]
  keySegments =
    key:
    (lib.foldl'
      (
        acc: part:
        if acc.scope != null then
          {
            scope = null;
            segments = acc.segments ++ [ "${acc.scope}/${part}" ];
          }
        else if lib.hasPrefix "@" part then
          acc // { scope = part; }
        else
          acc // { segments = acc.segments ++ [ part ]; }
      )
      {
        scope = null;
        segments = [ ];
      }
      (lib.splitString "/" key)
    ).segments;

  unscoped = packageName: lib.last (lib.splitString "/" packageName);

  isVersion = resolution: match "[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.+-]*)?" resolution != null;

  describe =
    key: entry:
    let
      spec = head entry;
      parts = match "(@?[^@]+)@(.*)" spec;
      packageName = elemAt parts 0;
      resolution = elemAt parts 1;
      segments = keySegments key;
      parentKey = lib.concatStringsSep "/" (lib.init segments);
      common = {
        inherit key segments parentKey;
        name = packageName;
        # Path inside node_modules: a/node_modules/b/node_modules/@s/c
        path = lib.concatStringsSep "/node_modules/" segments;
        # The node_modules directory holding it, relative to node_modules
        # ("" at the top).
        parentDir = lib.concatStringsSep "/" (map (segment: "${segment}/node_modules") (lib.init segments));
      };
    in
    if parts == null then
      fail "cannot parse \"${spec}\" (lock key ${key})"
    else if lib.hasPrefix "workspace:" resolution then
      common
      // {
        kind = "workspace";
        source = lib.removePrefix "workspace:" resolution;
      }
    else if isVersion resolution && length entry == 4 then
      let
        registry = elemAt entry 1;
        meta = elemAt entry 2;
        integrity = elemAt entry 3;
      in
      common
      // {
        kind = "npm";
        version = resolution;
        inherit meta;
        url =
          if registry == "" then
            "https://registry.npmjs.org/${packageName}/-/${unscoped packageName}-${resolution}.tgz"
          else
            # Bun writes the full tarball URL when it is not under the
            # default registry.
            registry;
        integrity =
          if isString integrity && integrity != "" then
            integrity
          else
            fail "${packageName}@${resolution} (lock key ${key}) has no integrity hash";
      }
    else
      fail "${packageName} (lock key ${key}) resolves to \"${resolution}\"; only registry packages and workspace members are supported, not git, github, file, link or tarball sources";

  described = lib.mapAttrs describe packages;

  # Keep an entry when its parent is kept, it is not bundled inside its
  # parent's tarball, and its os/cpu fields admit the host.
  keep = lib.mapAttrs (
    key: package:
    let
      meta = package.meta or { };
    in
    (package.parentKey == "" || keep.${package.parentKey})
    && !(meta.bundled or false)
    && allows osNames hostOs (meta.os or [ ])
    && allows cpuNames hostCpu (meta.cpu or [ ])
  ) described;

  kept = lib.sort (
    a: b:
    length a.segments < length b.segments || a.key < b.key && length a.segments == length b.segments
  ) (lib.filter (package: keep.${package.key}) (lib.attrValues described));

  tarball =
    package:
    pkgs.fetchurl {
      name = "${lib.replaceStrings [ "@" "/" ] [ "" "+" ] package.name}-${package.version}.tgz";
      inherit (package) url;
      hash = package.integrity;
    };

  bins =
    package:
    let
      bin = package.meta.bin or null;
    in
    if package.meta ? binDir then
      fail "${package.name} links its bin directory (directories.bin), which is not supported yet"
    else if bin == null then
      [ ]
    else if isString bin then
      [
        {
          name = unscoped package.name;
          target = bin;
        }
      ]
    else
      lib.mapAttrsToList (binName: target: {
        name = baseNameOf binName;
        inherit target;
      }) bin;

  install =
    package:
    let
      binDir = lib.concatStringsSep "/" (
        lib.filter (part: part != "") [
          package.parentDir
          ".bin"
        ]
      );
      ownDir = lib.last package.segments;
      linkBin =
        bin:
        let
          target = lib.removePrefix "./" bin.target;
        in
        "link_bin ${
          lib.escapeShellArgs [
            binDir
            bin.name
            "${package.path}/${target}"
            "../${ownDir}/${target}"
          ]
        }";
    in
    if package.kind == "workspace" then
      # Relative to the link's own directory: `../` per segment of
      # `node_modules/<name>`.
      "link_workspace ${
        lib.escapeShellArgs [
          package.path
          "${lib.concatStrings (lib.replicate (length (lib.splitString "/" package.path)) "../")}${package.source}"
        ]
      }"
    else
      lib.concatStringsSep "\n" (
        [
          "unpack ${
            lib.escapeShellArgs [
              (tarball package)
              package.path
            ]
          }"
        ]
        ++ map linkBin (bins package)
      );

  # Every entry is classified (and unsupported sources throw) even when the
  # host platform drops it, so the lock fails the same way on every system.
  checked = lib.all (
    package:
    (package.kind == "npm" || package.kind == "workspace")
    && (
      package.parentKey == ""
      || package.kind == "npm" && (described.${package.parentKey} or { }).kind or null == "npm"
      || fail "lock key ${package.key} sits under ${package.parentKey}, which is not a registry package in the lock; nested workspace members and per-workspace node_modules are not supported yet"
    )
  ) (lib.attrValues described);
in
assert checked;
pkgs.stdenvNoCC.mkDerivation {
  inherit name;

  # Resolves `#!/usr/bin/env node` in bin targets (patchShebangs --host).
  buildInputs = [ pkgs.nodejs ];

  # The lock's hash ties the output to the lock byte for byte.
  bunLock = builtins.hashFile "sha256" lock;
  bunPlatform = "${hostOs}-${hostCpu}";

  passAsFile = [ "buildCommand" ];
  buildCommand = ''
    tree=$out/node_modules
    mkdir -p "$tree"

    unpack() {
      mkdir -p "$tree/$2"
      tar -xzf "$1" -C "$tree/$2" --strip-components=1 --no-same-owner --no-same-permissions
      chmod -R u+rwX "$tree/$2"
    }

    link_bin() {
      if [ ! -f "$tree/$3" ]; then
        echo "bunix: skipping bin $2: $3 does not exist" >&2
        return
      fi
      if [ -e "$tree/$1/$2" ] || [ -L "$tree/$1/$2" ]; then
        echo "bunix: two packages install bin $1/$2" >&2
        exit 1
      fi
      mkdir -p "$tree/$1"
      chmod +x "$tree/$3"
      patchShebangs --host "$tree/$3" > /dev/null
      ln -s "$4" "$tree/$1/$2"
    }

    link_workspace() {
      mkdir -p "$(dirname "$tree/$1")"
      ln -s "$2" "$tree/$1"
    }

    ${lib.concatMapStringsSep "\n" install kept}
  '';

  passthru = {
    inherit kept;
    lockPackages = described;
  };
}
