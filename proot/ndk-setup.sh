#!/bin/bash

setup_ndk_env() {
    local target_arch="$1"
    local api_level="$2"
    local ndk_home="$3"

    if [ -z "$ndk_home" ]; then
        echo "Error: ANDROID_NDK_HOME is not set."
        exit 1
    fi

    local dest_cpu
    local toolchain_prefix
    local host_os="linux"
    local host_arch="x86_64"
    
    # Reset flags to ensure no pollution from previous runs
    unset CFLAGS LDFLAGS CXXFLAGS

    case ${target_arch} in
        arm)
            dest_cpu="arm"
            toolchain_prefix="armv7a-linux-androideabi"
            ;;
        x86)
            dest_cpu="ia32"
            toolchain_prefix="i686-linux-android"
            ;;
        x86_64)
            dest_cpu="x64"
            toolchain_prefix="x86_64-linux-android"
            ;;
        arm64|aarch64)
            dest_cpu="arm64"
            toolchain_prefix="aarch64-linux-android"
            target_arch="arm64"
            ;;
        *)
            echo "Error: Invalid architecture $target_arch"
            exit 1
            ;;
    esac

    local toolchain_bin="${ndk_home}/toolchains/llvm/prebuilt/${host_os}-${host_arch}/bin"

    export CC="${toolchain_bin}/${toolchain_prefix}${api_level}-clang"
    export CXX="${toolchain_bin}/${toolchain_prefix}${api_level}-clang++"
    export AR="${toolchain_bin}/llvm-ar"
    export LD="${toolchain_bin}/llvm-ld"
    export STRIP="${toolchain_bin}/llvm-strip"
    export OBJCOPY="${toolchain_bin}/llvm-objcopy"
    export OBJDUMP="${toolchain_bin}/llvm-objdump"
    export RANLIB="${toolchain_bin}/llvm-ranlib"

    # Critical: cpufeatures needed for Node/V8 based stuff, beneficial for proot
    export CFLAGS="-I${ndk_home}/sources/android/cpufeatures -fPIC"
    
    # 64-bit off_t is available on every supported API level
    export FILE_OFFSET_BITS="OK"

    echo " -> Configured env for: $target_arch (API $api_level)"
}