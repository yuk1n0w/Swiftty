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

echo "$APP_DIR"
