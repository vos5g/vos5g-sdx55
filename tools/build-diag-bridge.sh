#!/bin/sh
# Separate GPL-3.0-or-later QCSuper helper. Requires Zig (or an ARM musl CC).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/dist"
if [ -n "${CC_ARM:-}" ]; then
  "$CC_ARM" -O2 -static -s -pthread '-D__packed=__attribute__((packed))' \
    -Wno-int-conversion "$ROOT/tools/diag-bridge/adb_bridge.c" -ldl -o "$ROOT/dist/vos5g-diag-bridge-armv7"
else
  zig cc -target arm-linux-musleabihf -O2 -static -s -pthread '-D__packed=__attribute__((packed))' \
    -Wno-int-conversion "$ROOT/tools/diag-bridge/adb_bridge.c" -ldl -o "$ROOT/dist/vos5g-diag-bridge-armv7"
fi
