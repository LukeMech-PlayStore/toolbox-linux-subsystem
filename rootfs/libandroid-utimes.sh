#!/data/data/com.termux/files/usr/bin/bash
# Run by build.sh (with STAGE and WORK exported) when the rootfs has libandroid-utimes: Termux's
# is still linked for 4 KB pages, so it's rebuilt from the same source - only while Termux's own
# file is unaligned; once it isn't, the build warns that the rebuild can go.
set -euo pipefail

aligned_16k() {
  local align
  for align in $(llvm-readelf -lW "$1" | awk '$1 == "LOAD" { print $NF }'); do
    (( align >= 16384 )) || return 1
  done
}

apt-get install -y llvm
if aligned_16k "$PREFIX/lib/libandroid-utimes.so"; then
  echo "::warning::Termux's libandroid-utimes is 16 KB aligned now, drop rootfs/libandroid-utimes.sh"
  exit 0
fi

apt-get install -y clang curl
curl -fsSL -o "$WORK/utimes.tar.gz" https://github.com/termux/libandroid-utimes/archive/refs/tags/v0.4.tar.gz
echo "579dd000d084e2647d7b907d3c4ef2c46c8cda703e371ed1df32f4dd0366e25d  $WORK/utimes.tar.gz" | sha256sum -c -
tar -xzf "$WORK/utimes.tar.gz" -C "$WORK"
clang -fPIC -shared -Wl,-z,max-page-size=16384 "$WORK/libandroid-utimes-0.4/sys_time.c" \
  -o "$STAGE/usr/lib/libandroid-utimes.so"
