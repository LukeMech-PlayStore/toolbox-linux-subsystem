#!/data/data/com.termux/files/usr/bin/bash
# Run by build.sh on the jdk part's files (STAGE: its folder, usr/ the Termux prefix).
# bin/java: OpenJDK's programs are update-alternatives' links, made by its maintainer script and no
# package's file, so not exported; the app runs java by this name.
set -euo pipefail

JDK=$(cd "$STAGE/usr/lib/jvm" && ls -d java-25-openjdk* | head -n1)
[ -x "$STAGE/usr/lib/jvm/$JDK/bin/java" ] || { echo "::error::No java in the jdk part's $JDK"; exit 1; }
mkdir -p "$STAGE/usr/bin"
ln -sf "../lib/jvm/$JDK/bin/java" "$STAGE/usr/bin/java"
