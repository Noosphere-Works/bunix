# bunix

bunix turns a `bun.lock` into the `node_modules` tree bun's hoisted linker
would write. It is to `bun.lock` what crane's `vendorCargoDeps` is to
`Cargo.lock`. The lock is read at evaluation time, with no import from
derivation. Each registry tarball is a `fetchurl` pinned by the lock's own
`integrity` hash, so there is no generated file and no extra hash to keep up to
date. The build needs no network, and the tree changes exactly when the lock
does. No lifecycle scripts run.

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

`lib.nodeModules { pkgs, lock, name ? "node-modules" }` still builds the tree
by itself, for a project that filters its own source and writes its own
copy step:

```nix
bunDependencies = inputs.bunix.lib.nodeModules {
  inherit pkgs;
  lock = ./bun.lock;
};
```

Copy `${bunDependencies}/node_modules` and each
`${bunDependencies}/<member source>/node_modules` into the build's copy of the
workspace, as `copyNodeModules` does, and set
`disallowedReferences = [ bunDependencies ]`.

## Output

```
$out/node_modules/<name>/                      registry tarball, unpacked
$out/node_modules/<a>/node_modules/<b>/        nested copy, where the lock puts one
$out/node_modules/.bin/<bin> -> ../<name>/<file>
$out/node_modules/<member> -> ../package/<member>   workspace member, relative link
$out/package/<member>/node_modules/<name>/     a member's own copy, where the lock puts one
$out/package/<member>/node_modules/.bin/<bin> -> ../<name>/<file>
```

bun installs a member's dependency in the member's own `node_modules` when
its version conflicts with the hoisted one (lock key `<member>/<name>`). The
directory under `$out` is the member's source path from the lock, so
`package/<member>` above stands for wherever the project keeps its members.

The tree is `$out/node_modules`, not `$out`, because Node and Bun resolve a
package's imports from its real path, walking up through directories that are
literally named `node_modules`. The files that `.bin` links point to are made
executable, and their `#!/usr/bin/env node` line is patched to nixpkgs'
`nodejs`, because Nix sandboxes have no `/usr/bin/env`. Everything else is
byte-identical to the tarballs. A bin whose file is missing from its package
is skipped with a warning. If two packages install the same bin, the build
fails.

`passthru.kept` lists the lock entries in the tree for this host.
`passthru.lockPackages` holds every lock entry, classified.

## Platforms

The host platform of `pkgs` (`pkgs.stdenv.hostPlatform`) picks the optional
native packages. It maps to bun's names: `darwin` or `linux`, and `arm64` or
`x64`. An entry is kept when its `os` and `cpu` fields admit the host and its
parent is kept. bun's rules apply:

- A missing field allows everything.
- `"none"` allows nothing.
- A list of names allows those names.
- `"!name"` removes a name.

Bundled dependencies stay inside their parent's tarball. Every entry is
classified, including the ones the host drops, so a lock fails the same way on
every system. To get the tree for another platform, pass that platform's
`pkgs`.

## Not supported yet

bunix stops at evaluation time with a `bunix:` message on:

- `lockfileVersion` other than 1, 2 or 3
- host platforms other than Darwin or Linux on aarch64 or x86_64
- sources other than the registry and workspace members: git, github, file,
  link and tarball sources, and any resolution that isn't a plain version
- registry entries without an `integrity` hash
- nested workspace members (a workspace member under another entry, or a lock
  key under one)
- per-workspace `node_modules` for a member whose source path is absolute or
  has an empty, `.` or `..` segment
- packages that link a bin directory (`directories.bin`)

Lifecycle scripts (`preinstall`, `install`, `postinstall`) never run, so
packages that build native code in those scripts won't work.

## Versions

`v0.2.0` adds `lib.workspace`. `lib.nodeModules` is unchanged from `v0.1.1`.

## Checks

`nix flake check` builds `fixture/`, a two-member workspace, through both
functions. Its `.env.local`, `package/one/.env.local` and
`package/one/.env.production` are test files for the `src` filter: the first
two must be left out of `src`, the third kept.

## License

MIT, see [LICENSE.md](LICENSE.md).
