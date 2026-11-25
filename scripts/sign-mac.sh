#!/bin/bash
# Signs PinShot.app with AFK AI's Developer ID ("Developer ID Application: AFK AI, Inc. (D9AAN3VJK8)", hardened
# runtime, secure timestamp), has Apple notarize it and staples the ticket, so Gatekeeper opens it as downloaded and
# update_mac.m takes it as a release. The identity and the notarytool profile (AFK-Developer-ID-Keychain) are in AFK's
# signing keychain: in CI its base64 in two halves, MACOS_DEVELOPER_ID_KEYCHAIN_B64_1 and _2 (a secret holds 48 KB at
# most), opened with KEYCHAIN_PASSWORD_AFK, the same three secrets AFK-surf/monoid signs still.fail with.
# The zip next to it (PinShot-mac.zip, what build-mac.sh made) is made again of the app signed and stapled.
#   scripts/sign-mac.sh out/build/PinShot.app
set -euo pipefail
app="$1"
team=D9AAN3VJK8
profile=AFK-Developer-ID-Keychain
: "${MACOS_DEVELOPER_ID_KEYCHAIN_B64_1:?}" "${MACOS_DEVELOPER_ID_KEYCHAIN_B64_2:?}" "${KEYCHAIN_PASSWORD_AFK:?}"

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pinshot-signing.XXXXXX")
kc="$work/signing.keychain-db"
previous=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  previous+=("${line//\"/}")
done < <(security list-keychains -d user)
done_signing() {
  security list-keychains -d user -s "${previous[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$kc" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap done_signing EXIT

printf %s "$MACOS_DEVELOPER_ID_KEYCHAIN_B64_1$MACOS_DEVELOPER_ID_KEYCHAIN_B64_2" | tr -d ' \n\r' | base64 -D > "$kc"
chmod 600 "$kc"
security unlock-keychain -p "$KEYCHAIN_PASSWORD_AFK" "$kc"
security set-keychain-settings -lut 7200 "$kc"
security list-keychains -d user -s "$kc" "${previous[@]}"
identity=$(security find-identity -v -p codesigning "$kc" | sed -n "s/.*\"\(Developer ID Application: .*($team)\)\".*/\1/p" | head -1)
if [ -z "$identity" ]; then
  echo "sign-mac.sh: no Developer ID Application identity of $team in the signing keychain" >&2
  security find-identity -p codesigning "$kc" >&2 || true
  exit 1
fi
echo "sign-mac.sh: signing with $identity"
codesign --force --options runtime --timestamp --keychain "$kc" --sign "$identity" "$app"
codesign --verify --strict --deep -vv "$app"

zip="$work/notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
# (Apple's notary service now and then fails a submit with a server error a later try does not meet; a verdict,
# Invalid as well as Accepted, is never asked again)
verdict=""
for wait_s in 0 10 30; do
  sleep "$wait_s"
  if verdict=$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --keychain "$kc" --wait --output-format json); then
    break
  fi
  case "$verdict" in *'"status"'*) break ;; esac
  echo "sign-mac.sh: notarytool submit failed with no verdict: trying again" >&2
  verdict=""
done
echo "notarytool: $verdict"
status=$(printf %s "$verdict" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
if [ "$status" != "Accepted" ]; then
  id=$(printf %s "$verdict" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
  [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" --keychain "$kc" || true
  echo "sign-mac.sh: Apple did not notarize $app: ${status:-no verdict}" >&2
  exit 1
fi
xcrun stapler staple "$app"
spctl --assess --type execute -vv "$app"
out="$(dirname "$app")/PinShot-mac.zip"
rm -f "$out"
(cd "$(dirname "$app")" && ditto -c -k --sequesterRsrc --keepParent "$(basename "$app")" PinShot-mac.zip)
echo "sign-mac.sh: $out ($(wc -c < "$out") bytes, sha256 $(shasum -a 256 "$out" | cut -d' ' -f1))"
