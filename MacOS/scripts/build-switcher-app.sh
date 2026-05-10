#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/Codex Account Switcher.app"
SCRIPT_PATH="$ROOT_DIR/scripts/codex-account-switcher.sh"
SOURCE_PATH="$ROOT_DIR/Sources/CodexAccountSwitcher/main.swift"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/Codex Account Switcher"
ICONSET_PATH="$ROOT_DIR/build/AppIcon.iconset"
ICON_PNG_PATH="$ROOT_DIR/build/AppIcon-1024.png"
SOURCE_ICON_PNG_PATH="$ROOT_DIR/Assets/AppIcon-1024.png"
ICON_PATH="$APP_PATH/Contents/Resources/AppIcon.icns"

chmod +x "$SCRIPT_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$ROOT_DIR/build"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Codex Account Switcher</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex.account-switcher</string>
  <key>CFBundleName</key>
  <string>Codex Account Switcher</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.15</string>
  <key>NSHumanReadableCopyright</key>
  <string>Local account switcher</string>
</dict>
</plist>
PLIST

if [[ -f "$SOURCE_ICON_PNG_PATH" ]]; then
  cp "$SOURCE_ICON_PNG_PATH" "$ICON_PNG_PATH"
else
  swift "$ROOT_DIR/scripts/make-app-icon.swift" "$ICON_PNG_PATH"
fi
rm -rf "$ICONSET_PATH"
mkdir -p "$ICONSET_PATH"
sips -z 16 16 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_512x512.png" >/dev/null
cp "$ICON_PNG_PATH" "$ICONSET_PATH/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_PATH" -o "$ICON_PATH"

swiftc -parse-as-library "$SOURCE_PATH" -o "$EXECUTABLE_PATH" \
  -framework SwiftUI \
  -framework AppKit \
  -framework CryptoKit

chmod +x "$EXECUTABLE_PATH"
codesign --force --deep --sign - "$APP_PATH" >/dev/null
echo "$APP_PATH"
