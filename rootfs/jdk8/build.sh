#!/bin/bash
# OpenJDK 8's JRE for one ABI (the jdk8 part): Termux has no Java older than 17, so it's built here
# from OpenJDK's source with patches/ (PojavLauncher's for Android, and what the update pinned needs),
# cross-compiled with the NDK's GCC
# (config.yaml's jdk8 section). Into out/<abi>/: the part's files (usr/, as the rootfs's) and what it
# was built of (info.json). Runs on Linux x86_64 (build-jdk8.yml; by hand too, see README.md).
#
# usage: build.sh <abi>   (arm64-v8a, armeabi-v7a, x86, x86_64)
# BOOT_JDK: a JDK 8 to build with (JAVA_HOME's, else the one on PATH)
set -euo pipefail

ABI="${1:?usage: build.sh <abi>}"
HERE=$(dirname "$(readlink -f "$0")")
CONFIG="${CONFIG:-$HERE/../../config.yaml}"
WORK="${WORK:-$HERE/work/$ABI}"
OUT="${OUT:-$HERE/out/$ABI}"
JOBS="${JOBS:-$(nproc)}"

cfg() {
    local value
    value=$(yq -r ".jdk8.$1" "$CONFIG")
    if [ -z "$value" ] || [ "$value" = null ]; then
        echo "Error: jdk8.$1 is missing in $CONFIG" >&2
        exit 1
    fi
    echo "$value"
}
NDK_VERSION=$(cfg ndk)
API=$(cfg android_api)
FREETYPE_VERSION=$(cfg freetype)

# Each ABI as the NDK, OpenJDK's build and its lib/ folder name it. 32-bit ones get HotSpot's client VM
# (as PojavLauncher's), ARM's from the AArch32 port (its own repository and tags)
case "$ABI" in
    arm64-v8a)   TARGET=aarch64-linux-android;   SHORT=arm64;  JDK_CPU=aarch64; LIB_ARCH=aarch64; VM=server; REPO=$(cfg repo) ;;
    armeabi-v7a) TARGET=arm-linux-androideabi;   SHORT=arm;    JDK_CPU=aarch32; LIB_ARCH=aarch32; VM=client; REPO=$(cfg repo_arm) ;;
    x86)         TARGET=i686-linux-android;      SHORT=x86;    JDK_CPU=x86;     LIB_ARCH=i386;    VM=client; REPO=$(cfg repo) ;;
    x86_64)      TARGET=x86_64-linux-android;    SHORT=x86_64; JDK_CPU=x86_64;  LIB_ARCH=amd64;   VM=server; REPO=$(cfg repo) ;;
    *) echo "Error: unknown ABI $ABI" >&2; exit 1 ;;
esac
# OpenJDK's configure takes the AArch32 port's own triple
TARGET_PHYS=$TARGET
[ "$ABI" = armeabi-v7a ] && TARGET_PHYS=aarch32-linux-androideabi

# Their tags (the AArch32 port's own: its copies of OpenJDK's have none of its code), which patches/ fits
SRC_REF=$(cfg ref)
[ "$ABI" = armeabi-v7a ] && SRC_REF=$(cfg ref_arm)
echo "OpenJDK $REPO@$SRC_REF for $ABI ($TARGET, $VM VM), NDK $NDK_VERSION (android-$API)"

mkdir -p "$WORK"
cd "$WORK"

# The NDK: r10e, the last with GCC (HotSpot 8 doesn't build with clang), a standalone toolchain of it
# ANDROID_NDK_HOME's (build-jdk8.yml: setup-ndk's, as build-proot.yml's), else downloaded next to the work
NDK="${ANDROID_NDK_HOME:-$(dirname "$WORK")/android-ndk-$NDK_VERSION}"
if [ ! -d "$NDK" ]; then
    wget -nv -O "$NDK.zip" "https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-linux-x86_64.zip"
    unzip -q "$NDK.zip" -d "$(dirname "$NDK")"
    rm "$NDK.zip"
fi
# Its scripts find it by this
export ANDROID_NDK_ROOT=$NDK
TOOLCHAIN="$WORK/toolchain"
if [ ! -d "$TOOLCHAIN" ]; then
    "$NDK/build/tools/make-standalone-toolchain.sh" --arch="$SHORT" --platform="android-$API" --install-dir="$TOOLCHAIN"
    # How OpenJDK's configure finds it (--with-devkit)
    cat > "$TOOLCHAIN/devkit.info" <<EOF
DEVKIT_NAME="Android $SHORT"
DEVKIT_TOOLCHAIN_PATH="\$DEVKIT_ROOT/$TARGET/bin"
DEVKIT_SYSROOT="\$DEVKIT_ROOT/sysroot"
EOF
fi
INCLUDE="$TOOLCHAIN/sysroot/usr/include"
export AR=$TOOLCHAIN/bin/$TARGET-ar AS=$TOOLCHAIN/bin/$TARGET-as CC=$TOOLCHAIN/bin/$TARGET-gcc CXX=$TOOLCHAIN/bin/$TARGET-g++
export LD=$TOOLCHAIN/bin/$TARGET-ld OBJCOPY=$TOOLCHAIN/bin/$TARGET-objcopy RANLIB=$TOOLCHAIN/bin/$TARGET-ranlib STRIP=$TOOLCHAIN/bin/$TARGET-strip
# Its compilers have the sysroot built in: no -I or -L of it, which the build would also give the tools it
# compiles for this machine (bionic's headers in place of glibc's)

# FreeType (AWT's fonts), which the JRE links: built for Android, as it is
FREETYPE="$WORK/freetype-$FREETYPE_VERSION/build_android"
if [ ! -d "$FREETYPE" ]; then
    wget -nv -O- "https://downloads.sourceforge.net/project/freetype/freetype2/$FREETYPE_VERSION/freetype-$FREETYPE_VERSION.tar.gz" | tar -xz
    (cd "freetype-$FREETYPE_VERSION" \
        && PATH="$TOOLCHAIN/bin:$PATH" ./configure --host="$TARGET" --prefix="$FREETYPE" \
            --without-zlib --with-bzip2=no --with-brotli=no --with-png=no --with-harfbuzz=no \
        && CFLAGS=-fno-rtti CXXFLAGS=-fno-rtti make -j"$JOBS" && make install)
fi

# The source at its tag, and the patches for it
rm -rf openjdk
git clone -q --depth 1 -b "$SRC_REF" "https://github.com/$REPO" openjdk
pojav() {
    # PojavLauncher's for Android (jdk8-android*.patch: its buildjre8's jdk8u_android*.diff), as it applies
    # them: what no longer fits upstream (a newer update) is left out, and said
    git -C openjdk apply --reject --whitespace=fix "$HERE/patches/$1" || echo "::warning::$1: some hunks didn't apply"
}
pojav jdk8-android.patch
if [ "$ABI" = armeabi-v7a ]; then pojav jdk8-android-aarch32.patch; else pojav jdk8-android-main.patch; fi
if [ "$ABI" = x86 ]; then pojav jdk8-android-x86-page-trap.patch; fi
# What the update pinned needs that they don't know (as termux-java8 builds it): configure refuses GCC < 5
# for AArch64 (JDK-8360869; the NDK's is 4.9), BitMap's ArrayAllocator isn't instantiated where libjvm
# needs it. Each has to fit (the AArch32 port's configure is OpenJDK's, further down)
for p in jdk8-gcc49-aarch64.patch jdk8-bitmap-arrayallocator.patch; do
    patch -d openjdk -p1 --forward --fuzz=2 < "$HERE/patches/$p"
done

# What the build expects of a Linux system: X11's, Fontconfig's and ALSA's headers (the host's: configure
# looks for them; the patches leave out what would use ALSA), CUPS' (printing, which the JRE only compiles
# against), and libraries bionic has in libc (empty ones)
ln -sfn /usr/include/X11 "$INCLUDE/X11"
ln -sfn /usr/include/fontconfig "$INCLUDE/fontconfig"
ln -sfn /usr/include/alsa "$INCLUDE/alsa"
ln -sfn /usr/include/cups "$INCLUDE/cups"
mkdir -p dummy_libs
for lib in pthread thread_db; do [ -f "dummy_libs/lib$lib.a" ] || ar cru "dummy_libs/lib$lib.a"; done

boot=()
BOOT_JDK="${BOOT_JDK:-${JAVA_HOME:-}}"
[ -n "$BOOT_JDK" ] && boot=(--with-boot-jdk="$BOOT_JDK")
cd openjdk
bash ./configure \
    --openjdk-target="$TARGET_PHYS" \
    --with-extra-cflags="-DLE_STANDALONE -O3 -D__ANDROID__" \
    --with-extra-cxxflags="-DLE_STANDALONE -O3 -D__ANDROID__" \
    --with-extra-ldflags="-L$WORK/dummy_libs" \
    --enable-option-checking=fatal \
    --with-jdk-variant=normal \
    --with-jvm-variants="$VM" \
    --with-cups-include="$INCLUDE" \
    --with-devkit="$TOOLCHAIN" \
    --with-debug-level=release \
    --disable-precompiled-headers \
    --with-fontconfig-include="$INCLUDE" \
    --with-freetype-lib="$FREETYPE/lib" \
    --with-freetype-include="$FREETYPE/include/freetype2" \
    --x-includes="$INCLUDE/X11" \
    --x-libraries=/usr/lib \
    "${boot[@]}" \
    || { cat config.log; exit 1; }
# Its wrapper says nothing of configure failing: what that makes tells
BUILD="build/linux-$JDK_CPU-normal-$VM-release"
[ -f "$BUILD/spec.gmk" ] || { echo "Error: configure failed" >&2; exit 1; }
cd "$BUILD"
# Parallel makes sometimes trip over their own order: once more, as PojavLauncher does
make JOBS="$JOBS" images || make JOBS="$JOBS" images

# The part: the JRE in Termux's prefix (usr/lib/jvm/java-8-openjdk, as Termux's Java), without its
# debug info, man pages, or what only desktops use
rm -rf "$OUT"
JRE="$OUT/usr/lib/jvm/java-8-openjdk"
mkdir -p "$(dirname "$JRE")"
cp -a images/j2re-image "$JRE"
rm -rf "$JRE/man"
find "$JRE" -name '*.diz' -delete
LIB="$JRE/lib/$LIB_ARCH"
[ -f "$LIB/libfreetype.so.6" ] && mv "$LIB/libfreetype.so.6" "$LIB/libfreetype.so"
find "$JRE" -type f \( -name '*.so' -o -path '*/bin/*' \) -exec sh -c 'head -c4 "$1" | grep -q ELF' sh {} \; -print0 \
    | xargs -0 "$STRIP" --strip-unneeded

# Android 11+ tags heap pointers (their top byte) on 64-bit ARM, which HotSpot 8's code generator can't
# encode: bin/java loads libtagfix first, which turns that off. HotSpot's monotonic clock comes from
# librt, which bionic doesn't have: one linking libc stands in (dlsym searches what it links)
$CC -shared -fPIC -O2 -Wl,-z,max-page-size=16384 -Wl,-soname,libtagfix.so -o "$LIB/libtagfix.so" "$HERE/libtagfix.c"
echo > "$WORK/empty.c"
$CC -shared -fPIC -Wl,-z,max-page-size=16384 -Wl,-soname,librt.so -Wl,--no-as-needed -o "$LIB/librt.so" "$WORK/empty.c" -lc
$STRIP --strip-unneeded "$LIB/libtagfix.so" "$LIB/librt.so"
patchelf --add-needed libtagfix.so "$JRE/bin/java"

# The app runs it as java-8 (as jdk.sh links the other versions'): its libraries found where it is
mkdir -p "$OUT/usr/bin"
cat > "$OUT/usr/bin/java-8" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
J=/data/data/com.termux/files/usr/lib/jvm/java-8-openjdk
export LD_LIBRARY_PATH=\$J/lib/$LIB_ARCH/jli:\$J/lib/$LIB_ARCH:\$J/lib/$LIB_ARCH/$VM\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
exec "\$J/bin/java" "\$@"
EOF
chmod 755 "$OUT/usr/bin/java-8"

# What it was built of: what the app lists it holds, and what decides its version (rootfs/release.py)
VERSION=$(sed -n 's/^JAVA_VERSION="\(.*\)"/\1/p' "$JRE/release")
jq -n --arg name openjdk8-jre --arg src "$REPO@$SRC_REF" --arg ndk "$NDK_VERSION" --arg api "$API" --arg version "$VERSION" \
    '{name: $name, source: $src, ndk: $ndk, android_api: $api, version: $version}' > "$OUT/../info-$ABI.json"
echo "Built OpenJDK $VERSION ($SRC_REF) for $ABI: $(du -sh "$OUT" | cut -f1)"
