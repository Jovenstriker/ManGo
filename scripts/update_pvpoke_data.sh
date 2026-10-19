#!/bin/bash
# Downloads PvPoke's game master and Great League rankings into the app bundle.
set -euo pipefail
cd "$(dirname "$0")/../App/ManGo/Resources"
BASE=https://raw.githubusercontent.com/pvpoke/pvpoke/master/src/data
curl -fsSL "$BASE/gamemaster.json" -o gamemaster.json
curl -fsSL "$BASE/rankings/all/overall/rankings-1500.json" -o rankings-1500.json
ls -lh
