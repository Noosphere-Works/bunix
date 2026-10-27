# `pkgs`: the nixpkgs everything is built with. `root`: the workspace root, a
# path holding the root `package.json`. `lock`: the path of its `bun.lock`.
# `exclude`: directory or file names dropped from `src` wherever they occur.
# `name`: the `node_modules` derivation's name.
{
  pkgs,
  root,
  lock,
  exclude,
  name,
}:
let
  # A bun workspace as Nix needs it: the `node_modules` tree for its lock,
  # its members, a source filtered down to what a build reads, and a
  # `mkDerivation` that copies the tree into the build's copy of that
  # source.
  inherit (pkgs) lib;

  fail = message: throw "bunix: ${message}";

  nodeModules = import ./node-modules.nix { inherit pkgs lock name; };

  # Every workspace member in the lock, by lock key. The source is relative
  # to the root, as in the lock.
  checkMember =
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
      { inherit key source; };

  members = map checkMember (
    lib.filter (package: package.kind == "workspace") (lib.attrValues nodeModules.passthru.lockPackages)
  );

  sources = map (member: member.source) members;

  # The directories above each member (`package` for `package/app`), which
  # the filter has to keep for cleanSourceWith to reach the member.
  ancestors = lib.unique (
    lib.concatMap (
      source:
      let
        parts = lib.splitString "/" source;
      in
      map (count: lib.concatStringsSep "/" (lib.take count parts)) (lib.range 1 (lib.length parts - 1))
    ) sources
  );

  rootPrefix = "${toString root}/";

  src = lib.cleanSourceWith {
    name = "workspace-source";
    src = lib.cleanSource root;
    filter =
      path: type:
      let
        relative = lib.removePrefix rootPrefix (toString path);
        base = baseNameOf relative;
        dropped =
          lib.elem base (
            [
              "node_modules"
              "dist"
            ]
            ++ exclude
          )
          # Local env files bun and Vite load on the developer's machine:
          # `.env`, `.env.local`, `.env.<mode>.local`. Committed modes such
          # as `.env.production` stay.
          || base == ".env"
          || lib.hasPrefix ".env." base && lib.hasSuffix ".local" base
          || type != "directory" && lib.hasSuffix ".tsbuildinfo" base;
        atRoot = !lib.hasInfix "/" relative;
        rootFile =
          type != "directory"
          && (
            lib.elem base [
              "package.json"
              "bun.lock"
              "bunfig.toml"
            ]
            || lib.hasPrefix "tsconfig" base && lib.hasSuffix ".json" base
          );
        inMember = lib.any (source: relative == source || lib.hasPrefix "${source}/" relative) sources;
      in
      !dropped && (atRoot && rootFile || inMember || type == "directory" && lib.elem relative ancestors);
  };

  # The copy step, for a `configurePhase` of the caller's own: the root
  # tree, then each member's own `node_modules` where the lock gives it one,
  # copied (never linked) and made writable. It runs from the source root.
  copyNodeModules = ''
    cp -R --reflink=auto ${nodeModules}/node_modules node_modules
    chmod -R u+w node_modules
  ''
  + lib.concatMapStrings (
    member:
    let
      from = lib.escapeShellArg "${nodeModules}/${member.source}/node_modules";
      to = lib.escapeShellArg "${member.source}/node_modules";
    in
    ''
      if [ -d ${from} ]; then
        cp -R --reflink=auto ${from} ${to}
        chmod -R u+w ${to}
      fi
    ''
  ) members;

  bunArgs = {
    inherit src;
    strictDeps = true;
    nativeBuildInputs = [
      pkgs.bun
      pkgs.nodejs
    ];
    # Each build gets its own copy of the tree: workspace members are
    # relative links that resolve only inside the project, and a linked
    # tree's store path would end up in what the build writes.
    configurePhase = ''
      runHook preConfigure
      export HOME=$TMPDIR BUN_INSTALL_CACHE_DIR=$TMPDIR/bun-cache
      ${copyNodeModules}
      runHook postConfigure
    '';
    disallowedReferences = [ nodeModules ];
    dontFixup = true;
  };

  # The caller's `nativeBuildInputs` go after bunix's; every other attribute
  # replaces the default.
  mkDerivation =
    args:
    pkgs.stdenvNoCC.mkDerivation (
      bunArgs
      // args
      // {
        nativeBuildInputs = bunArgs.nativeBuildInputs ++ args.nativeBuildInputs or [ ];
      }
    );
in
{
  inherit
    nodeModules
    members
    src
    copyNodeModules
    bunArgs
    mkDerivation
    ;
}
