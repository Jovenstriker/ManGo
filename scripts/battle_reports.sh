#!/bin/bash
# Writes "Battle Logs/<video>.log" for each recorded battle: ManGo's settings, the energy
# math for every opponent charged move, ManGo's fast move counts vs the hand counts, and a
# timeline. Rerun after changing the counting logic or the hand counts.
set -euo pipefail
cd "$(dirname "$0")/.."
F=PvPCore/Tests/PvPCoreTests/Fixtures
(cd PvPCore && swift build --scratch-path ~/Library/Caches/ManGo-PvPCore --product battle-report >/dev/null)
report() {  # <fixture> <log name>
  ~/Library/Caches/ManGo-PvPCore/debug/battle-report "$F/$1.json" App/ManGo/Resources "$F/hand-counts.json" "$1" > "Battle Logs/$2.log"
  echo "Battle Logs/$2.log: $(grep -A1 '^SUMMARY' "Battle Logs/$2.log" | tail -1 | sed 's/^ *//')"
}
mkdir -p "Battle Logs"
report gbl-battle-2026-10-20 "ScreenRecording_10-20-2026 00-33-51_1"
report gbl-battle-2026-10-20-mango TestWithMangoV1
report gbl-battle-2026-10-20-v2 testV2
report gbl-battle-2026-10-20-v3 testV3
report gbl-battle-2026-10-20-v7 v7
report gbl-battle-2026-10-20-v8 v8
report gbl-battle-2026-10-23-v11 v11
report battle-2026-10-23-132243 battle-2026-10-23-132243
report battle-2026-10-23-135548 battle-2026-10-23-135548
report battle-2026-10-23-140441 battle-2026-10-23-140441
report battle-2026-10-23-155712 battle-2026-10-23-155712
report battle-2026-10-23-192858 battle-2026-10-23-192858
report battle-2026-10-24-171449 battle-2026-10-24-171449
report battle-2026-10-24-171905 battle-2026-10-24-171905
report battle-2026-10-24-172648 battle-2026-10-24-172648
report battle-2026-10-24-174243 battle-2026-10-24-174243
report battle-2026-10-24-214129 battle-2026-10-24-214129
report battle-2026-10-24-220440 battle-2026-10-24-220440
report battle-2026-10-24-220723 battle-2026-10-24-220723
report battle-2026-10-24-232707 battle-2026-10-24-232707
report battle-2026-10-28-002722 battle-2026-10-28-002722
