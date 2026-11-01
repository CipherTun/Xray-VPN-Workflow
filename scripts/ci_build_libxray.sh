#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.cores"
OUT="$ROOT/android-libs"
LIBXRAY_TAG="${LIBXRAY_TAG:-v26.9.9}"

mkdir -p "$WORK" "$OUT"
cd "$WORK"

if [ ! -d libXray/.git ]; then
    rm -rf libXray
    git clone https://github.com/XTLS/libXray.git libXray
fi

git -C libXray fetch --tags --force
git -C libXray checkout --detach "$LIBXRAY_TAG"

ACTUAL_TAG="$(git -C libXray describe --tags --exact-match HEAD)"
ACTUAL_COMMIT="$(git -C libXray rev-parse HEAD)"

[ "$ACTUAL_TAG" = "$LIBXRAY_TAG" ] || {
    echo "ERROR: libXray tag mismatch: $ACTUAL_TAG"
    exit 1
}

echo "libXray tag: $ACTUAL_TAG"
echo "libXray commit: $ACTUAL_COMMIT"

cd libXray

# Use the official upstream Android builder.
# It resolves the Xray-core dependency pinned by this libXray release,
# prepares gomobile, builds the AAR, and fails on build errors.
python3 build/main.py android

AAR="$(find . -maxdepth 2 -type f -name 'libXray.aar' -print -quit)"

[ -n "$AAR" ] && [ -s "$AAR" ] || {
    echo "ERROR: Official upstream builder did not produce libXray.aar"
    exit 1
}

mkdir -p "$OUT"
install -m 0644 "$AAR" "$OUT/libXray.aar"

echo
echo "========== AAR VERIFICATION =========="
ls -lh "$OUT/libXray.aar"
sha256sum "$OUT/libXray.aar"

echo "Official libXray Android build completed."
