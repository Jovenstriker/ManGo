"""Head to head: one player against another on random pairs of listed Mega Great League teams.

    cd POMDP && python3 -m experiments.head_to_head pomcp-list-mixed planner-list-mixed --pairs 150 --rollouts 12

Each pair of teams is played twice with the sides swapped, so team strength cancels, and each
player's list prior leaves out its own team. With --unlisted it leaves out both teams, so
neither side's real team is on the list the other's belief knows, as with most real opponents.
The score is the first player's win rate (a draw counts half), with a standard error over pairs.
"""
from __future__ import annotations

import argparse
import math
import random
import time
from concurrent.futures import ProcessPoolExecutor

from mango_pomdp import gamedata
from mango_pomdp.match import make_player, play, valid_player
from mango_pomdp.team_prior import TeamPrior

SCORE = {0: 1.0, -1: 0.5, 1: 0.0}


def game(job):
    a, b, k, rollouts, unlisted = job
    gd = gamedata.use("mega_great_league")
    prior = TeamPrior(gd)
    rng = random.Random(1000 + k)
    i, j = rng.sample(range(len(gd.teams)), 2)
    seeds = [rng.randrange(1 << 30) for _ in range(3)]
    out = 0.0
    for swap in (False, True):
        ti, tj = (j, i) if swap else (i, j)   # player a plays team ti
        hide_a, hide_b = ({ti, tj}, {ti, tj}) if unlisted else ({ti}, {tj})
        pa = make_player(a, gd, prior, seeds[0], rollouts=rollouts,
                         teams=[t for x, t in enumerate(gd.teams) if x not in hide_a])
        pb = make_player(b, gd, prior, seeds[1], rollouts=rollouts,
                         teams=[t for x, t in enumerate(gd.teams) if x not in hide_b])
        battle = play(gd, [list(gd.teams[ti].spec), list(gd.teams[tj].spec)], [pa, pb], seed=seeds[2])
        out += SCORE[battle.winner]
    return out / 2


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--pairs", type=int, default=150)
    ap.add_argument("--rollouts", type=int, default=12)
    ap.add_argument("--unlisted", action="store_true", help="leave both teams off both players' lists")
    ap.add_argument("--workers", type=int, default=None)
    args = ap.parse_args()
    for name in (args.a, args.b):
        if not valid_player(name):
            raise SystemExit(f"unknown player {name!r}")
    start = time.time()
    with ProcessPoolExecutor(args.workers) as pool:
        xs = list(pool.map(game, [(args.a, args.b, k, args.rollouts, args.unlisted) for k in range(args.pairs)],
                           chunksize=2))
    m = sum(xs) / len(xs)
    se = math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1) / len(xs))
    print(f"{args.a} vs {args.b}, {args.rollouts} rollouts{', teams unlisted' if args.unlisted else ''}: "
          f"{m:.3f} ± {se:.3f} over {len(xs)} team pairs × 2 sides ({time.time() - start:.0f}s)")


if __name__ == "__main__":
    main()
