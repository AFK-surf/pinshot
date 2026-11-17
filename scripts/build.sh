#!/bin/bash
# PinShot: app/ built as an app of still.fail's apps/mbui (its design system, @sf), with mbui's Windows build
# (libs/mbui/scripts/win.sh), into out/build/pinshot.exe. Run in Git Bash inside MSVC's environment (scripts/build.ps1 sets
# it up) with MoonBit on PATH. MODE=debug|release (release by default). Every warning is an error, as the app module
# says (STRICT=0: unused code let through while working).
set -e -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=${MODE:-release}
APPS="$ROOT/deps/stillfail/apps/mbui"
"$ROOT/scripts/fetch-stillfail.sh"
rm -rf "$APPS/src/pinshot"
mkdir -p "$APPS/src/pinshot"
cp "$ROOT"/app/* "$APPS/src/pinshot/"
restore() {
  rm -rf "$APPS/src/pinshot"
  (cd "$APPS" && git checkout -q moon.mod)
}
trap restore EXIT
[ "${STRICT:-1}" = 1 ] || sed -i 's/^warnings = "@a-33-79-29"$/warnings = "@a-33-79-29-1-2-7"/' "$APPS/moon.mod"
mkdir -p "$ROOT/out"
RES="$ROOT/out/pinshot.res"
(cd "$ROOT/assets" && rc.exe -nologo -fo "$(cygpath -w "$RES")" pinshot.rc)
cd "$ROOT/deps/stillfail/libs/mbui"
set +e
MBUI_WIN_RES="$RES" MODE=$MODE MBUI_APP_MOD=../../apps/mbui APP=pinshot scripts/win.sh build > "$ROOT/out/build.log" 2>&1
code=$?
set -e
grep -v "mbc: as is" "$ROOT/out/build.log" | grep -E "error|Error|\[E[0-9]+\]|\[W[0-9]+\]|warning C|linked" | grep -v C4530 | head -80 || true
if [ $code -ne 0 ]; then
  echo "build.sh: FAILED ($code), whole log in out/build.log"
  exit $code
fi
mkdir -p "$ROOT/out/build"
cp "out/win/app/_build/native/$MODE/build/stillfail/pinshot/pinshot.exe" "$ROOT/out/build/pinshot.exe"
(cd "$ROOT" && git rev-parse --short HEAD > out/build.txt)
echo "build.sh: $ROOT/out/build/pinshot.exe"
