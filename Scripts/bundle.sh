#!/bin/bash
# Package Flightdeck into a proper .app bundle (needed for mic/speech permissions),
# with Info.plist usage strings + the app icon, then ad-hoc code-sign it.
# Usage: Scripts/bundle.sh [debug|release]   (default: debug)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="Flightdeck.app"
ID="com.apace.flightdeck"

echo "> building (${CONFIG})"
swift build -c "${CONFIG}" >/dev/null
BIN="$(swift build -c "${CONFIG}" --show-bin-path)/Flightdeck"

echo "> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/Flightdeck"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Flightdeck</string>
  <key>CFBundleDisplayName</key>     <string>Flightdeck</string>
  <key>CFBundleExecutable</key>      <string>Flightdeck</string>
  <key>CFBundleIdentifier</key>      <string>$ID</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Flightdeck uses the microphone for push-to-talk dictation.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Flightdeck transcribes your speech on-device for dictation.</string>
</dict>
</plist>
PLIST

echo "> code-signing (ad-hoc)"
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1

echo "OK built $(pwd)/${APP}"
echo "   open it:  open ${APP}"
