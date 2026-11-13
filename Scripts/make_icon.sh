#!/usr/bin/env bash
# Renders the app icon (the golem sprite) with a debug build and writes Icon.icns.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
swift build -c debug
ICONSET="$ROOT/.build/Icon.iconset"
"$(swift build -c debug --show-bin-path)/Subzero" --render-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/Icon.icns"
echo "Icon.icns written"
