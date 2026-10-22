#!/usr/bin/env bash
# Build the vosclean port of QManager (QManager-GO) for the modem.
# Fetches upstream at the pinned commit, applies vosclean.patch, builds the
# Next.js front end and the ARMv7 Go back end.  Output: ../dist/qmanager-core-armv7
# Needs: git, Node.js 20+ with npm, Go 1.22+.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
UPSTREAM=https://github.com/evairo176/qmanager.git
COMMIT=$(cat "$HERE/UPSTREAM_COMMIT")
SRC=${SRC:-$HERE/../build/qmanager-src}

if [ ! -d "$SRC/.git" ]; then
  git clone "$UPSTREAM" "$SRC"
fi
cd "$SRC"
git fetch --quiet origin || true
git checkout --quiet "$COMMIT"
git reset --quiet --hard "$COMMIT"
git clean -fdq -e node_modules
git apply "$HERE/vosclean.patch"
echo "patched upstream $COMMIT"

if [ "${SKIP_WEB:-0}" != 1 ]; then
  npm ci --no-audit --no-fund
  NEXT_TELEMETRY_DISABLED=1 npx next build
  rm -rf backend/web/out && mkdir -p backend/web/out && cp -r out/. backend/web/out/
fi

cd backend
go test ./...
mkdir -p "$HERE/../dist"
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o "$HERE/../dist/qmanager-core-armv7" ./cmd/server
ls -l "$HERE/../dist/qmanager-core-armv7"
