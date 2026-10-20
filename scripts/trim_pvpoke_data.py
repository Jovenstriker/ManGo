"""Trims PvPoke's data files to the fields ManGo reads, in place.

    python3 scripts/trim_pvpoke_data.py App/ManGo/Resources

gamemaster.json keeps each Pokémon's id, name and moves, and each move's id, name,
type, energy cost, energy gain and turns. rankings-1500.json keeps each Pokémon's id
and recommended moveset, in rank order (ManGo reads the rank from the order).
"""
import json
import sys
from pathlib import Path

folder = Path(sys.argv[1])

gm_path = folder / "gamemaster.json"
gm = json.loads(gm_path.read_text())
pokemon_keys = ("speciesId", "speciesName", "fastMoves", "chargedMoves")
move_keys = ("moveId", "name", "type", "energy", "energyGain", "turns")
trimmed = {
    "pokemon": [{k: p[k] for k in pokemon_keys} for p in gm["pokemon"]],
    "moves": [{k: m[k] for k in move_keys} for m in gm["moves"]],
}
gm_path.write_text(json.dumps(trimmed, separators=(",", ":"), ensure_ascii=False))

rankings_path = folder / "rankings-1500.json"
rankings = json.loads(rankings_path.read_text())
rankings_path.write_text(json.dumps(
    [{"speciesId": r["speciesId"], "moveset": r["moveset"]} for r in rankings],
    separators=(",", ":"), ensure_ascii=False))
