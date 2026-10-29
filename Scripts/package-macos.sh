#!/bin/bash
# Build the host and viewer together so the other Mac needs no development tools.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/make-app.sh
Scripts/make-viewer-app.sh
package="$PWD/.build/Sill Mac-to-Mac"
archive="$PWD/.build/Sill-Mac-to-Mac.zip"
rm -rf "$package"
mkdir -p "$package"
ditto .build/Sill.app "$package/Sill.app"
ditto '.build/Sill Viewer.app' "$package/Sill Viewer.app"
cp LICENSE "$package/LICENSE"
cp Packaging/Mac-to-Mac-시작하기.txt "$package/START-HERE.txt"
ditto -c -k --sequesterRsrc --keepParent "$package" "$archive"
echo "$archive"
