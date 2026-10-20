#!/bin/bash
# Run by build.yml: packs a part's files into its archive, as the app unpacks it (XZ for Java).
#   pack.sh <part dir> <arch (termux's name)> <archive>
# xz's branch-call filter for the ABI's code turns its relative calls absolute, so repeated calls
# match (3-5% smaller with ELFs; nothing to the pure-Python parts), and its literal-position bits
# follow the instruction size (4 bytes on arm64, 2 with Thumb-2: Termux's arm). Measured on the
# 26.10.17 parts. The dictionary is what the app's decoder allocates in one piece, on its Java heap
# (16 MB on some devices, e.g. Android 10's x86 emulator): 8 MiB, not -9e's 64 (jdk21 2.9% larger,
# ffmpeg 2.1%, the parts under 8 MB no different). A change here repacks every part (rootfs/release.py: packing)
set -euo pipefail

case "$2" in
  aarch64) xz_opts=(--arm64 --lzma2=preset=9e,dict=8MiB,lc=2,lp=2) ;;
  arm) xz_opts=(--armthumb --lzma2=preset=9e,dict=8MiB,lp=1) ;;
  i686 | x86_64) xz_opts=(--x86 --lzma2=preset=9e,dict=8MiB) ;;
  *) echo "pack.sh: no filter for $2" >&2; exit 1 ;;
esac

# -T1: one block holds a whole part (threads would cut it into 24 MiB blocks, each starting with an
# empty dictionary), and the parts are packed side by side instead
tar --owner=0 --group=0 --numeric-owner -cf - -C "$1" . | xz "${xz_opts[@]}" -T1 -c > "$3"
