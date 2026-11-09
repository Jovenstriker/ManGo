#!/bin/bash
# Writes "Battle Logs/<video>.log" for each recorded battle: ManGo's settings, the energy
# math for every opponent charged move, ManGo's fast move counts vs the hand counts, and a
# timeline. Rerun after changing the counting logic or the hand counts.
set -euo pipefail
cd "$(dirname "$0")/.."
F=PvPCore/Tests/PvPCoreTests/Fixtures
BUILD_DIR=${MANGO_BUILD_DIR:-/tmp/ManGo-PvPCore}
OUTPUT_DIR=${MANGO_OUTPUT_DIR:-"Battle Logs"}
(cd PvPCore && swift build --disable-sandbox --scratch-path "$BUILD_DIR" --product battle-report >/dev/null)
failures=0
mkdir -p "$OUTPUT_DIR"
for fixture in "$F"/*.json; do
  name=$(basename "$fixture" .json)
  [ "$name" != hand-counts ] || continue
  case "$name" in
    gbl-battle-2026-10-20-mango) log=TestWithMangoV1 ;;
    gbl-battle-2026-10-20-v2) log=testV2 ;;
    gbl-battle-2026-10-20-v3) log=testV3 ;;
    gbl-battle-2026-10-20-v*) log=${name##*-} ;;
    gbl-battle-2026-10-23-v*) log=${name##*-} ;;
    *) log=$name ;;
  esac
  # Keep generating all reports even when one recording fails validation.
  if "$BUILD_DIR/debug/battle-report" "$fixture" App/ManGo/Resources "$F/hand-counts.json" "$name" > "$OUTPUT_DIR/$log.log"; then
    echo "$log: PASS (available evidence only)"
  else
    echo "$log: FAIL — see $OUTPUT_DIR/$log.log"
    failures=$((failures + 1))
  fi
done
echo "$failures recording(s) failed validation."
[ "$failures" -eq 0 ]
