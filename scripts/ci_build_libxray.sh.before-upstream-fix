#!/usr/bin/env bash
# Builds libXray.aar (gomobile) against Xray-core $XRAY_CORE_TAG. Used by the GitHub workflow.
# Output: android-libs/libXray.aar
set -euo pipefail
XRAY_CORE_TAG="${XRAY_CORE_TAG:-v26.10.21}"
LIBXRAY_TAG="${LIBXRAY_TAG:-v26.9.9}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.cores"; OUT="$ROOT/android-libs"
mkdir -p "$WORK" "$OUT"; cd "$WORK"

[ -d libXray ] || git clone https://github.com/XTLS/libXray.git
git -C libXray fetch --tags --force
git -C libXray checkout -f "$LIBXRAY_TAG"

# Go cannot fetch Xray's "v26.x.y" tags as modules (not valid semver), so pin by commit hash.
rm -rf xray-src && git clone --depth 1 --branch "$XRAY_CORE_TAG" https://github.com/XTLS/Xray-core.git xray-src
XRAY_COMMIT="$(git -C xray-src rev-parse HEAD)"
echo "Xray-core $XRAY_CORE_TAG = $XRAY_COMMIT"

cd libXray
export PATH="$PATH:$(go env GOPATH)/bin"
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
gomobile init
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
echo "NDK: $ANDROID_NDK_HOME"

build() {
  rm -f ./*.aar
  if [ -f build/main.py ]; then python3 build/main.py android || true; fi
  if ! ls ./*.aar >/dev/null 2>&1; then
    gomobile bind -target=android -androidapi 24 -ldflags="-s -w" -o libXray.aar .
  fi
}

# 1) try with the newest core
cp go.mod go.mod.orig; cp go.sum go.sum.orig
if go get "github.com/xtls/xray-core@${XRAY_COMMIT}" && go mod tidy && build; then
  echo "Built libXray against Xray-core ${XRAY_CORE_TAG}"
else
  # 2) libXray's own pinned core as a fallback, so you still get a working build
  echo "::warning::libXray did not compile against ${XRAY_CORE_TAG}; falling back to the core pinned by libXray ${LIBXRAY_TAG}"
  cp go.mod.orig go.mod; cp go.sum.orig go.sum
  build
fi
cp -v ./*.aar "$OUT/libXray.aar"
