import glob, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from truth2 import throws_truth
from truth import mid
# ManGo against the truth on every finished stream game, both views: for each charged move of
# the other player ManGo saw, its raw energy estimate and fast move count against what the
# other player's own buttons showed. Skips games the stream joined late (no countdown) and,
# as asked, any with Dunsparce.   evaluate.py [games dir] [--json out]
from paths import GAMES
D = GAMES
args = [a for i, a in enumerate(sys.argv[1:], 1) if not a.startswith('--') and sys.argv[i - 1] != '--json']
if args:
    D = args[0]
from paths import TRUTH
out_json = sys.argv[sys.argv.index('--json') + 1] if '--json' in sys.argv else TRUTH


def has_countdown(reads):
    t0 = reads[0]['time'] if reads else 0
    for r in reads:
        if r['time'] > t0 + 25:
            break
        for l in r['lines']:
            x, y = mid(l)
            if l['text'].strip() in ('GO', '3', '2') and 0.3 < x < 0.7 and 0.35 < y < 0.65:
                return True
    return False


def mentions(reads, word):
    return any(word in l['text'].lower() for r in reads for l in r['lines'])


rows = []
skipped = []
for d in sorted(glob.glob(D + '/g*')):
    g = os.path.basename(d)
    fx = {s: f'{d}/{g}-{s}.json' for s in 'LR'}
    if not all(os.path.exists(f) and os.path.exists(f[:-5] + '.pix.json') for f in fx.values()):
        continue
    reads = {s: json.load(open(f)) for s, f in fx.items()}
    if any(mentions(r, 'dunsparce') for r in reads.values()):
        skipped.append((g, 'Dunsparce'))
        continue
    if not all(has_countdown(r) for r in reads.values()):
        skipped.append((g, 'no countdown'))
        continue
    for side in 'LR':
        throws, truth_at = throws_truth(d, side)
        # counts: fast moves since that Pokémon's previous charged move (or coming in), when
        # both ends are known and the cap didn't eat any
        left = {}
        for r in sorted(throws, key=lambda r: r['t']):
            t = truth_at.get(r['t'])
            if not t or not r['seen']:
                continue
            k = r['labels']
            prev = left.get(k, 0)
            t['count'] = None
            if t['before'] is not None and prev is not None and t['before'] < 100 and (t['before'] - prev) % t['gain'] == 0:
                t['count'] = (t['before'] - prev) // t['gain']
            left[k] = None if t['before'] is None else t['before'] - r['seen']['cost']
        for r in throws:
            s = r['seen']
            t = truth_at.get(r['t'], {})
            rows.append(dict(game=g, side=side, their_time=r['t'], seen_time=s['time'] if s else None,
                             species=s['species'] if s else r['name'], move=s['move'] if s else None, cost=s['cost'] if s else None,
                             mango_raw=s['raw'] if s else None, mango_count=s['count'] if s else None,
                             truth_before=t.get('before'), truth_count=t.get('count'), truth_fast=t.get('fast'), truth_species=t.get('species'), fit=t.get('fit')))

for r in rows:
    diff = '' if r['mango_raw'] is None or r['truth_before'] is None else f"{r['mango_raw'] - r['truth_before']:+d}"
    cdiff = '' if r['mango_count'] is None or r['truth_count'] is None else f"{r['mango_count'] - r['truth_count']:+d}"
    print(f"{r['game']} {r['side']} {r['seen_time'] or 0:7.2f} {r['species'][:18]:18} {str(r['move'])[:16]:16} truth {str(r['truth_before']):>4} mango {str(r['mango_raw']):>4} {diff:>4}   count {str(r['truth_count']):>3} vs {str(r['mango_count']):>3} {cdiff:>3}  {r['truth_fast']}")
known = [r for r in rows if r['truth_before'] is not None and r['mango_raw'] is not None]
exact = [r for r in known if r['mango_raw'] == r['truth_before']]
print(f"\n{len(exact)} of {len(known)} exact ({len(rows)} throws; {len(rows) - len(known)} without an exact truth)")
kc = [r for r in rows if r['truth_count'] is not None and r['mango_count'] is not None]
print(f"counts: {sum(r['truth_count'] == r['mango_count'] for r in kc)} of {len(kc)} exact")
print('skipped:', skipped)
if out_json:
    json.dump(rows, open(out_json, 'w'), indent=1)
