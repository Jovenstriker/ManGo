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

Then it checks the estimates against how your battles really ended, and corrects them: Platt
scaling, P(won) = σ(a + b·logit(estimate)), fitted by 5-fold cross-validation by battle, so each
battle is corrected by a fit that never saw it. It prints everything twice, as estimated and
corrected, with a table of estimated P(win) against how often you really won, and saves the
fit (on every battle) to data/local/calibration.json.

`--styles` sets the opponent types the belief weighs and the rollouts play: the heuristic
styles, and "learned" (the opponent model fitted on your recorded opponents,
experiments/opponent_model.py), alone or mixed in with the styles.

The output names your recordings, so keep it local.
"""
from __future__ import annotations

import argparse
import json
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
from mango_pomdp.gamedata import DATA_DIR
from mango_pomdp.opponent_model import _sigmoid, fit_logistic
from mango_pomdp.planner import Planner
from mango_pomdp.policies import STYLES
from mango_pomdp.team_prior import TeamPrior

FORMAT = "mega_great_league"
TURNS = Path(__file__).resolve().parents[2] / "Battle Turns"
BLUNDER = 0.05
CALIBRATION = DATA_DIR / "local" / "calibration.json"


def label(d) -> str:
    return {"charged": "throw", "fast": "hold", "switch": "switch", "shield": "shield",
            "replace": "replace"}[d.choice[0]]


def evaluate(args):
    """[(decision type, regret, P(win) of yours, P(win) of best, what you did, the best)] for one battle."""
    rb, rollouts, styles = args
    gd = gamedata.use(FORMAT)
    planner = Planner(gd, TeamPrior(gd), rollouts=rollouts, seed=zlib.crc32(rb.id.encode()), styles=tuple(styles))
    planner.start(0)
    fed = -1   # events fed through this turn
    out = []

    def feed(t):
        # With the learned opponent in the belief, it also needs the battle as you saw it at the
        # start of each turn, to score their choices that turn.
        if planner.belief.model is not None and t in rb.snapshots:
            planner.before_turn(battle_at(gd, rb, t, free="them").view(0))
        planner.observe(rb.events.get(t, []))

    for d in rb.decisions:
        if d.turn not in rb.snapshots:
            continue
        for t in range(fed + 1, d.turn):   # what you'd seen before this turn
            feed(t)
        fed = max(fed, d.turn - 1)
        if d.kind == "replace":
            if d.turn + 1 not in rb.snapshots:
                continue
            feed(d.turn)   # the faint itself
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
        out.append((label(d), score[pick] - score[j], full[j], full[pick], str(mine), str(cands[pick]),
                    score[pick], score[j], me.remaining() + b.sides[1].remaining()))
    return rb.id, rb.result, out


def calibrate(rows, rollouts, folds=5):
    """Platt scaling of the planner's P(win) against your real results: P(won) = σ(a + b·logit(p)),
    fitted with battle-level cross-validation, so each battle's estimates are corrected by a fit
    that never saw it. Returns (each row's correction, (a, b) fitted on every battle)."""
    floor = 1 / (2 * rollouts)

    def logit(p):
        p = min(max(p, floor), 1 - floor)
        return math.log(p / (1 - p))

    def fit(rs):
        return fit_logistic([[1.0, logit(r[4])] for r in rs], [int(r[1] == "won") for r in rs], l2=0.01)

    def corrected(w):
        return lambda p: _sigmoid(w[0] + w[1] * logit(p))

    known = [r for r in rows if r[1] in ("won", "lost")]
    ids = sorted({r[0] for r in known})
    random.Random(0).shuffle(ids)
    fold = {bid: k % folds for k, bid in enumerate(ids)}
    fs = {k: corrected(fit([r for r in known if fold[r[0]] != k])) for k in range(folds)}
    whole = fit(known)
    every = corrected(whole)
    return [fs[fold[r[0]]] if r[0] in fold else every for r in rows], tuple(whole)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--turns", type=Path, default=TURNS)
    ap.add_argument("--rollouts", type=int, default=64)
    ap.add_argument("--styles", nargs="+", default=list(STYLES),
                    help="opponent types for the belief and the rollouts: any of the heuristic styles, and "
                         "learned (the opponent model in data/local/opponent_model.json)")
    ap.add_argument("--workers", type=int, default=None)
    args = ap.parse_args()
    gd = gamedata.use(FORMAT)
    battles = [b for b in load(gd, args.turns) if b.seen == 3 and not b.misread and b.decisions]
    start = time.time()
    with ProcessPoolExecutor(args.workers) as pool:
        res = list(pool.map(evaluate, [(b, args.rollouts, args.styles) for b in battles]))
    rows = [(bid, result, *r) for bid, result, out in res for r in out]
    print(f"{len(rows)} of your decisions in {len(battles)} recorded battles, {args.rollouts} rollouts each "
          f"(opponents in the belief and rollouts: {', '.join(args.styles)}), "
          f"{time.time() - start:.0f}s. Regret in win-probability points; a blunder costs over "
          f"{BLUNDER:.0%}.\n")
    report(rows, "The planner's estimates as they are:")
    fs, (a, b) = calibrate(rows, args.rollouts)
    print(f"Calibrated against your real results: P(won) = σ({a:+.2f} {b:+.2f}·logit(estimate)) fitted on "
          f"every battle (a slope under 1 means the raw estimates are overconfident). Below, each battle "
          f"is corrected by a fit on the other folds (5-fold, by battle).\n")
    cal = [(bid, result, kind, f(s_best) - f(s_mine), f(p_mine), f(p_best), mine, best, s_best, s_mine, left)
           for (bid, result, kind, reg, p_mine, p_best, mine, best, s_best, s_mine, left), f in zip(rows, fs)]
    report(cal, "Calibrated:")
    CALIBRATION.parent.mkdir(parents=True, exist_ok=True)
    CALIBRATION.write_text(json.dumps({"styles": args.styles, "rollouts": args.rollouts, "a": a, "b": b}, indent=1))
    print(f"Saved the fit to {CALIBRATION.relative_to(CALIBRATION.parents[2])} (local, git-ignored).")


def report(rows, title):
    print(title)

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
    print("Per battle: total regret (win probability given up over the battle), by how it really ended:")
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
        print("  Estimated P(win) of your choices against how often you really won:")
        for lo in (0.0, 0.2, 0.4, 0.6, 0.8):
            xs = [r for r in known if lo <= r[4] < lo + 0.2 or (lo == 0.8 and r[4] >= 1.0)]
            if xs:
                print(f"    {lo:.1f}–{lo + 0.2:.1f}: {len(xs):>4} decisions, estimated "
                      f"{statistics.mean(r[4] for r in xs):.2f}, won {statistics.mean(r[1] == 'won' for r in xs):.2f}")
        print("  By how far the battle had got (Pokémon left on both sides):")
        for name, lo, hi in (("start (5–6 left)", 5, 6), ("middle (3–4)", 3, 4), ("last 1v1 (2)", 2, 2)):
            xs = [r for r in known if lo <= r[10] <= hi]
            if len(xs) > 1:
                rate = statistics.mean(r[1] == "won" for r in xs)
                print(f"    {name:<17} {len(xs):>4} decisions: Brier {statistics.mean((r[4] - (r[1] == 'won')) ** 2 for r in xs):.3f}"
                      f" (base rate {rate * (1 - rate):.3f}); estimated {statistics.mean(r[4] for r in xs):.2f},"
                      f" won {rate:.2f}")
    worst = sorted(rows, key=lambda r: -r[3])[:12]
    print("Costliest decisions:")
    for bid, result, kind, reg, p_mine, p_best, mine, best, *_ in worst:
        print(f"  {bid:<30}{kind:<8} regret {reg:+.2f}: you {mine} (P(win) {p_mine:.2f}), "
              f"planner {best} ({p_best:.2f})")
    print()


if __name__ == "__main__":
    main()
