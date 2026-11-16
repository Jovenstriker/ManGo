import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from truth import per_throw, side_truth, fast_moves_for, moves
# Each of the other player's Pokémon, fitted: its fast move, with its energy on whole fast moves
# from 0, up as they land, down by each charged move's cost.
#
# A button of cost C fills exactly e / C of its height (measured in pixels: Charjabug's 16 and
# 32 of 40 fill 0.394 and 0.80). ManGo's reader samples a circle about 7px above the button's
# real one in these crops, so its level is the real fill less an offset (0.106 there), fitted
# per crop; and it can't see fills under about 0.2 (it reads 0.1 for anything up to 8 of 40).
# A level of 1 is a full button: the energy is at least its cost. 0 is a misread.

FLOOR = 0.12


def side_truth_pix(fixture, pix):
    """Steady stretches of the truth reader's fills (truthpix.py), as true fractions of each
    button, with the labels read near them. No edge on a button: full if ManGo's reader saw it
    bright (1), empty if dark (under 0.11 here), else unknown."""
    import json
    from truth import read_labels, read_name
    reads = json.load(open(fixture))
    labelled = [(r['time'], read_labels(r), read_name(r)) for r in reads]
    mango = sorted(tuple(x) for r in reads for x in (r.get('fillTrace') or []))
    frames = json.load(open(pix))['frames']
    import bisect
    mt = [m[0] for m in mango]

    def resolve(t, k, v):
        if v is not None:
            return v
        i = bisect.bisect_left(mt, t)
        near = [mango[j] for j in (i - 1, i) if 0 <= j < len(mango) and abs(mango[j][0] - t) < 0.05]
        if not near:
            return None
        lv = near[0][1 + k]
        return 1.0 if lv >= 0.97 else 0.08 if 0.05 < lv <= 0.12 else None

    vals = [(t, resolve(t, 0, a), resolve(t, 1, b)) for t, a, b, _, _ in frames]
    out, i = [], 0
    while i < len(vals):
        j = i
        same = lambda p, q: (p is None and q is None) or (p is not None and q is not None and abs(p - q) <= 0.02)
        while j + 1 < len(vals) and same(vals[j + 1][1], vals[i][1]) and same(vals[j + 1][2], vals[i][2]):
            j += 1
        if j - i + 1 >= 4 and vals[i][1] is not None and vals[i][2] is not None:
            t0, t1 = vals[i][0], vals[j][0]
            near = [(L, n) for t, L, n in labelled if t0 - 0.15 <= t <= t1 + 0.15 and L]
            if near:
                Ls = [x[0] for x in near]
                L = max(set(Ls), key=Ls.count)
                names = [n for x, n in near if n]
                out.append(dict(t0=t0, t1=t1, labels=L, name=names[0] if names else None, est=None, least=None,
                                levels=(vals[i][1], vals[i][2])))
        i = j + 1
    return out


def fit_pokemon(items, cands, delta, FLOOR=FLOOR):
    """items: time-ordered ('read', obs) and ('throw', t, cost). Returns (score, move, delta,
    assigned items, misreads)."""
    best = None
    for fm in cands:
        E = fm['energyGain']
        e, score, out, bad = 0.0, 0.0, [], 0
        pending = []  # charged moves since the last reading: their energy before is what the next
        # reading shows plus their cost (both buttons often read full before a throw)
        for it in items:
            if it[0] == 'throw':
                pending.append(it)
                continue
            o = it[1]
            levels, costs = o['levels'], [moves[m]['energy'] for m in o['labels']]
            full = [c for lv, c in zip(levels, costs) if lv >= 0.97]
            low = [c for lv, c in zip(levels, costs) if 0.05 < lv <= FLOOR]
            use = [(lv, c) for lv, c in zip(levels, costs) if FLOOR < lv < 0.97 and not any(c <= cf for cf in full)]
            spent = sum(p[2] for p in pending)
            if use:
                m = sum((lv + delta) * c for lv, c in use) / len(use)
            elif low and not full:
                m = 0.0  # under the floor: as little as it can be from here
            else:
                out.append(('read', o, None))
                continue
            kmin = max(0, -(-(spent - e) // E)) if spent > e else 0
            k = max(kmin, round((m + spent - e) / E))
            v = min(100.0, e + k * E) - spent
            if use:
                r = sum((lv - (v / c - delta)) ** 2 for lv, c in use) / len(use)
            else:
                r = 0.0 if all(v <= (FLOOR + delta) * c + 1 for c in low) else 1.0
            if any(v > (FLOOR + delta) * c + 1.5 for c in low) or any(v + 1.5 < c for c in full):
                r = max(r, 1.0)
            if r > 0.0016:  # more than ~0.04 off: a misread; skip it
                bad += 1
                score += 0.0016
                out.append(('read', o, None))
                continue
            score += r
            # Each charged move since the last reading: one alone had this reading plus its cost
            # before it; two or more, only the last is known that way. A reading under the floor
            # doesn't pin it down.
            for j, p in enumerate(pending):
                known = j == len(pending) - 1 and bool(use)
                out.append(('throw', p[1], p[2], v + p[2] if known else None, o))
            pending = []
            e = v
            out.append(('read', o, v))
        for p in pending:
            out.append(('throw', p[1], p[2], None, None))
        # Prefer the bigger fast move when both explain the readings: a small one fits anything.
        key = (round(score / 0.0008), bad, -E)
        if best is None or key < best[0]:
            best = (key, fm, delta, out, bad, score)
    return best


def view_truth(d, side):
    """ManGo's view from `side`, and the other player's Pokémon fitted from their own screen."""
    rows, seen, theirs = per_throw(d, side)
    g = os.path.basename(d.rstrip('/'))
    other = 'R' if side == 'L' else 'L'
    pix = f'{d}/{g}-{other}.pix.json'
    if os.path.exists(pix):
        obs, deltas, floor = side_truth_pix(f'{d}/{g}-{other}.json', pix), [0.0], 0.11
    else:
        obs, deltas, floor = side_truth(f'{d}/{g}-{other}.json'), [0.06 + 0.005 * k for k in range(19)], FLOOR
    groups = []
    for L in dict.fromkeys(o['labels'] for o in obs):
        names = [o['name'] for o in obs if o['labels'] == L and o['name']]
        name = max(set(names), key=names.count) if names else None
        cands = [m for m in fast_moves_for(name) if m.get('energyGain')]
        if not cands:
            continue
        items = [('read', o) for o in obs if o['labels'] == L]
        for r in rows:
            if r['labels'] == L and r['seen']:
                items.append(('throw', r['t'], r['seen']['cost']))
        items.sort(key=lambda it: it[1]['t0'] if it[0] == 'read' else it[1])
        groups.append((L, name, items, cands))
    best = None
    for delta in deltas:
        fits = [fit_pokemon(items, cands, delta, floor) for L, name, items, cands in groups]
        total = sum(f[5] + 0.0016 * f[4] for f in fits)
        if best is None or total < best[0]:
            best = (total, delta, fits)
    result = [dict(labels=L, name=name, fit=f) for (L, name, _, _), f in zip(groups, best[2])] if best else []
    return rows, result


if __name__ == '__main__':
    d, side = sys.argv[1], sys.argv[2]
    rows, fits = view_truth(d, side)
    for f in fits:
        key, fm, delta, out, bad, score = f['fit']
        print(f"{f['name']} {f['labels']}: {fm['moveId']} (+{fm['energyGain']}), offset {delta:.3f}, score {score:.4f}, misreads {bad}")
        for it in out:
            if it[0] == 'throw':
                print(f"    THROW {it[1]:7.2f} cost {it[2]}: energy before {it[3] if it[3] is None else round(it[3])}"
                      + (f" (reading at {it[4]['t0']:.2f})" if it[4] else ''))
            elif it[2] is not None:
                print(f"    {it[1]['t0']:7.2f}-{it[1]['t1']:7.2f} {it[2]:5.1f}  lv={tuple(round(x, 3) for x in it[1]['levels'])}")
