#!/bin/bash
# still.fail's app module apps/mbui (its design system, @sf) and mbui itself (libs/mbui), at the commit
# stillfail.lock names, into deps/stillfail: only those directories, only that commit. Nothing is fetched when it is
# there already. STILLFAIL_REPO: another place to fetch from (a local clone). The same as ScreenReplay's.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="$(tr -d ' \r\n' < "$ROOT/stillfail.lock")"
DIR="$ROOT/deps/stillfail"
REPO="${STILLFAIL_REPO:-https://github.com/AFK-surf/still.fail.git}"
farview() { [ "${1:-}" = library ] || [ ! -f "$DIR/apps/mbui/scripts/farview.sh" ] || sh "$DIR/apps/mbui/scripts/farview.sh"; }
# PinShot's patches to it (patches/*.patch, each saying why at its head), applied once over that commit
patched() {
  for p in "$ROOT"/patches/*.patch; do
    [ -f "$p" ] || continue
    if git -C "$DIR" apply --check "$p" 2>/dev/null; then
      git -C "$DIR" apply "$p"
      echo "fetch-stillfail.sh: applied $(basename "$p")"
    elif ! git -C "$DIR" apply --reverse --check "$p" 2>/dev/null; then
      echo "fetch-stillfail.sh: $(basename "$p") does not apply to $COMMIT" >&2
      exit 1
    fi
  done
}
if [ -d "$DIR/.git" ] && [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" = "$COMMIT" ]; then
  if [ "${1:-}" != library ] && { [ ! -f "$DIR/apps/mbui/moon.mod" ] || [ ! -f "$DIR/libs/sf-ui/moon.mod" ]; }; then
    git -C "$DIR" sparse-checkout add apps/mbui/ libs/sf-ui/
  fi
  farview "$@"
  patched
  exit 0
fi
mkdir -p "$DIR"
if [ ! -d "$DIR/.git" ]; then
  git -C "$DIR" init -q
  git -C "$DIR" remote add origin "$REPO"
fi
parts=(libs/mbui/)
[ "${1:-}" = library ] || parts+=(apps/mbui/ libs/sf-ui/)
git -C "$DIR" sparse-checkout set --no-cone "${parts[@]}"
git -C "$DIR" remote set-url origin "$REPO"
git -C "$DIR" fetch -q --depth 1 --filter=blob:none origin "$COMMIT"
git -C "$DIR" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
farview "$@"
patched
echo "fetch-stillfail.sh: still.fail $COMMIT"
