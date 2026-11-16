import glob, json, os, sys, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from truth import report, your_throws, read_labels
# How late each phone shows the other's charged move: for every charged move, when the buttons
# were last legible before it on the thrower's phone and on the other one. On the same stream
# both phones share a clock, up to a fixed capture offset per phone, which cancels out:
#   d1 = L's buttons gone - R's, for R's moves = (R's move shown late on L) - offset
#   d2 = R's - L's, for L's moves             = (L's move shown late on R) + offset
from paths import GAMES
D = GAMES
all1, all2 = [], []
for d in sorted(glob.glob(D + '/g*')):
    g = os.path.basename(d)
    try:
        reads = {s: json.load(open(f'{d}/{g}-{s}.json')) for s in 'LR'}
    except FileNotFoundError:
        continue
    labels = {s: [r['time'] for r in reads[s] if read_labels(r)] for s in 'LR'}
    own = {s: your_throws(report(f'{d}/{g}-{s}.json')) for s in 'LR'}

    def gone(s, t):
        return max([x for x in labels[s] if x < t], default=None)

    d1, d2 = [], []
    for s, other, acc in (('R', 'L', d1), ('L', 'R', d2)):
        for t in own[s]:
            a = gone(s, t)
            if a is None:
                continue
            b = gone(other, t + 0.25)  # the other phone's buttons, gone around the same time
            if b is not None and abs(b - a) < 2:
                acc.append(b - a)
    if d1 and d2:
        m1, m2 = statistics.median(d1), statistics.median(d2)
        print(f"{g}: R's moves gone on L {m1:+.2f}s after R ({len(d1)}), L's on R {m2:+.2f}s after L ({len(d2)});"
              f" shown late by {(m1 + m2) / 2:+.2f}s on average, capture offset {(m2 - m1) / 2:+.2f}s")
        all1 += d1
        all2 += d2
if all1 and all2:
    print(f"all: shown late by {(statistics.median(all1) + statistics.median(all2)) / 2:+.2f}s")
