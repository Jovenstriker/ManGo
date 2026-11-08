"""Every 1v1 among PvPoke's top Great League Pokémon, solved, against the heuristic AI.

    cd POMDP && python3 -m experiments.meta --top 20 --shields 1 1

For each pair (recommended movesets), it plays four battles in the simulator: both optimal, both
the baiter heuristic, and the solved player against the heuristic from each side. It reports how
often optimal play changes the winner, how many rating points a solved player gains against the
heuristic, and how often the optimal line needs a mixed strategy.
"""
from __future__ import annotations

import argparse
import time

from mango_pomdp.duel import DuelPlayer, Fighter, make_duel, play_out
from mango_pomdp.gamedata import load
from mango_pomdp.policies import Heuristic


def rating(battle, duel) -> float:
    a, b = duel.f
    return 500 + 500 * (battle.sides[0].mon.hp / a.species.hp - battle.sides[1].mon.hp / b.species.hp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--shields", nargs=2, type=int, default=[1, 1])
    args = ap.parse_args()
    shields = tuple(args.shields)
    gd = load()
    # One form per species (no shadow and regular of the same Pokémon).
    pool, dex = [], set()
    for s in gd.ranked:
        if s.dex not in dex:
            pool.append(s)
            dex.add(s.dex)
        if len(pool) == args.top:
            break

    def ai(seed):
        return Heuristic("baiter", eps=0, seed=seed)

    rows, gains, flips, mixed, states, solve = [], [], [], 0, 0, 0.0
    for i, a in enumerate(pool):
        for b in pool[i + 1:]:
            duel = make_duel(Fighter.of(gd, a.id), Fighter.of(gd, b.id))
            t = time.time()
            duel.value(duel.start(shields))
            solve += time.time() - t
            states += duel.states()
            players = [DuelPlayer(duel, 1), DuelPlayer(duel, 2)]
            opt = rating(play_out(duel, shields, players, seed=1), duel)
            mixed += any(max(s.mix[p.side]) < 0.999 for p in players for _, s in p.decisions)
            heur = rating(play_out(duel, shields, [ai(1), ai(2)], seed=1), duel)
            a_solved = rating(play_out(duel, shields, [DuelPlayer(duel, 1), ai(2)], seed=1), duel)
            b_solved = rating(play_out(duel, shields, [ai(1), DuelPlayer(duel, 2)], seed=1), duel)
            gains += [a_solved - heur, heur - b_solved]   # rating points gained by the solved side
            if (opt > 500) != (heur > 500):
                flips.append((a.name, b.name, opt, heur))
            rows.append((a.name, b.name, opt, heur, a_solved, b_solved))

    n = len(rows)
    print(f"Top {len(pool)} Great League Pokémon, {n} matchups, {shields[0]}-{shields[1]} shields. "
          f"Solved {states:,} states in {solve:.1f}s.\n")
    print(f"Optimal play changes the winner (vs both playing the baiter heuristic) in {len(flips)} of {n} matchups.")
    print(f"A solved player facing the heuristic gains {sum(gains) / len(gains):.0f} rating points on average "
          f"over playing the heuristic itself (median {sorted(gains)[len(gains) // 2]:.0f}, max {max(gains):.0f}).")
    print(f"Wins flipped by solving one side only: "
          f"{sum((r[4] > 500) != (r[3] > 500) for r in rows) + sum((r[5] > 500) != (r[3] > 500) for r in rows)} "
          f"of {2 * n} (matchup, side) pairs.")
    print(f"The optimal line needs a mixed strategy in {mixed} of {n} matchups.\n")
    if flips:
        print("Matchups where optimal play changes the winner (rating for the first):")
        for a, b, opt, heur in sorted(flips, key=lambda f: -abs(f[2] - f[3])):
            print(f"  {a:<22} vs {b:<22} optimal {opt:4.0f}   heuristic {heur:4.0f}")


if __name__ == "__main__":
    main()
