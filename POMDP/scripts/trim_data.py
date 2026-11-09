"""Builds a POMDP/data/<format>.json from PvPoke's full game master and one format's rankings.

    python3 -I POMDP/scripts/trim_data.py gamemaster.json rankings-1500.json POMDP/data/great_league.json
    python3 -I POMDP/scripts/trim_data.py gamemaster.json mega-1500.json POMDP/data/mega_great_league.json \
        --teams POMDP/data/mega_great_league_top_teams.csv

The app's copy (App/ManGo/Resources) is trimmed to what energy counting needs. The simulator
also needs base stats, types, move power and buffs, so it keeps its own file. For each of the
top TOP_N ranked Pokémon it keeps the CP 1500 stats PvPoke ranks with, the moves people actually
run (with PvPoke's usage counts, which the team prior samples from), and PvPoke's 5 hardest
counters (the prior uses them to tell balanced teams from lopsided ones).

`--teams` reads a PvPoke top teams export (a "Team" column like "Altaria DB/Ft/M Melmetal
TS/DbI/DyP ..."), decodes each Pokémon and its abbreviated moves against the game master, and
saves the teams too. Every Pokémon and move on them is kept, however low it ranks.

Species whose form changes mid-battle get an "ability" the simulator implements:
  disguise       Mimikyu: the first unshielded charged move it takes deals 1 damage
  gulp_missile   Cramorant: after Dive or Surf, the next unshielded charged move it takes fires back
  hunger_switch  Morpeko: toggles form after every charged move, which changes Aura Wheel's type
"""
import argparse
import csv
import json
import re
from pathlib import Path

TOP_N = 200
# Moves used in fewer than this share of a species' battles are left out of its prior.
MIN_SHARE = 0.03
SHADOW_ATK, SHADOW_DEF = 1.2, 0.83333331

ap = argparse.ArgumentParser()
ap.add_argument("gamemaster", type=Path)
ap.add_argument("rankings", type=Path)
ap.add_argument("out", type=Path)
ap.add_argument("--teams", type=Path, help="PvPoke top teams CSV to decode and keep")
args = ap.parse_args()

gm = json.loads(args.gamemaster.read_text())
rankings = json.loads(args.rankings.read_text())
species_by_id = {p["speciesId"]: p for p in gm["pokemon"]}
moves_by_id = {m["moveId"]: m for m in gm["moves"]}
ranked = {r["speciesId"]: (rank, r) for rank, r in enumerate(rankings, start=1)}


# Top teams ----------------------------------------------------------------------------------

def abbreviation(m):
    """PvPoke's: its own when the game master has one, else the initials of the move id."""
    return m.get("abbreviation") or "".join(w[0] for w in m["moveId"].split("_"))


def decode_teams(path):
    # Rankings name shadows ("Hydreigon (Shadow)"); the game master's names win where both exist.
    names = {r["speciesName"]: r["speciesId"] for r in rankings}
    names.update({p["speciesName"]: p["speciesId"] for p in gm["pokemon"]})
    teams = []
    for row in csv.DictReader(path.open()):
        members = []
        for name, moves in re.findall(r"(.+?) (\S+/\S+/\S+)\s*", row["Team"]):
            sid = names[name.strip()]
            p = species_by_id[sid]
            pools = (set(p["fastMoves"]) | set(p.get("eliteMoves", [])),
                     set(p["chargedMoves"]) | set(p.get("eliteMoves", [])) | set(p.get("extraChargedMoves", [])))
            ids = []
            for i, a in enumerate(moves.split("/")):
                hits = [m for m in pools[min(i, 1)] if m in moves_by_id and abbreviation(moves_by_id[m]) == a]
                if len(hits) != 1:
                    raise SystemExit(f"can't decode {a!r} for {name}: {hits}")
                ids.append(hits[0])
            members.append({"id": sid, "fast": ids[0], "charged": ids[1:]})
        teams.append({"members": members, "rating": float(row["Team Rating"]),
                      "usage": float(row["Usage"].rstrip("%")) / 100})
    return teams


teams = decode_teams(args.teams) if args.teams else []
required = {m["id"]: m for t in teams for m in t["members"]}


# Pokémon ------------------------------------------------------------------------------------

def common(entries):
    entries = [{**e, "uses": e.get("uses") or 0} for e in entries]
    total = sum(e["uses"] for e in entries) or 1
    kept = {e["moveId"]: e["uses"] for e in entries
            if e["uses"] / total >= MIN_SHARE and e["moveId"] in moves_by_id}
    return kept or {entries[0]["moveId"]: entries[0]["uses"]}


def ability(p):
    """The simulator's name for a form change, and moves that change with the form."""
    fc = p.get("formChange")
    if not fc:
        return None, {}
    if fc.get("effect") == "protect":
        return "disguise", {}
    if fc.get("moveIDs") and p["speciesId"].startswith("cramorant"):
        return "gulp_missile", {}
    if fc.get("type") == "toggle":
        # Moves the other form has under the same name (Aura Wheel: Electric <-> Dark).
        other = species_by_id[fc["alternativeFormId"]]
        mine = {moves_by_id[m]["name"]: m for m in p["chargedMoves"]}
        alt = {mine[moves_by_id[m]["name"]]: m for m in other["chargedMoves"]
               if moves_by_id[m]["name"] in mine and mine[moves_by_id[m]["name"]] != m}
        return "hunger_switch", alt
    return None, {}


keep = [sid for sid, (rank, _) in ranked.items() if rank <= TOP_N]
keep += [sid for sid in required if sid not in keep]
pokemon, used_moves = [], set()
for sid in keep:
    rank, r = ranked[sid]
    p = species_by_id[sid]
    shadow = sid.endswith("_shadow")
    fast = common(r["moves"]["fastMoves"])
    charged = common(r["moves"]["chargedMoves"])
    # PvPoke's recommended moveset and any top-team moveset always make the cut.
    picks = [r["moveset"]] + ([[required[sid]["fast"], *required[sid]["charged"]]] if sid in required else [])
    for moveset in picks:
        fast.setdefault(moveset[0], 1)
        for m in moveset[1:]:
            charged.setdefault(m, 1)
    charged.pop("FRUSTRATION", None)
    kind, alt = ability(p)
    used_moves.update(fast, charged, alt.values())
    entry = {
        "id": sid,
        "name": p["speciesName"],
        "dex": p["dex"],
        "rank": rank,
        "types": [t for t in p["types"] if t != "none"],
        # Stats at PvPoke's default CP 1500 IVs. Shadows hit harder and take more damage.
        "atk": round(r["stats"]["atk"] * (SHADOW_ATK if shadow else 1), 3),
        "def": round(r["stats"]["def"] * (SHADOW_DEF if shadow else 1), 3),
        "hp": r["stats"]["hp"],
        "fast": fast,
        "charged": charged,
        "moveset": r["moveset"][:3],
        "counters": [c["opponent"] for c in r.get("counters", [])],
    }
    if kind:
        entry["ability"] = kind
    if alt:
        entry["formMoves"] = alt
    pokemon.append(entry)


def trim_move(m):
    out = {k: m[k] for k in ("moveId", "name", "type", "power", "energy", "energyGain", "turns")}
    if "buffs" in m:
        target = m["buffTarget"]
        out["buffChance"] = float(m["buffApplyChance"])
        out["buffSelf"] = m.get("buffsSelf", m["buffs"] if target == "self" else [0, 0])
        out["buffOpponent"] = m.get("buffsOpponent", m["buffs"] if target == "opponent" else [0, 0])
    return out


data = {
    "source": f"PvPoke gamemaster {gm.get('timestamp', '')}, {args.rankings.name} (top {TOP_N}"
              + (f", plus every Pokémon on {len(teams)} top teams" if teams else "") + ")",
    "pokemon": pokemon,
    "moves": [trim_move(moves_by_id[m]) for m in sorted(used_moves)],
}
if teams:
    data["teams"] = teams
args.out.write_text(json.dumps(data, separators=(",", ":"), ensure_ascii=False))
print(f"{len(pokemon)} Pokémon, {len(used_moves)} moves" + (f", {len(teams)} teams" if teams else "")
      + f" -> {args.out}")
