#!/usr/bin/env bash
# Generates the Flutter platform folders, applies the native overlay, patches Gradle
# (min SDK, local AAR, R8 keep rules, release signing), downloads geo files and creates
# launcher icons. Runs on a clean checkout inside GitHub Actions, no local Flutter required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

flutter create . --org io.surprise --project-name vpn --platforms android,ios
rm -rf test   # default widget test references a template app that no longer exists
cp -R android_overlay/app/. android/app/
find android/app/src/main -name MainActivity.kt -not -path '*/io/surprise/vpn/*' -delete || true
mkdir -p android/app/libs android/app/src/main/assets
if [ -f android-libs/libv2ray.aar ]; then
  cp -v android-libs/libv2ray.aar android/app/libs/libv2ray.aar
else
  echo "::error::android-libs/libv2ray.aar is missing, run scripts/ci_fetch_core.sh first"
  exit 1
fi

for f in geoip.dat geosite.dat; do
  [ -f "android/app/src/main/assets/$f" ] || curl -fsSL --retry 3 -o "android/app/src/main/assets/$f" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" \
    || echo "::warning::could not download $f"
done

# Current Flutter templates use the Gradle Kotlin DSL (build.gradle.kts) only.
python3 - <<'PY'
import re, sys

path = "android/app/build.gradle.kts"
try:
    s = open(path).read()
except FileNotFoundError:
    sys.exit(f"::error::{path} not found. This project needs a Flutter version whose template uses the Kotlin DSL (3.29 or newer).")

# 1) Minimum SDK 24 (VpnService.Builder, TrafficStats and network callbacks used by the tunnel)
s, n = re.subn(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 24", s)
if n == 0 and "minSdk = 24" not in s:
    print("::warning::could not find minSdk line, check android/app/build.gradle.kts")

# 2) Local AAR (libv2ray = Xray-core) as a file dependency of the app module
if "fileTree" not in s:
    s += '\ndependencies {\n    implementation(fileTree("libs") { include("*.aar", "*.jar") })\n}\n'

# 3) Release signing from android/key.properties (written by the workflow)
if "keystoreProps" not in s:
    s = re.sub(r"(?m)^android \{", '''val keystoreProps = java.util.Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {''', s, count=1)
    s = s.replace("    buildTypes {", '''    signingConfigs {
        create("release") {
            if (keystoreProps.isNotEmpty()) {
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
            }
        }
    }

    buildTypes {''', 1)
    s = s.replace('signingConfig = signingConfigs.getByName("debug")',
                  'signingConfig = if (keystoreProps.isNotEmpty()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")')

# 4) R8: keep the gomobile classes (they are looked up by name from native code)
if "proguard-rules.pro" not in s:
    s = re.sub(r"(?m)^(\s*)release \{", r'''\1release {
\1    proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")''', s, count=1)

open(path, "w").write(s)
print("patched", path)
PY

grep -n "namespace\|applicationId\|minSdk" android/app/build.gradle.kts || true
flutter pub get
dart run flutter_launcher_icons
