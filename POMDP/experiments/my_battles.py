"""Your battles, replayed: in each one, your team (lead first) against that battle's opponent team,
with the planner playing your side.

    cd POMDP && python3 -m experiments.my_battles --games 4

data/mega_great_league_my_battles.csv lists each battle's two teams (species only, lead first;
Pokémon you didn't bring out are added in your usual order). Movesets are PvPoke's recommended
ones. Your real opponents were people, so each battle is played against each heuristic style
and against the planner itself (`planner-list`, which knows PvPoke's top teams, as yours does),
`--games` times each, alternating sides. Every player sees the same games (same seeds), so the
solver and the baiter heuristic are compared on identical battles. Battles where fewer than three
of their Pokémon were seen, or the read was unreliable, are left out.
"""
from __future__ import annotations

import argparse
import csv
import math
import random
import time
import zlib
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor

from mango_pomdp import gamedata
from mango_pomdp.match import make_player, play
from mango_pomdp.policies import STYLES, Heuristic
from mango_pomdp.team_prior import TeamPrior

FORMAT = "mega_great_league"
BATTLES = gamedata.DATA_DIR / "mega_great_league_my_battles.csv"
SCORE = {0: 1.0, -1: 0.5, 1: 0.0}


def load_battles(gd):
    ids = {s.name: s.id for s in gd.species.values()}
    out = []
    for r in csv.DictReader(BATTLES.open()):
        if r["note"]:
            continue
        team = lambda text: [ids[s.strip()] for s in text.split(";")]   # noqa: E731
        out.append((int(r["battle"]), team(r["your team"]), team(r["opponent team"])))
    return out


def spec(gd, sids):
    out = []
    for sid in sids:
        fast, charged = gd.recommended(sid)
        out.append((sid, fast.id, tuple(c.id for c in charged)))
    return out


def job(args):
    player, n, yours, theirs, opp, game, rollouts = args
    gd = gamedata.use(FORMAT)
    prior = TeamPrior(gd)
    pvpoke = [gd.teams[k] for k in gd.team_pool("pvpoke")]
    rng = random.Random(zlib.crc32(repr((n, opp, game)).encode()))   # the same game for every player
    seeds = [rng.randrange(1 << 30) for _ in range(3)]
    me = Heuristic("baiter", seed=seeds[0]) if player == "baiter" else \
        make_player(player, gd, prior, seeds[0], rollouts=rollouts, teams=pvpoke)
    foe = Heuristic(opp, seed=seeds[1]) if opp in STYLES else \
        make_player(opp, gd, prior, seeds[1], rollouts=rollouts, teams=pvpoke)
    side = game % 2
    teams = [spec(gd, yours), spec(gd, theirs)]
    if side:
        teams.reverse()
    players = [me, foe] if side == 0 else [foe, me]
    s = SCORE[play(gd, teams, players, seed=seeds[2]).winner]
    return player, n, opp, s if side == 0 else 1 - s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--games", type=int, default=4, help="games per battle per opponent")
    ap.add_argument("--players", nargs="+", default=["baiter", "planner-list"])
    ap.add_argument("--opponents", nargs="+", default=[*STYLES, "planner-list"])
    ap.add_argument("--rollouts", type=int, default=12)
    ap.add_argument("--workers", type=int, default=None)
    args = ap.parse_args()
    gd = gamedata.use(FORMAT)
    battles = load_battles(gd)
    jobs = [(p, n, y, t, o, g, args.rollouts) for p in args.players for n, y, t in battles
            for o in args.opponents for g in range(args.games)]
    start = time.time()
    res = defaultdict(list)   # (player, battle, opponent kind) -> scores
    with ProcessPoolExecutor(args.workers) as pool:
        for p, n, o, s in pool.map(job, jobs, chunksize=2):
            res[p, n, "styles" if o in STYLES else o].append(s)
    kinds = ["styles"] + [o for o in args.opponents if o not in STYLES]
    name = lambda sids: "/".join(gd.species[s].name.replace(" (Shadow)", "ˢ").replace(" (Galarian)", "-G")  # noqa: E731
                                 .replace(" (Alolan)", "-A").replace(" (Hisuian)", "-H")
                                 .replace(" (Full Belly)", "") for s in sids)
    print(f"{len(battles)} of your battles, each replayed {args.games}× per opponent "
          f"({', '.join(args.opponents)}), {time.time() - start:.0f}s.\n")

    cols = [(p, k) for k in kinds for p in args.players]
    head = "".join(f"{(p if p != 'planner-list' else 'solver') + ' vs ' + ('heuristics' if k == 'styles' else 'planner'):>26}"
                   for p, k in cols)
    print(f"{'#':>3}  {'your team':<26}{'opponent':<34}{head}")
    for n, y, t in battles:
        row = "".join(f"{sum(res[p, n, k]) / len(res[p, n, k]):>26.2f}" for p, k in cols)
        print(f"{n:>3}  {name(y):<26}{name(t):<34}{row}")

    print("\nBattles won (more than half the replays), and the win rate over every replay:")
    for p, k in cols:
        rates = [sum(res[p, n, k]) / len(res[p, n, k]) for n, _, _ in battles]
        allx = [s for n, _, _ in battles for s in res[p, n, k]]
        m = sum(allx) / len(allx)
        se = math.sqrt(sum((x - m) ** 2 for x in allx) / (len(allx) - 1) / len(allx))
        who = "solver (planner-list)" if p == "planner-list" else p
        vs = "the heuristic styles" if k == "styles" else "the planner"
        print(f"  {who:<22} vs {vs:<21} wins {sum(r > 0.5 for r in rates):>2} of {len(battles)}, "
              f"ties {sum(r == 0.5 for r in rates):>2}   win rate {m:.3f} ± {se:.3f}")

    if "planner-list" not in args.players:
        return
    print("\nBy your team (solver):")
    by = defaultdict(list)
    for n, y, t in battles:
        by[tuple(sorted(y))].append(n)
    for team, ns in sorted(by.items(), key=lambda kv: -len(kv[1])):
        parts = []
        for k in kinds:
            rates = [sum(res["planner-list", n, k]) / len(res["planner-list", n, k]) for n in ns]
            parts.append(f"vs {'heuristics' if k == 'styles' else 'planner'} wins {sum(r > 0.5 for r in rates)}"
                         f"/{len(ns)} ({sum(rates) / len(rates):.2f})")
        first = next(y for n, y, t in battles if n == ns[0])
        print(f"  {name(first):<28} {len(ns):>2} battles   " + "   ".join(parts))


if __name__ == "__main__":
    main()
