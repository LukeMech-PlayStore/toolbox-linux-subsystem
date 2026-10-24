#!/bin/bash
# OpenJDK 8's JRE for one ABI (the jdk8 part): Termux has no Java older than 17, so it's built here
# from OpenJDK's source (config.yaml's sources.openjdk8) with patches/ (PojavLauncher's for Android, and
# what the update pinned needs), cross-compiled with the NDK's clang (ndk.sh). Into out/<abi>/: the part's
# files (usr/, as the rootfs's), and out/info-<abi>.json: what it was built of. Runs on Linux x86_64
# (build-openjdk8.yml; by hand too, see README.md).
#
# usage: build.sh <abi>   (a name of config.yaml's android.abis)
# BOOT_JDK: a JDK 8 to build with (JAVA_HOME's, else PATH's); the NDK as ndk.sh finds it
set -euo pipefail

ABI="${1:?usage: build.sh <abi>}"
HERE=$(dirname "$(readlink -f "$0")")
CONFIG="${CONFIG:-$HERE/../../config.yaml}"
WORK="${WORK:-$HERE/work/$ABI}"
OUT="${OUT:-$HERE/out/$ABI}"
JOBS="${JOBS:-$(nproc)}"

cfg() {
    local value
    value=$(yq -r ".sources.openjdk8.$1" "$CONFIG")
    if [ -z "$value" ] || [ "$value" = null ]; then
        echo "Error: sources.openjdk8.$1 is missing in $CONFIG" >&2
        exit 1
    fi
    echo "$value"
}

# The NDK's clang for the ABI (the sysroot built in: no -I or -L of it, which the build would also give
# the tools it compiles for this machine, bionic's headers in place of glibc's), and LLVM's binutils
source "$HERE/../../ndk.sh"
ndk_setup "$ABI"
INCLUDE="$NDK_SYSROOT/usr/include"

# Each ABI as OpenJDK's build and its lib/ folder name it. 32-bit ones get HotSpot's client VM (as
# PojavLauncher's), ARM's from the AArch32 port (its own repository, tags and triple)
case "$NDK_ARCH" in
    arm64)  TARGET=aarch64-linux-android;     JDK_CPU=aarch64; LIB_ARCH=aarch64; VM=server; REPO=$(cfg repo);     SRC_REF=$(cfg ref) ;;
    arm)    TARGET=aarch32-linux-androideabi; JDK_CPU=aarch32; LIB_ARCH=aarch32; VM=client; REPO=$(cfg repo_arm); SRC_REF=$(cfg ref_arm) ;;
    x86)    TARGET=i686-linux-android;        JDK_CPU=x86;     LIB_ARCH=i386;    VM=client; REPO=$(cfg repo);     SRC_REF=$(cfg ref) ;;
    x86_64) TARGET=x86_64-linux-android;      JDK_CPU=x86_64;  LIB_ARCH=amd64;   VM=server; REPO=$(cfg repo);     SRC_REF=$(cfg ref) ;;
esac
echo "OpenJDK $REPO@$SRC_REF for $ABI ($TARGET, $VM VM)"

mkdir -p "$WORK"
cd "$WORK"

# The source at its tag, and the patches for it
rm -rf openjdk
git clone -q --depth 1 -b "$SRC_REF" "https://github.com/$REPO" openjdk
apply_patch() {
    # As PojavLauncher applies its own (jdk8-android*.patch: its buildjre8's jdk8u_android*.diff): what no
    # longer fits upstream (a newer update) is left out, and said
    git -C openjdk apply --reject --whitespace=fix "$HERE/patches/$1" || echo "::warning::$1: some hunks didn't apply"
}
apply_patch jdk8-android.patch
if [ "$ABI" = armeabi-v7a ]; then apply_patch jdk8-android-aarch32.patch; else apply_patch jdk8-android-main.patch; fi
if [ "$ABI" = x86 ]; then apply_patch jdk8-android-x86-page-trap.patch; fi
# What the update pinned needs that they don't know: BitMap's ArrayAllocator instantiated where libjvm needs it
patch -d openjdk -p1 --forward --fuzz=2 < "$HERE/patches/jdk8-bitmap-arrayallocator.patch"

# What the build expects of a Linux system: X11's, Fontconfig's and ALSA's headers (the host's: configure
# looks for them; the patches leave out what would use ALSA), and CUPS' (printing, which the JRE only
# compiles against)
ln -sfn /usr/include/X11 "$INCLUDE/X11"
ln -sfn /usr/include/fontconfig "$INCLUDE/fontconfig"
ln -sfn /usr/include/alsa "$INCLUDE/alsa"
ln -sfn /usr/include/cups "$INCLUDE/cups"

# OpenJDK 8's C and C++ as clang takes them now: its C has what C99 and newer clangs make errors of
# (functions used undeclared, ints for pointers), tentative definitions in headers (-fcommon), and its
# C++ is C++98's (register, dynamic exception specifications). HotSpot tests this against NULL, which clang
# may otherwise drop as never true (as OpenJDK tells GCC). Its libraries position-independent on 32-bit
# ABIs too (OpenJDK 8 doesn't make them so there, and Android loads no code relocated in place). Its
# exported symbols' list names some it no longer has, which LLVM's linker refuses where GNU's didn't mind
C_OLD="-fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion
 -Wno-error=incompatible-pointer-types -Wno-error=incompatible-function-pointer-types -Wno-error=return-type"
FLAGS="-DLE_STANDALONE -O3 -D__ANDROID__ -fPIC -fno-delete-null-pointer-checks $(echo $C_OLD)"
LDFLAGS_OLD="-Wl,--undefined-version"

boot=()
BOOT_JDK="${BOOT_JDK:-${JAVA_HOME:-}}"
[ -n "$BOOT_JDK" ] && boot=(--with-boot-jdk="$BOOT_JDK")
cd openjdk
# The tools the build runs on this machine (HotSpot's adlc) compiled with clang too: HotSpot gives them
# its clang flags (on the command line: configure ignores them from the environment). FreeType its own
# (bundled: OpenJDK's copy, built for Android and shipped in the JRE)
bash ./configure BUILD_CC=clang BUILD_CXX=clang++ \
    --openjdk-target="$TARGET" \
    --with-toolchain-type=clang \
    --with-extra-cflags="$FLAGS" \
    --with-extra-cxxflags="$FLAGS -std=gnu++98" \
    --with-extra-ldflags="$LDFLAGS_OLD" \
    --enable-option-checking=fatal \
    --with-jdk-variant=normal \
    --with-jvm-variants="$VM" \
    --with-debug-level=release \
    --disable-precompiled-headers \
    --with-freetype=bundled \
    --with-cups-include="$INCLUDE" \
    --with-fontconfig-include="$INCLUDE" \
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
# debug info and man pages
rm -rf "$OUT"
JRE="$OUT/usr/lib/jvm/java-8-openjdk"
mkdir -p "$(dirname "$JRE")"
cp -a images/j2re-image "$JRE"
rm -rf "$JRE/man"
find "$JRE" -name '*.diz' -delete
LIB="$JRE/lib/$LIB_ARCH"
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

# What it was built of: what the app lists it holds (rootfs/release.py)
VERSION=$(sed -n 's/^JAVA_VERSION="\(.*\)"/\1/p' "$JRE/release")
jq -n --arg name openjdk8-jre --arg src "$REPO@$SRC_REF" --arg version "$VERSION" \
    '{name: $name, source: $src, version: $version}' > "$OUT/../info-$ABI.json"
echo "Built OpenJDK $VERSION ($SRC_REF) for $ABI: $(du -sh "$OUT" | cut -f1)"
