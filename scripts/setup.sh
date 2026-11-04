#!/usr/bin/env bash
# One-time local setup (needs Flutter >= 3.38 with the Android SDK, Go and the Android NDK). Same steps as CI:
# build the core AAR first (ci_prepare.sh refuses to run without it), then generate the Flutter platform folders.
set -euo pipefail
DIR="$(dirname "$0")"
"$DIR/ci_fetch_core.sh"
"$DIR/ci_prepare.sh"
echo
echo "Done. For iOS also run: ./scripts/build_cores.sh ios"
