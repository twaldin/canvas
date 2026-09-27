#!/bin/sh
# Build Canvas and assemble .build/Canvas.app (ad-hoc signed) so macOS and window managers
# treat it as a real application. Usage: scripts/bundle.sh [debug|release]
# CANVAS_VERSION (default 0.1) and CANVAS_BUILD (default 1) set the bundle version (releases).
# CANVAS_BUNDLE_APP assembles it elsewhere (a frozen copy for studies), leaving the bundle a
# running dev instance launched from .build/Canvas.app untouched.
set -eu
config="${1:-debug}"
version="${CANVAS_VERSION:-0.1}"
build="${CANVAS_BUILD:-1}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
swift build -j 4 -c "$config" --product Canvas
bin="$(swift build -c "$config" --show-bin-path)"
app="${CANVAS_BUNDLE_APP:-$repo/.build/Canvas.app}"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/clients/ts"
cp "$bin/Canvas" "$app/Contents/MacOS/Canvas"
for bundle in "$bin"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
# extensions/omp/canvas.ts imports ../../clients and ../../skills, which sit beside it here too.
cp -R schema bin cli skills extensions LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
[ -d resources ] && cp -R resources "$app/Contents/Resources/resources"
cp -R clients/ts/src "$app/Contents/Resources/clients/ts/src"
cp -R clients/python "$app/Contents/Resources/clients/python"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>net.waldin.canvas</string>
  <key>CFBundleName</key><string>Canvas</string>
  <key>CFBundleExecutable</key><string>Canvas</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>CanvasApp.CanvasApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
# Development input replay helper (docs/testing.md); rebuilt only when its source changes.
if [ ! -x "$repo/.build/dev-input" ] || [ "$repo/scripts/dev-input.swift" -nt "$repo/.build/dev-input" ]; then
  swiftc -O "$repo/scripts/dev-input.swift" -o "$repo/.build/dev-input"
fi
echo "$app"
