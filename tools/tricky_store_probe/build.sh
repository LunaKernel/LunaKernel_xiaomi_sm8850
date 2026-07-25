#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BUILD_TOOLS="${BUILD_TOOLS:-$ANDROID_HOME/build-tools/36.0.0}"
PLATFORM="${PLATFORM:-$ANDROID_HOME/platforms/android-36/android.jar}"
NDK="${NDK:-$ANDROID_HOME/ndk/29.0.14206865}"
CLANG="${CLANG:-$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang}"

OUT="$ROOT/out"
APK="$OUT/tricky-store-probe.apk"
KEYSTORE="$OUT/debug.keystore"

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex" "$OUT/lib/arm64-v8a" "$OUT/compiled"

if [[ ! -x "$BUILD_TOOLS/aapt2" || ! -x "$BUILD_TOOLS/d8" || ! -x "$BUILD_TOOLS/apksigner" || ! -x "$BUILD_TOOLS/zipalign" ]]; then
  echo "[FAIL] missing Android build-tools under: $BUILD_TOOLS" >&2
  exit 1
fi

if [[ ! -f "$PLATFORM" ]]; then
  echo "[FAIL] missing android.jar: $PLATFORM" >&2
  exit 1
fi

if [[ ! -x "$CLANG" ]]; then
  echo "[FAIL] missing NDK clang: $CLANG" >&2
  exit 1
fi

echo "[STEP] build native arm64 timer"
"$CLANG" -O2 -Wall -Wextra -shared -fPIC \
  "$ROOT/jni/native_timer.c" \
  -o "$OUT/lib/arm64-v8a/libprobe_timer.so"

echo "[STEP] compile Java"
javac -source 11 -target 11 \
  -cp "$PLATFORM" \
  -d "$OUT/classes" \
  $(find "$ROOT/src" -name '*.java' | sort)

echo "[STEP] dex"
jar --create --file "$OUT/classes.jar" -C "$OUT/classes" .
"$BUILD_TOOLS/d8" \
  --release \
  --min-api 26 \
  --lib "$PLATFORM" \
  --output "$OUT/dex" \
  "$OUT/classes.jar"

echo "[STEP] package resources"
"$BUILD_TOOLS/aapt2" compile --dir "$ROOT/res" -o "$OUT/compiled/res.zip"
"$BUILD_TOOLS/aapt2" link \
  -I "$PLATFORM" \
  --manifest "$ROOT/AndroidManifest.xml" \
  --min-sdk-version 26 \
  --target-sdk-version 36 \
  --version-code 1 \
  --version-name 1.0 \
  -o "$OUT/base.apk" \
  "$OUT/compiled/res.zip"

echo "[STEP] assemble APK"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q -r "$OUT/unsigned.apk" classes.dex)
(cd "$OUT" && zip -q -r "$OUT/unsigned.apk" lib)

echo "[STEP] sign"
if [[ ! -f "$KEYSTORE" ]]; then
  keytool -genkeypair \
    -keystore "$KEYSTORE" \
    -storepass android \
    -keypass android \
    -alias androiddebugkey \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US" >/dev/null
fi

"$BUILD_TOOLS/zipalign" -p -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$BUILD_TOOLS/apksigner" sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --out "$APK" \
  "$OUT/aligned.apk"

"$BUILD_TOOLS/apksigner" verify "$APK"
echo "[OK] $APK"
