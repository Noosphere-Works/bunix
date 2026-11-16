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
  # build writes. Lock keys under a workspace member (`app/x`, where the
  # member's version of `x` conflicts with the hoisted one) go to that
  # member's own `node_modules`, under its source directory:
  # `$out/package/app/node_modules/x`.
  #
  # The lock is read at evaluation time (no import-from-derivation). Every
  # registry tarball is a `fetchurl` pinned by the lock's own integrity
  # hash, and the tree changes exactly when the lock does. No lifecycle
  # scripts run. A tarball contributes its regular files, extracted as
  # bun extracts them (`unpack.c`). The files `.bin` links point at get
  # their `#!/usr/bin/env node` line patched to nixpkgs' `nodejs`: Nix
  # sandboxes have no `/usr/bin/env`, and `bun <bin>` runs `.bin` entries
  # through their shebangs. Every other file is byte-identical to its
  # tarball entry.
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
  lockText = builtins.readFile lock;
  parsed = fromJSON (
    lib.concatMapStrings (part: if isList part then head part else part) (
      builtins.split ",([[:space:]]*[]}])" lockText
    )
  );

  # Each `packages` entry's `bin` object as a flat list of its keys and
  # targets, in lock order: `fromJSON` returns an object's keys sorted, but
  # bun links a package's bins in the order its lock entry lists them. The
  # lock text is split into JSON strings and structural characters, and a
  # walk over them keeps the bracket depth: the root object is depth 1,
  # `packages` 2, an entry's array 3, its metadata object 4 and `bin` 5.
  binObjects =
    let
      tokens = lib.concatMap (part: if isList part then [ (head part) ] else [ ]) (
        builtins.split "(\"([^\"\\\\]|\\\\.)*\"|[][{}:,])" lockText
      );
      step =
        state: token:
        let
          next = state // {
            previous = token;
            beforePrevious = state.previous;
          };
        in
        if token == "{" || token == "[" then
          next
          // {
            depth = state.depth + 1;
            bin =
              if
                state.section == "packages"
                && state.depth == 4
                && state.previous == ":"
                && state.beforePrevious == "\"bin\""
              then
                [ ]
              else
                state.bin;
          }
        else if token == "}" || token == "]" then
          next
          // {
            depth = state.depth - 1;
            bin = if state.depth == 5 then null else state.bin;
            found =
              if state.bin != null && state.depth == 5 then
                state.found
                ++ [
                  {
                    name = state.entry;
                    value = state.bin;
                  }
                ]
              else
                state.found;
          }
        else if token == ":" then
          next
          // (
            if state.depth == 1 then
              { section = fromJSON state.previous; }
            else if state.depth == 2 then
              { entry = fromJSON state.previous; }
            else
              { }
          )
        else if token == "," || state.bin == null then
          next
        else
          next // { bin = state.bin ++ [ (fromJSON token) ]; };
    in
    builtins.listToAttrs
      (lib.foldl' step {
        depth = 0;
        section = null;
        entry = null;
        previous = null;
        beforePrevious = null;
        bin = null;
        found = [ ];
      } tokens).found;

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

  # The top-level workspace member a lock key sits under (`app` for
  # `app/x/y`), or null for keys in the root tree.
  memberOf =
    segments:
    let
      top = if length segments > 1 then described.${head segments} or null else null;
    in
    if top != null && top.kind == "workspace" then top else null;

  # The `node_modules` directory an entry's tree hangs from, relative to
  # `$out`: the root's, or its workspace member's under the member's source.
  modulesDir =
    segments:
    let
      member = memberOf segments;
      source = member.source;
    in
    if member == null then
      "node_modules"
    else if
      lib.hasPrefix "/" source
      || lib.any (part: part == "" || part == "." || part == "..") (lib.splitString "/" source)
    then
      fail "workspace member ${member.key} has source \"${source}\"; per-workspace node_modules need a relative source inside the project"
    else
      "${source}/node_modules";

  describe =
    key: entry:
    let
      spec = head entry;
      parts = match "(@?[^@]+)@(.*)" spec;
      packageName = elemAt parts 0;
      resolution = elemAt parts 1;
      segments = keySegments key;
      parentKey = lib.concatStringsSep "/" (lib.init segments);
      # The key's segments below its workspace member, if it has one.
      inner = if memberOf segments == null then segments else lib.tail segments;
      common = {
        inherit key segments parentKey;
        name = packageName;
        # Path inside the root's or the workspace member's node_modules:
        # a/node_modules/b/node_modules/@s/c
        path = lib.concatStringsSep "/node_modules/" inner;
        # The node_modules directory holding it, relative to that
        # node_modules ("" at the top).
        parentDir = lib.concatStringsSep "/" (map (segment: "${segment}/node_modules") (lib.init inner));
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

  # A package's bins as bun's hoisted linker names and keeps them
  # (`bin.rs`, `Linker.link`), in the order it links them. A string `bin`
  # is named after the package's folder, which is the alias when there is
  # one, unscoped (`Dependency::unscoped_package_name` of the dependency
  # name). An object's keys are cut after their last `/`, `\` or `:`, and a
  # key that leaves `""`, `.` or `..` is dropped (`normalized_bin_name`);
  # its entries keep the lock's order (`binObjects`). A target that is
  # empty or would resolve outside the package directory is dropped
  # silently (`bin_target_escapes_package_dir`: absolute, a `:` in its
  # first component, or `..` past the package root, splitting on `/` and
  # `\`), so it never claims its `.bin` name. `path` is the target
  # normalised the way bun joins it to the package directory: `.` and
  # empty components go, and `..` takes the previous one off.
  bins =
    package:
    let
      bin = package.meta.bin or null;
      ownDir = lib.last package.segments;
      pairs = binObjects.${package.key} or (fail "found no bin object for lock key ${package.key}");
      named =
        if isString bin then
          [
            {
              name = unscoped ownDir;
              target = bin;
            }
          ]
        else
          lib.genList (i: {
            name = lib.last (builtins.split "[/\\\\:]" (elemAt pairs (2 * i)));
            target = elemAt pairs (2 * i + 1);
          }) (length pairs / 2);
      escapes =
        target:
        let
          components = lib.filter isString (builtins.split "[/\\\\]" target);
        in
        lib.hasPrefix "/" target
        || lib.hasInfix ":" (head components)
        ||
          lib.foldl' (
            depth: component:
            if depth < 0 || component == "" || component == "." then
              depth
            else if component == ".." then
              depth - 1
            else
              depth + 1
          ) 0 components < 0;
      normalise =
        target:
        lib.foldl' (
          kept: component:
          if component == "" || component == "." then
            kept
          else if component == ".." then
            lib.init kept
          else
            kept ++ [ component ]
        ) [ ] (lib.splitString "/" target);
    in
    if package.meta ? binDir then
      fail "${package.name} links its bin directory (directories.bin), which is not supported yet"
    else if bin == null then
      [ ]
    else
      map
        (entry: {
          inherit (entry) name;
          path = normalise entry.target;
        })
        (
          lib.filter (
            entry:
            !lib.elem entry.name [
              ""
              "."
              ".."
            ]
            && entry.target != ""
            && !escapes entry.target
          ) named
        );

  # The directory an entry is unpacked or linked at, relative to `$out`.
  installDir = package: "${modulesDir package.segments}/${package.path}";

  # Paths in install lines are relative to `$out`.
  install =
    package:
    let
      dir = installDir package;
    in
    if package.kind == "workspace" then
      # Relative to the link's own directory: `../` per segment of
      # `node_modules/<name>`.
      "link_workspace ${
        lib.escapeShellArgs [
          dir
          "${lib.concatStrings (lib.replicate (length (lib.splitString "/" package.path)) "../")}${package.source}"
        ]
      }"
    else
      "unpack ${
        lib.escapeShellArgs [
          (tarball package)
          dir
        ]
      }";

  # Every bin a kept registry package declares, with the `.bin` directory it
  # goes in: the one beside the package, in the same node_modules.
  binLinks = lib.concatMap (
    package:
    let
      modules = modulesDir package.segments;
      ownDir = lib.last package.segments;
    in
    map (bin: {
      inherit ownDir;
      binDir = lib.concatStringsSep "/" (
        lib.filter (part: part != "") [
          modules
          package.parentDir
          ".bin"
        ]
      );
      inherit (bin) name;
      file = lib.concatStringsSep "/" ([ (installDir package) ] ++ bin.path);
      link = lib.concatStringsSep "/" (
        [
          ".."
          ownDir
        ]
        ++ bin.path
      );
    }) (bins package)
  ) (lib.filter (package: package.kind == "npm") kept);

  # bun links a node_modules directory's bins in ascending byte order of
  # the packages' folder names (a priority queue keyed by dependency name,
  # `PackageInstaller.link_tree_bins`), and skips a `.bin` path it has
  # already linked (`bin.Linker.link_bin_or_create_shim`); a bin whose
  # target is missing is skipped without claiming the path, and one whose
  # target is a directory claims it like a file. So each `.bin` path gets
  # one `link_bin` with its candidates in that order, and the build links
  # the first one whose target exists. `sort` is stable, so two bins of one
  # name from one package stay in lock order, as `bins` lists them: the
  # first whose target exists wins.
  linkBins = lib.mapAttrsToList (
    _: candidates:
    let
      ordered = lib.sort (a: b: a.ownDir < b.ownDir) candidates;
      first = head ordered;
    in
    "link_bin ${
      lib.escapeShellArgs (
        [
          first.binDir
          first.name
        ]
        ++ lib.concatMap (candidate: [
          candidate.file
          candidate.link
        ]) ordered
      )
    }"
  ) (lib.groupBy (bin: "${bin.binDir}/${bin.name}") binLinks);

  # Every entry is classified (and unsupported sources throw) even when the
  # host platform drops it, so the lock fails the same way on every system.
  # A registry package sits under a registry package or under a top-level
  # workspace member, so by induction its chain ends in the root tree or in
  # one member's node_modules.
  checked = lib.all (
    package:
    let
      parent = described.${package.parentKey} or null;
    in
    (package.kind == "npm" || package.kind == "workspace")
    && (
      package.parentKey == ""
      || (
        if parent == null then
          fail "lock key ${package.key} sits under ${package.parentKey}, which is not in the lock"
        else if package.kind == "workspace" then
          fail "lock key ${package.key} is a workspace member under ${package.parentKey}; nested workspace members are not supported yet"
        else if parent.kind == "npm" || parent.kind == "workspace" && parent.parentKey == "" then
          true
        else
          fail "lock key ${package.key} sits under workspace member ${package.parentKey}, which is itself nested; nested workspace members are not supported yet"
      )
    )
  ) (lib.attrValues described);

  unpacker = import ./unpack.nix { inherit pkgs; };
in
assert checked;
pkgs.stdenvNoCC.mkDerivation {
  inherit name;

  nativeBuildInputs = [ unpacker ];
  # Resolves `#!/usr/bin/env node` in bin targets (patchShebangs --host).
  buildInputs = [ pkgs.nodejs ];

  # The lock's hash ties the output to the lock byte for byte.
  bunLock = builtins.hashFile "sha256" lock;
  bunPlatform = "${hostOs}-${hostCpu}";

  passAsFile = [ "buildCommand" ];
  buildCommand = ''
    mkdir -p "$out/node_modules"
    source ${./install.sh}

    ${lib.concatMapStringsSep "\n" install kept}
    ${lib.concatStringsSep "\n" linkBins}
  '';

  passthru = {
    inherit kept;
    lockPackages = described;
  };
}
