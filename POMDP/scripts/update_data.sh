#!/bin/bash
# Downloads PvPoke's full game master and rankings and trims them into data/:
#   great_league.json        Great League rankings
#   mega_great_league.json   Mega Great League rankings, plus the teams in mega_great_league_top_teams.csv
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
BASE=https://raw.githubusercontent.com/pvpoke/pvpoke/master/src/data
curl -fsSL "$BASE/gamemaster.json" -o "$tmp/gamemaster.json"
curl -fsSL "$BASE/rankings/all/overall/rankings-1500.json" -o "$tmp/rankings-1500.json"
curl -fsSL "$BASE/rankings/mega/overall/rankings-1500.json" -o "$tmp/mega-1500.json"
python3 -I scripts/trim_data.py "$tmp/gamemaster.json" "$tmp/rankings-1500.json" data/great_league.json
python3 -I scripts/trim_data.py "$tmp/gamemaster.json" "$tmp/mega-1500.json" data/mega_great_league.json \
    --teams data/mega_great_league_top_teams.csv
ls -lh data
