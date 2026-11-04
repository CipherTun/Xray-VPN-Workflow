#!/usr/bin/env bash
# Android: builds libv2ray.aar (AndroidLibXrayLite + patched Xray-core). iOS: builds XTLS/libXray (the only
# Xray wrapper with an iOS target). Installs the artifacts into the Flutter project.
# Needs: git, go (see the go.mod of each library), python3, Android NDK (Android), Xcode (iOS), gomobile.
# All versions are pinned in scripts/versions.env.
#
#   ./scripts/build_cores.sh android
#   ./scripts/build_cores.sh ios
#   ./scripts/build_cores.sh geo
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
# shellcheck source=versions.env
. "$ROOT/scripts/versions.env"
set +a
WORK="${WORK:-$ROOT/.cores}"

# libXray tags follow the Xray-core version they embed, so checking out LIBXRAY_TAG is enough.
build_libxray() {
  mkdir -p "$WORK" && cd "$WORK"
  [ -d libXray ] || git clone https://github.com/XTLS/libXray.git
  cd libXray
  git fetch --tags --force && git checkout --detach "$LIBXRAY_TAG"
  echo "libXray $(git describe --tags --exact-match) at $(git rev-parse HEAD)"
}

case "${1:-}" in
  android)
    "$ROOT/scripts/ci_fetch_core.sh"
    mkdir -p "$ROOT/android/app/libs"
    cp -v "$ROOT/android-libs/libv2ray.aar" "$ROOT/android/app/libs/libv2ray.aar"
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
      curl -fL -o "$ROOT/android/app/src/main/assets/$f" \
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f"
    done
    echo "Also add both files to the PacketTunnel target's resources for iOS."
    ;;
  *)
    echo "usage: $0 android|ios|geo"; exit 1;;
esac
