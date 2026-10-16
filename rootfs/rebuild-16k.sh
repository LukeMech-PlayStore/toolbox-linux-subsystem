#!/data/data/com.termux/files/usr/bin/bash
# Run by build.sh (with STAGE and WORK exported) for every part: its ELF files Termux still ships
# linked for 4 KB pages (packages built before it moved to 16 KB, e.g. libwebp) are rebuilt with
# Termux's own recipe of their package (termux-build.sh), linked for 16 KB pages, and replace them in
# $STAGE/usr. Nothing to keep up: once Termux rebuilds a package, its files are aligned and nothing happens.
set -euo pipefail
HERE=$(dirname "$(readlink -f "$0")")

aligned_16k() {
  local align
  for align in $(llvm-readelf -lW "$1" 2>/dev/null | awk '$1 == "LOAD" { print $NF }'); do
    (( align >= 16384 )) || return 1
  done
}
soname() { llvm-readelf -dW "$1" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p'; }

command -v llvm-readelf > /dev/null || apt-get install -y llvm
while IFS= read -r -d '' file; do
  path=${file#"$STAGE/usr/"}
  # 64-bit ELFs only: 32-bit ABIs never run with 16 KB pages
  [ "$(head -c 5 "$file" | od -An -tx1 | tr -d ' \n')" = 7f454c4602 ] || continue
  aligned_16k "$file" && continue
  package=$(dpkg -S "$PREFIX/$path" | head -n1 | cut -d: -f1)
  bash "$HERE/termux-build.sh" "$package" "$WORK/16k/$package"
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
