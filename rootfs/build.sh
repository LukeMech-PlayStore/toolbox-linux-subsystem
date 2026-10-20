#!/data/data/com.termux/files/usr/bin/bash
# Runs inside termux/termux-docker (as its "system" user):
#   bash build.sh <image version> <config.yaml as JSON>
# Installs everything config.yaml asks for and leaves the rootfs parts in ~/rootfs/<part> (core
# and the others), each holding only its packages' files (with their dependencies, minus what
# the parts it builds on have, and minus what its packages don't use of them) and what pip added
# for it - not the rest of the Termux bootstrap (apt, bash, ...), nor the build packages. The
# Termux prefix goes to usr/; the app binds it back to $PREFIX inside proot.
# Manifests and components (what the app tells a part holds), one of each per part, go to ~/out.
set -euo pipefail

IMAGE_VERSION=$1
CONFIG=$2

ROOT="$HOME/rootfs"
OUT="$HOME/out"
WORK="$HOME/work"
HERE=$(dirname "$(readlink -f "$0")")
mkdir -p "$ROOT" "$OUT" "$WORK"

# Docker-only stand-ins for what Android itself provides
EXCLUDE='^(aosp-libs|aosp-utils|libandroid-stub|resolv-conf)$'
# Not needed at runtime (EREs on paths relative to $PREFIX)
PERL='lib/perl5/[^/]+/([^/]+-android/)?(auto/)?'
PRUNE_PATTERNS=(
  # Docs, headers, static libs, bytecode, GObject introspection's XML (for building bindings)
  'share/(man|doc|info|locale|lintian|gir-1\.0)/' 'include/' '.*\.h$' 'lib/.*\.a$' '.*/__pycache__/' '.*\.py[co]$' '.*\.pod$'
  # Build files, GObject introspection's typelibs, shell completions, patch leftovers
  'lib/(cmake|pkgconfig|girepository-1\.0)/' 'share/(aclocal|pkgconfig|bash-completion|fish|zsh)/' '.*\.orig$'
  # GLib's schemas and codegen, Python packages' tests, libmysofa's HRTF samples (sofalizer
  # only loads the file it's given)
  'share/(glib-2\.0|libmysofa)/' 'lib/python3[^/]*/site-packages/Cryptodome/SelfTest/'
  # Python: tests, dev tools, REPL, pure-python fallbacks of C modules
  'lib/python3[^/]*/(test|idlelib|ensurepip|pydoc_data|tkinter|turtledemo|unittest|_pyrepl|__phello__|config-[^/]*)/'
  'lib/python3[^/]*/_pydecimal\.py$' 'lib/python3[^/]*/lib-dynload/(_test|_ctypes_test|xx)[^/]*$'
  # Perl: module building, tests, docs, debugger
  "$PERL(CPAN|ExtUtils|TAP|Test|Test2|Pod|Devel|App|Module/CoreList)(/|\.pm$)"
  'lib/perl5/[^/]+/(perl5db\.pl|unicore/TestNorm\.pl)$'
  # Tools nothing calls (only python3, perl, exiftool, qjs and pip's scripts are)
  'bin/(cpan|corelist|enc2xs|encguess|h2ph|h2xs|instmodsh|json_pp|libnetcfg|perldoc|perlivp|perlthanks|perlbug|piconv|pl2pm|pod2[a-z]+|podchecker|prove|ptar[a-z]*|py3clean|py3compile|pydoc[.0-9]*|python[.0-9]*-config|shasum|splain|streamzip|xsubpp|zipdetails|gdbm[a-z_]*|zstd[a-z]*|unzstd|qjsc|ncursesw6-config|clear|tset|reset|tabs|tic|toe|tput|infocmp|captoinfo|infotocap|idle3[.0-9]*)$'
  # Unused by the app's features (exiftool only needs Encode for UTF-8; Geolocation.dat is
  # for its -geolocation option, Lang/ its tag names translated, for -lang; no script uses sqlite)
  "${PERL}Encode/(JP|KR|CN|TW)(/|\.pm$)" "${PERL}Unicode/Collate(/|\.pm$)"
  'lib/perl5/site_perl/[^/]+/Image/ExifTool/(Geolocation\.dat|Lang/)'
  'lib/libsqlite3[^/]*$' 'lib/python3[^/]*/(sqlite3/|lib-dynload/_sqlite3)'
  # Terminal bits (REPL line editing, curses) and gdbm, for nothing run non-interactively
  'lib/(libncurses|libtinfo|libform|libmenu|libpanel|libreadline|libhistory|libgdbm)[^/]*$'
  'lib/python3[^/]*/lib-dynload/(readline|_curses|_gdbm)[^/]*$' 'lib/python3[^/]*/curses/' 'share/(terminfo|tabset)/'
  # OpenJDK: what only building and linking Java needs (jlink's modules, javac's symbols, its sources), docs, demos
  'lib/jvm/[^/]+/(jmods|man|include|demo)/' 'lib/jvm/[^/]+/lib/(src\.zip|ct\.sym)$'
)
PRUNE="^($(IFS='|'; echo "${PRUNE_PATTERNS[*]}"))"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::=--force-confnew upgrade
apt-get install -y jq

echo "$CONFIG" > "$WORK/config.json"
cfg() { jq -r "$@" "$WORK/config.json"; }
# Where a part's settings are in the config
part_of() { echo ".packages[\"$1\"]"; }
list_of() { cfg "($(part_of "$1") // {}) | (.$2 // [])[]"; }

# The core first, then the parts building on it (listed before what builds on them)
mapfile -t PARTS < <(echo core; cfg '(.packages // {}) | keys_unsorted[] | select(. != "core")')
mapfile -t PKGS < <(for p in "${PARTS[@]}"; do list_of "$p" packages; done | sort -u)
mapfile -t PIP < <(for p in "${PARTS[@]}"; do list_of "$p" pip; done)
# The libraries the pip packages are compiled against
mapfile -t PIP_LIBS < <(for p in "${PARTS[@]}"; do list_of "$p" pip_libs; done | sort -u)
# Installed for pip, never exported (left out of every part, with what only they need)
mapfile -t BUILD_PKGS < <(cfg '(.build_packages // [])[]')
read -r -a PIP_OPTIONS <<< "$(for p in "${PARTS[@]}"; do cfg "$(part_of "$p").pip_options // empty"; done | xargs)"

# pip first, with only its libraries and the build packages there: a build picks up whatever
# optional library it finds (Pillow linked FFmpeg's libtiff), which its part wouldn't have
if [ ${#PIP[@]} -gt 0 ]; then
  apt-get install -y "${BUILD_PKGS[@]}" "${PIP_LIBS[@]}"
  # Termux builds with 16 KB pages in mind, make sure locally built modules are too; without debug
  # info (-S), which named pip's random build folder: the same package built anew came out different
  # (a new part version every release), and it was most of Pillow's modules
  LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-S" pip install --no-cache-dir --no-compile --break-system-packages \
    "${PIP_OPTIONS[@]}" "${PIP[@]}"
fi
apt-get install -y "${PKGS[@]}"
# Packages built anew with Termux's recipe, without some of its options (config.yaml's rebuild), over
# Termux's own: what they link then decides what comes along (parts.py linked)
for p in "${PARTS[@]}"; do
  for pkg in $(cfg "($(part_of "$p").rebuild // {}) | keys[]"); do
    entry="$(part_of "$p").rebuild[\"$pkg\"]"
    mapfile -t drop < <(cfg "$entry.drop // [] | .[]")
    mapfile -t tools < <(cfg "$entry.build_packages // [] | .[]")
    apt-get install -y "${BUILD_PKGS[@]}" "${tools[@]}"
    WORK="$WORK" bash "$HERE/termux-build.sh" "$pkg" "$WORK/rebuilt-$pkg" "${drop[@]}"
    cp -a "$WORK/rebuilt-$pkg$PREFIX/." "$PREFIX/"
    echo "$pkg: rebuilt without ${drop[*]}"
  done
done
# A part's packages (or <key>'s, e.g. pip_libs) as installed: a name another package provides (as
# apt took it, e.g. yt-dlp for python-yt-dlp) is that package
packages_of() {
  local name
  list_of "$1" "${2:-packages}" | while IFS= read -r name; do
    if dpkg-query -W -f='${Status}\n' "$name" 2>/dev/null | grep -q ' installed$'; then
      echo "$name"
    else
      dpkg-query -W -f='${Package}\t${Provides}\n' \
        | awk -F'\t' -v n="$name" '{ split($2, p, /, */); for (i in p) { sub(/ .*/, "", p[i]); if (p[i] == n) { print $1; exit } } }' \
        | grep . || { echo "::error::Nothing installed is or provides $name" >&2; exit 1; }
    fi
  done
}

# What each part may need: its packages and pip_libs with everything they depend on
for p in "${PARTS[@]}"; do
  mapfile -t pkgs < <(packages_of "$p")
  mapfile -t deps < <({ printf '%s\n' "${pkgs[@]}"; packages_of "$p" pip_libs; } | grep . | sort -u)
  if [ ${#deps[@]} -gt 0 ]; then
    apt-cache depends --recurse --installed --no-recommends --no-suggests --no-conflicts \
        --no-breaks --no-replaces --no-enhances "${deps[@]}" \
      | grep -v '^[ <]' | sort -u | grep -Ev "$EXCLUDE" > "$WORK/$p.apt"
    # Minus what it leaves out (exclude, and the build packages) and what only that needed
    mapfile -t excluded < <(list_of "$p" exclude; printf '%s\n' "${BUILD_PKGS[@]}")
    if [ ${#excluded[@]} -gt 0 ]; then
      python3 "$HERE/parts.py" reachable "$PREFIX/var/lib/dpkg/status" "$WORK/$p.apt" \
        "$(IFS=,; echo "${excluded[*]}")" "${deps[@]}" > "$WORK/$p.apt.kept"
      mv "$WORK/$p.apt.kept" "$WORK/$p.apt"
    fi
  else
    : > "$WORK/$p.apt"
  fi
  # Its own packages and what pip added for it; of the rest, only what those use (parts.py linked)
  printf '%s\n' "${pkgs[@]}" | grep . > "$WORK/$p.roots" || true
  mapfile -t reqs < <(list_of "$p" pip)
  if [ ${#reqs[@]} -gt 0 ]; then python3 "$HERE/pip-files.py" closure "${reqs[@]}" > "$WORK/$p.pip"; else : > "$WORK/$p.pip"; fi
  if [ -s "$WORK/$p.pip" ]; then xargs python3 "$HERE/pip-files.py" files < "$WORK/$p.pip"; fi > "$WORK/$p.pip.files"
done

# Minus what the parts' own packages don't use of their dependencies (see parts.py linked)
sort -u "$WORK"/*.apt | while IFS= read -r pkg; do
  dpkg -L "$pkg" | sed "s|^|$pkg\t|"
done > "$WORK/files.tsv"
python3 "$HERE/parts.py" linked "$PREFIX" "$PREFIX/var/lib/dpkg/status" "$WORK/files.tsv" "$PRUNE" \
  "$WORK/config.json" "$WORK"
echo "Not used by any part: $(wc -l < "$WORK/unused.txt") libraries and programs"

# What each part gets (shared dependencies go to a part they build on)
python3 "$HERE/parts.py" split "$WORK/config.json" "$WORK"

export OUT WORK
for p in "${PARTS[@]}"; do
  STAGE="$ROOT/$p"
  MANIFEST="$OUT/manifest-$p.txt"
  COMPONENTS="$WORK/$p.components"
  mkdir -p "$STAGE/usr"

  xargs -r dpkg-query -W -f='${Package}-${Version}\n' < "$WORK/$p.apt.own" > "$MANIFEST"
  cat "$WORK/$p.pip.own" >> "$MANIFEST"

  {
    xargs -r dpkg -L < "$WORK/$p.apt.own" | while IFS= read -r f; do
      if [ -f "$f" ] || [ -L "$f" ]; then echo "$f"; fi
    done
    if [ -s "$WORK/$p.pip.own" ]; then xargs python3 "$HERE/pip-files.py" files < "$WORK/$p.pip.own"; fi
  } | sed "s|^$PREFIX/||" | { grep -Ev "^/|$PRUNE" || true; } | { grep -vxF -f "$WORK/unused.txt" || true; } \
    | sort -u > "$WORK/$p.files"
  tar -C "$PREFIX" --no-recursion -cf - -T "$WORK/$p.files" | tar -C "$STAGE/usr" -xf -

  # What the app lists it holds ("name version"): all of it, its own packages first - those that are
  # in it: one several parts use went to the one they build on (e.g. jdk's libc++, in the core)
  {
    packages_of "$p" | { grep -xF -f "$WORK/$p.apt.own" || true; } | xargs -r dpkg-query -W -f='${Package} ${Version}\n'
    mapfile -t reqs < <(list_of "$p" pip)
    if [ ${#reqs[@]} -gt 0 ]; then python3 "$HERE/pip-files.py" top "${reqs[@]}"; fi
  } > "$COMPONENTS"
  {
    xargs -r dpkg-query -W -f='${Package} ${Version}\n' < "$WORK/$p.apt.own"
    sed 's/==/ /' "$WORK/$p.pip.own"
  } | sort -f | { grep -vixF -f "$COMPONENTS" || true; } > "$WORK/$p.rest"
  cat "$WORK/$p.rest" >> "$COMPONENTS"

  # Libraries Termux still links for 4 KB pages, rebuilt (see the script)
  STAGE="$STAGE" bash "$HERE/rebuild-16k.sh"
  script=$(cfg "$(part_of "$p").script // empty")
  if [ -n "$script" ]; then
    STAGE="$STAGE" MANIFEST="$MANIFEST" COMPONENTS="$COMPONENTS" bash "$HERE/$script"
  fi
  sort -o "$MANIFEST" "$MANIFEST"
  cp "$COMPONENTS" "$OUT/components-$p.txt"
  echo "$p: $(find "$STAGE" -type f -o -type l | wc -l) files from $(wc -l < "$WORK/$p.apt.own") packages and $(wc -l < "$WORK/$p.pip.own") from pip"
done

# Termux scripts start with $PREFIX/bin/env (e.g. exiftool) and tools call $PREFIX/bin/sh; both
# come with the bootstrap, not as dependencies. Android's own can't stand in: on some devices
# (Samsung) proot can't execute anything from /system/bin (EPERM). So scripts get their
# interpreter directly, like termux-fix-shebang does, and sh is dash (see config.yaml). The
# interpreter has to be in the script's part or one it builds on.
for p in "${PARTS[@]}"; do
  # A part of libraries only has none (find failing would end the build)
  [ -d "$ROOT/$p/usr/bin" ] || continue
  find "$ROOT/$p/usr/bin" -type f | while IFS= read -r f; do
    head -n1 "$f" | grep -q "^#!$PREFIX/bin/env " || continue
    sed -i "1s|^#!$PREFIX/bin/env *|#!$PREFIX/bin/|" "$f"
    interpreter=$(head -n1 "$f" | sed 's|^#!||; s| .*||')
    found=
    for a in "$p" $(cat "$WORK/$p.ancestors"); do
      if [ -e "$ROOT/$a/usr${interpreter#"$PREFIX"}" ]; then found=1; fi
    done
    [ -n "$found" ] || { echo "::error::${f#"$ROOT/"} runs $interpreter, which isn't in $p or what it builds on"; exit 1; }
  done
done
[ -e "$ROOT/core/usr/bin/sh" ] || ln -s dash "$ROOT/core/usr/bin/sh"

# Each extension lists its files, for the app to delete it again
for p in "${PARTS[@]:1}"; do
  mkdir -p "$ROOT/$p/etc/extensions"
  (cd "$ROOT/$p" && find . \( -type f -o -type l \) -print | sed 's|^\./||' | sort) > "$WORK/$p.list"
  mv "$WORK/$p.list" "$ROOT/$p/etc/extensions/$p.files"
done

# The core's version, which the app keeps once it's unpacked; what the parts are (versions, sizes,
# what they hold) the release tells the app (parts.json, see rootfs/release.py)
mkdir -p "$ROOT/core/etc" "$ROOT/core/root" "$ROOT/core/tmp" "$ROOT/core/usr/tmp"
echo "$IMAGE_VERSION" > "$ROOT/core/etc/image-version"
