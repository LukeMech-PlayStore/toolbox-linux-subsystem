#!/data/data/com.termux/files/usr/bin/bash
# Run by build.sh on a jdk part's files (STAGE: its folder, usr/ the Termux prefix).
# bin/java-<version>: OpenJDK's programs are update-alternatives' links, made by its maintainer script
# and no package's file, so not exported; the app runs a version's java by this name (two parts'
# bin/java would be the same file, see config.yaml's jdk parts).
set -euo pipefail

found=
for jdk in "$STAGE"/usr/lib/jvm/java-*-openjdk*; do
  [ -x "$jdk/bin/java" ] || continue
  version=$(basename "$jdk" | sed -E 's/^java-([0-9]+)-.*/\1/')
  mkdir -p "$STAGE/usr/bin"
  ln -sf "../lib/jvm/$(basename "$jdk")/bin/java" "$STAGE/usr/bin/java-$version"
  found=1
done
[ -n "$found" ] || { echo "::error::No java in this jdk part"; exit 1; }
