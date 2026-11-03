#!/usr/bin/env bash
# One-time local setup (needs Flutter >= 3.38 with the Android SDK). Same steps as CI.
set -euo pipefail
"$(dirname "$0")/ci_prepare.sh"
echo
echo "Next: ./scripts/build_cores.sh android   (and ios)"
