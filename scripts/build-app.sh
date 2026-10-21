#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
BIN_DIR="$(swift build -c release "$@" --show-bin-path)"
APP="${SLURMBAR_DIST_DIR:-dist}/SlurmBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SlurmBar" "$APP/Contents/MacOS/SlurmBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${SLURMBAR_VERSION:-}" ]]; then
    if [[ ! "$SLURMBAR_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'SLURMBAR_VERSION must have the form 1.2.3\n' >&2
        exit 1
    fi
    plutil -replace CFBundleShortVersionString -string "$SLURMBAR_VERSION" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$SLURMBAR_VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
