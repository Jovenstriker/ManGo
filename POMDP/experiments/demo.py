"""One battle, narrated from the planner's side: what it sees, counts and believes.

    cd POMDP && python3 -m experiments.demo --seed 3 --opponent nuker
"""
from __future__ import annotations

import argparse
import random

from mango_pomdp.gamedata import load
from mango_pomdp.match import play
from mango_pomdp.planner import Planner
from mango_pomdp.policies import STYLES, Heuristic
from mango_pomdp.team_prior import TeamPrior, describe


class Narrator:
    def __init__(self, gd, planner: Planner):
        self.gd, self.planner = gd, planner

    def observe(self, events):
        b = self.planner.belief
        for e in events:
            who = "you " if e.side == self.planner.side else "them"
            name = self.gd.species[e.species].name
            if e.kind == "enter":
                print(f"{e.turn / 2:6.1f}s  {who}  {name} comes in")
                if e.side != self.planner.side:
                    self._belief(b)
            elif e.kind == "charged":
                shield = " (shielded)" if e.info["shielded"] else ""
                print(f"{e.turn / 2:6.1f}s  {who}  {name}: {e.move.name}, {e.info['damage']} damage{shield}")
                if e.side != self.planner.side:
                    self._belief(b)
            elif e.kind == "faint":
                print(f"{e.turn / 2:6.1f}s  {who}  {name} faints")

    def _belief(self, b):
        energy = ", ".join(f"{self.gd.species[s].name} {n}" for s, n in b.counter.energy.items())
        styles = ", ".join(f"{s} {p:.2f}" for s, p in sorted(b.style_posterior().items(), key=lambda x: -x[1]))
        back = ", ".join(f"{self.gd.species[s].name} {p:.2f}" for s, p in b.unseen_posterior()[:4])
        print(f"{'':16}counted energy: {energy}")
        print(f"{'':16}style: {styles}")
        if back:
            print(f"{'':16}unseen, most likely: {back}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--opponent", default="nuker", choices=STYLES)
    args = ap.parse_args()
    gd = load()
    prior = TeamPrior(gd)
    rng = random.Random(args.seed)
    teams = [prior.sample_team(rng), prior.sample_team(rng)]
    print("you: ", describe(gd, teams[0]))
    print("them:", describe(gd, teams[1]), f"— plays like a {args.opponent}\n")
    planner = Planner(gd, prior, seed=args.seed)
    narrator = Narrator(gd, planner)
    # Print each turn after the planner's belief has taken it in.
    update = planner.observe
    planner.observe = lambda events: (update(events), narrator.observe(events))  # type: ignore[method-assign]
    players = [planner, Heuristic(args.opponent, seed=args.seed + 1)]
    battle = play(gd, teams, players, seed=args.seed)
    result = {0: "you win", 1: "you lose", -1: "tie"}[battle.winner]
    print(f"\n{result} after {battle.clock / 2:.0f}s of battle clock; {planner.decisions} planned decisions")


if __name__ == "__main__":
    main()
