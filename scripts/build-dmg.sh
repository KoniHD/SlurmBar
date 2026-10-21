#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh "$@"
DIST_DIR="${SLURMBAR_DIST_DIR:-dist}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/slurmbar-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

# Build-only tooling writes Finder metadata directly; no GUI automation is needed.
TOOLS_DIR=".build/dmg-tools"
DMGBUILD_VERSION="1.6.7"
if [[ ! -x "$TOOLS_DIR/bin/python3" ]]; then
    python3 -m venv "$TOOLS_DIR"
fi
if ! "$TOOLS_DIR/bin/python3" -c \
    "import importlib.metadata; assert importlib.metadata.version('dmgbuild') == '$DMGBUILD_VERSION'" \
    2>/dev/null; then
    "$TOOLS_DIR/bin/python3" -m pip install --disable-pip-version-check "dmgbuild==$DMGBUILD_VERSION"
fi

swift scripts/generate-dmg-background.swift "$STAGING_DIR/install.png"
"$TOOLS_DIR/bin/dmgbuild" -s scripts/dmg-settings.py \
    -D "app=$DIST_DIR/SlurmBar.app" -D "background=$STAGING_DIR/install.png" \
    SlurmBar "$DIST_DIR/SlurmBar.dmg"
printf 'Built %s/SlurmBar.dmg\n' "$DIST_DIR"
