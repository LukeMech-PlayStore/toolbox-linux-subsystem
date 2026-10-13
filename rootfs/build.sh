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
# Not needed at runtime (paths relative to $PREFIX)
PRUNE='^(share/(man|doc|info|locale|lintian)/|include/|lib/.*\.a$|lib/python3[^/]*/(test|idlelib|ensurepip|pydoc_data|tkinter|turtledemo)/|.*/__pycache__/|.*\.py[co]$|.*\.pod$)'

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

# Termux packages still linked for 4 KB pages, rebuilt from the same source.
# Drop an entry once Termux ships it aligned (the workflow's 16 KB check tells).
if grep -qx 'lib/libandroid-utimes.so' "$WORK/files"; then
  apt-get install -y clang curl
  curl -fsSL -o "$WORK/utimes.tar.gz" https://github.com/termux/libandroid-utimes/archive/refs/tags/v0.4.tar.gz
  echo "579dd000d084e2647d7b907d3c4ef2c46c8cda703e371ed1df32f4dd0366e25d  $WORK/utimes.tar.gz" | sha256sum -c -
  tar -xzf "$WORK/utimes.tar.gz" -C "$WORK"
  clang -fPIC -shared -Wl,-z,max-page-size=16384 "$WORK/libandroid-utimes-0.4/sys_time.c" \
    -o "$STAGE/usr/lib/libandroid-utimes.so"
fi

mkdir -p "$STAGE/etc" "$STAGE/root" "$STAGE/tmp" "$STAGE/usr/tmp"
echo "$IMAGE_VERSION" > "$STAGE/etc/image-version"

echo "Exported $(wc -l < "$WORK/files") files from $(wc -l < "$WORK/closure") packages"
