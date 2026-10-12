#!/bin/bash
set -e

# Load Configuration
source ./config.sh
source ./ndk-setup.sh

# --- Functions ---

prepare_sources() {
    echo "==> Preparing Sources..."
    mkdir -p "$SRC_DIR" "$OUT_DIR"

    # 1. Download Talloc
    if [ ! -d "$SRC_DIR/talloc-$TALLOC_VERSION" ]; then
        echo " -> Downloading Talloc $TALLOC_VERSION..."
        curl -L -f -o "$SRC_DIR/talloc.tar.gz" "https://www.samba.org/ftp/talloc/talloc-$TALLOC_VERSION.tar.gz"
        tar -xzf "$SRC_DIR/talloc.tar.gz" -C "$SRC_DIR"
        rm "$SRC_DIR/talloc.tar.gz"
    fi

    # 2. Download Proot (tarball, so there is no .git for its version check to pick up)
    if [ ! -d "$SRC_DIR/proot" ]; then
        echo " -> Downloading Proot ($PROOT_REF)..."
        mkdir -p "$SRC_DIR/proot"
        curl -L -f -o "$SRC_DIR/proot.tar.gz" "https://github.com/${PROOT_REPO}/archive/${PROOT_REF}.tar.gz"
        tar -xzf "$SRC_DIR/proot.tar.gz" -C "$SRC_DIR/proot" --strip-components=1
        rm "$SRC_DIR/proot.tar.gz"
        cd "$SRC_DIR/proot"

        # Apply Patches
        if [ -d "$PATCH_DIR" ]; then
            echo " -> Applying patches..."
            for patch in "$PATCH_DIR"/*.patch; do
                [ -f "$patch" ] || continue
                echo "   Applying $(basename "$patch")"
                patch -p1 --forward < "$patch" || {
                    echo "Error: Failed to apply $(basename "$patch") to proot $PROOT_REF"
                    exit 1
                }
            done
        fi
        cd - > /dev/null
    fi
}

generate_talloc_answers() {
    local file=$1
    cat <<EOF > "$file"
Checking uname sysname type: "Linux"
Checking uname machine type: "dontcare"
Checking uname release type: "dontcare"
Checking uname version type: "dontcare"
Checking simple C program: OK
rpath library support: OK
-Wl,--version-script support: FAIL
Checking getconf LFS_CFLAGS: OK
Checking for large file support without additional flags: OK
Checking for -D_FILE_OFFSET_BITS=64: $FILE_OFFSET_BITS
Checking for -D_LARGE_FILES: OK
Checking correct behavior of strtoll: OK
Checking for working strptime: OK
Checking for C99 vsnprintf: OK
Checking for HAVE_SHARED_MMAP: OK
Checking for HAVE_MREMAP: OK
Checking for HAVE_INCOHERENT_MMAP: OK
Checking for HAVE_SECURE_MKSTEMP: OK
Checking getconf large file support flags work: OK
Checking for HAVE_IFACE_IFCONF: FAIL
EOF
}

build_arch() {
    local ARCH=$1
    echo "==> Building for Architecture: $ARCH"

    # Define paths for this arch
    local ARCH_BUILD_DIR="$BUILD_DIR/$ARCH"
    local STATIC_ROOT="$ARCH_BUILD_DIR/static-root"

    # Clean build dirs
    rm -rf "$ARCH_BUILD_DIR"
    mkdir -p "$STATIC_ROOT"

    # 1. Setup Environment
    setup_ndk_env "$ARCH" "$ANDROID_API_LEVEL" "$ANDROID_NDK_HOME"

    # 2. Build Talloc (Static)
    echo " -> Building Talloc..."
    cd "$SRC_DIR/talloc-$TALLOC_VERSION"

    generate_talloc_answers "cross-answers-$ARCH.txt"
    make distclean >/dev/null 2>&1 || true

    ./configure build \
        --prefix="$STATIC_ROOT" \
        --disable-rpath \
        --disable-python \
        --cross-compile \
        --cross-answers="cross-answers-$ARCH.txt" > /dev/null

    make -j$(nproc)

    mkdir -p "$STATIC_ROOT/include" "$STATIC_ROOT/lib"
    # Talloc >= 2.4.4 calls libreplace helpers (e.g. rep_memset_explicit). The waf build
    # links libreplace into libtalloc.so, so archive its objects alongside talloc's.
    "$AR" rcs "$STATIC_ROOT/lib/libtalloc.a" bin/default/talloc*.o bin/default/lib/replace/*.o
    cp -f talloc.h "$STATIC_ROOT/include"

    # 3. Build Proot and its loaders (the loaders are built from the same source, so
    #    LOADER_ADDRESS and the proot <-> loader protocol always match)
    echo " -> Building Proot..."
    cd "$SRC_DIR/proot/src"
    make distclean >/dev/null 2>&1 || true

    export CFLAGS="-I$STATIC_ROOT/include -Werror=implicit-function-declaration"
    CFLAGS+=" -DVERSION=\\\"${PROOT_REF#v}\\\""
    CFLAGS+=" -DPROOT_UNBUNDLE_LOADER_NAME=\\\"libproot-loader.so\\\""
    CFLAGS+=" -DPROOT_UNBUNDLE_LOADER_NAME_32=\\\"libproot-loader32.so\\\""
    export LDFLAGS="-L$STATIC_ROOT/lib -Wl,-z,max-page-size=16384"

    # Relative: resolved against the directory of the proot binary (the app's nativeLibraryDir)
    export PROOT_UNBUNDLE_LOADER='.'

    # GIT=false: don't let the version check describe this repository instead of proot
    make -j$(nproc) V=1 GIT=false proot > /dev/null

    # 4. Packaging
    local ABI_DIR="$ARCH"
    if [ "$ARCH" == "arm64" ]; then ABI_DIR="arm64-v8a"; fi
    if [ "$ARCH" == "arm" ]; then ABI_DIR="armeabi-v7a"; fi

    local FINAL_OUT="$OUT_DIR/$ABI_DIR"
    rm -rf "$FINAL_OUT"
    mkdir -p "$FINAL_OUT"

    echo " -> Packaging artifacts into $ABI_DIR..."
    cp ./proot "$FINAL_OUT/libproot.so"
    cp ./loader/loader "$FINAL_OUT/libproot-loader.so"
    if [ -f ./loader/loader-m32 ]; then
        cp ./loader/loader-m32 "$FINAL_OUT/libproot-loader32.so"
    fi

    # 5. Strip Binaries
    echo " -> Stripping binaries..."
    find "$FINAL_OUT" -type f -exec "$STRIP" --strip-unneeded {} \;

    make distclean >/dev/null 2>&1 || true

    echo "==> Finished $ARCH"
}

# --- Main Execution ---

prepare_sources

for ARCH in $TARGET_ARCHS; do
    build_arch "$ARCH"
done

echo "=========================================="
echo "Build Complete. Artifacts in $OUT_DIR"
echo "=========================================="
ls -R "$OUT_DIR"
