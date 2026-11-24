#!/bin/bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p out/Release
PIONC="${PIONC:-pionc}"
"$PIONC" build --release . -o out/Release/PinShot
echo "build-mac.sh: out/Release/PinShot"
