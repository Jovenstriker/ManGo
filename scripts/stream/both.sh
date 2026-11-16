#!/bin/bash
# A change against both test sets: your hand-counted recordings (which recordings change and
# which fail validation, as built and with the settings given) and the stream's truth-checked
# throws (check.py). Settings are battle-report's environment variables, e.g. RULES_OFF=align.
#   scripts/stream/both.sh ['ENV=VAL ...']      (no argument: just the stream score as built)
set -uo pipefail
cd "$(dirname "$0")/../.."
F=PvPCore/Tests/PvPCoreTests/Fixtures
B=${MANGO_BUILD_DIR:-/tmp/ManGo-PvPCore}/release/battle-report
TMP=$(mktemp -d)
if [ -n "${1:-}" ]; then
  changed=0; fails_off=0; fails_on=0
  for f in "$F"/battle-*.json "$F"/gbl-battle-*.json; do
    n=$(basename "$f" .json)
    "$B" "$f" App/ManGo/Resources "$F/hand-counts.json" "$n" 2>/dev/null | grep -E "^ +[0-9]+  [0-9]|VALIDATION|expected" > "$TMP/off"
    env $1 "$B" "$f" App/ManGo/Resources "$F/hand-counts.json" "$n" 2>/dev/null | grep -E "^ +[0-9]+  [0-9]|VALIDATION|expected" > "$TMP/on"
    grep -q "VALIDATION: FAIL" "$TMP/off" && fails_off=$((fails_off + 1))
    grep -q "VALIDATION: FAIL" "$TMP/on" && fails_on=$((fails_on + 1))
    if ! cmp -s "$TMP/on" "$TMP/off"; then
      changed=$((changed + 1))
      echo "== $n"
      diff "$TMP/off" "$TMP/on" | grep -E "✗|✓|expected"
    fi
  done
  echo "Your recordings: $changed changed; failing validation as built $fails_off, with '$1' $fails_on"
fi
python3 -I scripts/stream/check.py "" ${1:+"$1"}
rm -rf "$TMP"
