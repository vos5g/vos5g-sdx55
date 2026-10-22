#!/usr/bin/env bash
# Build qcmd for the modem (ARMv7, static). Needs Go 1.22+.  Output: ../dist/qcmd-armv7
set -euo pipefail
cd "$(dirname "$0")"
go test ./...
mkdir -p ../dist
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o ../dist/qcmd-armv7 .
ls -l ../dist/qcmd-armv7
