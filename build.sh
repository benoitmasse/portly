#!/bin/zsh
# Builds Portly.app next to this script.
#   ./build.sh            build
#   ./build.sh --install  build, copy to /Applications and open it
#   ./build.sh --zip      build and make Portly.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

APP=Portly.app
VERSION=${VERSION:-1.0.0}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Portly</string>
  <key>CFBundleDisplayName</key><string>Portly</string>
  <key>CFBundleIdentifier</key><string>io.github.benoitmasse.portly</string>
  <key>CFBundleExecutable</key><string>Portly</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# The icon is drawn by icon/make-icon.swift (run it again after changing the design).
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Universal binary: Apple Silicon and Intel. Liquid Glass needs macOS 26.
BUILD=$(mktemp -d)
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos26.0" main.swift -o "$BUILD/Portly-$arch"
done
lipo -create "$BUILD/Portly-arm64" "$BUILD/Portly-x86_64" -output "$APP/Contents/MacOS/Portly"
rm -rf "$BUILD"

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"

case "${1:-}" in
  --install)
    pkill -x Portly || true
    rm -rf /Applications/Portly.app
    cp -R "$APP" /Applications/
    open /Applications/Portly.app
    echo "Installed to /Applications and launched"
    ;;
  --zip)
    rm -f Portly.zip
    ditto -c -k --keepParent "$APP" Portly.zip
    echo "Made $PWD/Portly.zip"
    ;;
esac
