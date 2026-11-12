#!/bin/sh
# Builds "T3 Island.app" into ./build. Pass --install to copy it to ~/Applications.
set -eu
cd "$(dirname "$0")"

swift build -c release
app="build/T3 Island.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/T3Island "$app/Contents/MacOS/T3Island"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>T3 Island</string>
  <key>CFBundleDisplayName</key><string>T3 Island</string>
  <key>CFBundleIdentifier</key><string>local.t3island</string>
  <key>CFBundleExecutable</key><string>T3Island</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null
echo "Built $(pwd)/$app"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/T3 Island.app"
  cp -R "$app" "$HOME/Applications/"
  echo "Installed ~/Applications/T3 Island.app"
fi
