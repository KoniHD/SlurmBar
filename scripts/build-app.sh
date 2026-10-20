#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
BIN_DIR="$(swift build -c release "$@" --show-bin-path)"
APP="dist/SlurmBar.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/SlurmBar" "$APP/Contents/MacOS/SlurmBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
