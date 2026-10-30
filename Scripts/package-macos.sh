#!/bin/bash
# Package only the viewer. The remote Mac keeps the official Sill release.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/make-viewer-app.sh
package="$PWD/.build/Sill Viewer macOS"
archive="$PWD/.build/Sill-Viewer-macOS.zip"
rm -rf "$package"
mkdir -p "$package"
ditto '.build/Sill Viewer.app' "$package/Sill Viewer.app"
cp LICENSE "$package/LICENSE"
cp Packaging/Mac-to-Mac-시작하기.txt "$package/START-HERE.txt"
ditto -c -k --sequesterRsrc --keepParent "$package" "$archive"
echo "$archive"
