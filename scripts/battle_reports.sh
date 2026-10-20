#!/bin/bash
# Writes "Test Videos/<video>.log" for each recorded battle: ManGo's settings, the energy
# math for every opponent charged move, ManGo's fast move counts vs the hand counts, and a
# timeline. Rerun after changing the counting logic or the hand counts.
set -euo pipefail
cd "$(dirname "$0")/.."
F=PvPCore/Tests/PvPCoreTests/Fixtures
(cd PvPCore && swift build --scratch-path ~/Library/Caches/ManGo-PvPCore --product battle-report >/dev/null)
report() {  # <fixture> <log name>
  ~/Library/Caches/ManGo-PvPCore/debug/battle-report "$F/$1.json" App/ManGo/Resources "$F/hand-counts.json" "$1" > "Test Videos/$2.log"
  echo "Test Videos/$2.log: $(grep -A1 '^SUMMARY' "Test Videos/$2.log" | tail -1 | sed 's/^ *//')"
}
mkdir -p "Test Videos"
report gbl-battle-2026-10-20 "ScreenRecording_10-20-2026 00-33-51_1"
report gbl-battle-2026-10-20-mango TestWithMangoV1
report gbl-battle-2026-10-20-v2 testV2
