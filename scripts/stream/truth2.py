import json, os, sys, bisect
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from truthfit import view_truth
from truth import moves
# The energy each of the other player's Pokémon had as it threw a charged move, only where the
# readings pin it down. Two ways, which must agree when both apply:
#  before: the last steady reading, plus the fast moves that could have landed after it before
#    the buttons went (one per fast move's length from when that reading began), at least as
#    many as the buttons' fullness then needs (a full button: at least its cost) and the cost;
#  after: a reading taken before any fast move could have landed since play restarted (within a
#    fast move's length, less half a second, of the buttons coming back), plus the cost.
# Exact when one value is left.


def throws_truth(d, side):
    rows, fits = view_truth(d, side)
    g = os.path.basename(d.rstrip('/'))
    other = 'R' if side == 'L' else 'L'
    pix = json.load(open(f'{d}/{g}-{other}.pix.json'))['frames']
    reads = json.load(open(f'{d}/{g}-{other}.json'))
    mango = sorted(tuple(x) for r in reads for x in (r.get('fillTrace') or []))
    mt = [m[0] for m in mango]
    pt = [p[0] for p in pix]
    from truth import read_labels
    label_times = [r['time'] for r in reads if read_labels(r)]

    def visible(t):
        i = bisect.bisect_left(pt, t)
        return 0 <= i < len(pix) and (pix[i][1] is not None or pix[i][2] is not None)

    def mango_at(t):
        i = bisect.bisect_left(mt, t)
        return mango[i] if 0 <= i < len(mango) and abs(mango[i][0] - t) < 0.05 else None

    out = {}
    for f in fits:
        key, fm, delta, items, bad, score = f['fit']
        E, dur = fm['energyGain'], fm['turns'] * 0.5
        costs = [moves[m]['energy'] for m in f['labels']]
        readings = [(it[1]['t0'], it[1]['t1'], it[2]) for it in items if it[0] == 'read' and it[2] is not None]
        throws = [it for it in items if it[0] == 'throw']
        for k, th in enumerate(throws):
            T, cost = th[1], th[2]
            prev_throw = throws[k - 1][1] if k else -1e9
            next_throw = throws[k + 1][1] if k + 1 < len(throws) else 1e9
            # buttons last read before the throw, and back after it (their labels legible: the
            # charged move's scenes make edges where there are no buttons)
            gone = max([t for t in label_times if t < T], default=T)
            back = min([t for t in label_times if t > T + 1], default=None)
            cands = None
            before = [r for r in readings if prev_throw < r[0] < T]
            if before:
                t0, t1, v = before[-1]
                # when it reached that level: the first of the readings at it in a row
                for r in reversed(before):
                    if r[2] != v:
                        break
                    t0 = r[0]
                nmax = int((gone - t0) / dur + 0.15) if dur else 0
                # fullness after that reading: a button ManGo's reader sees full on 3 frames in a
                # row means at least its cost (its glow fools the truth reader)
                need = cost
                for b, c in enumerate(costs):
                    run = 0
                    for m in mango:
                        if t1 < m[0] <= gone + 0.05:
                            run = run + 1 if m[1 + b] >= 0.97 else 0
                            if run >= 3:
                                need = max(need, c)
                                break
                cands = sorted({min(100.0, v + n * E) for n in range(0, nmax + 1) if min(100.0, v + n * E) >= need - 0.5})
            after = None
            if back is not None:
                a = [r for r in readings if T < r[0] < next_throw]
                if a:
                    # play restarted about when the buttons came back (a little before they're
                    # legible); a fast move started then lands a fast move's length later
                    jmax = max(0, int((a[0][0] - (back - 0.5)) / dur)) if dur else 0
                    after = sorted({a[0][2] + cost - j * E for j in range(jmax + 1) if a[0][2] + cost - j * E >= cost})
            if after and cands:
                both = [x for x in cands if x in after]
                value, how = (both[0], 'both') if len(both) == 1 else (None, f'unknown: before {cands}, after {after}')
            elif after and len(after) == 1:
                value, how = after[0], 'after'
            elif cands and len(cands) == 1:
                value, how = cands[0], 'before'
            else:
                value, how = None, f'unknown: before {cands}, after {after}'
            out[T] = dict(before=None if value is None else int(round(value)), how=how, fast=fm['moveId'], gain=E,
                          species=f['name'], fit=round(score, 4), misreads=bad)
    return rows, out


if __name__ == '__main__':
    rows, out = throws_truth(sys.argv[1], sys.argv[2])
    for r in rows:
        t = out.get(r['t'])
        s = r['seen']
        print(f"{r['t']:7.2f} {s and s['species']} {s and s['move']} mango {s and s['raw']}  truth {t and t['before']} ({t and t['how']})")
