#!/bin/sh
# Build Canvas and assemble .build/Canvas.app (ad-hoc signed) so macOS and window managers
# treat it as a real application. Usage: scripts/bundle.sh [debug|release]
# CANVAS_VERSION (default: the VERSION file) and CANVAS_BUILD (default 1) set the bundle version.
# CANVAS_BUNDLE_APP assembles it elsewhere (a frozen copy for studies), leaving the bundle a
# running dev instance launched from .build/Canvas.app untouched.
# CANVAS_SIGN_IDENTITY signs for distribution (docs/releasing.md): a Developer ID Application
# identity, with the hardened runtime, scripts/Canvas.entitlements and a secure timestamp. "-"
# signs the same way ad hoc (no timestamp), to try the hardened runtime without a certificate.
set -eu
config="${1:-debug}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
version="${CANVAS_VERSION:-$(cat "$repo/VERSION")}"
build="${CANVAS_BUILD:-1}"
cd "$repo"
swift build -j 4 -c "$config" --product Canvas
bin="$(swift build -c "$config" --show-bin-path)"
app="${CANVAS_BUNDLE_APP:-$repo/.build/Canvas.app}"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/clients/ts" "$app/Contents/Resources/clients/python"
cp "$bin/Canvas" "$app/Contents/MacOS/Canvas"
for bundle in "$bin"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
# extensions/omp/canvas.ts imports ../../clients and ../../skills, which sit beside it here too.
cp -R schema bin cli skills extensions LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
# The hooks' tests (`bun test extensions/agent-hooks`) stay in the checkout.
find "$app/Contents/Resources/extensions" -name '*.test.ts' -delete
[ -d resources ] && cp -R resources "$app/Contents/Resources/resources"
cp -R clients/ts/src "$app/Contents/Resources/clients/ts/src"
# Tiles put clients/python on PYTHONPATH: only the SDK, so no other package (its tests) shadows
# the user's, and no stale bytecode.
cp -R clients/python/canvas_sdk clients/python/pyproject.toml "$app/Contents/Resources/clients/python/"
find "$app/Contents/Resources/clients/python" -name __pycache__ -prune -exec rm -rf {} +
# Importing the SDK would write bytecode into the bundle for whichever Python the user runs, and a
# file added to the bundle breaks its signature. A plain file named __pycache__ where Python would
# make that directory makes it skip writing (the import still works, compiled in memory), without
# touching the user's own code the way PYTHONDONTWRITEBYTECODE or PYTHONPYCACHEPREFIX would.
find "$app/Contents/Resources/clients/python" -name '*.py' -exec dirname {} \; | sort -u | while IFS= read -r dir; do
  : > "$dir/__pycache__"
done
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
  <key>NSAppleEventsUsageDescription</key><string>A program running in Canvas wants to control another app.</string>
  <key>NSMicrophoneUsageDescription</key><string>A program or page running in Canvas wants to use the microphone.</string>
  <key>NSCameraUsageDescription</key><string>A program or page running in Canvas wants to use the camera.</string>
</dict>
</plist>
PLIST
# SwiftPM copies some resource files (tree-sitter queries) read-only; the README's
# `xattr -dr com.apple.quarantine` can't clear a read-only file, so make everything user-writable.
chmod -R u+w "$app"
if [ -n "${CANVAS_SIGN_IDENTITY:-}" ]; then
  set -- --force --options runtime --sign "$CANVAS_SIGN_IDENTITY"
  [ "$CANVAS_SIGN_IDENTITY" = - ] || set -- "$@" --timestamp
  # Inside out: nested code before the bundle that seals it. The executable is the only Mach-O
  # today; a nested framework, XPC service or helper app would need signing as a bundle.
  nested="$(find "$app/Contents" \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.appex' \) -print)"
  [ -z "$nested" ] || { echo "bundle.sh: sign these nested bundles before the app: $nested" >&2; exit 1; }
  find "$app/Contents" -depth -type f ! -path "$app/Contents/MacOS/Canvas" -print | while IFS= read -r file; do
    case "$(file -b "$file")" in Mach-O*) codesign "$@" "$file" ;; esac
  done
  codesign "$@" --entitlements "$repo/scripts/Canvas.entitlements" "$app"
  codesign --verify --deep --strict "$app"
else
  codesign --force --sign - "$app"
fi
# Development input replay helper (docs/testing.md); rebuilt only when its source changes.
if [ ! -x "$repo/.build/dev-input" ] || [ "$repo/scripts/dev-input.swift" -nt "$repo/.build/dev-input" ]; then
  swiftc -O "$repo/scripts/dev-input.swift" -o "$repo/.build/dev-input"
fi
echo "$app"
