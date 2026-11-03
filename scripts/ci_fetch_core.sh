#!/usr/bin/env bash
# Build AndroidLibXrayLite against pinned Xray-core with CipherTun legacy plaintext compatibility.
set -euo pipefail
REPO="${CORE_REPO:-2dust/AndroidLibXrayLite}"
REF="${CORE_REF:-}"
XRAY_REPO="${XRAY_CORE_REPO:-XTLS/Xray-core}"
XRAY_COMMIT="${XRAY_CORE_COMMIT:-a4a3dff5b20c}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/android-libs"
WORK="$ROOT/.cores"
mkdir -p "$OUT" "$WORK"
valid() {
  [ -s "$1" ] && unzip -tq "$1" >/dev/null 2>&1 &&
    unzip -l "$1" | grep -q 'classes.jar' &&
    unzip -l "$1" | grep -q 'libgojni.so'
}
# Upstream prebuilt AARs do not contain CipherTun's compatibility patch.
rm -f "$OUT/libv2ray.aar"
cd "$WORK"
rm -rf core-src
git clone "https://github.com/$REPO.git" core-src
cd core-src
if [ -n "$REF" ]; then git checkout "$REF"; fi
rm -rf xray-core
git clone "https://github.com/$XRAY_REPO.git" xray-core
git -C xray-core checkout "$XRAY_COMMIT"
python3 "$ROOT/scripts/patch_xray_core.py" "$WORK/core-src/xray-core"
go mod edit -replace="github.com/xtls/xray-core=./xray-core"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export PATH="$PATH:$(go env GOPATH)/bin"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
go version
echo "Android NDK: ${ANDROID_NDK_HOME:-not set}"
echo "Patched Xray commit: $(git -C xray-core rev-parse HEAD)"
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
gomobile init
go mod tidy -v
go get golang.org/x/mobile/bind
gomobile bind -v -androidapi 24 -trimpath -ldflags='-s -w -buildid= -checklinkname=0' ./
valid libv2ray.aar || {
  echo "::error::gomobile did not produce a valid patched libv2ray.aar"
  exit 1
}
cp -v libv2ray.aar "$OUT/libv2ray.aar"
