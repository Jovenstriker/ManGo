#!/bin/bash
# Writes "Battle Logs/<video>.log" for each recorded battle: ManGo's settings, the energy
# math for every opponent charged move, ManGo's fast move counts vs the hand counts, and a
# timeline. Rerun after changing the counting logic or the hand counts.
#
# The report tool is built optimized and the recordings run several at a time (MANGO_JOBS,
# default: the Mac's core count): a debug build one at a time took about 2.5 minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
F=PvPCore/Tests/PvPCoreTests/Fixtures
BUILD_DIR=${MANGO_BUILD_DIR:-/tmp/ManGo-PvPCore}
OUTPUT_DIR=${MANGO_OUTPUT_DIR:-"Battle Logs"}
JOBS=${MANGO_JOBS:-$(sysctl -n hw.ncpu)}
REPORT="$BUILD_DIR/release/battle-report"

if [ "${1:-}" = --one ]; then
  # One recording (run by xargs below): its report, and PASS or FAIL in the status folder.
  fixture=$2 status=$3
  name=$(basename "$fixture" .json)
  case "$name" in
    gbl-battle-2026-10-20-mango) log=TestWithMangoV1 ;;
    gbl-battle-2026-10-20-v2) log=testV2 ;;
    gbl-battle-2026-10-20-v3) log=testV3 ;;
    gbl-battle-2026-10-20-v*|gbl-battle-2026-10-23-v*) log=${name##*-} ;;
    *) log=$name ;;
  esac
  # Keep generating all reports even when one recording fails validation.
  if "$REPORT" "$fixture" App/ManGo/Resources "$F/hand-counts.json" "$name" > "$OUTPUT_DIR/$log.log"; then
    echo "$log: PASS (available evidence only)" > "$status/$log"
  else
    echo "$log: FAIL — see $OUTPUT_DIR/$log.log" > "$status/$log"
  fi
  exit 0
fi

(cd PvPCore && swift build -c release --disable-sandbox --scratch-path "$BUILD_DIR" --product battle-report >/dev/null)
mkdir -p "$OUTPUT_DIR"
STATUS=$(mktemp -d)
trap 'rm -rf "$STATUS"' EXIT
export MANGO_BUILD_DIR="$BUILD_DIR" MANGO_OUTPUT_DIR="$OUTPUT_DIR"
for fixture in "$F"/*.json; do
  if [ "$(basename "$fixture")" != hand-counts.json ]; then printf '%s\0' "$fixture"; fi
done | xargs -0 -P "$JOBS" -I {} "$0" --one {} "$STATUS"
cat "$STATUS"/*
failures=$(cat "$STATUS"/* | grep -c ": FAIL" || true)
echo "$failures recording(s) failed validation."
[ "$failures" -eq 0 ]
