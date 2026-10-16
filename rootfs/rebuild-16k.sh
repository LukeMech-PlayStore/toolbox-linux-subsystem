#!/data/data/com.termux/files/usr/bin/bash
# Run by build.sh (with STAGE and WORK exported) for every part: its ELF files Termux still ships
# linked for 4 KB pages (packages built before it moved to 16 KB, e.g. libwebp) are rebuilt with
# Termux's own recipe of their package (termux-packages' packages/<name>/build.sh: its source,
# checksum and configure arguments), linked for 16 KB pages, and replace them in $STAGE/usr.
# Nothing to keep up: once Termux rebuilds a package, its files are aligned and nothing happens.
set -euo pipefail

TERMUX_PACKAGES=https://raw.githubusercontent.com/termux/termux-packages/master
export LDFLAGS="-Wl,-z,max-page-size=16384" CC=clang CXX=clang++ AR=llvm-ar

aligned_16k() {
  local align
  for align in $(llvm-readelf -lW "$1" 2>/dev/null | awk '$1 == "LOAD" { print $NF }'); do
    (( align >= 16384 )) || return 1
  done
}
soname() { llvm-readelf -dW "$1" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p'; }

# The NDK's cpufeatures (some Android builds compile it in, e.g. libwebp's), as in the NDK Termux
# builds with; Termux itself has no NDK. Prints the directory to use as ANDROID_NDK
mini_ndk() {
  local ndk="$WORK/ndk" dir=sources/android/cpufeatures version f
  if [ ! -d "$ndk" ]; then
    version=$(curl -fsSL "$TERMUX_PACKAGES/scripts/properties.sh" | sed -n 's/.*TERMUX_NDK_VERSION_NUM:="\([0-9]*\)".*/\1/p')
    mkdir -p "$ndk/$dir"
    for f in cpu-features.c cpu-features.h; do
      curl -fsSL "https://android.googlesource.com/platform/ndk/+/refs/tags/ndk-r$version/$dir/$f?format=TEXT" \
        | base64 -d > "$ndk/$dir/$f" || echo "::warning::No $f in NDK r$version" >&2
    done
  fi
  echo "$ndk"
}

# Builds <package> with its Termux recipe and installs it into $WORK/16k/<package>
rebuild() {
  local package=$1 dest="$WORK/16k/$1" src="$WORK/16k-src/$1"
  [ -d "$dest" ] && return
  echo "Rebuilding $package for 16 KB pages (Termux's recipe)"
  curl -fsSL -o "$WORK/$package.build.sh" "$TERMUX_PACKAGES/packages/$package/build.sh"
  (
    set +u
    TERMUX_PREFIX=$PREFIX TERMUX_PKG_SRCDIR=$src
    termux_error_exit() { echo "::error::$package's recipe: $*"; exit 1; }
    # shellcheck source=/dev/null
    source "$WORK/$package.build.sh"
    urls=("${TERMUX_PKG_SRCURL[@]}") sums=("${TERMUX_PKG_SHA256[@]}")
    [ ${#urls[@]} -eq 1 ] || termux_error_exit "several sources aren't supported"
    curl -fsSL -o "$WORK/$package.src" "${urls[0]}"
    echo "${sums[0]}  $WORK/$package.src" | sha256sum -c -
    mkdir -p "$src" && tar -xf "$WORK/$package.src" -C "$src" --strip-components=1
    cd "$src"
    if declare -F termux_step_post_get_source > /dev/null; then termux_step_post_get_source; fi
    read -r -a args <<< "$(echo $TERMUX_PKG_EXTRA_CONFIGURE_ARGS)"
    # As Termux's build picks the build system
    if [ "$TERMUX_PKG_FORCE_CMAKE" = true ] || { [ ! -f configure ] && [ -f CMakeLists.txt ]; }; then
      command -v cmake > /dev/null || apt-get install -y cmake
      # Unversioned names, as Termux's cross-compiling for Android gets them (what's linked against them)
      cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON -DCMAKE_SKIP_INSTALL_RPATH=ON -DBUILD_TESTING=OFF \
        -DANDROID_NDK="$(mini_ndk)" "${args[@]}"
      cmake --build build -j"$(nproc)"
      DESTDIR="$dest" cmake --install build
    elif [ -f configure ]; then
      ./configure --prefix="$PREFIX" "${args[@]}"
      make -j"$(nproc)" && make install DESTDIR="$dest"
    elif [ -f Makefile ]; then
      make -j"$(nproc)" PREFIX="$PREFIX" && make install DESTDIR="$dest" PREFIX="$PREFIX"
    else
      termux_error_exit "no build system this script knows"
    fi
  )
}

command -v llvm-readelf > /dev/null || apt-get install -y llvm
command -v clang > /dev/null || apt-get install -y clang
command -v make > /dev/null || apt-get install -y make
while IFS= read -r -d '' file; do
  path=${file#"$STAGE/usr/"}
  # 64-bit ELFs only: 32-bit ABIs never run with 16 KB pages
  [ "$(head -c 5 "$file" | od -An -tx1 | tr -d ' \n')" = 7f454c4602 ] || continue
  aligned_16k "$file" && continue
  package=$(dpkg -S "$PREFIX/$path" | head -n1 | cut -d: -f1)
  rebuild "$package"
  built="$WORK/16k/$package$PREFIX/$path"
  [ -f "$built" ] || { echo "::error::Rebuilding $package didn't give $path"; exit 1; }
  # Loadable in place of Termux's: same name for the linker (if it has one), and aligned
  if [ "$(soname "$built")" != "$(soname "$file")" ]; then
    echo "::error::Rebuilt $path is named '$(soname "$built")', Termux's '$(soname "$file")'"
    exit 1
  fi
  aligned_16k "$built" || { echo "::error::Rebuilt $path isn't 16 KB aligned"; exit 1; }
  cp "$built" "$file"
  echo "Rebuilt $path ($package) for 16 KB pages"
done < <(find "$STAGE/usr" -type f -size +0 -print0)
