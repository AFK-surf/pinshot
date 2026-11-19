#!/bin/bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
bash scripts/fetch-stillfail.sh library
work="$root/out/mac-work"
pkg="$work/src/pinshot"
rm -rf "$pkg"
mkdir -p "$pkg" out/build
printf '%s\n' 'name = "pinshot"' 'version = "0.1.0"' 'source = "src"' 'warnings = "@a-33-79-29"' 'import { "mbui@0.1.0" }' > "$work/moon.mod"
printf '%s\n' 'members = [' '  ".",' '  "../../deps/stillfail/libs/mbui",' ']' > "$work/moon.work"
cp app/*.mbt app/*_mac.m app/mac_platform.h packaging/macos/moon.pkg "$pkg/"
cp packaging/macos/update.mbt "$pkg/update.mbt"
export MBUI_APP_MOD="$work" APP=pinshot MBUI_MAC_NAME=PinShot MBUI_APP_ID=org.motion-space.pinshot
export MBUI_MAC_HOOK="$root/packaging/macos/bundle.sh" MACOSX_DEPLOYMENT_TARGET=14.0
export PINSHOT_ROOT="$root"
bash deps/stillfail/libs/mbui/scripts/mac.sh bundle
ditto "$work/out/mac/PinShot.app" out/build/PinShot.app
cp "$work/out/mac/PinShot-mac.zip" out/build/
