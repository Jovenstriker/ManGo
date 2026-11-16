import json, os, re, subprocess, sys
from collections import Counter, defaultdict
# Which situations ManGo's misses on the stream come from: each truth-checked charged move of
# theirs is tagged by what ManGo noted since that Pokémon's previous one (or its coming in),
# and the misses are tallied against the exact ones per tag. ManGo's counts are the ones
# truth.json was made with (rerun evaluate.py after a change).   situations.py [--list]
from paths import ROOT, BR, GAMES, EMPTY, TRUTH
G = GAMES
norm = lambda s: re.sub(r'[^a-z]', '', (s or '').lower().split('(')[0])
clock = lambda s: int(s.split(':')[0]) * 60 + float(s.split(':')[1])
rows = [r for r in json.load(open(TRUTH)) if r['truth_count'] is not None and r['mango_count'] is not None
        and (r['truth_species'] is None or norm(r['truth_species']) == norm(r['species']))]
TAGS = [('your charged move (sneak)', r'You threw a charged move'),
        ('tie they won', r'CMP tie'), ('tie you won', r'same turn as you'),
        ('align: one more', r'had finished one more fast move'),
        ('HP veto', r'HP bar shows no hit'),
        ('restart seen by hit', r'in progress hit you'),
        ('your fast move clock', r'Your fast move landed'),
        ('fade-in restart', r'buttons began fading in'),
        ('their Pokémon switched/fainted', r'fainted or switched out'),
        ('your Pokémon fainted', r'Your Pokémon fainted'),
        ('your buttons changed (your switch)', r'Your buttons:'),
        ('cap/underpay', r'Timing uncertain|resynchronized'),
        ('fast move changed', r"wouldn't be|rhythm|couldn't have")]
cache = {}
tally = defaultdict(Counter)
listing = []
for r in rows:
    v = (r['game'], r['side'])
    if v not in cache:
        out = subprocess.run([BR, f"{G}/{v[0]}/{v[0]}-{v[1]}.json", ROOT + 'App/ManGo/Resources', EMPTY, 'none'],
                             capture_output=True, text=True).stdout
        tl = []
        for l in out.split('TIMELINE')[-1].splitlines():
            m = re.match(r'\s+(\d+:\d+\.\d+)\s+(.*)', l)
            if m:
                tl.append((clock(m.group(1)), m.group(2).strip()))
        cache[v] = tl
    tl = cache[v]
    sp = norm(r['species'])
    # window: since this Pokémon's previous charged move, or since it came in
    start = 0.0
    for t, s in tl:
        if t >= r['seen_time'] - 0.01:
            break
        if norm(s.split(' used ')[0]) == sp and ' used ' in s:
            start = t
        if s.startswith('Opponent: ') and norm(s[10:]) == sp and start == 0.0:
            start = t
    window = [(t, s) for t, s in tl if start < t < r['seen_time'] - 0.01]
    tags = [name for name, pat in TAGS if any(re.search(pat, s) for t, s in window)]
    if start == 0.0 or not any(s.startswith('Opponent: ') and norm(s[10:]) == sp for t, s in tl if t <= start + 0.01):
        pass
    lead = not any(' used ' in s for t, s in tl if t < r['seen_time'] - 0.01) and not any(s.startswith('You threw') for t, s in tl if t < start)
    if lead:
        tags.append('lead, first stretch')
    d = r['mango_count'] - r['truth_count']
    ok = 'exact' if d == 0 else 'over' if d > 0 else 'under'
    for tag in tags or ['(nothing noted)']:
        tally[tag][ok] += 1
    tally['ALL'][ok] += 1
    listing.append((r, d, tags, window))
print(f"{'situation in the stretch':38} exact  over under   miss rate")
for tag, c in sorted(tally.items(), key=lambda kv: -sum(kv[1].values())):
    n = sum(c.values())
    print(f"{tag:38} {c['exact']:5} {c['over']:5} {c['under']:5}   {(c['over'] + c['under']) / n:5.0%}")
if '--list' in sys.argv:
    for r, d, tags, window in listing:
        if d:
            print(f"\n{r['game']} {r['side']} {r['seen_time']:.2f} {r['species']} {r['move']}: truth {r['truth_before']}, mango {r['mango_raw']} ({d:+d})")
            for t, s in window:
                if not s.startswith(('running', 'stopped')):
                    print(f"     {t:7.2f} {s}")
