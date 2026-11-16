import json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# The stream test set: ManGo's raw energy and fast move count at each of the other player's
# charged moves the truth pins down (truth.json, from evaluate.py), how many are exact, under
# the current build and any settings given (battle-report's environment variables).
#   check.py ['ENV=VAL ENV2=VAL' ...]     (no arguments, or '': as built)
from paths import ROOT, BR, GAMES, EMPTY, TRUTH
G = GAMES
from truth import their_throws

rows = json.load(open(TRUTH))
norm = lambda s: re.sub(r'[^a-z]', '', (s or '').lower().split('(')[0])
rows = [r for r in rows if r['truth_before'] is not None and r['seen_time'] is not None
        and (r['truth_species'] is None or norm(r['truth_species']) == norm(r['species']))]
views = sorted({(r['game'], r['side']) for r in rows})


def run(env, view):
    g, side = view
    e = dict(os.environ)
    for kv in env.split():
        k, v = kv.split('=', 1)
        e[k] = v
    out = subprocess.run([BR, f'{G}/{g}/{g}-{side}.json', ROOT + 'App/ManGo/Resources', EMPTY, 'none'],
                         capture_output=True, text=True, env=e).stdout
    return view, their_throws(out)


for env in sys.argv[1:] or ['']:
    with ThreadPoolExecutor(8) as ex:
        got = dict(ex.map(lambda v: run(env, v), views))
    exact, total, diffs, cex, ctot = 0, 0, [], 0, 0
    for r in rows:
        th = [t for t in got[(r['game'], r['side'])] if abs(t['time'] - r['seen_time']) < 0.6]
        if not th:
            continue
        total += 1
        d = th[0]['raw'] - r['truth_before']
        exact += d == 0
        diffs.append(d)
        if r.get('truth_count') is not None:
            ctot += 1
            cex += th[0]['count'] == r['truth_count']
    over = sum(1 for d in diffs if d > 0)
    under = sum(1 for d in diffs if d < 0)
    print(f"{env or '(defaults)':45} energy {exact}/{total} exact, {over} over, {under} under; counts {cex}/{ctot}")
