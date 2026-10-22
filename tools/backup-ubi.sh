#!/usr/bin/env bash
# Back up the modem's UBI volumes (the restorable kind of backup) to this computer.
#
#   ./tools/backup-ubi.sh [--host 192.168.225.1] [--with-modem-fw] [OUTDIR]
#
# Each volume is streamed over SSH and gzipped here, so nothing is written to the
# modem. Saves ubinfo -a (volume sizes/layout, needed to restore) and SHA256SUMS.
# Restore = from the modem's own Linux: ubiupdatevol /dev/ubiX_Y <image>  (see docs/03-backup.md)
#
# Do NOT read the efs2 MTD partition from Linux: it is a TrustZone-protected range
# and reading it resets the modem. Back up EFS (IMEI, calibration) as a QCN with QPST.
set -euo pipefail
HOST=192.168.225.1 MODEMFW=0 OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST=$2; shift 2 ;;
    --with-modem-fw) MODEMFW=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) OUT=$1; shift ;;
  esac
done
OUT=${OUT:-VOS_UBI_BACKUP_$(date +%Y%m%d_%H%M%S)}
mkdir -p "$OUT"; chmod 700 "$OUT"
CTL=$(mktemp -d); trap 'ssh -o ControlPath="$CTL/c" -O exit root@"$HOST" >/dev/null 2>&1 || true; rm -rf "$CTL"' EXIT
SSH=(ssh -o ControlMaster=auto -o ControlPath="$CTL/c" -o ControlPersist=600 root@"$HOST")

"${SSH[@]}" 'ubinfo -a' > "$OUT/ubinfo-a.txt"
vols="ubi0_0 ubi0_1 ubi0_2 ubi0_3 ubi0_4 ubi2_0"
[ $MODEMFW = 1 ] && vols="$vols ubi1_0"
for v in $vols; do
  name=$("${SSH[@]}" "cat /sys/class/ubi/$v/name")
  size=$("${SSH[@]}" "cat /sys/class/ubi/$v/data_bytes")
  f="$OUT/${v}_${name}.ubifs.gz"
  echo "-- $v ($name, $size bytes) -> $f"
  "${SSH[@]}" "cat /dev/$v" | gzip -c > "$f"
  got=$(gzip -dc "$f" | wc -c | tr -d ' ')
  [ "$got" = "$size" ] || { echo "   SIZE MISMATCH: got $got, expected $size"; exit 1; }
done
( cd "$OUT" && if command -v sha256sum >/dev/null; then sha256sum ./*; else shasum -a 256 ./*; fi > SHA256SUMS.txt )
echo "Done: $OUT  (keep a second copy offline; these images contain your settings and keys)"
