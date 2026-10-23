#!/bin/bash
# Copies the battles a debug build saved on the phone (Files → On My iPhone → ManGo) into
# "Test Videos/", and turns each one's reads into a fixture: the phone's own screen reads,
# timed to its video, so the battle replays exactly as the card counted it.
#   scripts/pull_battles.sh [device id]   (default: the first connected iPhone)
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE=${1:-$(xcrun devicectl list devices 2>/dev/null | grep ' connected ' | grep physical | grep -o '[0-9A-F-]\{20,\} (UDID)' | head -1 | cut -d' ' -f1)}
[ -n "$DEVICE" ] || { echo "No iPhone connected"; exit 1; }
TMP=$(mktemp -d)
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier com.jovenstriker.mango --source Documents --destination "$TMP" >/dev/null
F=PvPCore/Tests/PvPCoreTests/Fixtures
shopt -s nullglob
for reads in "$TMP"/*.reads.jsonl; do
  name=$(basename "$reads" .reads.jsonl)
  [ -e "$F/$name.json" ] && continue
  cp "$TMP/$name.mp4" "Test Videos/$name.mp4"
  # One read per line -> the JSON array the replay tests and battle-report read.
  python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in open(sys.argv[1]) if l.strip()], separators=(",",":")))' "$reads" > "$F/$name.json"
  echo "Test Videos/$name.mp4 and $F/$name.json"
done
rm -rf "$TMP"
