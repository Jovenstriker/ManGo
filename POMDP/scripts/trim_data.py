"""Builds POMDP/data/great_league.json from PvPoke's full game master and Great League rankings.

    python3 -I POMDP/scripts/trim_data.py gamemaster.json rankings-1500.json POMDP/data/great_league.json

The app's copy (App/ManGo/Resources) is trimmed to what energy counting needs. The simulator
also needs base stats, types, move power and buffs, so it keeps its own file. For each of the
top TOP_N ranked Pokémon it keeps the CP 1500 stats PvPoke ranks with, the moves people actually
run (with PvPoke's usage counts, which the team prior samples from), and PvPoke's 5 hardest
counters (the prior uses them to tell balanced teams from lopsided ones).
"""
import json
import sys
from pathlib import Path

TOP_N = 200
# Moves used in fewer than this share of a species' battles are left out of its prior.
MIN_SHARE = 0.03
SHADOW_ATK, SHADOW_DEF = 1.2, 0.83333331

gm_path, rankings_path, out_path = map(Path, sys.argv[1:4])
gm = json.loads(gm_path.read_text())
rankings = json.loads(rankings_path.read_text())
species_by_id = {p["speciesId"]: p for p in gm["pokemon"]}
moves_by_id = {m["moveId"]: m for m in gm["moves"]}


def common(entries):
    entries = [{**e, "uses": e.get("uses") or 0} for e in entries]
    total = sum(e["uses"] for e in entries) or 1
    kept = {e["moveId"]: e["uses"] for e in entries
            if e["uses"] / total >= MIN_SHARE and e["moveId"] in moves_by_id}
    return kept or {entries[0]["moveId"]: entries[0]["uses"]}


pokemon, used_moves = [], set()
for rank, r in enumerate(rankings[:TOP_N], start=1):
    p = species_by_id[r["speciesId"]]
    shadow = r["speciesId"].endswith("_shadow")
    fast = common(r["moves"]["fastMoves"])
    charged = common(r["moves"]["chargedMoves"])
    # PvPoke's recommended moveset always makes the cut, even if its usage count is low.
    fast.setdefault(r["moveset"][0], 1)
    for m in r["moveset"][1:]:
        charged.setdefault(m, 1)
    charged.pop("FRUSTRATION", None)
    used_moves.update(fast, charged)
    pokemon.append({
        "id": r["speciesId"],
        "name": r["speciesName"],
        "dex": p["dex"],
        "rank": rank,
        "types": [t for t in p["types"] if t != "none"],
        # Stats at PvPoke's default CP 1500 IVs. Shadows hit harder and take more damage.
        "atk": round(r["stats"]["atk"] * (SHADOW_ATK if shadow else 1), 3),
        "def": round(r["stats"]["def"] * (SHADOW_DEF if shadow else 1), 3),
        "hp": r["stats"]["hp"],
        "fast": fast,
        "charged": charged,
        "moveset": r["moveset"],
        "counters": [c["opponent"] for c in r.get("counters", [])],
    })


def trim_move(m):
    out = {k: m[k] for k in ("moveId", "name", "type", "power", "energy", "energyGain", "turns")}
    if "buffs" in m:
        target = m["buffTarget"]
        out["buffChance"] = float(m["buffApplyChance"])
        out["buffSelf"] = m.get("buffsSelf", m["buffs"] if target == "self" else [0, 0])
        out["buffOpponent"] = m.get("buffsOpponent", m["buffs"] if target == "opponent" else [0, 0])
    return out


data = {
    "source": f"PvPoke gamemaster {gm.get('timestamp', '')}, rankings-1500 (top {TOP_N})",
    "pokemon": pokemon,
    "moves": [trim_move(moves_by_id[m]) for m in sorted(used_moves)],
}
out_path.write_text(json.dumps(data, separators=(",", ":"), ensure_ascii=False))
print(f"{len(pokemon)} Pokémon, {len(used_moves)} moves -> {out_path}")
