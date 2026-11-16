import json, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from truthfit import view_truth
# One view's timeline between two times: ManGo's events and count (its report, TRACE) next to the
# truth (the other player's fitted readings: each new level is a fast move landing).
#   side.py <game dir> <L|R> <from s> <to s>
from paths import ROOT, BR, GAMES, EMPTY
d, side, lo, hi = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
g = os.path.basename(d.rstrip('/'))
env = dict(os.environ, TRACE=f'{lo}-{hi}')
p = subprocess.run([BR, f'{d}/{g}-{side}.json', ROOT + 'App/ManGo/Resources', EMPTY, 'none'], capture_output=True, text=True, env=env)
clock = lambda s: int(s.split(':')[0]) * 60 + float(s.split(':')[1])
events = []
for l in p.stdout.split('TIMELINE')[-1].splitlines():
    m = re.match(r'\s+(\d+:\d+\.\d+)\s+(.*)', l)
    if m and lo <= clock(m.group(1)) <= hi:
        events.append((clock(m.group(1)), 'M', m.group(2)))
last = None
for l in p.stderr.splitlines():
    m = re.match(r'(\d+:\d+\.\d+) (\S+) (.*) (\d+)$', l)
    if m:
        k = (m.group(2), m.group(3), m.group(4))
        if k != last:
            events.append((clock(m.group(1)), 'm', f'{m.group(2)} {m.group(3)} {m.group(4)}'))
            last = k
rows, fits = view_truth(d, side)
for f in fits:
    key, fm, delta, items, bad, score = f['fit']
    prev = None
    for it in items:
        if it[0] == 'read' and it[2] is not None and lo <= it[1]['t0'] <= hi and it[2] != prev:
            events.append((it[1]['t0'], 'T', f"{f['name']} {it[2]:.0f}  ({fm['moveId']})"))
            prev = it[2]
        if it[0] == 'throw' and lo <= it[1] <= hi:
            events.append((it[1], 'T', f"{f['name']} THROWS (cost {it[2]})"))
for t, k, s in sorted(events):
    print(f"{t:8.2f} {'MANGO' if k == 'M' else 'mango' if k == 'm' else 'TRUTH'}  {s}")
