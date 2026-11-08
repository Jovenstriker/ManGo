"""One 1v1 matchup, solved: optimal pacing, throws and shields for both sides.

    cd POMDP
    python3 -m experiments.duel medicham azumarill                  # 1-1 shields
    python3 -m experiments.duel medicham azumarill --shields 2 0
    python3 -m experiments.duel medicham azumarill --grid           # all 9 shield scenarios
    python3 -m experiments.duel registeel swampert --moves LOCK_ON FLASH_CANNON ZAP_CANNON

Movesets default to PvPoke's recommended ones. Ratings are PvPoke's battle rating for the first
Pokémon: 500 + 500 × (its HP% left − the other's HP% left), so above 500 is a win.
"""
from __future__ import annotations

import argparse
import time

from mango_pomdp.duel import Duel, DuelPlayer, Fighter, Strategy, make_duel, play_out
from mango_pomdp.gamedata import load
from mango_pomdp.policies import Heuristic
from mango_pomdp.timeline import render


def rating(battle, duel) -> float:
    a, b = duel.f
    return 500 + 500 * (battle.sides[0].mon.hp / a.species.hp - battle.sides[1].mon.hp / b.species.hp)


def actor_value(strat: Strategy, side: int, action) -> float:
    """What `action` is worth to the side taking it, against the other side's equilibrium mix."""
    acts = strat.actions[side]
    i = acts.index(action)
    if side == 0:
        return sum(y * strat.payoffs[i][j] for j, y in enumerate(strat.mix[1]))
    return -sum(x * strat.payoffs[r][i] for r, x in enumerate(strat.mix[0]))


def single(duel: Duel, shields: tuple[int, int], energy: tuple[int, int]) -> None:
    a, b = duel.f
    names = (a.species.name, b.species.name)
    start = time.time()
    v = duel.value(duel.start(shields, energy))
    solve = time.time() - start
    players = [DuelPlayer(duel, 1), DuelPlayer(duel, 2)]
    battle = play_out(duel, shields, players, seed=1, energy=energy)

    print(f"{a}\n  vs {b}\n  {shields[0]}-{shields[1]} shields"
          + (f", starting energy {energy[0]}-{energy[1]}" if any(energy) else ""))
    print(f"Solved {duel.states():,} states in {solve:.2f}s.\n")
    winner = {0: names[0], 1: names[1], -1: None}[battle.winner]
    left = [m.hp for side in battle.sides for m in side.mons]
    mixed = any(max(s.mix[p.side]) < 0.999 for p in players for _, s in p.decisions)
    print(("Tie" if winner is None else f"{winner} wins") + f" with optimal play by both: "
          f"{names[0]} {left[0]}/{a.species.hp} HP, {names[1]} {left[1]}/{b.species.hp} HP, "
          f"rating {rating(battle, duel):.0f}.")
    if mixed:
        print(f"Some turns call for a mixed strategy, so this is one sample; the expected payoff is {v:+.3f}.")
    print()
    print(render(battle, names))
    print()
    play_by_play(battle, duel, players)
    print()

    baseline = play_out(duel, shields, [Heuristic("baiter", eps=0, seed=1), Heuristic("baiter", eps=0, seed=2)],
                        seed=1, energy=energy)
    vs_ai = [play_out(duel, shields, [DuelPlayer(duel, 1), Heuristic("baiter", eps=0, seed=2)], seed=1, energy=energy),
             play_out(duel, shields, [Heuristic("baiter", eps=0, seed=1), DuelPlayer(duel, 2)], seed=1, energy=energy)]
    rows = [("both optimal", rating(battle, duel)), ("both play the baiter heuristic", rating(baseline, duel)),
            (f"{names[0]} optimal, {names[1]} baiter", rating(vs_ai[0], duel)),
            (f"{names[0]} baiter, {names[1]} optimal", rating(vs_ai[1], duel))]
    width = max(len(r) for r, _ in rows)
    print(f"Ratings for {names[0]}:")
    for label, r in rows:
        print(f"  {label:<{width}}  {r:4.0f}")


def play_by_play(battle, duel: Duel, players: list[DuelPlayer]) -> None:
    names = [f.species.name for f in duel.f]
    energy = [0, 0]
    decisions = [dict(p.decisions) for p in players]
    shields = {(t, m): (no, yes) for p in players for t, m, no, yes in p.shield_calls}
    print("Charged moves. Values are payoffs for the player deciding (±0.9 for the result, ±0.1 × HP% margin):")
    print("what the throw was worth, then the alternatives; what taking and shielding it were worth.")
    print(f"  {'turn':>4}  {'who':<12} {'move':<16} {'energy':>7}   {'defender':<44} {'thrower: this / instead'}")
    for e in battle.log:
        if e.kind == "fast":
            energy[e.side] = min(100, energy[e.side] + e.move.energy_gain)
        elif e.kind == "charged":
            before = energy[e.side]
            energy[e.side] -= e.move.energy
            strat = decisions[e.side].get(e.turn)
            instead = ""
            if strat:
                acts = strat.actions[e.side]
                mine = acts[[duel.f[e.side].charged[i].id if i >= 0 else None for i in acts].index(e.move.id)]
                alts = [f"{duel.f[e.side].action_name(a)} {actor_value(strat, e.side, a):+.3f}" for a in acts if a != mine]
                instead = f"{actor_value(strat, e.side, mine):+.3f} / " + ", ".join(alts)
            no_yes = shields.get((e.turn, e.move.id))
            if e.info["target_shields"] == 0:
                verdict = "no shields left"
            elif no_yes:
                d = 1 - e.side   # the defender, valued for itself
                take, block = (no_yes[0], no_yes[1]) if d == 0 else (-no_yes[0], -no_yes[1])
                verdict = f"{'shielded' if e.info['shielded'] else 'took it'} (take {take:+.3f}, shield {block:+.3f})"
            else:
                verdict = "shielded" if e.info["shielded"] else "took it"
            print(f"  {e.turn:>4}  {names[e.side]:<12} {e.move.name:<16} {before:>3}→{energy[e.side]:<3}   "
                  f"{verdict:<44} {instead}")
    for side, p in enumerate(players):
        held = [t for t, s in p.decisions if not any(
            e.kind == "charged" and e.turn == t and e.side == side for e in battle.log)]
        if held:
            print(f"  {names[side]} fast moved on {len(held)} turn(s) it could have thrown: "
                  f"{', '.join(map(str, held[:12]))}{' …' if len(held) > 12 else ''}")


def grid(duel: Duel) -> None:
    a, b = duel.f
    start = time.time()
    duel.value(duel.start((2, 2)))   # every smaller shield count is part of this game too
    print(f"{a}\n  vs {b}")
    print(f"Solved {duel.states():,} states in {time.time() - start:.1f}s.\n")
    cells = {}
    for s0 in range(3):
        for s1 in range(3):
            optimal = play_out(duel, (s0, s1), seed=1)
            ai = play_out(duel, (s0, s1), [Heuristic("baiter", eps=0, seed=1), Heuristic("baiter", eps=0, seed=2)], seed=1)
            cells[s0, s1] = (rating(optimal, duel), rating(ai, duel))
    for title, k in (("Optimal play", 0), ("Both play the baiter heuristic", 1)):
        print(f"{title}: rating for {a.species.name}; rows are its shields, columns {b.species.name}'s")
        print("        " + "".join(f"{s1:>8}" for s1 in range(3)))
        for s0 in range(3):
            print(f"  {s0:>4}  " + "".join(f"{cells[s0, s1][k]:>7.0f}{'W' if cells[s0, s1][k] > 500 else ' '}"
                                         for s1 in range(3)))
        print()
    flips = sum((o > 500) != (h > 500) for o, h in cells.values())
    print(f"Optimal play changes the winner in {flips} of 9 shield scenarios.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--shields", nargs=2, type=int, default=[1, 1], metavar=("A", "B"))
    ap.add_argument("--energy", nargs=2, type=int, default=[0, 0], metavar=("A", "B"), help="starting energy")
    ap.add_argument("--moves", nargs=3, metavar=("FAST", "CHARGED1", "CHARGED2"), help="moveset for the first")
    ap.add_argument("--vs-moves", nargs=3, metavar=("FAST", "CHARGED1", "CHARGED2"), help="moveset for the second")
    ap.add_argument("--grid", action="store_true", help="all 9 shield scenarios")
    ap.add_argument("--python", action="store_true", help="use the pure Python solver (slow; the reference)")
    args = ap.parse_args()
    gd = load()
    fa, fb = Fighter.of(gd, args.a, args.moves), Fighter.of(gd, args.b, args.vs_moves)
    duel = Duel(fa, fb) if args.python else make_duel(fa, fb)
    if args.grid:
        grid(duel)
    else:
        single(duel, tuple(args.shields), tuple(args.energy))


if __name__ == "__main__":
    main()
