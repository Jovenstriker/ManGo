"""Fit the opponent model on your recorded battles, and check it on battles it didn't see.

    cd POMDP && python3 -m experiments.opponent_model

Every opponent decision in the local Battle Turns export becomes a training case: the rebuilt
battle at that turn (battle_turns.battle_at, from their side), the model's features, and what
they did. The four parts:

  shield  shield or not, when you threw at them
  throw   hold, their cheaper charged move or their bigger one, with energy for the cheaper
  switch  switch or stay, on a free turn when they could switch
  pick    which Pokémon they brought in, on a switch or after a faint, with two to choose from

Five-fold cross-validation by battle (a battle's decisions are all in the same fold) compares
the held-out log loss and accuracy of:

  learned   the opponent model (mango_pomdp.opponent_model)
  styles    the four heuristic styles, equally likely, each choosing as policies.py says
            (ε = 0.1; a switch rule that fires gives 0.9, else the base rate)
  base      always the training folds' base rates (uniform, for a pick)

Then it fits on everything and saves the model to data/local/opponent_model.json, which the
planner's "learned" opponent uses. Both the cases and the model come from your recordings, so
they stay local.
"""
from __future__ import annotations

import argparse
import math
import random
from pathlib import Path

from mango_pomdp import gamedata
from mango_pomdp.battle_turns import battle_at, load
from mango_pomdp.gamedata import damage
from mango_pomdp.opponent_model import (CHOICES, MODEL, PICK, SHIELD, SWITCH_F, THROW, OpponentModel, _sigmoid,
                                        _softmax, allowed_throws, cheap_big, features_pick, features_shield,
                                        features_switch, features_throw, fit_choice, fit_logistic, fit_softmax)
from mango_pomdp.policies import (STYLES, Heuristic, ShieldContext, ThrowContext, matchup, shield_prob,
                                  throw_probs)

FORMAT = "mega_great_league"
TURNS = Path(__file__).resolve().parents[2] / "Battle Turns"
EPS = 0.1
KINDS = ("shield", "throw", "switch", "pick")


def cases(gd, battles):
    """(battle id, kind, features, label, mask or None, the styles' prediction) for every usable
    decision. For a pick, the features are one vector per Pokémon they could bring in."""
    out = []
    for rb in battles:
        for c in rb.shields:
            if c.turn not in rb.snapshots or c.move not in gd.moves:
                continue
            b = battle_at(gd, rb, c.turn, free="them")
            me, foe = b.sides[1], b.sides[0]
            if me.mon.species.id != c.defender or foe.mon.species.id != c.attacker or me.shields == 0:
                continue
            move = gd.moves[c.move]
            full = damage(move, foe.mon.species, me.mon.species, foe.mon.atk_stage, me.mon.def_stage)
            ctx = ShieldContext(me.mon.hp, me.mon.max_hp, full, me.shields)
            p = sum(shield_prob(st, ctx, EPS) for st in STYLES) / len(STYLES)
            out.append((rb.id, "shield", features_shield(b, 1, move), int(c.shielded), None, [1 - p, p]))
        for c in rb.throws:
            if c.turn not in rb.snapshots:
                continue
            b = battle_at(gd, rb, c.turn, energy=c.energy, free="them")
            mon = b.sides[1].mon
            order = cheap_big(mon)
            if mon.species.id != c.active or order is None:
                continue
            mask = allowed_throws(mon)
            if not mask[1]:
                continue
            ids = [mon.base_move(m).id for m in mon.charged]
            label = 0 if not c.choice else (1 if ids.index(c.choice) == order[0] else 2) if c.choice in ids else None
            if label is None or not mask[label]:
                continue
            foe = b.sides[0].mon
            ctx = ThrowContext(mon.species, mon.charged, mon.energy, mon.atk_stage, foe.species, foe.hp,
                               foe.def_stage, b.sides[0].shields)
            styles = [0.0, 0.0, 0.0]
            for st in STYLES:
                p = throw_probs(st, ctx, EPS)
                for k, o in enumerate((None, order[0], order[1])):
                    styles[k] += p.get(o, 0.0) / len(STYLES)
            out.append((rb.id, "throw", features_throw(b, 1), label, mask, _renorm(styles, mask)))
        for c in rb.switches:
            if c.turn not in rb.snapshots:
                continue
            b = battle_at(gd, rb, c.turn, free="them")
            side = b.sides[1]
            ids = [m.species.id for m in side.mons]
            if side.mon.species.id != c.active or not side.bench() or side.switch_timer or \
                    (c.choice and (c.choice not in ids or ids.index(c.choice) not in side.bench())):
                continue
            view = b.view(1)
            fires = [Heuristic(st, eps=0.0).switch_choice(view) is not None for st in STYLES]
            out.append((rb.id, "switch", features_switch(b, 1), int(bool(c.choice)), None, fires))
            if c.choice and len(side.bench()) >= 2:
                out.append(_pick_row(rb.id, b, ids.index(c.choice)))
        for c in rb.replaces:
            if c.turn not in rb.snapshots:
                continue
            b = battle_at(gd, rb, c.turn, free="them")
            side = b.sides[1]
            ids = [m.species.id for m in side.mons]
            if c.fainted not in ids or c.choice not in ids:
                continue
            side.active = ids.index(c.fainted)
            side.mon.hp = 0
            if len(side.bench()) < 2 or ids.index(c.choice) not in side.bench():
                continue
            out.append(_pick_row(rb.id, b, ids.index(c.choice)))
    return out


def _pick_row(bid, b, chosen):
    """A pick among the Pokémon behind side 1's active one. The styles take the best matchup."""
    side, foe = b.sides[1], b.sides[0].mon
    options = side.bench()
    score = [matchup(side.mons[i], side.mons[i].hp, foe.species, foe.hp,
                     {"fast": foe.fast, "charged": {c.id for c in foe.charged}}) for i in options]
    best = max(range(len(options)), key=lambda k: score[k])
    styles = [EPS / len(options) + (1 - EPS) * (k == best) for k in range(len(options))]
    return (bid, "pick", [features_pick(b, 1, i) for i in options], options.index(chosen), None, styles)


def _renorm(p, mask):
    q = [x if m else 0.0 for x, m in zip(p, mask)]
    total = sum(q) or 1.0
    return [x / total for x in q]


def fit(kind, rows, l2):
    """The fitted part for `kind`, and a function from a row to its predicted probabilities."""
    if kind in ("shield", "switch"):
        w = fit_logistic([r[2] for r in rows], [r[3] for r in rows], l2)
        return w, lambda r: (lambda q: [1 - q, q])(_sigmoid(sum(a * x for a, x in zip(w, r[2]))))
    if kind == "throw":
        W = fit_softmax([r[2] for r in rows], [r[3] for r in rows], [r[4] for r in rows], l2)
        return W, lambda r: _softmax([sum(a * x for a, x in zip(row, r[2])) for row in W], r[4])
    w = fit_choice([r[2] for r in rows], [r[3] for r in rows], l2)
    return w, lambda r: _softmax([sum(a * x for a, x in zip(w, opt)) for opt in r[2]], [True] * len(r[2]))


def baselines(kind, train):
    """The styles' and the base rates' predictions, as functions of a row."""
    if kind == "pick":
        return (lambda r: r[5]), (lambda r: [1 / len(r[2])] * len(r[2]))
    if kind == "throw":
        freq = [sum(r[3] == c for r in train) + 1 for c in range(3)]
        return (lambda r: r[5]), (lambda r: _renorm(freq, r[4]))
    rate = sum(r[3] for r in train) / len(train)
    if kind == "switch":
        def styles(r):
            p = sum(1 - EPS if f else rate for f in r[5]) / len(r[5])
            return [1 - p, p]
        return styles, (lambda r: [1 - rate, rate])
    return (lambda r: r[5]), (lambda r: [1 - rate, rate])


def scores(pairs):
    """Mean log loss and accuracy of (row, predicted probabilities) pairs. A tie for the most
    likely choice counts as a share of a right answer (the team lists are in the order the
    Pokémon came in, so breaking ties by position would leak the answer for picks)."""
    loss = -sum(math.log(max(p[r[3]], 1e-6)) for r, p in pairs) / len(pairs)
    right = 0.0
    for r, p in pairs:
        top = [i for i in range(len(p)) if p[i] >= max(p) - 1e-12]
        right += (r[3] in top) / len(top)
    return loss, right / len(pairs)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--turns", type=Path, default=TURNS)
    ap.add_argument("--folds", type=int, default=5)
    ap.add_argument("--l2", type=float, default=1.0)
    args = ap.parse_args()
    gd = gamedata.use(FORMAT)
    battles = [b for b in load(gd, args.turns) if b.seen == 3 and not b.misread]
    data = cases(gd, battles)
    ids = sorted({r[0] for r in data})
    random.Random(0).shuffle(ids)
    fold = {bid: k % args.folds for k, bid in enumerate(ids)}
    print(f"Your opponents' decisions in {len(ids)} battles: "
          + ", ".join(f"{sum(r[1] == k for r in data)} {k}" for k in KINDS)
          + f". {args.folds}-fold cross-validation by battle.\n")

    names = {"shield": ("no", "yes"), "throw": CHOICES, "switch": ("stay", "switch")}
    for kind in KINDS:
        rows = [r for r in data if r[1] == kind]
        held = {"learned": [], "styles": [], "base": []}
        for k in range(args.folds):
            train = [r for r in rows if fold[r[0]] != k]
            test = [r for r in rows if fold[r[0]] == k]
            if not test or not train:
                continue
            _, learned = fit(kind, train, args.l2)
            styles, base = baselines(kind, train)
            for name, f in (("learned", learned), ("styles", styles), ("base", base)):
                held[name] += [(r, f(r)) for r in test]
        if kind == "pick":
            print(f"pick: {len(rows)} decisions between two Pokémon")
        else:
            print(f"{kind}: {len(rows)} decisions ("
                  + ", ".join(f"{names[kind][c]} {sum(r[3] == c for r in rows)}" for c in range(len(names[kind])))
                  + ")")
        print(f"  {'model':<9}{'log loss':>10}{'accuracy':>10}")
        for name in ("learned", "styles", "base"):
            loss, acc = scores(held[name])
            print(f"  {name:<9}{loss:>10.3f}{acc:>10.1%}")
        print()

    parts = {kind: fit(kind, [r for r in data if r[1] == kind], args.l2)[0] for kind in KINDS}
    OpponentModel(parts["shield"], parts["throw"], parts["switch"], parts["pick"]).save()
    print(f"Fitted on everything and saved to {MODEL.relative_to(MODEL.parents[2])} (local, git-ignored).")
    for title, feats, w in (("Shield", SHIELD, parts["shield"]), ("Switch", SWITCH_F, parts["switch"])):
        print(f"\n{title}: the largest weights (log-odds per unit of the feature):")
        for f, v in sorted(zip(feats, w), key=lambda fv: -abs(fv[1]))[:8]:
            print(f"  {f:<24}{v:+.2f}")
    for c in (1, 2):
        print(f"\nThrow {CHOICES[c]} (vs hold): the largest weights:")
        for f, v in sorted(zip(THROW, parts["throw"][c]), key=lambda fv: -abs(fv[1]))[:8]:
            print(f"  {f:<24}{v:+.2f}")
    print("\nPick: the weights:")
    for f, v in zip(PICK, parts["pick"]):
        print(f"  {f:<24}{v:+.2f}")


if __name__ == "__main__":
    main()
