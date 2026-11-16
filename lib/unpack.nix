# `bunix-unpack` (`unpack.c`), built for the platform that builds the tree.
{ pkgs }:
pkgs.buildPackages.runCommandCC "bunix-unpack"
  {
    buildInputs = [ pkgs.buildPackages.libarchive ];
  }
  ''
    mkdir -p $out/bin
    $CC -O2 -Wall -Werror -o $out/bin/bunix-unpack ${./unpack.c} -larchive
  ''
