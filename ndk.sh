#!/bin/bash
# The NDK, for what's cross-compiled here (proot/build.sh, rootfs/<source>/build.sh): sourced, then
# `ndk_setup <abi> <section>` sets it up for that ABI (a name of config.yaml's android.abis) with the
# NDK and API level of config.yaml's <section> (its ndk and api: e.g. proot, sources.openjdk8; CONFIG to
# read another file). An NDK with clang (r19+) is used as it is; one with GCC alone (r10e, OpenJDK 8's)
# as a standalone toolchain of it for that API level, made in NDK_TOOLCHAIN (by default next to the NDK).
#
# The NDK is ANDROID_NDK_HOME's (setup-ndk's in CI), else downloaded into NDK_CACHE (~/.cache/ndk).
# Exported: CC and CXX (its compilers for the ABI and API, the sysroot built in), AR, LD, NM, OBJCOPY,
# OBJDUMP, RANLIB, READELF and STRIP (clang's NDK: LLVM's; GCC's: its binutils, and AS), ANDROID_NDK_HOME,
# NDK_SYSROOT, NDK_TRIPLE (the compilers' target), NDK_ARCH (the NDK's name of the ABI), ANDROID_API, and
# NDK_TOOLCHAIN (GCC's: the standalone toolchain).

NDK_CONFIG="${CONFIG:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/config.yaml}"

ndk_cfg() {
    local value
    value=$(yq -r "$1" "$NDK_CONFIG")
    if [ -z "$value" ] || [ "$value" = null ]; then
        echo "Error: $1 is missing in $NDK_CONFIG" >&2
        exit 1
    fi
    echo "$value"
}

ndk_setup() {
    local abi="$1" section="${2:?usage: ndk_setup <abi> <config section>}"
    local version
    version=$(ndk_cfg ".$section.ndk")
    ANDROID_API=$(ndk_cfg ".$section.api")
    NDK_ARCH=$(ndk_cfg ".android.abis[\"$abi\"].ndk_arch")
    case "$NDK_ARCH" in
        arm64|arm|x86|x86_64) ;;
        *) echo "Error: unknown NDK arch $NDK_ARCH ($abi)" >&2; exit 1 ;;
    esac

    if [ -z "${ANDROID_NDK_HOME:-}" ]; then
        local cache="${NDK_CACHE:-$HOME/.cache/ndk}"
        ANDROID_NDK_HOME="$cache/android-ndk-$version"
        if [ ! -d "$ANDROID_NDK_HOME" ]; then
            mkdir -p "$cache"
            # Named for the host since r23 no longer
            wget -nv -O "$ANDROID_NDK_HOME.zip" "https://dl.google.com/android/repository/android-ndk-$version-linux.zip" \
                || wget -nv -O "$ANDROID_NDK_HOME.zip" "https://dl.google.com/android/repository/android-ndk-$version-linux-x86_64.zip"
            unzip -q "$ANDROID_NDK_HOME.zip" -d "$cache"
            rm "$ANDROID_NDK_HOME.zip"
        fi
    fi

    local tools="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
    if [ -x "$tools/bin/clang" ]; then
        case "$NDK_ARCH" in
            arm64)  NDK_TRIPLE=aarch64-linux-android ;;
            arm)    NDK_TRIPLE=armv7a-linux-androideabi ;;
            x86)    NDK_TRIPLE=i686-linux-android ;;
            x86_64) NDK_TRIPLE=x86_64-linux-android ;;
        esac
        NDK_SYSROOT="$tools/sysroot"
        NDK_TOOLCHAIN=
        export CC="$tools/bin/$NDK_TRIPLE$ANDROID_API-clang" CXX="$tools/bin/$NDK_TRIPLE$ANDROID_API-clang++"
        export AR="$tools/bin/llvm-ar" NM="$tools/bin/llvm-nm" OBJCOPY="$tools/bin/llvm-objcopy"
        export OBJDUMP="$tools/bin/llvm-objdump" RANLIB="$tools/bin/llvm-ranlib" READELF="$tools/bin/llvm-readelf"
        export STRIP="$tools/bin/llvm-strip" LD="$tools/bin/ld.lld"
    elif [ -x "$ANDROID_NDK_HOME/build/tools/make-standalone-toolchain.sh" ]; then
        case "$NDK_ARCH" in
            arm64)  NDK_TRIPLE=aarch64-linux-android ;;
            arm)    NDK_TRIPLE=arm-linux-androideabi ;;
            x86)    NDK_TRIPLE=i686-linux-android ;;
            x86_64) NDK_TRIPLE=x86_64-linux-android ;;
        esac
        NDK_TOOLCHAIN="${NDK_TOOLCHAIN:-$ANDROID_NDK_HOME-toolchains/$NDK_ARCH-$ANDROID_API}"
        if [ ! -d "$NDK_TOOLCHAIN" ]; then
            # Its scripts find it by this
            ANDROID_NDK_ROOT="$ANDROID_NDK_HOME" "$ANDROID_NDK_HOME/build/tools/make-standalone-toolchain.sh" \
                --arch="$NDK_ARCH" --platform="android-$ANDROID_API" --install-dir="$NDK_TOOLCHAIN"
        fi
        NDK_SYSROOT="$NDK_TOOLCHAIN/sysroot"
        local bin="$NDK_TOOLCHAIN/bin/$NDK_TRIPLE"
        export CC="$bin-gcc" CXX="$bin-g++" AR="$bin-ar" AS="$bin-as" NM="$bin-nm" OBJCOPY="$bin-objcopy"
        export OBJDUMP="$bin-objdump" RANLIB="$bin-ranlib" READELF="$bin-readelf" STRIP="$bin-strip" LD="$bin-ld"
    else
        echo "Error: no NDK compilers in $ANDROID_NDK_HOME" >&2
        exit 1
    fi

    export ANDROID_NDK_HOME ANDROID_API NDK_ARCH NDK_TRIPLE NDK_SYSROOT NDK_TOOLCHAIN
    echo " -> NDK $version for $abi ($NDK_TRIPLE, API $ANDROID_API)"
}
