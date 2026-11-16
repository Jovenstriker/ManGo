"""How long a simulated battle stays like the real one.

    cd POMDP && python3 -m experiments.recorded_paths --games 4

Each of your recorded battles (`Battle Turns/`, all three of theirs seen) is played with the
real teams and movesets, the planner on your side and the planner on theirs. After every turn
the simulation is compared with the real battle at the same point (HP rebuilt from the recorded
moves): the same Pokémon in on both sides, the same shields on both sides, and both active
Pokémon's HP within 20%. The first turn that fails is where the replay left the real battle.
The output names your recordings, so keep it local.
"""
from __future__ import annotations

import argparse
import random
import statistics
import time
import zlib
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from mango_pomdp import gamedata
from mango_pomdp.battle import Battle
from mango_pomdp.battle_turns import State, load
from mango_pomdp.match import make_player
from mango_pomdp.team_prior import TeamPrior, build_team

FORMAT = "mega_great_league"
PLANNER = "planner-list-mixed"   # the four styles and the learned opponent, farming down
TURNS = Path(__file__).resolve().parents[2] / "Battle Turns"


class PathTracker:
    """Watches a simulated battle and notes the first turn it differs from the real one."""

    def __init__(self, battle: Battle, path: dict[int, State], you: int):
        self.b, self.path, self.you = battle, path, you
        self.left: int | None = None
        self.why = ""

    def observe(self, events) -> None:
        if self.left is not None:
            return
        t = self.b.clock - 1
        real = self.path.get(t)
        if real is None:
            return
        me, them = self.b.sides[self.you], self.b.sides[1 - self.you]
        sim = State(me.mon.species.id, them.mon.species.id, me.shields, them.shields,
                    me.mon.hp / me.mon.max_hp, them.mon.hp / them.mon.max_hp)
        if not sim.like(real):
            self.left = t
            if (sim.you, sim.them) != (real.you, real.them):
                self.why = "a different Pokémon in"
            elif (sim.you_shields, sim.them_shields) != (real.you_shields, real.them_shields):
                self.why = "different shields"
            else:
                self.why = "HP more than 20% off"


def job(args):
    battle, game, rollouts = args
    gd = gamedata.use(FORMAT)
    prior = TeamPrior(gd)
    pvpoke = [gd.teams[k] for k in gd.team_pool("pvpoke")]
    rng = random.Random(zlib.crc32(repr((battle.id, game)).encode()))
    seeds = [rng.randrange(1 << 30) for _ in range(3)]
    me = make_player(PLANNER, gd, prior, seeds[0], rollouts=rollouts, teams=pvpoke)
    foe = make_player(PLANNER, gd, prior, seeds[1], rollouts=rollouts, teams=pvpoke)
    side = game % 2
    specs, players = [battle.you, battle.them], [me, foe]
    if side:
        specs.reverse()
        players.reverse()
    b = Battle([build_team(gd, specs[0]), build_team(gd, specs[1])], seed=seeds[2])
    for s, p in enumerate(players):
        p.start(s)
    tracker = PathTracker(b, battle.path, side)
    for p in players:
        p.observe(b.log)
    b.play(players, players + [tracker])
    length = max(battle.path) + 1
    won = {0: 1.0, -1: 0.5, 1: 0.0}[b.winner]
    return battle.id, tracker.left if tracker.left is not None else length, length, tracker.why, \
        won if side == 0 else 1 - won


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--turns", type=Path, default=TURNS)
    ap.add_argument("--games", type=int, default=4)
    ap.add_argument("--rollouts", type=int, default=12)
    ap.add_argument("--workers", type=int, default=None)
    args = ap.parse_args()
    gd = gamedata.use(FORMAT)
    battles = [b for b in load(gd, args.turns) if b.seen == 3 and not b.misread]
    jobs = [(b, g, args.rollouts) for b in battles for g in range(args.games)]
    start = time.time()
    with ProcessPoolExecutor(args.workers) as pool:
        res = list(pool.map(job, jobs, chunksize=2))
    print(f"{len(battles)} recorded battles × {args.games} replays, planner vs planner, {time.time() - start:.0f}s.\n")
    print(f"{'battle':<30}{'real turns':>11}{'stays like it for (turns, per replay)':>40}")
    for b in battles:
        rs = [r for r in res if r[0] == b.id]
        print(f"{b.id:<30}{rs[0][2]:>11}{'  '.join(str(r[1]) for r in rs):>40}")
    left = [r[1] for r in res]
    frac = [r[1] / r[2] for r in res]
    print(f"\nTurns until a replay leaves the real battle: median {statistics.median(left):.0f}, "
          f"mean {statistics.mean(left):.1f} (real battles run {statistics.median(r[2] for r in res):.0f} "
          f"turns, median).")
    for share in (0.1, 0.25, 0.5, 1.0):
        n = sum(f >= share for f in frac)
        print(f"  still like the real battle {share:.0%} of the way through: {n} of {len(res)} replays ({n / len(res):.0%})")
    why = Counter(r[3] for r in res if r[3])
    print("What differed first: " + ", ".join(f"{k} {v}" for k, v in why.most_common()))
    real = {b.id: b.result for b in battles}
    by = {}
    for bid, _, _, _, w in res:
        by.setdefault(bid, []).append(w)
    agree = [(sum(v) / len(v) > 0.5) == (real[bid] == "won") for bid, v in by.items() if real[bid] in ("won", "lost")
             and sum(v) / len(v) != 0.5]
    print(f"Simulated winner (majority of replays) matches the real result in {sum(agree)} of {len(agree)} battles.")


if __name__ == "__main__":
    main()
