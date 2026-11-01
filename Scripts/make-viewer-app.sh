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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# SwiftPM records the deployment target as the SDK; stamp the actual SDK for macOS app behavior.
minos="$(xcrun vtool -show-build "$bin/SillViewer" | awk '$1 == "minos" && !found { print $2; found = 1 }')"
xcrun vtool -set-build-version macos "$minos" "$(xcrun --sdk macosx --show-sdk-version)" \
    -output "$app/Contents/MacOS/SillViewer" "$bin/SillViewer"
cp Packaging/Viewer-Info.plist "$app/Contents/Info.plist"
# Use the host's native Icon Composer pipeline so macOS applies the same mask and finish.
icon_out="$PWD/.build/viewer-icon"
if [ ! -f "$icon_out/compiled/Assets.car" ] || [ design/ViewerAppIcon.svg -nt "$icon_out/compiled/Assets.car" ] \
   || [ "$0" -nt "$icon_out/compiled/Assets.car" ]; then
    mkdir -p "$icon_out/compiled" "$icon_out/ViewerAppIcon.icon/Assets"
    qlmanage -t -s 1024 -o "$icon_out" "$PWD/design/ViewerAppIcon.svg" >/dev/null
    mv "$icon_out/ViewerAppIcon.svg.png" "$icon_out/ViewerAppIcon.icon/Assets/Viewer.png"
    cat > "$icon_out/ViewerAppIcon.icon/icon.json" <<'JSON'
{
  "fill": { "solid": "srgb:0.00000,0.00000,0.00000,1.00000" },
  "groups": [ { "layers": [ { "image-name": "Viewer.png", "name": "Sill Viewer" } ] } ],
  "supported-platforms": { "squares": [ "macOS" ] }
}
JSON
    xcrun actool --compile "$icon_out/compiled" --platform macosx --minimum-deployment-target 14.0 \
        --app-icon ViewerAppIcon --output-partial-info-plist "$icon_out/partial.plist" \
        "$icon_out/ViewerAppIcon.icon" >/dev/null
fi
cp "$icon_out/compiled/Assets.car" "$app/Contents/Resources/"
cp "$icon_out/compiled/ViewerAppIcon.icns" "$app/Contents/Resources/"
identity="${SILL_VIEWER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }' || true)}"
if [ -z "$identity" ]; then
    identity="-"
    echo "No Apple Development identity found; using ad hoc signing. Keychain may ask for access again after rebuilding." >&2
fi
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "$app"
if [ "${1:-}" = --open ]; then open "$app"; fi
