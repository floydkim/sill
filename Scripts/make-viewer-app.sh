#!/bin/bash
# Build a local macOS viewer without installing or replacing the host app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --open ]; }; then
    echo "usage: $0 [--open]" >&2
    exit 2
fi
swift build -c release --product SillViewer
bin="$(swift build -c release --show-bin-path)"
app="$PWD/.build/Sill Viewer.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/SillViewer" "$app/Contents/MacOS/SillViewer"
cp Packaging/Viewer-Info.plist "$app/Contents/Info.plist"
codesign --force --sign "${SILL_VIEWER_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
echo "$app"
if [ "${1:-}" = --open ]; then open "$app"; fi
