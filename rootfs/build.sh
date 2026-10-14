#!/data/data/com.termux/files/usr/bin/bash
# Runs inside termux/termux-docker (as its "system" user):
#   bash build.sh <image version> "<packages>" "<build packages>" "<pip args>"
# Installs the packages and leaves a rootfs in ~/rootfs holding only their files (with their
# dependencies) and whatever pip added - not the rest of the Termux bootstrap (apt, bash, ...).
# The Termux prefix goes to usr/; the app binds it back to $PREFIX inside proot.
# Manifests go to ~/out.
set -euo pipefail

IMAGE_VERSION=$1
PKGS=$2
BUILD_PKGS=$3
PIP_ARGS=$4

STAGE="$HOME/rootfs"
OUT="$HOME/out"
WORK="$HOME/work"
mkdir -p "$STAGE/usr" "$OUT" "$WORK"

# Docker-only stand-ins for what Android itself provides
EXCLUDE='^(aosp-libs|aosp-utils|libandroid-stub|resolv-conf)$'
# Not needed at runtime (EREs on paths relative to $PREFIX)
PERL='lib/perl5/[^/]+/([^/]+-android/)?(auto/)?'
PRUNE_PATTERNS=(
  # Docs, headers, static libs, bytecode
  'share/(man|doc|info|locale|lintian)/' 'include/' '.*\.h$' 'lib/.*\.a$' '.*/__pycache__/' '.*\.py[co]$' '.*\.pod$'
  # Python: tests, dev tools, REPL, pure-python fallbacks of C modules
  'lib/python3[^/]*/(test|idlelib|ensurepip|pydoc_data|tkinter|turtledemo|unittest|_pyrepl|__phello__|config-[^/]*)/'
  'lib/python3[^/]*/_pydecimal\.py$' 'lib/python3[^/]*/lib-dynload/(_test|_ctypes_test|xx)[^/]*$'
  # Perl: module building, tests, docs, debugger
  "$PERL(CPAN|ExtUtils|TAP|Test|Test2|Pod|Devel|App|Module/CoreList)(/|\.pm$)"
  'lib/perl5/[^/]+/(perl5db\.pl|unicore/TestNorm\.pl)$'
  # Tools nothing calls (only python3, perl, exiftool, qjs and pip's scripts are)
  'bin/(cpan|corelist|enc2xs|encguess|h2ph|h2xs|instmodsh|json_pp|libnetcfg|perldoc|perlivp|perlthanks|perlbug|piconv|pl2pm|pod2[a-z]+|podchecker|prove|ptar[a-z]*|py3clean|py3compile|pydoc[.0-9]*|python[.0-9]*-config|shasum|splain|streamzip|xsubpp|zipdetails|gdbm[a-z_]*|zstd[a-z]*|unzstd|ncursesw6-config|clear|tset|reset|tabs|tic|toe|tput|infocmp|captoinfo|infotocap|idle3[.0-9]*)$'
  # Unused by the app's features (exiftool only needs Encode for UTF-8; Geolocation.dat is
  # for its -geolocation option; no script uses sqlite)
  "${PERL}Encode/(JP|KR|CN|TW)(/|\.pm$)" "${PERL}Unicode/Collate(/|\.pm$)"
  'lib/perl5/site_perl/[^/]+/Image/ExifTool/Geolocation\.dat$'
  'lib/libsqlite3[^/]*$' 'lib/python3[^/]*/(sqlite3/|lib-dynload/_sqlite3)'
  # Terminal bits (REPL line editing, curses) and gdbm, for nothing run non-interactively
  'lib/(libncurses|libtinfo|libform|libmenu|libpanel|libreadline|libhistory|libgdbm)[^/]*$'
  'lib/python3[^/]*/lib-dynload/(readline|_curses|_gdbm)[^/]*$' 'lib/python3[^/]*/curses/' 'share/(terminfo|tabset)/'
)
PRUNE="^($(IFS='|'; echo "${PRUNE_PATTERNS[*]}"))"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::=--force-confnew upgrade
# shellcheck disable=SC2086
apt-get install -y $PKGS

snapshot() { find "$PREFIX" -path "$PREFIX/tmp" -prune -o \( -type f -o -type l \) -print | sort; }

: > "$WORK/pip-files"
: > "$OUT/manifest-pip.txt"
if [ -n "$PIP_ARGS" ]; then
  # shellcheck disable=SC2086
  apt-get install -y python-pip $BUILD_PKGS
  snapshot > "$WORK/before"
  # Termux builds with 16 KB pages in mind, make sure locally built modules are too
  # shellcheck disable=SC2086
  LDFLAGS="-Wl,-z,max-page-size=16384" pip install --no-cache-dir --no-compile --break-system-packages $PIP_ARGS
  snapshot > "$WORK/after"
  comm -13 "$WORK/before" "$WORK/after" > "$WORK/pip-files"

  { grep '\.dist-info/METADATA$' "$WORK/pip-files" || true; } | while IFS= read -r meta; do
    echo "$(sed -n 's/^Name: //p' "$meta" | head -n1)==$(sed -n 's/^Version: //p' "$meta" | head -n1)"
  done | sort > "$OUT/manifest-pip.txt"
fi

# Requested packages with everything they depend on
# shellcheck disable=SC2086
apt-cache depends --recurse --installed --no-recommends --no-suggests --no-conflicts \
    --no-breaks --no-replaces --no-enhances $PKGS \
  | grep -v '^[ <]' | sort -u | grep -Ev "$EXCLUDE" > "$WORK/closure"

xargs dpkg-query -W -f='${Package}-${Version}\n' < "$WORK/closure" | sort > "$OUT/manifest-pkg.txt"

{
  xargs dpkg -L < "$WORK/closure" | while IFS= read -r f; do
    if [ -f "$f" ] || [ -L "$f" ]; then echo "$f"; fi
  done
  cat "$WORK/pip-files"
} | sed "s|^$PREFIX/||" | grep -v '^/' | grep -Ev "$PRUNE" | sort -u > "$WORK/files"

tar -C "$PREFIX" --no-recursion -cf - -T "$WORK/files" | tar -C "$STAGE/usr" -xf -

# Parts with scripts of their own (next to this one)
export STAGE OUT WORK
HERE=$(dirname "$(readlink -f "$0")")
if grep -qx 'lib/libandroid-utimes.so' "$WORK/files"; then
  bash "$HERE/libandroid-utimes.sh"
fi
bash "$HERE/ffmpeg.sh"

# Termux scripts start with $PREFIX/bin/env (e.g. exiftool) and tools call $PREFIX/bin/sh; both
# come with the bootstrap, not as dependencies. Android's own can't stand in: on some devices
# (Samsung) proot can't execute anything from /system/bin (EPERM). So scripts get their
# interpreter directly, like termux-fix-shebang does, and sh is dash (see config.yaml).
find "$STAGE/usr/bin" -type f | while IFS= read -r f; do
  head -n1 "$f" | grep -q "^#!$PREFIX/bin/env " || continue
  sed -i "1s|^#!$PREFIX/bin/env *|#!$PREFIX/bin/|" "$f"
  interpreter=$(head -n1 "$f" | sed 's|^#!||; s| .*||')
  [ -e "$STAGE/usr${interpreter#"$PREFIX"}" ] || { echo "::error::${f#"$STAGE/"} runs $interpreter, which isn't in the rootfs"; exit 1; }
done
[ -e "$STAGE/usr/bin/sh" ] || ln -s dash "$STAGE/usr/bin/sh"

mkdir -p "$STAGE/etc" "$STAGE/root" "$STAGE/tmp" "$STAGE/usr/tmp"
echo "$IMAGE_VERSION" > "$STAGE/etc/image-version"

echo "Exported $(wc -l < "$WORK/files") files from $(wc -l < "$WORK/closure") packages"
