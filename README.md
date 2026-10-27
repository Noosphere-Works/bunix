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
bunDependencies = inputs.bunix.lib.nodeModules {
  inherit pkgs;
  lock = ./bun.lock;
  # name = "node-modules";  # the default
};
```

`lib.nodeModules { pkgs, lock, name ? "node-modules" }` works on any system.
It uses only the `pkgs` you pass, never bunix's own nixpkgs input.

Copy the tree into the build's copy of the workspace. Don't link it.
Workspace members are relative links, so they resolve only inside the
project. A linked tree would also put its store path into the build's output.
A workspace member with its own `node_modules` gets it under the same path in
`$out` as in the project, so copy those too. The loop below fits members under
`package/`; a project whose members live elsewhere copies from its own paths.

```nix
pkgs.stdenvNoCC.mkDerivation {
  src = ./.; # the workspace root, next to bun.lock
  nativeBuildInputs = [ pkgs.bun pkgs.nodejs ];
  configurePhase = ''
    runHook preConfigure
    cp -R --reflink=auto ${bunDependencies}/node_modules node_modules
    chmod -R u+w node_modules
    for member in ${bunDependencies}/package/*; do
      [ -d "$member/node_modules" ] || continue
      target=package/$(basename "$member")/node_modules
      cp -R --reflink=auto "$member/node_modules" "$target"
      chmod -R u+w "$target"
    done
    runHook postConfigure
  '';
  disallowedReferences = [ bunDependencies ];
  # ...
}
```

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

## License

MIT, see [LICENSE.md](LICENSE.md).
