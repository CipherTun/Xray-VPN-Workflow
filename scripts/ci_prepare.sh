#!/usr/bin/env bash
# Generates the Flutter platform folders, applies the native overlay, patches Gradle
# (min SDK, local AAR, R8 keep rules, release signing) and creates launcher icons.
# Runs on a clean checkout inside GitHub Actions, no local Flutter required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

flutter create . --org io.surprise --project-name vpn --platforms android,ios
rm -rf test   # default widget test references a template app that no longer exists
cp -R android_overlay/app/. android/app/
find android/app/src/main -name MainActivity.kt -not -path '*/io/surprise/vpn/*' -delete || true
mkdir -p android/app/libs
if [ -f android-libs/v2tun.aar ]; then
  cp -v android-libs/v2tun.aar android/app/libs/v2tun.aar
else
  echo "::error::android-libs/v2tun.aar is missing, run scripts/build_core.sh first"
  exit 1
fi

# Current Flutter templates use the Gradle Kotlin DSL (build.gradle.kts) only.
python3 - <<'PY'
import re, sys

path = "android/app/build.gradle.kts"
try:
    s = open(path).read()
except FileNotFoundError:
    sys.exit(f"::error::{path} not found. This project needs a Flutter version whose template uses the Kotlin DSL (3.29 or newer).")

# 1) Minimum SDK 24 (VpnService.Builder and network callbacks used by the tunnel; matches gomobile -androidapi 24)
s, n = re.subn(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 24", s)
if n == 0 and "minSdk = 24" not in s:
    print("::warning::could not find minSdk line, check android/app/build.gradle.kts")

# 2) Local AAR (v2tun = the Go tunnel library) as a file dependency of the app module
if "fileTree" not in s:
    s += '\ndependencies {\n    implementation(fileTree("libs") { include("*.aar", "*.jar") })\n}\n'

# 3) Release signing from android/key.properties (written by the workflow)
if "keystoreProps" not in s:
    if "import java.util.Properties" not in s:
        s = "import java.util.Properties\n\n" + s

    declaration = """val keystoreProps = Properties().apply {
    val propsFile = rootProject.file("key.properties")
    if (propsFile.exists()) {
        propsFile.inputStream().use { input -> this.load(input) }
    }
}

android {"""

    s, count = re.subn(
        r"(?m)^android\s*\{",
        lambda _: declaration,
        s,
        count=1
    )
    if count != 1:
        raise SystemExit("STOP: Android block not found; file unchanged.")

    signing = """    signingConfigs {
        create("release") {
            if (keystoreProps.isNotEmpty()) {
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
            }
        }
    }

    buildTypes {"""

    if "    buildTypes {" not in s:
        raise SystemExit("STOP: buildTypes block not found; file unchanged.")

    s = s.replace("    buildTypes {", signing, 1)
    s = s.replace(
        'signingConfig = signingConfigs.getByName("debug")',
        'signingConfig = if (keystoreProps.isNotEmpty()) '
        'signingConfigs.getByName("release") '
        'else signingConfigs.getByName("debug")'
    )

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
