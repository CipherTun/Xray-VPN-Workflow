#!/usr/bin/env bash
# Gets libv2ray.aar (AndroidLibXrayLite, the Xray-core library behind v2rayNG).
#   1) download the prebuilt AAR from the project's latest GitHub release
#   2) otherwise build it from source with gomobile
# Output: android-libs/libv2ray.aar
set -euo pipefail
REPO="${CORE_REPO:-2dust/AndroidLibXrayLite}"
REF="${CORE_REF:-}"          # optional tag or commit: forces a source build of exactly that version
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/android-libs"; WORK="$ROOT/.cores"
mkdir -p "$OUT" "$WORK"

valid() {  # a usable gomobile AAR has the Java classes and the native Go library
  [ -s "$1" ] && unzip -tq "$1" >/dev/null 2>&1 && unzip -l "$1" | grep -q 'classes.jar' && unzip -l "$1" | grep -q 'libgojni.so'
}

if [ -z "$REF" ]; then
  echo "Trying the prebuilt AAR from $REPO releases…"
  if curl -fsSL --retry 3 -o "$OUT/libv2ray.aar" "https://github.com/$REPO/releases/latest/download/libv2ray.aar" && valid "$OUT/libv2ray.aar"; then
    echo "Using prebuilt libv2ray.aar ($(du -h "$OUT/libv2ray.aar" | cut -f1))"
    exit 0
  fi
  echo "::notice::no usable prebuilt AAR, building from source"
  rm -f "$OUT/libv2ray.aar"
fi

cd "$WORK"
rm -rf core-src
git clone "https://github.com/$REPO.git" core-src
cd core-src
[ -z "$REF" ] || git checkout "$REF"

# Go downloads whatever toolchain go.mod asks for.
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export PATH="$PATH:$(go env GOPATH)/bin"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
go version
echo "NDK: ${ANDROID_NDK_HOME:-not set}"

# Tools are installed with `go install`; `go get` only adds module dependencies.
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
gomobile init
go mod tidy -v
go get golang.org/x/mobile/bind
# -checklinkname=0 is required by the library on Go 1.23+ (it links to internal Xray symbols).
gomobile bind -v -androidapi 24 -trimpath -ldflags='-s -w -buildid= -checklinkname=0' ./

valid libv2ray.aar || { echo "::error::build finished but libv2ray.aar looks wrong"; exit 1; }
cp -v libv2ray.aar "$OUT/libv2ray.aar"
