#!/bin/bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p out/Release out/build
PIONC="${PIONC:-pionc}"
"$PIONC" build --release . -o out/Release/PinShot
echo "build-mac.sh: out/Release/PinShot"

ver=$(sed -n 's/^let app_version : String = "\(.*\)"$/\1/p' "$root/src/main.pion")
app="$root/out/build/PinShot.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/out/Release/PinShot" "$app/Contents/MacOS/PinShot"
chmod +x "$app/Contents/MacOS/PinShot"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>PinShot</string>
  <key>CFBundleIdentifier</key><string>io.github.pengx17.PinShot</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>PinShot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${ver:-1.0.0}</string>
  <key>CFBundleVersion</key><string>${ver:-1.0.0}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

export PINSHOT_ROOT="$root"
# shellcheck source=packaging/macos/bundle.sh
source "$root/packaging/macos/bundle.sh"
app_bundle "$app"
codesign --force --deep --sign - "$app"
rm -f "$root/out/build/PinShot-mac.zip" "$root/out/build/PinShot-mac.dmg"
(cd "$root/out/build" && ditto -c -k --sequesterRsrc --keepParent PinShot.app PinShot-mac.zip)
dmg_stage=$(mktemp -d "${TMPDIR:-/tmp}/pinshot-dmg.XXXXXX")
trap 'rm -rf "$dmg_stage"' EXIT
ditto "$app" "$dmg_stage/PinShot.app"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create -volname "PinShot" -srcfolder "$dmg_stage" -ov -format UDZO -imagekey zlib-level=9 "$root/out/build/PinShot-mac.dmg" >/dev/null
echo "build-mac.sh: out/build/PinShot-mac.dmg ($(wc -c < "$root/out/build/PinShot-mac.dmg") bytes), PinShot-mac.zip ($(wc -c < "$root/out/build/PinShot-mac.zip") bytes)"
