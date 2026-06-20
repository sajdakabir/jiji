#!/usr/bin/env bash
# Builds Jiji as a proper macOS .app bundle so WKWebView's WebContent process
# can launch correctly. `swift run` alone leaves the binary unbundled, which
# causes a blank-white login WebView.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP="Jiji.app"
EXEC_NAME="Jiji"

echo "[1/4] swift build -c release"
swift build -c release

BIN_PATH=".build/release/${EXEC_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "[2/4] Assembling $APP bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

echo "[3/4] Copying binary + Info.plist + Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/${EXEC_NAME}"
cp Info.plist "$APP/Contents/Info.plist"

# Copy user-supplied animation assets into the bundle. Hidden files
# (e.g. .gitkeep) are skipped. The directory is created above whether
# or not anything ends up in it.
RES_SRC="Sources/Jiji/Resources"
if [[ -d "$RES_SRC" ]]; then
    shopt -s nullglob
    for f in "$RES_SRC"/*; do
        cp "$f" "$APP/Contents/Resources/"
    done
    shopt -u nullglob
fi

echo "[4/4] Ad-hoc code signing (required by Gatekeeper for WKWebView XPC)"
codesign --force --deep --sign - "$APP" >/dev/null

echo
echo "Built $APP."
echo "Run with: open $APP"
echo "Quit via the menu bar icon's Quit button."
