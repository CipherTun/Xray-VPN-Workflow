#!/usr/bin/env bash
# Generates the Flutter platform folders, applies the native overlay, patches Gradle
# (min SDK, local AAR, release signing), downloads geo files and creates launcher icons.
# Runs on a clean checkout inside GitHub Actions, no local Flutter required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

flutter create . --org io.surprise --project-name vpn --platforms android,ios
rm -rf test   # default widget test references a template app that no longer exists
cp -R android_overlay/app/. android/app/
find android/app/src/main -name MainActivity.kt -not -path '*/io/surprise/vpn/*' -delete || true
mkdir -p android/app/libs android/app/src/main/assets
[ -f android-libs/libXray.aar ] && cp -v android-libs/libXray.aar android/app/libs/libXray.aar \
  || echo "::warning::libXray.aar missing: the app will not compile the core wrapper"

for f in geoip.dat geosite.dat; do
  [ -f "android/app/src/main/assets/$f" ] || curl -fsSL --retry 3 -o "android/app/src/main/assets/$f" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" || echo "::warning::could not download $f"
done

python3 - <<'PY'
import re, sys, os
for name in ("android/app/build.gradle.kts", "android/app/build.gradle"):
    if os.path.exists(name):
        path = name; break
else:
    sys.exit("no gradle file found")
s = open(path).read()
kts = path.endswith(".kts")
if not kts:
    print("::warning::Groovy gradle detected; only the AAR dependency is patched"); 
# min SDK
s = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion", "minSdk = 24" if kts else "minSdkVersion 24", s)
# local AAR
if "fileTree" not in s:
    s += ('\ndependencies {\n    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar", "*.jar"))))\n}\n'
          if kts else "\ndependencies {\n    implementation fileTree(dir: 'libs', include: ['*.aar', '*.jar'])\n}\n")
# release signing from key.properties (kts only)
if kts and "keystoreProps" not in s:
    s = s.replace("android {", 'val keystoreProps = java.util.Properties().apply {\n    val f = rootProject.file("key.properties")\n    if (f.exists()) load(f.inputStream())\n}\n\nandroid {', 1)
    s = s.replace("    buildTypes {", '''    signingConfigs {
        create("release") {
            if (keystoreProps.isNotEmpty()) {
                keyAlias = keystoreProps["keyAlias"] as String
                keyPassword = keystoreProps["keyPassword"] as String
                storeFile = file(keystoreProps["storeFile"] as String)
                storePassword = keystoreProps["storePassword"] as String
            }
        }
    }

    buildTypes {''', 1)
    s = s.replace('signingConfig = signingConfigs.getByName("debug")',
                  'signingConfig = if (keystoreProps.isNotEmpty()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")')
open(path, "w").write(s)
print("patched", path)
PY

grep -n "namespace\|applicationId" android/app/build.gradle* || true
flutter pub get
dart run flutter_launcher_icons
