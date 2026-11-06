#!/usr/bin/env bash
# One-time local setup (needs Flutter >= 3.38 with the Android SDK, Go and the Android NDK). Same steps as CI:
# build v2tun.aar first (ci_prepare.sh refuses to run without it), then generate the Flutter platform folders.
# The V2-TUN library is cloned next to the app (v2-tun/) at the ref pinned in scripts/versions.env.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
set -a; . "$DIR/versions.env"; set +a
if [ ! -f "$ROOT/v2-tun/go.mod" ]; then
  git clone --branch "$V2TUN_REF" "https://github.com/$V2TUN_REPO.git" "$ROOT/v2-tun"
fi
bash "$DIR/build_core.sh"
bash "$DIR/ci_prepare.sh"
echo
echo "Done. iOS has no V2-TUN build yet (gomobile iOS target is not wired up)."
