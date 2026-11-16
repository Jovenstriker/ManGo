"""Decision regret: how much each of your real decisions cost, by the planner's estimate.

    cd POMDP && python3 -m experiments.regret --rollouts 64

For each of your recorded battles (`Battle Turns/`), the battle is rebuilt at the start of every
turn where you decided something (battle_turns.battle_at): HP rebuilt from the recorded moves,
energy, buffs, shields, switch timers, who's mid fast move, and what each side had seen. The
planner's belief is fed everything you'd seen up to then, so it knows what you knew and no more.
Then it estimates each option's chance of winning with rollouts:

  act      on a free turn: fast move, each charged move you could afford, each switch
  shield   when they threw at you: shield or not
  replace  after a faint: each Pokémon you could bring in

Regret = P(win | the planner's best option) − P(win | what you did). The rollouts are split in
half: one half picks the best option and the other half scores both, so noise in the estimates
doesn't inflate the regret (it can come out slightly negative). Like a chess engine's accuracy
score, it measures decisions, not results.

The output names your recordings, so keep it local.
"""
from __future__ import annotations

import argparse
import math
import random
import statistics
import time
import zlib
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from mango_pomdp import gamedata
from mango_pomdp.battle import CHARGED, FAST, SWITCH
from mango_pomdp.battle_turns import battle_at, load
from mango_pomdp.planner import Planner
from mango_pomdp.team_prior import TeamPrior

FORMAT = "mega_great_league"
TURNS = Path(__file__).resolve().parents[2] / "Battle Turns"
BLUNDER = 0.05


def label(d) -> str:
    return {"charged": "throw", "fast": "hold", "switch": "switch", "shield": "shield",
            "replace": "replace"}[d.choice[0]]


def evaluate(args):
    """[(decision type, regret, P(win) of yours, P(win) of best, what you did, the best)] for one battle."""
    rb, rollouts = args
    gd = gamedata.use(FORMAT)
    planner = Planner(gd, TeamPrior(gd), rollouts=rollouts, seed=zlib.crc32(rb.id.encode()))
    planner.start(0)
    fed = -1   # events fed through this turn
    out = []
    for d in rb.decisions:
        if d.turn not in rb.snapshots:
            continue
        for t in range(fed + 1, d.turn):   # what you'd seen before this turn
            planner.observe(rb.events.get(t, []))
        fed = max(fed, d.turn - 1)
        if d.kind == "replace":
            if d.turn + 1 not in rb.snapshots:
                continue
            planner.observe(rb.events.get(d.turn, []))   # the faint itself
            fed = d.turn
            b = battle_at(gd, rb, d.turn + 1, active=d.fainted)
            b.sides[0].mon.hp = 0
        else:
            b = battle_at(gd, rb, d.turn, energy=d.energy if d.kind == "act" else None)
        view = b.view(0)
        me = b.sides[0]
        if me.mon.hp <= 0 and d.kind != "replace":
            continue
        ids = [m.species.id for m in me.mons]
        if d.kind == "act":
            cands = [FAST] + [CHARGED(i) for i, c in enumerate(me.mon.charged) if me.mon.energy >= c.energy]
            if me.switch_timer == 0:
                cands += [SWITCH(i) for i in me.bench()]
            kind, arg = d.choice
            mine = (FAST if kind == "fast" else
                    next((CHARGED(i) for i, c in enumerate(me.mon.charged) if c.id == arg), None) if kind == "charged" else
                    SWITCH(ids.index(arg)) if arg in ids else None)
            if mine not in cands:
                continue   # the rebuilt state doesn't allow it (energy or timer off by a little)
            outs = planner.outcomes(view, cands, first=True, rollouts=rollouts)
        elif d.kind == "shield":
            if me.shields == 0 or d.move not in gd.moves:
                continue
            move = gd.moves[d.move]
            cands = [False, True]
            mine = d.choice[1]

            def apply(bb, choice, ctrls, move=move):
                for x in (0, 1):
                    if bb.sides[x].fast_due == bb.turn:
                        bb._land_fast(x)
                bb.land_charged(1, move, ctrls, shield=choice)
                bb.handle_faints(ctrls)
                bb.end_turn(True)

            b.sides[1].mon.energy = max(b.sides[1].mon.energy, move.energy)
            if move not in b.sides[1].mon.charged:
                continue
            outs = planner.outcomes(view, cands, apply, incoming=move, rollouts=rollouts)
        else:
            bench = [i for i, m in enumerate(me.mons) if m.hp > 0 and i != me.active]
            arg = d.choice[1]
            if len(bench) < 2 or arg not in ids or ids.index(arg) not in bench:
                continue
            cands = bench
            mine = ids.index(arg)
            outs = planner.outcomes(view, cands, lambda bb, i, ctrls: bb.switch_in(0, i, timer=False),
                                    rollouts=rollouts)
        half = len(outs[0]) // 2
        pick = max(range(len(cands)), key=lambda j: sum(outs[j][:half]))
        score = [sum(o[half:]) / (len(o) - half) for o in outs]
        j = cands.index(mine)
        full = [sum(o) / len(o) for o in outs]
        out.append((label(d), score[pick] - score[j], full[j], full[pick], str(mine), str(cands[pick])))
    return rb.id, rb.result, out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--turns", type=Path, default=TURNS)
    ap.add_argument("--rollouts", type=int, default=64)
    ap.add_argument("--workers", type=int, default=None)
    args = ap.parse_args()
    gd = gamedata.use(FORMAT)
    battles = [b for b in load(gd, args.turns) if b.seen == 3 and not b.misread and b.decisions]
    start = time.time()
    with ProcessPoolExecutor(args.workers) as pool:
        res = list(pool.map(evaluate, [(b, args.rollouts) for b in battles]))
    rows = [(bid, result, *r) for bid, result, out in res for r in out]
    print(f"{len(rows)} of your decisions in {len(battles)} recorded battles, {args.rollouts} rollouts each, "
          f"{time.time() - start:.0f}s. Regret in win-probability points; a blunder costs over "
          f"{BLUNDER:.0%}.\n")

    def summary(xs):
        reg = [x[3] for x in xs]
        m = statistics.mean(reg)
        se = statistics.stdev(reg) / math.sqrt(len(reg)) if len(reg) > 1 else 0
        same = sum(x[6] == x[7] for x in xs)
        return (f"{len(xs):>5}  {m:>+7.3f} ± {se:.3f}  {sum(r > BLUNDER for r in reg) / len(reg):>8.0%}"
                f"  {same / len(xs):>13.0%}")

    print(f"{'decision':<10}{'count':>6}  {'mean regret':>15}  {'blunders':>8}  {'planner agrees':>13}")
    for kind in ("throw", "hold", "shield", "switch", "replace"):
        xs = [r for r in rows if r[2] == kind]
        if xs:
            print(f"{kind:<10}{summary(xs)}")
    print(f"{'all':<10}{summary(rows)}")

    per = defaultdict(list)
    for r in rows:
        per[r[0], r[1]].append(r[3])
    print("\nPer battle: total regret (win probability given up over the battle), by how it really ended:")
    for result in ("won", "lost", ""):
        tot = [sum(v) for (bid, res_), v in per.items() if res_ == result]
        each = [x for (bid, res_), v in per.items() if res_ == result for x in v]
        if tot:
            print(f"  {result or 'unknown':<8} {len(tot):>3} battles: mean {statistics.mean(tot):+.2f}, "
                  f"median {statistics.median(tot):+.2f}; per decision {statistics.mean(each):+.3f} "
                  f"over {len(each) / len(tot):.0f} decisions a battle")
    # A check on the estimates themselves: is the planner's P(win) for what you did higher in
    # battles you really won? (A Brier score compares it with the result, decision by decision.)
    known = [r for r in rows if r[1] in ("won", "lost")]
    if known:
        for result in ("won", "lost"):
            ps = [r[4] for r in known if r[1] == result]
            print(f"  estimated P(win) of your choices in battles you {result}: mean {statistics.mean(ps):.2f}")
        brier = statistics.mean((r[4] - (r[1] == "won")) ** 2 for r in known)
        base = statistics.mean(r[1] == "won" for r in known)
        print(f"  Brier score {brier:.3f} (0 is perfect; always guessing the {base:.0%} base rate scores "
              f"{base * (1 - base):.3f})")
    worst = sorted(rows, key=lambda r: -r[3])[:12]
    print("\nCostliest decisions:")
    for bid, result, kind, reg, p_mine, p_best, mine, best in worst:
        print(f"  {bid:<30}{kind:<8} regret {reg:+.2f}: you {mine} (P(win) {p_mine:.2f}), "
              f"planner {best} ({p_best:.2f})")


if __name__ == "__main__":
    main()
