#!/usr/bin/env bash
# Install (or update) vosclean, and optionally the QManager port, on a
# Tri Cascade VOS 5G / SG500M2-X (Compal RXM-G1, Snapdragon X55) over SSH.
#
# Run from a Mac or Linux PC with the dongle plugged in over USB.
# Re-running it is safe: it updates scripts and keeps your settings.
#
#   ./install.sh --pubkey ~/.ssh/id_ed25519.pub                       # vosclean only
#   ./install.sh --pubkey ~/.ssh/id_ed25519.pub \
#       --qmanager dist/qmanager-core-armv7 --qcmd dist/qcmd-armv7      # + QManager
#
# Options:
#   --host IP        modem address (default 192.168.225.1)
#   --pubkey FILE    SSH public key to authorise for root (strongly recommended)
#   --qmanager FILE  qmanager-core ARMv7 binary (see qmanager/build.sh)
#   --qcmd FILE      qcmd ARMv7 binary (see qcmd/build.sh)
#   --tailscale-tiny FILE  Tailscale Tiny binary (see tools/build-tailscale-tiny.sh);
#                    then install it from QManager -> VPN -> Tailscale -> Tiny
#   --modules DIR    extra kernel modules (see tools/build-modules.sh, e.g. dist/modules-4.14.117-perf);
#                    then pick groups with MODULES="..." in etc/vosclean.conf and run: vosclean modules
#   --check          only run the compatibility checks, change nothing
#
# See docs/05-install.md before running this for the first time.
set -euo pipefail

HOST=192.168.225.1
PUBKEY="" QM="" QCMD="" TSTINY="" MODS="" CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST=$2; shift 2 ;;
    --pubkey) PUBKEY=$2; shift 2 ;;
    --qmanager) QM=$2; shift 2 ;;
    --qcmd) QCMD=$2; shift 2 ;;
    --tailscale-tiny) TSTINY=$2; shift 2 ;;
    --modules) MODS=$2; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

REPO=$(cd "$(dirname "$0")" && pwd)
die() { echo "ERROR: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

[ -z "$PUBKEY" ] || [ -s "$PUBKEY" ] || die "public key $PUBKEY not found"
[ -z "$PUBKEY" ] || grep -q '^ssh-' "$PUBKEY" || die "$PUBKEY is not an OpenSSH public key (.pub)"
if [ -n "$QM$QCMD" ]; then
  [ -n "$QM" ] && [ -n "$QCMD" ] || die "--qmanager and --qcmd must be given together"
  [ -s "$QM" ] && [ -s "$QCMD" ] || die "binary not found"
fi

[ -z "$TSTINY" ] || [ -s "$TSTINY" ] || die "Tailscale Tiny binary $TSTINY not found"
[ -z "$MODS" ] || [ -s "$MODS/SHA256SUMS" ] || die "module directory $MODS has no SHA256SUMS (run tools/build-modules.sh)"

# one SSH connection for the whole run, so the password (if any) is asked once
CTL_DIR=$(mktemp -d); trap 'ssh -o ControlPath="$CTL_DIR/c" -O exit root@"$HOST" >/dev/null 2>&1 || true; rm -rf "$CTL_DIR"' EXIT
SSH=(ssh -o ControlMaster=auto -o ControlPath="$CTL_DIR/c" -o ControlPersist=300 -o ConnectTimeout=10 root@"$HOST")

echo "== Checking the device at $HOST"
"${SSH[@]}" 'sh -s' <<'EOF' || die "this does not look like a supported VOS 5G / SG500M2-X; nothing was changed"
set -e
fail() { echo "  FAIL: $*"; exit 1; }
[ "$(uname -m)" = armv7l ] || fail "CPU is $(uname -m), expected armv7l"
tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null | grep -q sdxprairie || fail "not an SDX55 (sdxprairie) device"
[ -x /usr/bin/cricli ] || fail "Compal cricli not found (not a Compal RXM-G1 firmware?)"
[ -f /oem/script/oem_init_post.sh ] || fail "/oem/script/oem_init_post.sh not found"
grep -q ' /data ' /proc/mounts || fail "/data is not mounted"
free=$(df -k /data | awk 'NR==2{print $4}'); [ "$free" -gt 40000 ] || fail "less than 40 MB free on /data"
echo "  firmware: $(cat /etc/version 2>/dev/null) kernel $(uname -r), /data free ${free} kB"
echo "  OK"
EOF
[ $CHECK_ONLY = 1 ] && { echo "Check passed; nothing changed (--check)."; exit 0; }

echo "== Copying vosclean to /data/vosclean"
tar -C "$REPO/vosclean" -cf - bin etc stub web | "${SSH[@]}" 'rm -rf /data/vosclean.new && mkdir -p /data/vosclean.new && tar xf - -C /data/vosclean.new'
"${SSH[@]}" 'sh -s' <<'EOF'
set -e
VC=/data/vosclean N=/data/vosclean.new
mkdir -p $VC/bin $VC/etc $VC/stub $VC/web $VC/log $VC/state $VC/backup $VC/qm/bin $VC/qm/etc $VC/roothome/.ssh
cp -r $N/bin/. $VC/bin/; cp -r $N/stub/. $VC/stub/; cp -r $N/web/. $VC/web/
cp $N/etc/sshd_config $N/etc/lighttpd-ui.conf $VC/etc/
if [ -f $VC/etc/vosclean.conf ]; then echo "  kept your existing etc/vosclean.conf"; else cp $N/etc/vosclean.conf $VC/etc/; fi
chmod 755 $VC $VC/bin/vosclean $VC/bin/boot.sh $VC/bin/uninstall.sh $VC/bin/diag.sh $VC/stub/fotaclient $VC/web/cgi-bin/api.sh $VC/roothome
chmod 700 $VC/roothome/.ssh
rm -rf $N
echo "  OK"
EOF

if [ -n "$PUBKEY" ]; then
  echo "== Authorising $PUBKEY for root"
  "${SSH[@]}" 'K=/data/vosclean/roothome/.ssh/authorized_keys; touch $K; chmod 600 $K; read -r line; grep -qxF "$line" $K && echo "  already present" || { echo "$line" >> $K; echo "  added"; }' < "$PUBKEY"
fi

if [ -n "$QM" ]; then
  echo "== Installing QManager and qcmd"
  for pair in "qmanager-core:$QM" "qcmd:$QCMD"; do
    name=${pair%%:*}; file=${pair#*:}; want=$(sha "$file")
    "${SSH[@]}" "B=/data/vosclean/qm/bin; cat > \$B/$name.new && [ \"\$(sha256sum \$B/$name.new | cut -d' ' -f1)\" = $want ] && chmod 755 \$B/$name.new && mv \$B/$name.new \$B/$name && echo '  $name ${want:0:8} OK' || { rm -f \$B/$name.new; echo '  $name: checksum mismatch, not installed'; exit 1; }" < "$file"
  done
  "${SSH[@]}" 'systemctl stop qmanager 2>/dev/null; true'
fi

if [ -n "$TSTINY" ]; then
  echo "== Uploading Tailscale Tiny (install it from QManager -> VPN -> Tailscale -> Tiny)"
  want=$(sha "$TSTINY")
  "${SSH[@]}" "F=/data/vosclean/qm/tailscale-tiny; mkdir -p /data/vosclean/qm; cat > \$F.new && [ \"\$(sha256sum \$F.new | cut -d' ' -f1)\" = $want ] && chmod 755 \$F.new && mv \$F.new \$F && echo '  uploaded ${want:0:8}' || { rm -f \$F.new; echo '  checksum mismatch, not uploaded'; exit 1; }" < "$TSTINY"
fi

if [ -n "$MODS" ]; then
  kver=$(basename "$MODS"); kver=${kver#modules-}
  echo "== Uploading kernel modules for $kver"
  (cd "$MODS" && tar -cf - *.ko SHA256SUMS) | "${SSH[@]}" "set -e; [ \"\$(uname -r)\" = $kver ] || { echo '  modem runs kernel '\$(uname -r)', modules are for $kver: not installed'; exit 1; }
    T=/data/vosclean/modules/.new; rm -rf \$T; mkdir -p \$T; tar -xf - -C \$T
    cd \$T && sha256sum -c SHA256SUMS >/dev/null || { echo '  checksum mismatch, not installed'; rm -rf \$T; exit 1; }
    rm -rf /data/vosclean/modules/$kver; mv \$T /data/vosclean/modules/$kver; echo \"  \$(ls /data/vosclean/modules/$kver/*.ko | wc -l) modules installed\""
fi

echo "== Installing the boot hook"
"${SSH[@]}" 'sh -s' <<'EOF'
set -e
VC=/data/vosclean F=/oem/script/oem_init_post.sh
[ -f $VC/backup/oem_init_post.sh.orig ] || cp -p $F $VC/backup/oem_init_post.sh.orig
# the vendor ships this script non-executable, so systemd never runs it: fix that
chmod 755 $F
if ! grep -q '/data/vosclean/bin/boot.sh' $F; then
  printf '\n# vosclean hook (remove this line to disable)\n[ -f /data/vosclean/ENABLED ] && systemd-run --unit=vosclean-boot /data/vosclean/bin/boot.sh >/dev/null 2>&1 # vosclean\n' >> $F
  echo "  hook added to $F (original saved in $VC/backup/)"
else
  echo "  hook already present"
fi
touch $VC/ENABLED
if systemctl is-active --quiet vosclean-boot; then
  $VC/bin/vosclean apply
else
  systemd-run --unit=vosclean-boot $VC/bin/boot.sh >/dev/null 2>&1
fi
echo "  started"
EOF

echo "== Waiting 30 s for the first apply, then showing status"
sleep 30
"${SSH[@]}" /data/vosclean/bin/vosclean status
cat <<EOF

Done. Next steps:
  * If you passed --pubkey, check that key login works:  ssh root@$HOST 'echo works'
    (root password login is switched off as soon as a key is authorised; see etc/vosclean.conf)
  * If you installed QManager, set its password:  ssh -t root@$HOST /data/vosclean/bin/vosclean qmpass
    then open http://$HOST:8080  or  https://$HOST:8443
  * Undo everything:  ssh root@$HOST /data/vosclean/bin/uninstall.sh
EOF
