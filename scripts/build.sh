#!/bin/bash
set -e
ROOT=/c/Users/pengx/Documents/GitHub/pinshot
SF=${SF:-/c/Users/pengx/AppData/Local/Temp/sfm3}
APPS=$SF/apps/mbui
OUT=$ROOT/out
mkdir -p "$OUT"
rm -rf "$APPS/src/pinshot"
mkdir -p "$APPS/src/pinshot"
cp "$ROOT"/app/* "$APPS/src/pinshot/"
[ "$STRICT" = 1 ] || sed -i 's/^warnings = "@a-33-79-29"$/warnings = "@a-33-79-29-1-2-7"/' "$APPS/moon.mod"
cd "$SF/libs/mbui"
(cd "$ROOT/assets" && rc.exe -nologo -fo "$(cygpath -w "$OUT/pinshot.res")" pinshot.rc)
MBUI_WIN_RES="$OUT/pinshot.res" MODE=release MBUI_APP_MOD=../../apps/mbui APP=pinshot scripts/win.sh build > "$ROOT/build.raw" 2>&1
code=$?
grep -v "mbc: as is" "$ROOT/build.raw" | grep -E "error|Error|\[E[0-9]+\]|\[W[0-9]+\]|warning:|linked" | grep -v "C4530" | head -120 || true
if [ $code -eq 0 ]; then
  cp "out/win/app/_build/native/release/build/stillfail/pinshot/pinshot.exe" "$OUT/pinshot.exe"
  echo "BUILT $OUT/pinshot.exe"
else
  echo "BUILD FAILED ($code)"
fi
rm -rf "$APPS/src/pinshot"
(cd "$APPS" && git checkout -q moon.mod)
exit $code
