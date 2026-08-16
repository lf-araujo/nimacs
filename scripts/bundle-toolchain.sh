#!/usr/bin/env bash
# Assemble a self-contained toolchain next to the focim binary so config
# hot-reload (C-c r) works without a system Nim/C compiler.
#
# Layout it produces (focim's detectRebuildCmd looks here):
#   ./toolchain/nim/bin/nim   + ./toolchain/nim/lib + config  (Nim finds its
#                                                              stdlib beside it)
#   ./toolchain/zig/zig                                        (hermetic C backend)
#
# Usage:
#   scripts/bundle-toolchain.sh /path/to/zig
# where /path/to/zig is a zig binary (download the single-file release from
# https://ziglang.org/download/ and point at the extracted `zig`). Nim drives it
# as `zig cc`, which ships its own libc/headers and cross-compiles.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"     # project root
dest="$here/toolchain"
zig_src="${1:-}"

# 1. Copy the active Nim prefix (binary + lib + config) verbatim.
nim_bin="$(command -v nim || true)"
[ -n "$nim_bin" ] || { echo "error: no 'nim' on PATH to copy"; exit 1; }
nim_prefix="$(cd "$(dirname "$nim_bin")/.." && pwd)"   # .../nim-X.Y.Z
echo "copying Nim from $nim_prefix"
rm -rf "$dest/nim"
mkdir -p "$dest/nim"
cp -a "$nim_prefix/bin"    "$dest/nim/"
cp -a "$nim_prefix/lib"    "$dest/nim/"
[ -d "$nim_prefix/config" ] && cp -a "$nim_prefix/config" "$dest/nim/" || true

# 2. Place the zig binary (optional but recommended -- the compiler-free C path).
if [ -n "$zig_src" ]; then
  [ -x "$zig_src" ] || { echo "error: '$zig_src' is not an executable zig"; exit 1; }
  echo "copying zig from $zig_src"
  rm -rf "$dest/zig"; mkdir -p "$dest/zig"
  # zig needs its lib/ sibling; copy the whole zig dir if it has one.
  zdir="$(dirname "$zig_src")"
  if [ -d "$zdir/lib" ]; then cp -a "$zdir/." "$dest/zig/"; else cp -a "$zig_src" "$dest/zig/zig"; fi
  chmod +x "$dest/zig/zig"
else
  echo "note: no zig given -- bundling Nim only; C-c r will use the system C compiler."
fi

echo "done. toolchain assembled at $dest"
echo "focim's C-c r will now prefer it (see detectRebuildCmd)."
