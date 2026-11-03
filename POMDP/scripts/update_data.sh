#!/bin/bash
# Downloads PvPoke's full game master and Great League rankings and trims them into data/great_league.json.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
BASE=https://raw.githubusercontent.com/pvpoke/pvpoke/master/src/data
curl -fsSL "$BASE/gamemaster.json" -o "$tmp/gamemaster.json"
curl -fsSL "$BASE/rankings/all/overall/rankings-1500.json" -o "$tmp/rankings-1500.json"
python3 -I scripts/trim_data.py "$tmp/gamemaster.json" "$tmp/rankings-1500.json" data/great_league.json
ls -lh data
