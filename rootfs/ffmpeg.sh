#!/data/data/com.termux/files/usr/bin/bash
# Run by build.sh (with STAGE, OUT and WORK exported): builds yt-dlp's FFmpeg (merging, remuxing,
# audio conversion, thumbnails) into the rootfs. Termux's package pulls in ~390 MB of libraries
# (x265, Vulkan, libass, ...); this one has FFmpeg's own codecs, plus LAME and Opus (see
# config.yaml) for audio. Its version and checksum follow Termux's recipe.
set -euo pipefail

RECIPE=$(curl -fsSL https://raw.githubusercontent.com/termux/termux-packages/master/packages/ffmpeg/build.sh)
VERSION=$(sed -n 's/^TERMUX_PKG_VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' <<< "$RECIPE")
VERSION=${VERSION#*:} # without an epoch
SHA256=$(sed -n 's/^TERMUX_PKG_SHA256=\([0-9a-f]\{64\}\)$/\1/p' <<< "$RECIPE")
[ -n "$VERSION" ] && [ -n "$SHA256" ] || { echo "::error::Couldn't read FFmpeg's version from Termux's recipe"; exit 1; }

apt-get install -y curl llvm
curl -fsSL -o "$WORK/ffmpeg.tar.xz" "https://www.ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
echo "$SHA256  $WORK/ffmpeg.tar.xz" | sha256sum -c -
tar -xJf "$WORK/ffmpeg.tar.xz" -C "$WORK"

case "$(dpkg --print-architecture)" in
  aarch64) ARCH=(--arch=aarch64 --enable-neon) ;;
  arm) ARCH=(--arch=armeabi-v7a --enable-neon) ;;
  # Assembly would need text relocations on i686 (https://trac.ffmpeg.org/ticket/4928)
  i686) ARCH=(--arch=x86 --disable-asm) ;;
  x86_64) ARCH=(--arch=x86_64); apt-get install -y nasm ;;
esac

cd "$WORK/ffmpeg-$VERSION"
# Its scripts run with /bin/sh, which Termux doesn't have; configure also writes one to check
# it can run what it makes
grep -rlI '^#! */bin/sh' . | xargs -r termux-fix-shebang
sed -i "s|^#!/bin/sh\$|#!$PREFIX/bin/sh|" configure

# Audio (yt-dlp's -x), covers (thumbnails), subtitles (movtext is mp4's mov_text)
ENCODERS=(aac alac flac libmp3lame libopus pcm_s16le mjpeg png movtext subrip srt ass ssa webvtt)
./configure --prefix="$PREFIX" --target-os=android --cc=clang --cxx=clang++ "${ARCH[@]}" \
  --enable-shared --disable-static --disable-symver --disable-doc --disable-debug --disable-ffplay \
  --disable-autodetect --disable-devices --disable-hwaccels \
  --enable-zlib --enable-libmp3lame --enable-libopus \
  --disable-encoders --enable-encoder="$(IFS=,; echo "${ENCODERS[*]}")" \
  --extra-ldflags="-Wl,-z,max-page-size=16384"
# configure only warns about a name it doesn't know (or an encoder it can't build)
for encoder in "${ENCODERS[@]}"; do
  grep -q "^#define CONFIG_${encoder^^}_ENCODER 1" config_components.h \
    || { echo "::error::FFmpeg has no $encoder encoder"; exit 1; }
done
make -j"$(nproc)"
make install DESTDIR="$WORK/ffmpeg-root"

ROOT="$WORK/ffmpeg-root$PREFIX"
cp -a "$ROOT/bin/ffmpeg" "$ROOT/bin/ffprobe" "$STAGE/usr/bin/"
cp -a "$ROOT"/lib/lib*.so* "$STAGE/usr/lib/"
find "$STAGE/usr/bin/ffmpeg" "$STAGE/usr/bin/ffprobe" "$STAGE/usr/lib" -maxdepth 1 \
  \( -name 'ff*' -o -name 'libav*' -o -name 'libsw*' \) -type f -exec llvm-strip --strip-unneeded {} +

echo "ffmpeg-$VERSION" >> "$OUT/manifest-pkg.txt"
sort -o "$OUT/manifest-pkg.txt" "$OUT/manifest-pkg.txt"
