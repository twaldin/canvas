#!/bin/sh
# Build Canvas and assemble .build/Canvas.app (ad-hoc signed) so macOS and window managers
# treat it as a real application. Usage: scripts/bundle.sh [debug|release]
set -eu
config="${1:-debug}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
swift build -j 4 -c "$config" --product Canvas
bin="$(swift build -c "$config" --show-bin-path)"
app="$repo/.build/Canvas.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/clients/ts"
cp "$bin/Canvas" "$app/Contents/MacOS/Canvas"
for bundle in "$bin"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
cp -R schema bin cli "$app/Contents/Resources/"
cp -R clients/ts/src "$app/Contents/Resources/clients/ts/src"
cp -R clients/python "$app/Contents/Resources/clients/python"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>net.waldin.canvas</string>
  <key>CFBundleName</key><string>Canvas</string>
  <key>CFBundleExecutable</key><string>Canvas</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "$app"
