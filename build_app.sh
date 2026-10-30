#!/bin/bash
# Builds a release Explorer.app into ./build
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(tr -d '[:space:]' < VERSION)
swift build -c release
APP=build/Explorer.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Explorer "$APP/Contents/MacOS/Explorer"
cp Resources/explorermac "$APP/Contents/Resources/explorermac"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Explorer</string>
<key>CFBundleDisplayName</key><string>Explorer</string>
<key>CFBundleIdentifier</key><string>com.local.explorer</string>
<key>CFBundleExecutable</key><string>Explorer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>tr</string><string>bs</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>Explorer</string>
  <key>CFBundleURLSchemes</key><array><string>explorermac</string></array>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Folder</string>
  <key>CFBundleTypeRole</key><string>Viewer</string>
  <key>LSHandlerRank</key><string>None</string>
  <key>LSItemContentTypes</key><array><string>public.folder</string></array>
</dict></array>
</dict></plist>
PL
# A plain ad-hoc signature is identified by its hash, so macOS treats every rebuild as a new app and
# asks for folder access again. Pin the identity to the bundle id so granted permissions survive rebuilds.
codesign --force --sign - -r='designated => identifier "com.local.explorer"' "$APP"
echo "Built $APP"
