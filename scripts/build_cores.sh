#!/usr/bin/env bash
# Builds libXray (gomobile) against a pinned Xray-core release and installs the artifacts
# into the Flutter project. Needs: git, go (see libXray go.mod), python3, Android NDK
# (for Android), Xcode (for iOS), gomobile.
#
#   ./scripts/build_cores.sh android
#   ./scripts/build_cores.sh ios
#   ./scripts/build_cores.sh geo
set -euo pipefail

XRAY_CORE_TAG="v26.10.21"
LIBXRAY_TAG="v26.9.9"             # latest libXray tag found; bumped to the core commit below
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.cores}"

build_libxray() {
  mkdir -p "$WORK" && cd "$WORK"
  [ -d libXray ] || git clone https://github.com/XTLS/libXray.git
  cd libXray
  git fetch --tags && git checkout "$LIBXRAY_TAG"
  rm -rf "$WORK/xray-src" && git clone --depth 1 --branch "$XRAY_CORE_TAG" https://github.com/XTLS/Xray-core.git "$WORK/xray-src"
  go get "github.com/xtls/xray-core@$(git -C "$WORK/xray-src" rev-parse HEAD)"
  go mod tidy
}

case "${1:-}" in
  android)
    build_libxray
    # See libXray README for the exact build entry point of your tag.
    python3 build/main.py android
    mkdir -p "$ROOT/android/app/libs"
    cp -v libXray.aar "$ROOT/android/app/libs/libXray.aar"
    ;;
  ios)
    build_libxray
    python3 build/main.py apple gomobile
    echo "Copy LibXray.xcframework into ios/ and add it to BOTH the Runner and PacketTunnel targets"
    echo "(PacketTunnel: Embed & Sign is not needed; Do Not Embed is correct for the extension)."
    ;;
  geo)
    mkdir -p "$ROOT/android/app/src/main/assets"
    for f in geoip.dat geosite.dat; do
      curl -L -o "$ROOT/android/app/src/main/assets/$f" \
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f"
    done
    echo "Also add both files to the PacketTunnel target's resources for iOS."
    ;;
  *)
    echo "usage: $0 android|ios|geo"; exit 1;;
esac
