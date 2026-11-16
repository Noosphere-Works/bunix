# bunix

bunix turns a `bun.lock` into the `node_modules` tree bun's hoisted linker
writes. It is to `bun.lock` what crane's `vendorCargoDeps` is to `Cargo.lock`.
The lock is read at evaluation time, with no import from derivation. Each
registry tarball is a `fetchurl` pinned by the lock's own `integrity` hash, so
there is no generated file and no extra hash to keep up to date. The build
needs no network, and the tree changes exactly when the lock or a workspace
`package.json` does.

bun writes the tree itself. The build serves the fetched tarballs on
127.0.0.1 as the registry and runs `bun install --frozen-lockfile --linker
hoisted --ignore-scripts` over the lock and the workspace's `package.json`
files. A frozen install asks the registry only for tarballs, never for package
metadata, so the tree is the one bun writes on a developer's machine. No
lifecycle scripts run.

## Usage

```nix
# flake.nix
inputs.bunix.url = "github:noosphere-works/bunix";

# with `pkgs` for the system being built
bun = inputs.bunix.lib.workspace {
  inherit pkgs;
  root = ./.; # the workspace root, next to bun.lock
};

app = bun.mkDerivation {
  pname = "app";
  version = "0.1.0";
  buildPhase = "cd package/app && bun run build";
  installPhase = "cp -R dist $out";
};
```

Both functions work on any system. They use only the `pkgs` you pass, never
bunix's own nixpkgs input.

## Workspace

`lib.workspace { pkgs, root, lock ? root + "/bun.lock", exclude ? [ ], name ? "node-modules" }`
returns:

- `nodeModules`: the tree for the lock, `lib.nodeModules { inherit pkgs lock name; }`.
- `members`: the lock's workspace members as `{ key, source }`, sorted by key.
  `key` is the lock key (the member's name) and `source` its directory
  relative to `root`, such as `{ key = "app"; source = "package/app"; }`. A
  source that is absolute or has an empty, `.` or `..` segment stops
  evaluation.
- `src`: `root`, filtered down to what a build reads.
- `mkDerivation`: `args: pkgs.stdenvNoCC.mkDerivation (bunArgs // args)`, with
  the caller's `nativeBuildInputs` added to bunix's.
- `bunArgs`: the defaults `mkDerivation` starts from, for
  `pkgs.stdenvNoCC.mkDerivation (bun.bunArgs // { ... })` or another builder.
- `copyNodeModules`: the shell snippet the default `configurePhase` runs.

### `src`

`src` is a `lib.cleanSourceWith` over `lib.cleanSource root`, so what
`cleanSource` drops (version control directories, `result` links, editor
backups) stays out too. It keeps:

- at the root: `package.json`, `bun.lock`, `bunfig.toml` and every
  `tsconfig*.json`
- each member directory in `members`, wherever it lives, with everything in it

Anywhere in those, it drops:

- directories or files named `node_modules` or `dist`
- files ending in `.tsbuildinfo`
- the local env files bun and Vite load on a developer's machine: `.env`,
  `.env.local` and `.env.<mode>.local`. Committed modes such as
  `.env.production` stay.
- every name in `exclude`. These are directory or file names, matched against
  the last path component wherever it occurs, not paths:
  `exclude = [ ".types" "coverage" ];`

Everything else under `root` is left out: other root files, and directories
that hold no member (a Rust crate next to the workspace, say).

### `mkDerivation`

The defaults are:

- `src`: the filtered `src` above
- `strictDeps = true`
- `nativeBuildInputs = [ pkgs.bun pkgs.nodejs ]`. A caller's
  `nativeBuildInputs` are appended, not substituted.
- `configurePhase`: sets `HOME` and `BUN_INSTALL_CACHE_DIR` under `$TMPDIR`,
  then runs `copyNodeModules`, between the `preConfigure` and `postConfigure`
  hooks
- `disallowedReferences = [ nodeModules ]`
- `dontFixup = true`

The caller supplies `pname`, `version`, `buildPhase` and `installPhase`, and
any other attribute replaces the default. Add inputs through
`nativeBuildInputs` or `buildInputs`, and steps through `preConfigure`,
`postConfigure`, `preBuild` and the other hooks, which leave the copy in
place. A caller's own `configurePhase` replaces the copy; splice the snippet
back in to keep it:

```nix
bun.mkDerivation {
  # ...
  configurePhase = ''
    runHook preConfigure
    ${bun.copyNodeModules}
    # ...
    runHook postConfigure
  '';
}
```

`copyNodeModules` runs from the source root. It copies the root tree to
`node_modules`, then each member's own `node_modules`, where the lock gives it
one, to `<member source>/node_modules`, and makes the copies writable. The
tree is copied, never linked: workspace members are relative links that
resolve only inside the project, and a linked tree's store path would end up
in the build's output, which `disallowedReferences` refuses.

### `nodeModules` alone

`lib.nodeModules { pkgs, root, lock ? root + "/bun.lock", name ? "node-modules" }`
builds the tree by itself, for a project that filters its own source and
writes its own copy step:

```nix
bunDependencies = inputs.bunix.lib.nodeModules {
  inherit pkgs;
  root = ./.;
};
```

It reads the lock and the `package.json` of the root and of each workspace
member, and nothing else from `root`. Copy `${bunDependencies}/node_modules`
and each `${bunDependencies}/<member source>/node_modules` into the build's
copy of the workspace, as `copyNodeModules` does, and set
`disallowedReferences = [ bunDependencies ]`. `passthru.members` lists the
members as `workspace` does.

## Output

```
$out/node_modules/<name>/                      registry tarball's files, unpacked
$out/node_modules/<a>/node_modules/<b>/        nested copy, where the lock puts one
$out/node_modules/.bin/<bin> -> ../<name>/<file>
$out/node_modules/<member> -> ../package/<member>   workspace member, relative link
$out/package/<member>/node_modules/<name>/     a member's own copy, where the lock puts one
$out/package/<member>/node_modules/.bin/<bin> -> ../<name>/<file>
```

bun installs a member's dependency in the member's own `node_modules` when
its version conflicts with the hoisted one. The directory under `$out` is the
member's source path from the lock, so `package/<member>` above stands for
wherever the project keeps its members.

The tree is `$out/node_modules`, not `$out`, because Node and Bun resolve a
package's imports from its real path, walking up through directories that are
literally named `node_modules`. Everything in it is what bun wrote, with one
change: the file a `.bin` link points at has its `#!/usr/bin/env node` line
patched to nixpkgs' `nodejs`, because Nix sandboxes have no `/usr/bin/env`.
A workspace member's bins point into the project and are left alone.

## Platforms

The host platform of `pkgs` (`pkgs.stdenv.hostPlatform`) is the platform bun
installs for, passed as `bun install --os --cpu` in bun's names: `darwin` or
`linux`, and `arm64` or `x64`. To get the tree for another platform, pass that
platform's `pkgs`.

Nix fetches every tarball bun could ask for on that platform: each registry
entry not bundled inside its parent whose own `os` and `cpu` fields admit the
host, read with bun's rules (a missing field allows everything, `"none"`
nothing, names those names, and `"!name"` removes a name). bun installs a
subset of those: it also leaves out packages only an excluded package needs.

The registry listens on 127.0.0.1. The derivation sets
`__darwinAllowLocalNetworking`, which macOS's sandbox needs for that; Linux
sandboxes have their own loopback.

## Not supported yet

bunix stops at evaluation time with a `bunix:` message on:

- `lockfileVersion` other than 1, 2 or 3
- host platforms other than Darwin or Linux on aarch64 or x86_64
- sources other than the registry and workspace members: git, github, file,
  link and tarball sources, and any resolution that isn't a plain version
- packages from a registry other than `https://registry.npmjs.org/`: the lock
  holds their full tarball URL, which bun fetches itself
- registry entries without an `integrity` hash
- workspace members whose source path is absolute or has an empty, `.` or
  `..` segment

Lifecycle scripts (`preinstall`, `install`, `postinstall`) never run, so
packages that build native code in those scripts won't work.

## Versions

`v0.3.0` runs bun's own installer, and `lib.nodeModules` takes `root` as
well as `lock`. `v0.2.0` added `lib.workspace`.

## Checks

`nix flake check` builds `fixture/`, a two-member workspace, through both
functions. Its `.env.local`, `package/one/.env.local` and
`package/one/.env.production` are test files for the `src` filter: the first
two must be left out of `src`, the third kept.

## License

MIT, see [LICENSE.md](LICENSE.md).
