"""Fit the opponent model on your recorded battles, and check it on battles it didn't see.

    cd POMDP && python3 -m experiments.opponent_model

Every opponent decision in the local Battle Turns export becomes a training case: the rebuilt
battle at that turn (battle_turns.battle_at, from their side), the model's features, and what
they did. Five-fold cross-validation by battle (a battle's decisions are all in the same fold)
compares the held-out log loss and accuracy of:

  learned   the opponent model (mango_pomdp.opponent_model)
  styles    the four heuristic styles, equally likely, each choosing as policies.py says (ε = 0.1)
  base      always the training folds' base rates

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
from mango_pomdp.opponent_model import (CHOICES, MODEL, SHIELD, THROW, OpponentModel, _sigmoid, _softmax,
                                        allowed_throws, cheap_big, features_shield, features_throw,
                                        fit_logistic, fit_softmax)
from mango_pomdp.policies import STYLES, ShieldContext, ThrowContext, shield_prob, throw_probs

FORMAT = "mega_great_league"
TURNS = Path(__file__).resolve().parents[2] / "Battle Turns"
EPS = 0.1


def cases(gd, battles):
    """(battle id, kind, features, label, mask or None, style likelihoods) for every usable decision."""
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
            styles = [shield_prob(st, ctx, EPS) for st in STYLES]
            out.append((rb.id, "shield", features_shield(b, 1, move), int(c.shielded), None, styles))
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
            styles = []
            for st in STYLES:
                p = throw_probs(st, ctx, EPS)
                styles.append([p.get(None, 0.0), p.get(order[0], 0.0), p.get(order[1], 0.0)])
            out.append((rb.id, "throw", features_throw(b, 1), label, mask, styles))
    return out


def scores(rows, predict):
    """Mean log loss and accuracy of predict(row) -> probabilities of each label."""
    loss, right = 0.0, 0
    for row in rows:
        p = predict(row)
        loss -= math.log(max(p[row[3]], 1e-6))
        right += max(range(len(p)), key=lambda i: p[i]) == row[3]
    return loss / len(rows), right / len(rows)


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
    print(f"{sum(r[1] == 'shield' for r in data)} shield and {sum(r[1] == 'throw' for r in data)} throw decisions "
          f"by your opponents in {len(ids)} battles; {args.folds}-fold cross-validation by battle.\n")

    for kind, n in (("shield", 2), ("throw", 3)):
        rows = [r for r in data if r[1] == kind]
        held = {"learned": [], "styles": [], "base": []}
        for k in range(args.folds):
            train = [r for r in rows if fold[r[0]] != k]
            test = [r for r in rows if fold[r[0]] == k]
            if not test or not train:
                continue
            if kind == "shield":
                w = fit_logistic([r[2] for r in train], [r[3] for r in train], args.l2)
                rate = sum(r[3] for r in train) / len(train)
                learned = lambda r, w=w: [1 - _sigmoid(sum(a * x for a, x in zip(w, r[2]))),   # noqa: E731
                                          _sigmoid(sum(a * x for a, x in zip(w, r[2])))]
                styles = lambda r: [1 - sum(r[5]) / len(r[5]), sum(r[5]) / len(r[5])]   # noqa: E731
                base = lambda r, rate=rate: [1 - rate, rate]   # noqa: E731
            else:
                W = fit_softmax([r[2] for r in train], [r[3] for r in train], [r[4] for r in train], args.l2)
                freq = [sum(r[3] == c for r in train) + 1 for c in range(3)]
                learned = lambda r, W=W: _softmax([sum(a * x for a, x in zip(row, r[2])) for row in W], r[4])  # noqa: E731
                styles = lambda r: _renorm([sum(s[c] for s in r[5]) / len(r[5]) for c in range(3)], r[4])  # noqa: E731
                base = lambda r, freq=freq: _renorm(freq, r[4])   # noqa: E731
            for name, f in (("learned", learned), ("styles", styles), ("base", base)):
                held[name] += [(r, f(r)) for r in test]
        print(f"{kind}: {len(rows)} decisions ({', '.join(f'{CHOICES[c] if kind == 'throw' else ('no', 'yes')[c]} '
                                                         f'{sum(r[3] == c for r in rows)}' for c in range(n))})")
        print(f"  {'model':<9}{'log loss':>10}{'accuracy':>10}")
        for name in ("learned", "styles", "base"):
            loss, acc = scores([r for r, _ in held[name]], lambda r, d=dict((id(r), p) for r, p in held[name]): d[id(r)])
            print(f"  {name:<9}{loss:>10.3f}{acc:>10.1%}")
        print()

    shield_rows = [r for r in data if r[1] == "shield"]
    throw_rows = [r for r in data if r[1] == "throw"]
    w = fit_logistic([r[2] for r in shield_rows], [r[3] for r in shield_rows], args.l2)
    W = fit_softmax([r[2] for r in throw_rows], [r[3] for r in throw_rows], [r[4] for r in throw_rows], args.l2)
    OpponentModel(w, W).save()
    print(f"Fitted on everything and saved to {MODEL.relative_to(MODEL.parents[2])} (local, git-ignored).")
    print("\nShield: the largest weights (log-odds of shielding per unit of the feature):")
    for f, v in sorted(zip(SHIELD, w), key=lambda fv: -abs(fv[1]))[:8]:
        print(f"  {f:<24}{v:+.2f}")
    for c in (1, 2):
        print(f"\nThrow {CHOICES[c]} (vs hold): the largest weights:")
        for f, v in sorted(zip(THROW, W[c]), key=lambda fv: -abs(fv[1]))[:8]:
            print(f"  {f:<24}{v:+.2f}")


def _renorm(p, mask):
    q = [x if m else 0.0 for x, m in zip(p, mask)]
    total = sum(q) or 1.0
    return [x / total for x in q]


if __name__ == "__main__":
    main()
