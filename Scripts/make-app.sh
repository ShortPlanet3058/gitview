#!/bin/zsh
# Assembles GitView.app from a SwiftPM release build.
#
# SwiftPM produces a bare executable; macOS wants a bundle with an Info.plist to give the
# app a name, an icon slot, a bundle identifier and normal window/menu behaviour. This is
# all that an Xcode app target would have added, so it lives here instead.
#
# Usage: Scripts/make-app.sh [--universal]
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release --product GitView "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release --product GitView "${ARCH_FLAGS[@]}" --show-bin-path)/GitView"

APP="build/GitView.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitView"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>GitView</string>
    <key>CFBundleIdentifier</key>         <string>fr.liriscom.gitview</string>
    <key>CFBundleName</key>               <string>GitView</string>
    <key>CFBundleDisplayName</key>        <string>GitView</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>  <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper and the hardened runtime do not complain locally.
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
lipo -archs "$APP/Contents/MacOS/GitView" | sed 's/^/architectures: /'
