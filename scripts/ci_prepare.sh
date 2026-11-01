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
s = open(path, encoding="utf-8").read()
# Repair a Gradle header containing literal escaped line breaks.
bad_header = r"import java.util.Properties\n\nplugins {"
good_header = "import java.util.Properties\n\nplugins {"
if s.startswith(bad_header):
    s = good_header + s[len(bad_header):]
    print("repaired escaped Gradle header")
kts = path.endswith(".kts")
if not kts:
    print("::warning::Groovy gradle detected; only the AAR dependency is patched"); 
# min SDK
s = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion", "minSdk = 24" if kts else "minSdkVersion 24", s)
# local AAR
if "fileTree" not in s:
    s += ('\ndependencies {\n    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar", "*.jar"))))\n}\n'
          if kts else "\ndependencies {\n    implementation fileTree(dir: 'libs', include: ['*.aar', '*.jar'])\n}\n")
# release signing from key.properties (Kotlin DSL only)
if kts and "keystoreProps" not in s:
    signing_header = [
        'val keystoreProps: Map<String, String> = rootProject.file("key.properties").let { f ->',
        '    if (!f.exists()) emptyMap()',
        '    else f.readLines().mapNotNull { line ->',
        '        val t = line.trim()',
        '        if (t.isEmpty() || t.startsWith("#") || !t.contains("=")) null',
        '        else {',
        '            val i = t.indexOf("=")',
        '            t.substring(0, i).trim() to t.substring(i + 1).trim()',
        '        }',
        '    }.toMap()',
        '}',
        '',
        'android {',
    ]
    s = s.replace("android {", "\n".join(signing_header), 1)

    signing_config = [
        '    signingConfigs {',
        '        create("release") {',
        '            if (keystoreProps.isNotEmpty()) {',
        '                keyAlias = keystoreProps.getValue("keyAlias")',
        '                keyPassword = keystoreProps.getValue("keyPassword")',
        '                storeFile = file(keystoreProps.getValue("storeFile"))',
        '                storePassword = keystoreProps.getValue("storePassword")',
        '            }',
        '        }',
        '    }',
        '',
        '    buildTypes {',
    ]

    if "    buildTypes {" not in s:
        sys.exit("ERROR: buildTypes block not found")

    s = s.replace("    buildTypes {", "\n".join(signing_config), 1)

    debug_signing = 'signingConfig = signingConfigs.getByName("debug")'
    release_signing = 'signingConfig = if (keystoreProps.isNotEmpty()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")'

    if debug_signing in s:
        s = s.replace(debug_signing, release_signing, 1)
    else:
        print("WARNING: debug signing assignment was not found")

open(path, "w").write(s)
print("patched", path)
PY

grep -n "namespace\|applicationId" android/app/build.gradle* || true
flutter pub get
dart run flutter_launcher_icons
