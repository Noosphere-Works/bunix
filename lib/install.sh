# Shell functions the tree's build command runs. Every path they take is
# relative to `$out`; link targets are relative to the link's own directory.

# unpack <tarball> <dir>: the tarball's regular files, as bun extracts them
# (`bunix-unpack`).
unpack() {
  mkdir -p "$out/$2"
  bunix-unpack "$1" "$out/$2"
}

# link_bin <.bin dir> <name> (<file> <link target>)...: links the first
# candidate that exists, file or directory, as bun's
# `Linker::link_bin_or_create_shim` does. bun then sets the target's mode to
# 0777 minus the umask (`chmod_on_ok`), and its shebang rewrite cannot read
# a directory. A file's `#!/usr/bin/env node` line is patched to nixpkgs'
# node; a directory is left as it is, since patchShebangs would rewrite
# every file in it.
link_bin() {
  dir=$1
  name=$2
  shift 2
  while [ $# -gt 0 ]; do
    if [ -e "$out/$1" ]; then
      mkdir -p "$out/$dir"
      chmod "$(printf '%o' $((0777 & ~$(umask))))" "$out/$1"
      if [ -f "$out/$1" ]; then
        patchShebangs --host "$out/$1" > /dev/null
      fi
      ln -s "$2" "$out/$dir/$name"
      return
    fi
    echo "bunix: skipping bin $name: $1 does not exist" >&2
    shift 2
  done
}

link_workspace() {
  mkdir -p "$(dirname "$out/$1")"
  ln -s "$2" "$out/$1"
}
