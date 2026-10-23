#!/bin/bash
# OpenJDK 8's JRE for one ABI (the jdk8 part): Termux has no Java older than 17, so it's built here
# from OpenJDK's source with patches/ (PojavLauncher's for Android, and what the update pinned needs),
# cross-compiled with the NDK's clang (config.yaml's jdk8 section). Into out/<abi>/: the part's files
# (usr/, as the rootfs's) and what it was built of (info-<abi>.json). Runs on Linux x86_64 (build-jdk8.yml;
# by hand too, see README.md).
#
# usage: build.sh <abi>   (arm64-v8a, armeabi-v7a, x86, x86_64)
# ANDROID_NDK_HOME: the NDK (else downloaded); BOOT_JDK: a JDK 8 to build with (JAVA_HOME's, else PATH's)
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

# Each ABI as clang, OpenJDK's build and its lib/ folder name it. 32-bit ones get HotSpot's client VM
# (as PojavLauncher's), ARM's from the AArch32 port (its own repository and tags, its own triple)
case "$ABI" in
    arm64-v8a)   CLANG=aarch64-linux-android;     TARGET=aarch64-linux-android;     JDK_CPU=aarch64; LIB_ARCH=aarch64; VM=server; REPO=$(cfg repo) ;;
    armeabi-v7a) CLANG=armv7a-linux-androideabi;  TARGET=aarch32-linux-androideabi; JDK_CPU=aarch32; LIB_ARCH=aarch32; VM=client; REPO=$(cfg repo_arm) ;;
    x86)         CLANG=i686-linux-android;        TARGET=i686-linux-android;        JDK_CPU=x86;     LIB_ARCH=i386;    VM=client; REPO=$(cfg repo) ;;
    x86_64)      CLANG=x86_64-linux-android;      TARGET=x86_64-linux-android;      JDK_CPU=x86_64;  LIB_ARCH=amd64;   VM=server; REPO=$(cfg repo) ;;
    *) echo "Error: unknown ABI $ABI" >&2; exit 1 ;;
esac

# Their tags (the AArch32 port's own: its copies of OpenJDK's have none of its code), which patches/ fits
SRC_REF=$(cfg ref)
[ "$ABI" = armeabi-v7a ] && SRC_REF=$(cfg ref_arm)
echo "OpenJDK $REPO@$SRC_REF for $ABI ($TARGET, $VM VM), NDK $NDK_VERSION (android-$API)"

mkdir -p "$WORK"
cd "$WORK"

# The NDK: ANDROID_NDK_HOME's (build-jdk8.yml: setup-ndk's, as build-proot.yml's), else downloaded next to the work
NDK="${ANDROID_NDK_HOME:-$(dirname "$WORK")/android-ndk-$NDK_VERSION}"
if [ ! -d "$NDK" ]; then
    wget -nv -O "$NDK.zip" "https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-linux-x86_64.zip"
    unzip -q "$NDK.zip" -d "$(dirname "$NDK")"
    rm "$NDK.zip"
fi
# Its clang for the ABI and API (the sysroot built in: no -I or -L of it, which the build would also give
# the tools it compiles for this machine, bionic's headers in place of glibc's), and LLVM's binutils
TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
INCLUDE="$TOOLS/sysroot/usr/include"
export CC="$TOOLS/bin/$CLANG$API-clang" CXX="$TOOLS/bin/$CLANG$API-clang++"
export AR="$TOOLS/bin/llvm-ar" NM="$TOOLS/bin/llvm-nm" OBJCOPY="$TOOLS/bin/llvm-objcopy" RANLIB="$TOOLS/bin/llvm-ranlib" STRIP="$TOOLS/bin/llvm-strip"

# FreeType (AWT's fonts), which the JRE links: built for Android, as it is
FREETYPE="$WORK/freetype-$FREETYPE_VERSION/build_android"
if [ ! -d "$FREETYPE" ]; then
    wget -nv -O- "https://downloads.sourceforge.net/project/freetype/freetype2/$FREETYPE_VERSION/freetype-$FREETYPE_VERSION.tar.gz" | tar -xz
    (cd "freetype-$FREETYPE_VERSION" \
        && ./configure --host="$CLANG" --prefix="$FREETYPE" \
            --without-zlib --with-bzip2=no --with-brotli=no --with-png=no --with-harfbuzz=no \
        && make -j"$JOBS" && make install)
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
# What the update pinned needs that they don't know: BitMap's ArrayAllocator instantiated where libjvm needs it
patch -d openjdk -p1 --forward --fuzz=2 < "$HERE/patches/jdk8-bitmap-arrayallocator.patch"

# What the build expects of a Linux system: X11's, Fontconfig's and ALSA's headers (the host's: configure
# looks for them; the patches leave out what would use ALSA), CUPS' (printing, which the JRE only compiles
# against), and libraries bionic has in libc (empty ones)
ln -sfn /usr/include/X11 "$INCLUDE/X11"
ln -sfn /usr/include/fontconfig "$INCLUDE/fontconfig"
ln -sfn /usr/include/alsa "$INCLUDE/alsa"
ln -sfn /usr/include/cups "$INCLUDE/cups"
mkdir -p dummy_libs
for lib in pthread thread_db; do [ -f "dummy_libs/lib$lib.a" ] || "$AR" cru "dummy_libs/lib$lib.a"; done

# OpenJDK 8's C and C++ as clang takes them now: its C has what C99 and newer clangs make errors of
# (functions used undeclared, ints for pointers), tentative definitions in headers (-fcommon), and its
# C++ is C++98's (register, dynamic exception specifications)
C_OLD="-fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion
 -Wno-error=incompatible-pointer-types -Wno-error=incompatible-function-pointer-types -Wno-error=return-type"
FLAGS="-DLE_STANDALONE -O3 -D__ANDROID__ $(echo $C_OLD)"

boot=()
BOOT_JDK="${BOOT_JDK:-${JAVA_HOME:-}}"
[ -n "$BOOT_JDK" ] && boot=(--with-boot-jdk="$BOOT_JDK")
cd openjdk
bash ./configure \
    --openjdk-target="$TARGET" \
    --with-toolchain-type=clang \
    --with-extra-cflags="$FLAGS" \
    --with-extra-cxxflags="$FLAGS -std=gnu++98" \
    --with-extra-ldflags="-L$WORK/dummy_libs" \
    --enable-option-checking=fatal \
    --with-jdk-variant=normal \
    --with-jvm-variants="$VM" \
    --with-cups-include="$INCLUDE" \
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
# HotSpot takes clang from make (configure doesn't tell it), its warnings not as errors: a newer clang
# warns of more than it was written for. Parallel makes sometimes trip over their own order: once
# more, as PojavLauncher does
MAKE_ARGS=(JOBS="$JOBS" USE_CLANG=true WARNINGS_ARE_ERRORS= images)
make "${MAKE_ARGS[@]}" || make "${MAKE_ARGS[@]}"

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
"$CC" -shared -fPIC -O2 -Wl,-soname,libtagfix.so -o "$LIB/libtagfix.so" "$HERE/libtagfix.c"
echo > "$WORK/empty.c"
"$CC" -shared -fPIC -Wl,-soname,librt.so -Wl,--no-as-needed -o "$LIB/librt.so" "$WORK/empty.c" -lc
"$STRIP" --strip-unneeded "$LIB/libtagfix.so" "$LIB/librt.so"
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
