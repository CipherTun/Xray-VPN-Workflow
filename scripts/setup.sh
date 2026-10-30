#!/usr/bin/env bash
# One-time project setup. Run from the project root (the folder that contains pubspec.yaml).
# Requires Flutter >= 3.27 and Android SDK / Xcode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1) Generate platform folders with the right package name: org io.surprise + project "vpn" = io.surprise.vpn
flutter create . --org io.surprise --project-name vpn --platforms android,ios
rm -rf test

# 2) Overlay native sources
cp -Rv android_overlay/app/. android/app/
cp -v  ios_overlay/Runner/AppDelegate.swift ios/Runner/AppDelegate.swift
cp -v  ios_overlay/Runner/Runner.entitlements ios/Runner/Runner.entitlements
mkdir -p ios/PacketTunnel && cp -Rv ios_overlay/PacketTunnel/. ios/PacketTunnel/

# 3) Gradle: min SDK 24, namespace/applicationId, local AAR
G=android/app/build.gradle.kts
if [ -f "$G" ]; then
  sed -i.bak -E 's/minSdk *= *flutter\.minSdkVersion/minSdk = 24/' "$G"
  grep -q 'io.surprise.vpn' "$G" || echo "WARNING: namespace/applicationId is not io.surprise.vpn in $G"
  grep -q 'libs' "$G" || cat >> "$G" <<'GRADLE'

dependencies {
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar", "*.jar"))))
}
GRADLE
else
  echo "Groovy build.gradle found: add  implementation fileTree(dir: 'libs', include: ['*.aar','*.jar'])  and minSdkVersion 24 by hand."
fi
mkdir -p android/app/libs

# 4) Remove the generated Kotlin MainActivity if it sits in a different folder
find android/app/src/main -name MainActivity.kt -not -path '*/io/surprise/vpn/*' -delete || true

flutter pub get
dart run flutter_launcher_icons
echo
echo "Next: ./scripts/build_cores.sh android   (and ios / geo)"
