#!/usr/bin/env bash
# Builds Highlight.app into ./build so it can be double-clicked or copied to /Applications.
#   UNIVERSAL=1  build for both Apple Silicon and Intel Macs (needs full Xcode)
#   ZIP=1        also write build/Highlight-mac.zip for distribution
set -euo pipefail

cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

APP="build/Highlight.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Highlight" "$APP/Contents/MacOS/Highlight"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Highlight</string>
    <key>CFBundleDisplayName</key><string>Highlight</string>
    <key>CFBundleIdentifier</key><string>local.highlight.Highlight</string>
    <key>CFBundleExecutable</key><string>Highlight</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PDF Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS treats the bundle as one consistent app.
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
if [[ "${ZIP:-0}" == "1" ]]; then
  rm -f build/Highlight-mac.zip
  # ditto keeps the bundle's symlinks and code signature intact.
  ditto -c -k --keepParent "$APP" build/Highlight-mac.zip
  echo "Zipped build/Highlight-mac.zip"
fi
echo "Run it with:   open $APP"
echo "Install with:  cp -R $APP /Applications/"
