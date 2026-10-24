#!/bin/bash
# The NDK, for what's cross-compiled here (proot/build.sh, rootfs/<source>/build.sh): sourced, then
# `ndk_setup <abi>` (a name of config.yaml's android.abis) sets it up for that ABI, with config.yaml's
# android.ndk and android.api (CONFIG to read another file).
#
# The NDK is ANDROID_NDK_HOME's (setup-ndk's in CI), else downloaded into NDK_CACHE (~/.cache/ndk).
# Exported: CC and CXX (its clang for the ABI and API, the sysroot built in), AR, NM, OBJCOPY, OBJDUMP,
# RANLIB, READELF, STRIP and LD (LLVM's), ANDROID_NDK_HOME, NDK_SYSROOT, NDK_TRIPLE (clang's target),
# NDK_ARCH (the NDK's name of the ABI) and ANDROID_API.

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
    local abi="$1"
    local version
    version=$(ndk_cfg .android.ndk)
    ANDROID_API=$(ndk_cfg .android.api)
    NDK_ARCH=$(ndk_cfg ".android.abis[\"$abi\"].ndk_arch")
    case "$NDK_ARCH" in
        arm64)  NDK_TRIPLE=aarch64-linux-android ;;
        arm)    NDK_TRIPLE=armv7a-linux-androideabi ;;
        x86)    NDK_TRIPLE=i686-linux-android ;;
        x86_64) NDK_TRIPLE=x86_64-linux-android ;;
        *) echo "Error: unknown NDK arch $NDK_ARCH ($abi)" >&2; exit 1 ;;
    esac

    if [ -z "${ANDROID_NDK_HOME:-}" ]; then
        local cache="${NDK_CACHE:-$HOME/.cache/ndk}"
        ANDROID_NDK_HOME="$cache/android-ndk-$version"
        if [ ! -d "$ANDROID_NDK_HOME" ]; then
            mkdir -p "$cache"
            wget -nv -O "$ANDROID_NDK_HOME.zip" "https://dl.google.com/android/repository/android-ndk-$version-linux.zip"
            unzip -q "$ANDROID_NDK_HOME.zip" -d "$cache"
            rm "$ANDROID_NDK_HOME.zip"
        fi
    fi
    local tools="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
    [ -x "$tools/bin/clang" ] || { echo "Error: no NDK clang in $ANDROID_NDK_HOME" >&2; exit 1; }
    NDK_SYSROOT="$tools/sysroot"

    export ANDROID_NDK_HOME ANDROID_API NDK_ARCH NDK_TRIPLE NDK_SYSROOT
    export CC="$tools/bin/$NDK_TRIPLE$ANDROID_API-clang" CXX="$tools/bin/$NDK_TRIPLE$ANDROID_API-clang++"
    export AR="$tools/bin/llvm-ar" NM="$tools/bin/llvm-nm" OBJCOPY="$tools/bin/llvm-objcopy" OBJDUMP="$tools/bin/llvm-objdump"
    export RANLIB="$tools/bin/llvm-ranlib" READELF="$tools/bin/llvm-readelf" STRIP="$tools/bin/llvm-strip" LD="$tools/bin/ld.lld"
    echo " -> NDK $version for $abi ($NDK_TRIPLE, API $ANDROID_API)"
}
