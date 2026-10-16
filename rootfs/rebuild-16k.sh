#!/data/data/com.termux/files/usr/bin/bash
# Run by build.sh (with STAGE and WORK exported) for every part: the libraries in it Termux still
# links for 4 KB pages (built before it moved to 16 KB) are rebuilt from the same source, linked for
# 16 KB pages, over its copies in $STAGE/usr/lib. Only while Termux's own file is unaligned; once it
# isn't, the build warns that its recipe can go.
set -euo pipefail

aligned_16k() {
  local align
  for align in $(llvm-readelf -lW "$1" | awk '$1 == "LOAD" { print $NF }'); do
    (( align >= 16384 )) || return 1
  done
}

# Downloads <url> into $WORK (checked against <sha256>) and unpacks it there
fetch() {
  local url=$1 sha=$2 archive="$WORK/$(basename "$1")"
  curl -fsSL -o "$archive" "$url"
  echo "$sha  $archive" | sha256sum -c -
  tar -xzf "$archive" -C "$WORK"
}

# Recipes: build_<name> leaves the libraries in $WORK/16k/<name>/, named as Termux names them
build_libandroid_utimes() {
  fetch https://github.com/termux/libandroid-utimes/archive/refs/tags/v0.4.tar.gz \
    579dd000d084e2647d7b907d3c4ef2c46c8cda703e371ed1df32f4dd0366e25d
  clang -fPIC -shared -Wl,-z,max-page-size=16384 "$WORK/libandroid-utimes-0.4/sys_time.c" \
    -o "$OUT_DIR/libandroid-utimes.so"
}

build_libwebp() {
  # Termux's 1.6.0 build (packages/libwebp/build.sh): its options, without the tools
  fetch https://github.com/webmproject/libwebp/archive/refs/tags/v1.6.0.tar.gz \
    93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136
  apt-get install -y cmake
  # Unversioned names, as Termux's (what FFmpeg's libraries link)
  cmake -S "$WORK/libwebp-1.6.0" -B "$WORK/libwebp-build" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON -DWEBP_ENABLE_SWAP_16BIT_CSP=ON \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
    -DWEBP_BUILD_EXTRAS=OFF -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384"
  cmake --build "$WORK/libwebp-build" -j"$(nproc)"
  cp "$WORK/libwebp-build"/lib*.so "$OUT_DIR/"
}

# Each library and its recipe
declare -A RECIPES=(
  [libandroid-utimes.so]=libandroid_utimes
  [libwebp.so]=libwebp [libwebpmux.so]=libwebp [libwebpdemux.so]=libwebp
  [libwebpdecoder.so]=libwebp [libsharpyuv.so]=libwebp
)

command -v llvm-readelf > /dev/null || apt-get install -y llvm
for lib in "${!RECIPES[@]}"; do
  [ -e "$STAGE/usr/lib/$lib" ] || continue
  recipe=${RECIPES[$lib]}
  if aligned_16k "$PREFIX/lib/$lib"; then
    echo "::warning::Termux's $lib is 16 KB aligned now, drop its recipe from rootfs/rebuild-16k.sh"
    continue
  fi
  # Built once, for every part needing it
  OUT_DIR="$WORK/16k/$recipe"
  if [ ! -d "$OUT_DIR" ]; then
    command -v clang > /dev/null || apt-get install -y clang
    command -v curl > /dev/null || apt-get install -y curl
    mkdir -p "$OUT_DIR.tmp"
    OUT_DIR="$OUT_DIR.tmp" "build_$recipe"
    mv "$OUT_DIR.tmp" "$OUT_DIR"
  fi
  built="$OUT_DIR/$lib"
  [ -f "$built" ] || { echo "::error::rebuild-16k.sh: $recipe didn't build $lib"; exit 1; }
  # Loadable in place of Termux's: same name for the linker (if it has one), and aligned
  soname() { llvm-readelf -dW "$1" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p'; }
  if [ "$(soname "$built")" != "$(soname "$PREFIX/lib/$lib")" ]; then
    echo "::error::rebuild-16k.sh: $lib is named '$(soname "$built")', Termux's '$(soname "$PREFIX/lib/$lib")'"
    exit 1
  fi
  aligned_16k "$built" || { echo "::error::rebuild-16k.sh: $lib isn't 16 KB aligned"; exit 1; }
  # Over the link, if Termux's is one
  rm -f "$STAGE/usr/lib/$lib"
  cp "$built" "$STAGE/usr/lib/$lib"
  echo "Rebuilt $lib for 16 KB pages"
done
