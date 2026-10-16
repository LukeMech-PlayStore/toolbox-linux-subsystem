#!/data/data/com.termux/files/usr/bin/bash
# termux-build.sh <package> <dest> [<configure option to drop>...]
# Builds a Termux package as termux-packages' recipe of it does (packages/<package>/: its source and
# checksum, its patches, its configure step), natively in termux-docker and linked for 16 KB pages,
# and installs it into <dest> (DESTDIR: <dest>$PREFIX/...). The recipe's configure options listed
# are left out as configure is called (e.g. FFmpeg's --enable-libaom). Run by build.sh (rebuilt
# packages, see config.yaml) and rebuild-16k.sh, with WORK exported.
set -euo pipefail

package=$1 dest=$2
shift 2
DROP=("$@")
REPO="$WORK/termux-packages"
src="$WORK/src-$package"
build="$WORK/build-$package"

[ -d "$dest" ] && exit 0
echo "Building $package with Termux's recipe${DROP:+, without ${DROP[*]}}"

for tool in git:git clang:clang make:make pkg-config:pkg-config llvm-nm:llvm; do
  command -v "${tool%%:*}" > /dev/null || apt-get install -y "${tool#*:}"
done
# The recipes, only what's used of them
if [ ! -d "$REPO" ]; then
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/termux/termux-packages "$REPO"
  git -C "$REPO" sparse-checkout set scripts
fi
git -C "$REPO" sparse-checkout add "packages/$package"
recipe="$REPO/packages/$package"

# As Termux's toolchain has them for its packages (natively: the host is the target)
export TERMUX_PREFIX=$PREFIX TERMUX_PKG_BUILDER_DIR=$recipe TERMUX_PKG_SRCDIR=$src TERMUX_PKG_BUILDDIR=$build
export TERMUX_ARCH=$(dpkg --print-architecture)
case $TERMUX_ARCH in
  aarch64) TERMUX_HOST_PLATFORM=aarch64-linux-android TERMUX_ARCH_BITS=64 ;;
  arm) TERMUX_HOST_PLATFORM=arm-linux-androideabi TERMUX_ARCH_BITS=32 ;;
  i686) TERMUX_HOST_PLATFORM=i686-linux-android TERMUX_ARCH_BITS=32 ;;
  x86_64) TERMUX_HOST_PLATFORM=x86_64-linux-android TERMUX_ARCH_BITS=64 ;;
esac
export TERMUX_HOST_PLATFORM TERMUX_ARCH_BITS
export CC=clang CXX=clang++ AS=clang AR=llvm-ar NM=llvm-nm RANLIB=llvm-ranlib STRIP=llvm-strip \
  PKG_CONFIG=pkg-config CFLAGS="" CXXFLAGS="" CPPFLAGS="" LDFLAGS="-Wl,-z,max-page-size=16384"

# The NDK's cpufeatures (some Android builds compile it in, e.g. libwebp's), from the NDK Termux
# builds with: Termux's NDK packages (ndk-sysroot, ndk-multilib) have its headers and libraries, not
# its sources/. Prints the directory to use as ANDROID_NDK
mini_ndk() {
  local ndk="$WORK/ndk" dir=sources/android/cpufeatures version f
  if [ ! -d "$ndk" ]; then
    version=$(sed -n 's/.*TERMUX_NDK_VERSION_NUM:="\([0-9]*\)".*/\1/p' "$REPO/scripts/properties.sh")
    mkdir -p "$ndk/$dir"
    for f in cpu-features.c cpu-features.h; do
      curl -fsSL "https://android.googlesource.com/platform/ndk/+/refs/tags/ndk-r$version/$dir/$f?format=TEXT" \
        | base64 -d > "$ndk/$dir/$f" || echo "::warning::No $f in NDK r$version" >&2
    done
  fi
  echo "$ndk"
}

# The recipe's options, minus those dropped
keep() {
  local arg d
  for arg in "$@"; do
    for d in "${DROP[@]}"; do [ "$arg" = "$d" ] && continue 2; done
    printf '%s\n' "$arg"
  done
}

set +u
termux_error_exit() { echo "::error::$package's recipe: $*"; exit 1; }
# shellcheck source=/dev/null
source "$recipe/build.sh"

# Its build tools, as its recipe lists them
deps=$(echo "${TERMUX_PKG_BUILD_DEPENDS:-}" | tr ',' '\n' | sed 's/([^)]*)//; s/|.*//; s/ //g' | grep . || true)
[ -z "$deps" ] || apt-get install -y $deps

urls=("${TERMUX_PKG_SRCURL[@]}") sums=("${TERMUX_PKG_SHA256[@]}")
[ ${#urls[@]} -eq 1 ] || termux_error_exit "several sources aren't supported"
curl -fsSL -o "$WORK/$package.src" "${urls[0]}"
echo "${sums[0]}  $WORK/$package.src" | sha256sum -c -
rm -rf "$src" "$build"
mkdir -p "$src" "$build"
tar -xf "$WORK/$package.src" -C "$src" --strip-components=1

# Its patches, as termux_step_patch_package applies them (with its placeholders filled in)
cd "$src"
for patch in "$recipe"/*.patch "$recipe"/*.patch"$TERMUX_ARCH_BITS"; do
  [ -f "$patch" ] || continue
  sed -e "s%@TERMUX_PREFIX@%$PREFIX%g" -e "s%@TERMUX_BASE_DIR@%${PREFIX%/usr}%g" \
    -e "s%@TERMUX_HOME@%${PREFIX%/usr}/home%g" -e "s%@TERMUX_APP_PACKAGE@%com.termux%g" \
    -e "s%@TERMUX_CACHE_DIR@%/data/data/com.termux/cache%g" "$patch" | patch -s -p1
done
if declare -F termux_step_post_get_source > /dev/null; then termux_step_post_get_source; fi
if declare -F termux_step_pre_configure > /dev/null; then termux_step_pre_configure; fi

if declare -F termux_step_configure > /dev/null; then
  # Its own configure step, through a configure that leaves out what's dropped
  shim="$WORK/shim-$package"
  mkdir -p "$shim"
  {
    echo '#!/data/data/com.termux/files/usr/bin/bash'
    echo "DROP=($(printf '%q ' "${DROP[@]}"))"
    declare -f keep
    echo "mapfile -t args < <(keep \"\$@\")"
    # Through sh: configure scripts start with #!/bin/sh, which Termux hasn't (its build host has)
    echo "exec sh $(printf '%q' "$src/configure") \"\${args[@]}\""
  } > "$shim/configure"
  chmod 755 "$shim/configure"
  TERMUX_PKG_SRCDIR=$shim termux_step_configure
  cd "$build"
  make -j"$(nproc)"
  make install DESTDIR="$dest"
else
  mapfile -t args < <(keep $(echo $TERMUX_PKG_EXTRA_CONFIGURE_ARGS))
  # As Termux's build picks the build system
  if [ "$TERMUX_PKG_FORCE_CMAKE" = true ] || { [ ! -f configure ] && [ -f CMakeLists.txt ]; }; then
    command -v cmake > /dev/null || apt-get install -y cmake
    # Unversioned names, as Termux's cross-compiling for Android gets them (what's linked against them)
    cmake -S . -B "$build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON -DCMAKE_SKIP_INSTALL_RPATH=ON -DBUILD_TESTING=OFF \
      -DANDROID_NDK="$(mini_ndk)" "${args[@]}"
    cmake --build "$build" -j"$(nproc)"
    DESTDIR="$dest" cmake --install "$build"
  elif [ -f configure ]; then
    sh ./configure --prefix="$PREFIX" "${args[@]}"
    make -j"$(nproc)" && make install DESTDIR="$dest"
  elif [ -f Makefile ]; then
    make -j"$(nproc)" PREFIX="$PREFIX" && make install DESTDIR="$dest" PREFIX="$PREFIX"
  else
    termux_error_exit "no build system this script knows"
  fi
fi
if declare -F termux_step_post_massage > /dev/null; then
  TERMUX_PKG_MASSAGEDIR=$dest termux_step_post_massage
fi
