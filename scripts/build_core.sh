#!/usr/bin/env bash
# Builds v2tun.aar (the tunnel library, github.com/CipherTun/V2-TUN) with gomobile.
# Usage: V2TUN_DIR=v2-tun bash scripts/build_core.sh   (the library must already be checked out there)
# Output: android-libs/v2tun.aar  ->  Java package io.surprise.mobile (class Mobile, interface Protector)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${V2TUN_DIR:-$ROOT/v2-tun}"
[ -f "$LIB/go.mod" ] || { echo "::error::V2-TUN not found in $LIB"; exit 1; }

export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
[ -n "$ANDROID_NDK_HOME" ] || { echo "::error::ANDROID_NDK_HOME is not set"; exit 1; }

go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
export PATH="$PATH:$(go env GOPATH)/bin"

cd "$LIB"
# gvisor is not pinned in go.mod (see its README); gomobile bind needs x/mobile/bind in the module.
go get gvisor.dev/gvisor@go
go get golang.org/x/mobile/bind@latest
go mod tidy
go build ./...
go vet ./...

gomobile init
mkdir -p "$ROOT/android-libs"
gomobile bind -target=android/arm64,android/arm,android/amd64 -androidapi 24 \
  -javapkg=io.surprise -ldflags="-s -w" \
  -o "$ROOT/android-libs/v2tun.aar" io.surprise.vpn/mobile
ls -la "$ROOT/android-libs"
