#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
cd "$ROOT_DIR"

swift build --disable-sandbox --configuration release
BIN_DIR="$(swift build --disable-sandbox --configuration release --show-bin-path)"
APP_DIR="$ROOT_DIR/build/Swiftty.app"

mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/Swiftty" "$APP_DIR/Contents/MacOS/Swiftty"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

# Re-sign the assembled bundle. SwiftPM emits a linker-signed binary whose
# signature covers the Mach-O alone; once it sits in a bundle, macOS validates
# the signature against Info.plist too, finds it does not cover them, and kills
# the process on launch with "Taskgated Invalid Signature". Signing here, after
# everything is in place, is what makes the bundle launchable.
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
