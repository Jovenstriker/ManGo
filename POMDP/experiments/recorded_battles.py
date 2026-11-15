"""Your recorded battles (`Battle Turns/`), replayed with the planner on your side.

    cd POMDP && python3 -m experiments.recorded_battles --games 8

Each battle where all three of their Pokémon came in is played with the real teams and
movesets: yours from your buttons, theirs from the moves they threw (PvPoke's for the rest).
The planner (`planner-list`) plays your side. The opponent is played two ways:

  habits   the strong planner, shielding and baiting the way that opponent did (battle_turns)
  planner  the strong planner on its own

Each is replayed `--games` times, alternating sides, and compared with how the battle really
went. The output names your recordings, so keep it local.
"""
from __future__ import annotations

import argparse
import math
import random
import time
import zlib
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from mango_pomdp import gamedata
from mango_pomdp.battle_turns import HabitOpponent, load
from mango_pomdp.match import make_player, play
from mango_pomdp.team_prior import TeamPrior

FORMAT = "mega_great_league"
SCORE = {0: 1.0, -1: 0.5, 1: 0.0}
TURNS = Path(__file__).resolve().parents[2] / "Battle Turns"


def job(args):
    battle, opp, game, rollouts = args
    gd = gamedata.use(FORMAT)
    prior = TeamPrior(gd)
    pvpoke = [gd.teams[k] for k in gd.team_pool("pvpoke")]
    rng = random.Random(zlib.crc32(repr((battle.id, game)).encode()))   # same game for both opponents
    seeds = [rng.randrange(1 << 30) for _ in range(4)]
    me = make_player("planner-list", gd, prior, seeds[0], rollouts=rollouts, teams=pvpoke)
    foe = make_player("planner-list", gd, prior, seeds[1], rollouts=rollouts, teams=pvpoke)
    if opp == "habits":
        foe = HabitOpponent(foe, battle.habits, seeds[3])
    side = game % 2
    teams, players = [battle.you, battle.them], [me, foe]
    if side:
        teams.reverse()
        players.reverse()
    s = SCORE[play(gd, teams, players, seed=seeds[2]).winner]
    return battle.id, opp, s if side == 0 else 1 - s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--turns", type=Path, default=TURNS, help="the Battle Turns folder")
    ap.add_argument("--games", type=int, default=8, help="replays per battle per opponent")
    ap.add_argument("--rollouts", type=int, default=12)
    ap.add_argument("--workers", type=int, default=None)
    args = ap.parse_args()
    gd = gamedata.use(FORMAT)
    every = load(gd, args.turns)
    battles = [b for b in every if b.seen == 3]
    jobs = [(b, opp, g, args.rollouts) for b in battles for opp in ("habits", "planner") for g in range(args.games)]
    start = time.time()
    with ProcessPoolExecutor(args.workers) as pool:
        res = list(pool.map(job, jobs, chunksize=2))
    rate = {(b, o): [] for b in (x.id for x in battles) for o in ("habits", "planner")}
    for bid, o, s in res:
        rate[bid, o].append(s)
    rate = {k: sum(v) / len(v) for k, v in rate.items()}
    name = lambda spec: "/".join(gd.species[s].name.replace(" (Shadow)", "ˢ").replace(" (Galarian)", "-G")  # noqa: E731
                                 .replace(" (Alolan)", "-A").replace(" (Full Belly)", "") for s, _, _ in spec)
    print(f"{len(battles)} of your {len(every)} recorded battles (all three of theirs seen), "
          f"{args.games} replays each per opponent, {time.time() - start:.0f}s.\n")
    print(f"{'battle':<30}{'you':<26}{'them':<32}{'shielded':>9}{'baited':>8}{'real':>6}{'vs habits':>11}{'vs planner':>12}")
    for b in battles:
        h = b.habits
        sh = f"{sum(h.shields)}/{len(h.shields)}" if h.shields else "-"
        ba = f"{sum(h.baits)}/{len(h.baits)}" if h.baits else "-"
        print(f"{b.id:<30}{name(b.you):<26}{name(b.them):<32}{sh:>9}{ba:>8}{b.result or '?':>6}"
              f"{rate[b.id, 'habits']:>11.2f}{rate[b.id, 'planner']:>12.2f}")

    print()
    for o, title in (("habits", "the planner with their shield and bait habits"), ("planner", "the planner alone")):
        xs = [s for _, oo, s in res if oo == o]
        m = sum(xs) / len(xs)
        se = math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1) / len(xs))
        per = [rate[b.id, o] for b in battles]
        print(f"vs {title}: your planner wins {sum(p > 0.5 for p in per)} of {len(battles)} battles, "
              f"splits {sum(p == 0.5 for p in per)}; {m:.3f} ± {se:.3f} of replays")
        for real in ("won", "lost"):
            sub = [rate[b.id, o] for b in battles if b.result == real]
            if sub:
                print(f"    in the {len(sub)} you {real}: it wins {sum(p > 0.5 for p in sub)} "
                      f"({sum(sub) / len(sub):.2f} of replays)")
    real = [b for b in battles if b.result in ("won", "lost")]
    print(f"\nYou won {sum(b.result == 'won' for b in real)} of these {len(real)} (with a result recorded).")
    all_sh = [x for b in battles for x in b.habits.shields]
    all_ba = [x for b in battles for x in b.habits.baits]
    print(f"Your opponents shielded {sum(all_sh)} of {len(all_sh)} charged moves they could have, and "
          f"threw their cheaper move {sum(all_ba)} of {len(all_ba)} times while you had a shield.")


if __name__ == "__main__":
    main()
