"""Win rates against realistic opponents.

    cd POMDP && python3 -m experiments.tournament --games 200 --players baiter planner oracle

Each game draws two teams from the structured prior and an opponent style, then is played twice
with the teams swapped, so a strong or weak draw counts for both sides equally (a paired design).
Ties count as half a win. The opponent never knows which player it faces.

Columns: overall win rate ± standard error, then the win rate against each opponent style.
The lowest of those is a crude exploitability measure: how badly the best-responding style does.
"""
from __future__ import annotations

import argparse
import math
import random
import time
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor

from mango_pomdp.gamedata import load
from mango_pomdp.match import PLAYERS, make_player, play, valid_player
from mango_pomdp.policies import STYLES, Heuristic
from mango_pomdp.team_prior import TeamPrior


def run_game(job):
    player, game, seed, rollouts, styles = job
    gd = load()
    prior = TeamPrior(gd)
    rng = random.Random(seed * 7919 + game)
    teams = [prior.sample_team(rng), prior.sample_team(rng)]
    style = rng.choice(styles)
    out = []
    for swap in (False, True):
        mine, theirs = (teams[1], teams[0]) if swap else (teams[0], teams[1])
        me = make_player(player, gd, prior, rng.randrange(1 << 30), truth=theirs, truth_style=style, rollouts=rollouts)
        foe = Heuristic(style, seed=rng.randrange(1 << 30))
        battle = play(gd, [mine, theirs], [me, foe], seed=rng.randrange(1 << 30))
        out.append((style, {0: 1.0, -1: 0.5, 1: 0.0}[battle.winner]))
    return player, out


def player_name(name: str) -> str:
    if valid_player(name):
        return name
    raise argparse.ArgumentTypeError(f"unknown player {name!r}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--games", type=int, default=100)
    ap.add_argument("--players", nargs="+", default=["random", "baiter", "planner", "oracle"], type=player_name,
                    help=f"{PLAYERS}; planners take @start, @zero-turn, @catch (the default) or @any")
    ap.add_argument("--opponents", nargs="+", default=list(STYLES), choices=STYLES)
    ap.add_argument("--rollouts", type=int, default=12)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--workers", type=int, default=None)
    args = ap.parse_args()

    jobs = [(p, g, args.seed, args.rollouts, tuple(args.opponents)) for p in args.players for g in range(args.games)]
    results: dict[str, list[tuple[str, float]]] = defaultdict(list)
    start = time.time()
    with ProcessPoolExecutor(args.workers) as pool:
        for player, out in pool.map(run_game, jobs, chunksize=4):
            results[player].extend(out)

    header = f"{'player':<16}{'win rate':>16}" + "".join(f"{'vs ' + s:>14}" for s in args.opponents)
    print(f"{args.games} games × 2 sides per player, opponents {', '.join(args.opponents)}, "
          f"{args.rollouts} rollouts, {time.time() - start:.0f}s\n")
    print(header)
    for p in args.players:
        scores = [s for _, s in results[p]]
        mean = sum(scores) / len(scores)
        se = math.sqrt(sum((s - mean) ** 2 for s in scores) / (len(scores) - 1) / len(scores))
        row = f"{p:<16}{f'{mean:.3f} ± {se:.3f}':>16}"
        for style in args.opponents:
            vs = [s for st, s in results[p] if st == style]
            row += f"{(sum(vs) / len(vs) if vs else float('nan')):>14.3f}"
        print(row)


if __name__ == "__main__":
    main()
