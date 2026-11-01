#!/usr/bin/env bash
set -euo pipefail

LIBXRAY_TAG="${LIBXRAY_TAG:-v26.9.9}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.cores"
OUT="$ROOT/android-libs"

mkdir -p "$WORK" "$OUT"
cd "$WORK"

if [ ! -d libXray/.git ]; then
    git clone https://github.com/XTLS/libXray.git
fi

git -C libXray fetch --tags --force
git -C libXray checkout --detach "$LIBXRAY_TAG"

cd libXray

echo "========== UPSTREAM LIBXRAY VERSION =========="
git describe --tags --exact-match
git rev-parse HEAD

echo "========== BUILD USING UPSTREAM SCRIPT =========="
test -f build/main.py || {
    echo "::error::Upstream build/main.py is missing"
    exit 1
}

rm -f ./*.aar
python3 build/main.py android

echo "========== VERIFY UPSTREAM AAR =========="
test -s libXray.aar || {
    echo "::error::Upstream build did not produce libXray.aar"
    find . -maxdepth 3 -type f -name '*.aar' -print
    exit 1
}

install -m 0644 libXray.aar "$OUT/libXray.aar"

echo "========== FINAL AAR =========="
test -s "$OUT/libXray.aar"
sha256sum "$OUT/libXray.aar"
ls -lh "$OUT/libXray.aar"
