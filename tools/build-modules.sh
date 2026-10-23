#!/usr/bin/env bash
# Build extra kernel modules for the stick's running kernel (4.14.117-perf).
#
#   ./tools/build-modules.sh            -> dist/modules-4.14.117-perf/*.ko + SHA256SUMS
#   ./install.sh --modules dist/modules-4.14.117-perf
#   then set MODULES="..." in /data/vosclean/etc/vosclean.conf and run: vosclean modules
#
# Source: Qualcomm's public SDX55 kernel on CodeLinaro, tag LE.UM.4.4.2.r1-01400-SDX55
# (the last SDX55 release still on 4.14.117), configured with the stick's own
# /proc/config.gz plus tools/kmod/modules.fragment. Compal's own kernel changes are
# not public; tested on the stick: all modules load, work and unload cleanly.
#
# The kernel accepts unsigned modules and has no MODVERSIONS, so only the version
# string has to match. The real risk is a module compiled against a different
# struct layout than the running kernel; the script refuses to build if the
# fragment changes any built-in (=y) option.
#
# Toolchain: ARM GCC 10.3 (xPack, downloaded once) or set CROSS_COMPILE yourself.
# nftables is deliberately absent: CONFIG_NF_TABLES adds a member to struct net,
# so nf_tables modules would not match the running kernel.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
B=$HERE/build/kmod
TAG=LE.UM.4.4.2.r1-01400-SDX55
WG_COMMIT=3d3c92b4711b42169137b2ddf42ed4382e2babdf   # wireguard-linux-compat, module version 1.0.20220627
KVER=4.14.117-perf
OUT=$HERE/dist/modules-$KVER
mkdir -p "$B" "$OUT"

if [ -z "${CROSS_COMPILE:-}" ]; then
  TC=$B/xpack-arm-none-eabi-gcc-10.3.1-2.3
  if [ ! -x "$TC/bin/arm-none-eabi-gcc" ]; then
    curl -fsSL -o "$B/gcc.tgz" https://github.com/xpack-dev-tools/arm-none-eabi-gcc-xpack/releases/download/v10.3.1-2.3/xpack-arm-none-eabi-gcc-10.3.1-2.3-linux-x64.tar.gz
    tar -xzf "$B/gcc.tgz" -C "$B" && rm "$B/gcc.tgz"
  fi
  export PATH=$TC/bin:$PATH CROSS_COMPILE=arm-none-eabi-
fi
# Qualcomm's tree wraps gcc in a Python 2 script (scripts/gcc-wrapper.py); call gcc directly.
MK=(make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" CC="${CROSS_COMPILE}gcc" HOSTCFLAGS=-fcommon)

K=$B/msm-4.14
[ -d "$K" ] || git clone --depth 1 --branch "$TAG" https://git.codelinaro.org/clo/la/kernel/msm-4.14.git "$K"
grep -q '^SUBLEVEL = 117$' "$K/Makefile" || { echo "unexpected kernel version in $TAG" >&2; exit 1; }

gzip -dc "$HERE/tools/kmod/config-$KVER.gz" > "$K/.config"
cat "$HERE/tools/kmod/modules.fragment" >> "$K/.config"
"${MK[@]}" -C "$K" olddefconfig >/dev/null
# no built-in option may change (the two menu switches have no compiled effect)
changed=$(diff <(gzip -dc "$HERE/tools/kmod/config-$KVER.gz" | grep '=y$' | sort) <(grep '=y$' "$K/.config" | sort) \
  | grep '^[<>]' | grep -vE 'CONFIG_(TCP_CONG_ADVANCED|DEFAULT_CUBIC|PROJECT_ZX56|CHGBAT_DEBUG)=y' || true)
[ -z "$changed" ] || { echo "refusing: built-in options would change:" >&2; echo "$changed" >&2; exit 1; }
"${MK[@]}" -C "$K" -j"$(nproc)" modules_prepare >/dev/null
grep -q "\"$KVER\"" "$K/include/generated/utsrelease.h" || { echo "kernel release is not $KVER" >&2; exit 1; }

for d in net/ipv4 net/ipv6 net/sched net/netfilter lib; do "${MK[@]}" -C "$K" -j"$(nproc)" M="$d" modules >/dev/null; done
cp "$K"/net/ipv6/netfilter/{nf_nat_ipv6,nf_nat_masquerade_ipv6,ip6table_nat,ip6t_MASQUERADE}.ko \
   "$K"/net/ipv4/tcp_bbr.ko "$K"/net/sched/{sch_fq,sch_fq_codel}.ko \
   "$K"/net/netfilter/{xt_owner,xt_string,xt_connbytes}.ko "$K"/lib/{ts_bm,ts_fsm}.ko "$OUT/"

# udp_tunnel / ip6_udp_tunnel: hidden option, only "selected" by drivers; build the files directly
U=$B/udp_tunnel; rm -rf "$U"; mkdir -p "$U"
cp "$K/net/ipv4/udp_tunnel.c" "$K/net/ipv6/ip6_udp_tunnel.c" "$U/"
echo 'obj-m += udp_tunnel.o ip6_udp_tunnel.o' > "$U/Makefile"
"${MK[@]}" -C "$K" M="$U" modules >/dev/null
cp "$U"/{udp_tunnel,ip6_udp_tunnel}.ko "$OUT/"

W=$B/wireguard-linux-compat
[ -d "$W" ] || git clone https://github.com/WireGuard/wireguard-linux-compat.git "$W"
git -C "$W" checkout -q "$WG_COMMIT"
"${MK[@]}" -C "$K" M="$W/src" KBUILD_EXTRA_SYMBOLS="$U/Module.symvers" modules >/dev/null
cp "$W/src/wireguard.ko" "$OUT/"

for k in "$OUT"/*.ko; do
  "${CROSS_COMPILE}strip" --strip-debug "$k"
  "${CROSS_COMPILE}readelf" -p .modinfo "$k" | grep -q "vermagic=$KVER preempt mod_unload ARMv7 p2v8" \
    || { echo "wrong vermagic: $k" >&2; exit 1; }
done
(cd "$OUT" && sha256sum *.ko > SHA256SUMS)
ls -l "$OUT"
