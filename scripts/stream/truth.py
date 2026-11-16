import json, re, subprocess, sys, difflib, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# Ground truth for one view of a stream game: ManGo on one player's screen ("you") counting
# the other's energy, and the other's own charge buttons (their screen) showing it.
#
#   truth.py <game dir> <L|R>   (the side ManGo watches from; truth from the other side)
#
# Their energy, per Pokémon (one per pair of button labels): starts at 0, rises by its fast
# move's energy as each lands, drops by a charged move's cost. Each steady stretch of their
# buttons' fill is a reading of it: a button of cost C at level f holds (f - 0.083) * C (fitted
# on Empoleon's 8-energy Metal Sounds: 0.283, 0.483, 0.683 under 40-energy buttons; an empty
# button reads 0.1). A full button says only "at least"; a level of 0 is a misread (a full
# button glowing). Readings are snapped to the energies the fast move allows from the last
# known one, so they're exact while the readings are within a few energy.
#
# Prints JSON: the opponent's charged moves as ManGo saw them, each with the truth.
from paths import ROOT, BR, GAMES, EMPTY
A = 0.083
gm = json.load(open(ROOT + 'App/ManGo/Resources/gamemaster.json'))
moves = {m['moveId']: m for m in gm['moves']}
norm = lambda s: re.sub(r'[^A-Z]', '', s.upper())
charged_by_name = {}
for m in gm['moves']:
    if m.get('energy', 0) > 0 and not m['moveId'].endswith('_PLUS'):
        charged_by_name.setdefault(norm(m['name']), m)
base = lambda n: n.split(' (')[0].strip()
species_by_base = {}
for p in gm['pokemon']:
    species_by_base.setdefault(norm(base(p['speciesName'])), []).append(p)


def move_for(text):
    k = norm(text)
    if len(k) < 4:
        return None
    if k in charged_by_name:
        return charged_by_name[k]
    close = difflib.get_close_matches(k, charged_by_name.keys(), n=1, cutoff=0.8)
    return charged_by_name[close[0]] if close else None


def mid(l):
    (x, y), (w, h) = l['box']
    return x + w / 2, y + h / 2


def read_labels(read):
    left = right = None
    for l in read['lines']:
        x, y = mid(l)
        if not 0.9 <= y <= 0.97:
            continue
        m = move_for(l['text'])
        if m:
            if x < 0.5:
                left = m['moveId']
            else:
                right = m['moveId']
    return (left, right) if left and right else None


def read_name(read):
    for l in read['lines']:
        x, y = mid(l)
        if x < 0.45 and 0.08 <= y <= 0.2:
            k = norm(l['text'])
            if k in species_by_base:
                return k
    return None


def report(fixture):
    out = subprocess.run([BR, fixture, ROOT + 'App/ManGo/Resources', EMPTY, 'none'], capture_output=True, text=True).stdout
    return out


def clock(s):
    m, x = s.split(':')
    return int(m) * 60 + float(x)


def their_throws(rep):
    """The opponent's charged moves in a report: time, species name, move name, cost, energy, raw."""
    out = []
    lines = rep.split('\n')
    for i, l in enumerate(lines):
        m = re.match(r'\s+(\d+)\s+(\d+:\d+\.\d+)\s+(.+?)\s{2,}(.+?) \((\d+)\)\s+(\d+) → (\d+)\s+(\d+)', l)
        if not m:
            continue
        raw = int(m.group(6))
        for k in range(i + 1, min(i + 4, len(lines))):
            r = re.search(r'raw estimate (\d+)', lines[k])
            if r:
                raw = int(r.group(1))
            if re.match(r'\s+\d+\s+\d+:', lines[k]):
                break
        out.append(dict(ordinal=int(m.group(1)), time=clock(m.group(2)), species=m.group(3).strip(), move=m.group(4).strip(),
                        cost=int(m.group(5)), energy=int(m.group(6)), raw=raw, count=int(m.group(8))))
    return out


def your_throws(rep):
    return [clock(m.group(1)) for m in re.finditer(r'\n\s+(\d+:\d+\.\d+)\s+You threw a charged move', rep)]


def stable(frames, hold=4, tol=0.02):
    out, i = [], 0
    while i < len(frames):
        j = i
        while j + 1 < len(frames) and abs(frames[j + 1][1] - frames[i][1]) <= tol and abs(frames[j + 1][2] - frames[i][2]) <= tol:
            j += 1
        if j - i + 1 >= hold:
            out.append((frames[i][0], frames[j][0], frames[i][1], frames[i][2]))
        i = j + 1
    return out


def reading(f, cost):
    """(estimate, at least) from one button: estimate None if saturated or misread."""
    if f >= 0.97:
        return None, (0.97 - A) * cost
    if f <= 0.05:
        return None, None
    return max(0.0, (f - A) * cost), None


def side_truth(fixture):
    reads = json.load(open(fixture))
    frames = sorted(tuple(x) for r in reads for x in (r.get('fillTrace') or []))
    labelled = [(r['time'], read_labels(r), read_name(r)) for r in reads]
    obs = []  # (t0, t1, labels, species key, estimate or None, at least or None)
    for t0, t1, a, b in stable(frames):
        near = [(L, n) for t, L, n in labelled if t0 - 0.15 <= t <= t1 + 0.15 and L]
        if not near:
            continue
        L = max(set(x[0] for x in near), key=[x[0] for x in near].count)
        names = [n for x, n in near if n]
        ests, least = [], []
        costs = [moves[mv]['energy'] for mv in L]
        rs = [reading(f, c) for f, c in zip((a, b), costs)]
        # A full button means one no dearer is full too: a lower level on that one is a misread
        # (a full button glowing reads at the bottom).
        full = [c for (e, lo), c in zip(rs, costs) if lo is not None]
        for (e, lo), c in zip(rs, costs):
            if e is not None and not any(c <= cf for cf in full):
                ests.append(e)
            if lo is not None:
                least.append(lo)
        if len(ests) == 2 and abs(ests[0] - ests[1]) > 5:
            # the buttons disagree: keep the one from the cheaper button only if the other is
            # covered (a sprite over it reads low); here: drop the reading
            continue
        est = sum(ests) / len(ests) if ests else None
        obs.append(dict(t0=t0, t1=t1, labels=L, name=names[0] if names else None, est=est,
                        least=max(least) if least and not ests else None, levels=(a, b)))
    return obs


def fast_moves_for(name_key):
    out = set()
    for p in species_by_base.get(name_key or '', []):
        out |= set(p['fastMoves'])
    return [moves[m] for m in out if m in moves]


def chain(obs, throws_at, cost_of):
    """Each Pokémon's energy through the readings, snapped to its fast move's steps.
    throws_at: times this side threw; cost_of(t): the cost of the throw at t (from the other view)."""
    per = {}
    for o in obs:
        per.setdefault(o['labels'], []).append(o)
    result = {}
    for L, os_ in per.items():
        name = next((o['name'] for o in os_ if o['name']), None)
        cands = [m for m in fast_moves_for(name) if m.get('energyGain')]
        best = None
        for fm in cands or [dict(moveId='?', energyGain=g, turns=0) for g in range(3, 21)]:
            E = fm['energyGain']
            err, e, trail = 0.0, 0.0, []
            ok = True
            k_throw = 0
            for o in os_:
                # throws by this Pokémon since the previous reading
                while k_throw < len(throws_at) and throws_at[k_throw] < o['t0']:
                    t = throws_at[k_throw]
                    k_throw += 1
                    if trail and trail[-1]['t1'] < t and cost_of(t, L) is not None:
                        trail.append(dict(throw=t, before=e, cost=cost_of(t, L)))
                        e = e - cost_of(t, L)
                if o['est'] is None:
                    trail.append(dict(o, snapped=None))
                    continue
                k = round((o['est'] - e) / E)
                if k < 0:
                    ok = ok and k >= -1
                    k = max(k, 0)
                v = min(100.0, e + k * E)
                err += (o['est'] - v) ** 2
                e = v
                trail.append(dict(o, snapped=v))
            score = err / max(1, len([o for o in os_ if o['est'] is not None]))
            if ok and (best is None or score < best[0]):
                best = (score, fm, trail)
        result[L] = dict(name=name, fast=best[1]['moveId'] if best else None, energyGain=best[1]['energyGain'] if best else None,
                         score=best[0] if best else None, trail=best[2] if best else [])
    return result


def restarts(rep):
    return [clock(m.group(1)) for m in re.finditer(r'\n\s+(\d+:\d+\.\d+)\s+running ', rep)]


def per_throw(d, side, verbose=False):
    g = os.path.basename(d.rstrip('/'))
    other = 'R' if side == 'L' else 'L'
    you, them = f'{d}/{g}-{side}.json', f'{d}/{g}-{other}.json'
    rep_you, rep_them = report(you), report(them)
    seen = their_throws(rep_you)
    theirs = your_throws(rep_them)
    runs = restarts(rep_them)
    obs = side_truth(them)
    labelled = [(r['time'], read_labels(r)) for r in json.load(open(them))]
    labelled = [(t, L) for t, L in labelled if L]
    if verbose:
        for o in obs:
            print(f"   {o['t0']:7.2f}-{o['t1']:7.2f} {o['labels']} {o['name']} est={o['est'] and round(o['est'], 1)} least={o['least'] and round(o['least'])} lv={tuple(round(x, 3) for x in o['levels'])}")
    rows = []
    for t in theirs:
        before = [o for o in obs if o['t1'] < t - 0.2]
        # The Pokémon throwing: the buttons last read before it (a switch since the last
        # steady reading changes them).
        last = [L for tl, L in labelled if tl < t - 0.1]
        if not before or not last:
            continue
        L = last[-1]
        mine = [o for o in obs if o['labels'] == L]
        b = [o for o in mine if o['t1'] < t - 0.2][-3:]
        nxt = [x for x in theirs if x > t]
        a = [o for o in mine if o['t0'] > t and o['t0'] < (nxt[0] if nxt else t + 30)][:3]
        run = next((r for r in runs if r > t + 1), None)
        match = [x for x in seen if t + 3 <= x['time'] <= t + 11]
        rows.append(dict(t=t, labels=L, name=before[-1]['name'], before=b, after=a, restart=run, seen=match[0] if match else None))
    return rows, seen, theirs


if __name__ == '__main__':
    d, side = sys.argv[1], sys.argv[2]
    rows, seen, theirs = per_throw(d, side, verbose=len(sys.argv) > 3)
    for r in rows:
        s = r['seen']
        print(f"their throw {r['t']:.2f} {r['name']} {r['labels']}  restart {r['restart']}  ManGo: " + (f"{s['species']} {s['move']} ({s['cost']}) raw {s['raw']} count {s['count']}" if s else 'not seen'))
        for o in r['before']:
            print(f"     before {o['t0']:7.2f}-{o['t1']:7.2f} est={o['est'] and round(o['est'], 1)} least={o['least'] and round(o['least'])} lv={tuple(round(x, 3) for x in o['levels'])}")
        for o in r['after']:
            print(f"     after  {o['t0']:7.2f}-{o['t1']:7.2f} est={o['est'] and round(o['est'], 1)} least={o['least'] and round(o['least'])} lv={tuple(round(x, 3) for x in o['levels'])}")
    print('unmatched seen:', [(x['time'], x['species'], x['move']) for x in seen if not any(r['seen'] is x for r in rows)])
