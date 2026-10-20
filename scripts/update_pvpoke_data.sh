#!/bin/bash
# Downloads PvPoke's game master and Great League rankings into the app bundle, trimmed.
set -euo pipefail
cd "$(dirname "$0")/../App/ManGo/Resources"
BASE=https://raw.githubusercontent.com/pvpoke/pvpoke/master/src/data
curl -fsSL "$BASE/gamemaster.json" -o gamemaster.json
curl -fsSL "$BASE/rankings/all/overall/rankings-1500.json" -o rankings-1500.json
# Keep only the fields ManGo reads (about a tenth of the size; the app opens faster).
python3 -I ../../../scripts/trim_pvpoke_data.py .
ls -lh
