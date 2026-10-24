#!/bin/bash
# OpenJDK 8's JRE for one ABI (the jdk8 part): Termux has no Java older than 17, so it's built here
# from OpenJDK's source (config.yaml's sources.openjdk8) with patches/ (PojavLauncher's for Android, and
# what the update pinned needs of GCC 4.9), cross-compiled with its NDK's GCC (r10e, as PojavLauncher's).
# Into out/<abi>/: the part's files (usr/, as the rootfs's), and out/info-<abi>.json: what it was built
# of. Runs on Linux x86_64 (build-openjdk8.yml; by hand too, see README.md).
#
# usage: build.sh <abi>   (a name of config.yaml's android.abis)
#        build.sh --versions   (only print the tags it builds: ref=..., ref_arm=...)
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

# Its tags: config's, or the ones resolved before (OPENJDK8_REF, OPENJDK8_REF_ARM: build.yml's, which
# decided to build). "latest": OpenJDK's newest release (jdk8u<N>-ga), and its AArch32 port's newest tag of it
REF="${OPENJDK8_REF:-$(cfg ref)}"
if [ "$REF" = latest ]; then
    REF=$(git ls-remote --tags --refs "https://github.com/$(cfg repo)" 'jdk8u*-ga' | sed 's|.*refs/tags/||' \
        | grep -E '^jdk8u[0-9]+-ga$' | sort -V | tail -n1)
    [ -n "$REF" ] || { echo "Error: no release (jdk8u<N>-ga) in $(cfg repo)" >&2; exit 1; }
fi
REF_ARM="${OPENJDK8_REF_ARM:-$(cfg ref_arm)}"
if [ "$REF_ARM" = latest ]; then
    REF_ARM=$(git ls-remote --tags --refs "https://github.com/$(cfg repo_arm)" "$REF-aarch32-*" | sed 's|.*refs/tags/||' \
        | sort -V | tail -n1)
    [ -n "$REF_ARM" ] || { echo "Error: no $REF-aarch32-* in $(cfg repo_arm)" >&2; exit 1; }
fi
if [ "$ABI" = --versions ]; then
    printf 'ref=%s\nref_arm=%s\n' "$REF" "$REF_ARM"
    exit 0
fi

# The NDK (config.yaml's sources.openjdk8: r10e, the last with GCC, as PojavLauncher's; HotSpot 8 isn't
# C++ that clang 13+ compiles right: it takes `this` as aligned, which markOop's isn't), a standalone
# toolchain of it in the work (ndk.sh). Its compilers have the sysroot built in: no -I or -L of it, which
# the build would also give the tools it compiles for this machine (bionic's headers in place of glibc's)
mkdir -p "$WORK"
NDK_TOOLCHAIN="$WORK/toolchain"
source "$HERE/../../ndk.sh"
ndk_setup "$ABI" sources.openjdk8
TOOLCHAIN=$NDK_TOOLCHAIN
INCLUDE="$NDK_SYSROOT/usr/include"
# How OpenJDK's configure finds it (--with-devkit)
cat > "$TOOLCHAIN/devkit.info" <<EOF
DEVKIT_NAME="Android $NDK_ARCH"
DEVKIT_TOOLCHAIN_PATH="\$DEVKIT_ROOT/$NDK_TRIPLE/bin"
DEVKIT_SYSROOT="\$DEVKIT_ROOT/sysroot"
EOF
# Linked for 16 KB pages (as the app's every native lib; r10e's x86_64 linker takes 4 KB), whatever links:
# HotSpot's makefiles have their own flags
for ld in "$TOOLCHAIN/$NDK_TRIPLE/bin/ld" "$TOOLCHAIN/bin/$NDK_TRIPLE-ld"; do
    [ -e "$ld.real" ] || mv "$ld" "$ld.real"
    printf '#!/bin/sh\nexec "%s.real" -z max-page-size=16384 "$@"\n' "$ld" > "$ld"
    chmod 755 "$ld"
done

# Each ABI as OpenJDK's build and its lib/ folder name it, and its source (config's repo, or repo_arm:
# the AArch32 port, with its own triple). 32-bit ones get HotSpot's client VM (as PojavLauncher's)
case "$NDK_ARCH" in
    arm64)  TARGET=$NDK_TRIPLE;               JDK_CPU=aarch64; LIB_ARCH=aarch64; VM=server; SRC=repo ;;
    arm)    TARGET=aarch32-linux-androideabi; JDK_CPU=aarch32; LIB_ARCH=aarch32; VM=client; SRC=repo_arm ;;
    x86)    TARGET=$NDK_TRIPLE;               JDK_CPU=x86;     LIB_ARCH=i386;    VM=client; SRC=repo ;;
    x86_64) TARGET=$NDK_TRIPLE;               JDK_CPU=x86_64;  LIB_ARCH=amd64;   VM=server; SRC=repo ;;
esac
REPO=$(cfg "$SRC")
if [ "$SRC" = repo ]; then SRC_REF=$REF; else SRC_REF=$REF_ARM; fi
echo "OpenJDK $REPO@$SRC_REF for $ABI ($TARGET, $VM VM)"
cd "$WORK"

# The source at its tag (fetched, not cloned with -b, which warns of annotated tags), and the patches for it
rm -rf openjdk
git init -q openjdk
git -C openjdk fetch -q --depth 1 "https://github.com/$REPO" "$SRC_REF"
git -C openjdk -c advice.detachedHead=false checkout -q FETCH_HEAD
# patches/ by where they apply: common/ to every ABI, then the source's (repo/, repo_arm/, as config
# names them), then the ABI's own, by the NDK's name of it (arm64/, x86/): numbered in that order
# (common/ 01-09, repo/ 10s, repo_arm/ 20s, the ABI's 30s).
# As PojavLauncher applies its own (the android.patch ones): what no longer fits (a newer update) is
# left out, and said
for dir in common "$SRC" "$NDK_ARCH"; do
    for p in "$HERE/patches/$dir"/*.patch; do
        [ -e "$p" ] || continue
        git -C openjdk apply --reject --whitespace=fix "$p" || echo "::warning::$dir/$(basename "$p"): some hunks didn't apply"
    done
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
# java -version as the release's (1.8.0_504-b01, not -internal and b00): its update and build, of
# OpenJDK's tag (the AArch32 port's is of the same). A -ga one is its last build's commit
version=()
UPDATE=$(sed -nE 's/^jdk8u([0-9]+)-.*/\1/p' <<< "$REF")
BUILD=$(sed -nE 's/^jdk8u[0-9]+-(b[0-9]+).*/\1/p' <<< "$REF")
if [ -n "$UPDATE" ] && [ -z "$BUILD" ]; then
    # Each tag and its commit (an annotated tag's line, then its commit's: ^{})
    tags=$(git ls-remote --tags "https://github.com/$(cfg repo)" "jdk8u$UPDATE-*" | sed 's|refs/tags/||; s|\^{}$||' \
        | awk '{ c[$2] = $1 } END { for (t in c) print c[t], t }')
    commit=$(awk -v t="$REF" '$2 == t { print $1 }' <<< "$tags")
    BUILD=$(awk -v c="$commit" '$1 == c { print $2 }' <<< "$tags" | sed -nE 's/^jdk8u[0-9]+-(b[0-9]+)$/\1/p' | sort -V | tail -n1)
fi
if [ -n "$UPDATE" ] && [ -n "$BUILD" ]; then
    version=(--with-update-version="$UPDATE" --with-build-number="$BUILD" --with-milestone=fcs)
fi
cd openjdk
bash ./configure \
    --openjdk-target="$TARGET" \
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
    --with-freetype=bundled \
    --x-includes="$INCLUDE/X11" \
    --x-libraries=/usr/lib \
    "${boot[@]}" "${version[@]}" \
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

# Android 11+ tags heap pointers (their top byte) on 64-bit ARM, which HotSpot 8's code generator can't
# encode: bin/java loads libtagfix first, which turns that off. HotSpot's monotonic clock comes from
# librt, which bionic doesn't have: one linking libc stands in (dlsym searches what it links)
$CC -shared -fPIC -O2 -Wl,-z,max-page-size=16384 -Wl,-soname,libtagfix.so -o "$LIB/libtagfix.so" "$HERE/libtagfix.c"
echo > "$WORK/empty.c"
$CC -shared -fPIC -Wl,-z,max-page-size=16384 -Wl,-soname,librt.so -Wl,--no-as-needed -o "$LIB/librt.so" "$WORK/empty.c" -lc
patchelf --page-size 16384 --add-needed libtagfix.so "$JRE/bin/java"
# Stripped, and without the DT_RPATH OpenJDK gives them (bionic ignores it, warning each run: java-8
# finds its libraries)
find "$JRE" -type f \( -name '*.so' -o -path '*/bin/*' \) -exec sh -c 'head -c4 "$1" | grep -q ELF' sh {} \; -print0 \
    | while IFS= read -r -d '' f; do
        $STRIP --strip-unneeded "$f"
        patchelf --remove-rpath "$f"
    done

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
jq -n --arg name openjdk8-jre --arg src "$REPO@$SRC_REF" --arg ndk "$(cfg ndk)" --arg api "$ANDROID_API" --arg version "$VERSION" \
    '{name: $name, source: $src, ndk: $ndk, api: $api, version: $version}' > "$OUT/../info-$ABI.json"
echo "Built OpenJDK $VERSION ($SRC_REF) for $ABI: $(du -sh "$OUT" | cut -f1)"
