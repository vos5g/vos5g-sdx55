#!/usr/bin/env bash
# Build "Tailscale Tiny" for the stick: one ARMv7 binary (tailscaled with the CLI
# built in) compiled from Tailscale's official source, with features this modem
# doesn't use left out. About 15 MB, versus about 70 MB for the official tarball.
#
#   ./tools/build-tailscale-tiny.sh [VERSION]        (default: latest stable)
#   ./install.sh --tailscale-tiny dist/tailscaled-tiny-armv7
#   then QManager -> VPN -> Tailscale -> Install -> Tiny
#
# Kept: kernel-TUN routing, NAT traversal, port mapping, exit node / subnet
# advertising, health, the CLI. Left out: SSH server, Taildrop, Serve/Funnel,
# MagicDNS/resolv.conf management, iptables management, log upload, etc.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
VER=${1:-$(curl -fsSL "https://pkgs.tailscale.com/stable/?mode=json" | sed -n 's/.*"TarballsVersion": *"\([^"]*\)".*/\1/p')}
[ -n "$VER" ] || { echo "could not determine the Tailscale version" >&2; exit 1; }
SRC=$HERE/build/tailscale-$VER
[ -d "$SRC" ] || git clone --depth 1 --branch "v$VER" https://github.com/tailscale/tailscale.git "$SRC"
cd "$SRC"
FEATURES=osrouter,nattraversal,portmapper,listenrawdisco,advertiseexitnode,advertiseroutes,health,ipnbus,debug
TAGS="$(GOOS= GOARCH= go run ./cmd/featuretags --min --add=$FEATURES),ts_include_cli"
eval "$(CGO_ENABLED=0 GOOS= GOARCH= go run ./cmd/mkversion)"
mkdir -p "$HERE/dist"
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -tags="$TAGS" -trimpath \
  -ldflags "-s -w -X tailscale.com/version.longStamp=$VERSION_LONG -X tailscale.com/version.shortStamp=$VERSION_SHORT" \
  -o "$HERE/dist/tailscaled-tiny-armv7" ./cmd/tailscaled
ls -l "$HERE/dist/tailscaled-tiny-armv7"
