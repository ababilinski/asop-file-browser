#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/Tools/AppMetadataBridge/AppMetadataBridge.java"
OUTPUT="$ROOT/Sources/AndroidFileBrowserCore/AppMetadataBridgePayload.swift"
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ANDROID_JAR="$(find "$SDK_ROOT/platforms" -name android.jar -type f | sort -V | tail -1)"
D8="$(find "$SDK_ROOT/build-tools" -name d8 -type f | sort -V | tail -1)"
JAVAC="${JAVAC:-$(command -v javac)}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/asop-metadata-bridge.XXXXXX")"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

if [ ! -f "$ANDROID_JAR" ] || [ ! -x "$D8" ] || [ ! -x "$JAVAC" ]; then
  echo "Android SDK build tools and Java are required." >&2
  exit 1
fi

mkdir -p "$WORK/classes" "$WORK/dex"
"$JAVAC" -source 8 -target 8 -Xlint:-options -Xlint:-deprecation -classpath "$ANDROID_JAR" -d "$WORK/classes" "$SOURCE"
"$D8" --min-api 26 --output "$WORK/dex" "$WORK/classes/com/asopfilebrowser/metadata/"*.class

ENCODED="$(base64 < "$WORK/dex/classes.dex" | tr -d '\n')"
cat > "$OUTPUT" <<EOF
import Foundation

enum AppMetadataBridgePayload {
    static let version = 1
    static let data = Data(base64Encoded: "$ENCODED")!
}
EOF

echo "Updated $OUTPUT"
