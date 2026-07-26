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

# Compile SwiftTerm's Metal shaders into the app's default library.
#
# SwiftTerm loads its shaders by first trying `device.makeDefaultLibrary()` and,
# only if that fails, falling back to a path that forces `Bundle.module` -- whose
# SwiftPM-generated accessor checks the .app root and a hardcoded absolute .build
# path, then fatalErrors. On a copied .app both are gone, so the app crashed on
# launch the instant Metal was enabled; it only ran on the build machine because
# its .build directory still held the resource bundle.
#
# Shipping default.metallib in Contents/Resources makes makeDefaultLibrary()
# succeed with every required function, so the crashing path is never reached --
# and unlike a bundle at the .app root, a resource here keeps the signature seal
# intact. The shader source travels inside SwiftTerm's own resource bundle.
RES_DIR="$APP_DIR/Contents/Resources"
mkdir -p "$RES_DIR"
SHADER_SRC="$BIN_DIR/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
if [ -f "$SHADER_SRC" ]; then
  AIR="$(mktemp -t swiftty_shaders).air"
  xcrun -sdk macosx metal -c "$SHADER_SRC" -o "$AIR"
  xcrun -sdk macosx metallib "$AIR" -o "$RES_DIR/default.metallib"
  rm -f "$AIR"
else
  echo "warning: SwiftTerm Shaders.metal not found; Metal may fail at runtime" >&2
fi

# Re-sign the assembled bundle. SwiftPM emits a linker-signed binary whose
# signature covers the Mach-O alone; once it sits in a bundle, macOS validates
# the signature against Info.plist too, finds it does not cover them, and kills
# the process on launch with "Taskgated Invalid Signature". Signing here, after
# everything is in place, is what makes the bundle launchable.
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
