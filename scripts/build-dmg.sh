#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh "$@"
DIST_DIR="${SLURMBAR_DIST_DIR:-dist}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/slurmbar-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

ditto "$DIST_DIR/SlurmBar.app" "$STAGING_DIR/SlurmBar.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname SlurmBar -srcfolder "$STAGING_DIR" \
    -format UDZO -ov "$DIST_DIR/SlurmBar.dmg"
printf 'Built %s/SlurmBar.dmg\n' "$DIST_DIR"
