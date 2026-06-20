#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.1.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -d "Jiji.app" ]; then
    echo "Jiji.app not found, building..."
    ./build-app.sh
fi

STAGING_DIR="./dmg-staging"
DMG_NAME="Jiji-${VERSION}.dmg"

# Clean up any prior staging or DMG
rm -rf "$STAGING_DIR"
rm -f "$DMG_NAME"

mkdir -p "$STAGING_DIR"
cp -R Jiji.app "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname Jiji -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_NAME"

rm -rf "$STAGING_DIR"

DMG_PATH="$SCRIPT_DIR/$DMG_NAME"
DMG_SIZE="$(du -h "$DMG_PATH" | cut -f1)"
echo "DMG created: $DMG_PATH ($DMG_SIZE)"
