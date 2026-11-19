app_bundle() {
  local plist="$1/Contents/Info.plist"
  plutil -insert LSUIElement -bool YES "$plist"
  plutil -replace CFBundleShortVersionString -string "$(sed -n 's/^let app_version : String = "\(.*\)"$/\1/p' "$PINSHOT_ROOT/app/main.mbt")" "$plist"
  cp "$PINSHOT_ROOT/assets/shutter.wav" "$1/Contents/Resources/"
  local icons="$PWD/out/PinShot.iconset"
  mkdir -p "$icons"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PINSHOT_ROOT/assets/icon.png" --out "$icons/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$PINSHOT_ROOT/assets/icon.png" --out "$icons/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$icons" -o "$1/Contents/Resources/PinShot.icns"
  plutil -insert CFBundleIconFile -string PinShot.icns "$plist"
}
