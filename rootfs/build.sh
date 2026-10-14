#!/data/data/com.termux/files/usr/bin/bash
# Runs inside termux/termux-docker (as its "system" user):
#   bash build.sh <image version> <config.yaml as JSON>
# Installs everything config.yaml asks for and leaves the rootfs parts in ~/rootfs/<part> (base
# and the extensions), each holding only its packages' files (with their dependencies, minus what
# the parts it builds on have) and what pip added for it - not the rest of the Termux bootstrap
# (apt, bash, ...). The Termux prefix goes to usr/; the app binds it back to $PREFIX inside proot.
# Manifests (one per part) go to ~/out.
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
apt-get install -y jq

echo "$CONFIG" > "$WORK/config.json"
cfg() { jq -r "$@" "$WORK/config.json"; }
# Where a part's settings are in the config
part_of() { if [ "$1" = base ]; then echo '.base'; else echo ".extensions[\"$1\"]"; fi; }
list_of() { cfg "($(part_of "$1") // {}) | (.$2 // [])[]"; }

mapfile -t PARTS < <(echo base; cfg '(.extensions // {}) | keys_unsorted[]')
mapfile -t PKGS < <(for p in "${PARTS[@]}"; do list_of "$p" packages; done | sort -u)
mapfile -t PIP < <(for p in "${PARTS[@]}"; do list_of "$p" pip; done)
mapfile -t BUILD_PKGS < <(cfg '(.build_packages // [])[]')
read -r -a PIP_OPTIONS <<< "$(cfg '.pip_options // ""')"

apt-get install -y "${PKGS[@]}"
if [ ${#PIP[@]} -gt 0 ]; then
  apt-get install -y python-pip "${BUILD_PKGS[@]}"
  # Termux builds with 16 KB pages in mind, make sure locally built modules are too
  LDFLAGS="-Wl,-z,max-page-size=16384" pip install --no-cache-dir --no-compile --break-system-packages \
    "${PIP_OPTIONS[@]}" "${PIP[@]}"
fi

# What each part needs: its packages with everything they depend on
for p in "${PARTS[@]}"; do
  mapfile -t pkgs < <(list_of "$p" packages)
  if [ ${#pkgs[@]} -gt 0 ]; then
    apt-cache depends --recurse --installed --no-recommends --no-suggests --no-conflicts \
        --no-breaks --no-replaces --no-enhances "${pkgs[@]}" \
      | grep -v '^[ <]' | sort -u | grep -Ev "$EXCLUDE" > "$WORK/$p.apt"
  else
    : > "$WORK/$p.apt"
  fi
  mapfile -t reqs < <(list_of "$p" pip)
  if [ ${#reqs[@]} -gt 0 ]; then python3 "$HERE/pip-files.py" closure "${reqs[@]}" > "$WORK/$p.pip"; else : > "$WORK/$p.pip"; fi
done

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
  } | sed "s|^$PREFIX/||" | { grep -Ev "^/|$PRUNE" || true; } | sort -u > "$WORK/$p.files"
  tar -C "$PREFIX" --no-recursion -cf - -T "$WORK/$p.files" | tar -C "$STAGE/usr" -xf -

  # What the app tells it unpacks: the part's own packages
  {
    list_of "$p" packages | xargs -r dpkg-query -W -f='${Package} ${Version}\n'
    mapfile -t reqs < <(list_of "$p" pip)
    if [ ${#reqs[@]} -gt 0 ]; then python3 "$HERE/pip-files.py" top "${reqs[@]}"; fi
  } > "$COMPONENTS"

  # Termux's libandroid-utimes is still linked for 4 KB pages (see the script)
  if grep -qx 'lib/libandroid-utimes.so' "$WORK/$p.files"; then
    STAGE="$STAGE" bash "$HERE/libandroid-utimes.sh"
  fi
  script=$(cfg "$(part_of "$p").script // empty")
  if [ -n "$script" ]; then
    STAGE="$STAGE" MANIFEST="$MANIFEST" COMPONENTS="$COMPONENTS" bash "$HERE/$script"
  fi
  sort -o "$MANIFEST" "$MANIFEST"
  echo "$p: $(find "$STAGE" -type f -o -type l | wc -l) files from $(wc -l < "$WORK/$p.apt.own") packages and $(wc -l < "$WORK/$p.pip.own") from pip"
done

# Termux scripts start with $PREFIX/bin/env (e.g. exiftool) and tools call $PREFIX/bin/sh; both
# come with the bootstrap, not as dependencies. Android's own can't stand in: on some devices
# (Samsung) proot can't execute anything from /system/bin (EPERM). So scripts get their
# interpreter directly, like termux-fix-shebang does, and sh is dash (see config.yaml). The
# interpreter has to be in the script's part or one it builds on.
for p in "${PARTS[@]}"; do
  find "$ROOT/$p/usr/bin" -type f 2>/dev/null | while IFS= read -r f; do
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
[ -e "$ROOT/base/usr/bin/sh" ] || ln -s dash "$ROOT/base/usr/bin/sh"

# Each extension lists its files, for the app to delete it again
for p in "${PARTS[@]:1}"; do
  mkdir -p "$ROOT/$p/etc/extensions"
  (cd "$ROOT/$p" && find . \( -type f -o -type l \) -print | sed 's|^\./||' | sort) > "$WORK/$p.list"
  mv "$WORK/$p.list" "$ROOT/$p/etc/extensions/$p.files"
done

mkdir -p "$ROOT/base/etc" "$ROOT/base/root" "$ROOT/base/tmp" "$ROOT/base/usr/tmp"
echo "$IMAGE_VERSION" > "$ROOT/base/etc/image-version"
python3 "$HERE/parts.py" index "$WORK/config.json" "$WORK" "$ROOT" > "$ROOT/base/etc/extensions.json"
cat "$ROOT/base/etc/extensions.json"
