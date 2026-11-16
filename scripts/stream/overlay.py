import json, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from truthfit import view_truth
from truth2 import throws_truth
from paths import ROOT, BR, EMPTY
# A stream game with ManGo drawn over it, to watch what it did: both phones side by side, and
# under each one ManGo's count of the opponent (that phone's view) next to the truth (the other
# phone's own buttons), each charged move of theirs with both counts, and ManGo's notes as it
# makes them. The stream clock is in the top corner.
#   overlay.py <game dir> [out.mp4]      (Stream Battles/…/gNNNNN; out defaults to gNNNNN-overlay.mp4 in it)
d = sys.argv[1].rstrip('/')
g = os.path.basename(d)
out = sys.argv[2] if len(sys.argv) > 2 else f'{d}/{g}-overlay.mp4'
start = int(g[1:]) - 5  # fetch.sh downloads from 5s before the stretch
clock = lambda s: int(s.split(':')[0]) * 60 + float(s.split(':')[1])
hms = lambda s: f"{int(s // 3600)}:{int(s % 3600 // 60):02d}:{s % 60:04.1f}"
W = {'L': 454, 'R': 452}
H, PANEL = 980, 380
X = {'L': 0, 'R': W['L']}


def mango(side):
    env = dict(os.environ, TRACE='0-100000')
    p = subprocess.run([BR, f'{d}/{g}-{side}.json', ROOT + 'App/ManGo/Resources', EMPTY, 'none'],
                       capture_output=True, text=True, env=env)
    states = []
    for l in p.stderr.splitlines():
        m = re.match(r'(\d+:\d+\.\d+) (\S+) (.*) (\d+)$', l)
        if m:
            states.append((clock(m.group(1)), m.group(2), m.group(3), int(m.group(4))))
    notes = []
    for l in p.stdout.split('TIMELINE')[-1].split('VALIDATION')[0].splitlines():
        m = re.match(r'\s+(\d+:\d+\.\d+)\s+(.*)', l)
        if m and not re.match(r'(stopped|running)\s', m.group(2).strip()):
            notes.append((clock(m.group(1)), m.group(2).strip()))
    return states, notes


def truth(side):
    """The other player's Pokémon's energy at each reading of their own buttons."""
    _, fits = view_truth(d, side)
    reads = []
    for f in fits:
        key, fm, delta, items, bad, score = f['fit']
        for it in items:
            if it[0] == 'read' and it[2] is not None:
                reads.append((it[1]['t0'], (f['name'] or '?').title(), fm['name'], int(round(it[2]))))
    return sorted(reads)


def throws(side):
    rows, truth_at = throws_truth(d, side)
    left, result = {}, []
    for r in sorted(rows, key=lambda r: r['t']):
        t, s = truth_at.get(r['t']), r['seen']
        count = None
        if t and t['before'] is not None:
            prev = left.get(r['labels'], 0)
            if prev is not None and t['before'] < 100 and (t['before'] - prev) % t['gain'] == 0:
                count = (t['before'] - prev) // t['gain']
            left[r['labels']] = t['before'] - s['cost'] if s else None
        else:
            left[r['labels']] = None
        result.append(dict(their=r['t'], seen=s, truth=t and t['before'], truth_count=count))
    return result


def ass_time(s):
    s = max(0.0, s)
    return f"{int(s // 3600)}:{int(s % 3600 // 60):02d}:{s % 60:05.2f}"


def esc(s):
    return s.replace('{', '(').replace('}', ')').replace('\n', '\\N')


WHITE, GREEN, RED, GREY, YELLOW = '&HFFFFFF&', '&H66DD66&', '&H5555FF&', '&H999999&', '&H44DDFF&'
events = []


def event(t0, t1, side, y, text, size=20, colour=WHITE, bold=0):
    if t1 <= t0:
        return
    ml = X[side] + 8
    mr = W['L'] + W['R'] - X[side] - W[side] + 8
    events.append(f"Dialogue: 0,{ass_time(t0)},{ass_time(t1)},Default,,{ml},{mr},{H + y},,"
                  f"{{\\fs{size}\\c{colour}\\b{bold}}}{esc(text)}")


duration = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0',
                                 f'{d}/{g}-L.mp4'], capture_output=True, text=True).stdout.strip() or 0)
for side in 'LR':
    other = 'right' if side == 'L' else 'left'
    event(0, duration, side, 6, f"{'LEFT' if side == 'L' else 'RIGHT'} PHONE: ManGo counts the {other} player", 17, GREY, 1)
    states, notes = mango(side)
    reads = truth(side)
    # ManGo's count and the truth, a line each, as they change
    rows = []
    ti = 0
    for k, (t, state, who, e) in enumerate(states):
        while ti + 1 < len(reads) and reads[ti + 1][0] <= t:
            ti += 1
        tr = reads[ti] if reads and reads[ti][0] <= t else None
        fresh = tr is not None and t - tr[0] <= 1.5
        rows.append((t, f"ManGo  {who}  {e}   {'(frozen)' if state == 'stopped' else ''}",
                     None if tr is None else f"Truth  {tr[1]}  {tr[3]}   {tr[2]}" + ('' if fresh else '  (last seen)'),
                     tr is not None and tr[3] == e, fresh))
    for k, (t, mline, tline, same, fresh) in enumerate(rows):
        t1 = rows[k + 1][0] if k + 1 < len(rows) else duration
        event(t, t1, side, 30, mline, 24, WHITE, 1)
        if tline:
            event(t, t1, side, 60, tline, 22, (GREEN if same else RED) if fresh else GREY, 1)
    # Their charged moves: when their own phone threw, and when ManGo saw it, with both counts
    for th in throws(side):
        s = th['seen']
        if not s:
            event(th['their'], th['their'] + 4, side, 96, "They threw: ManGo didn't see it", 20, RED, 1)
            continue
        ok = th['truth'] is not None and s['raw'] == th['truth']
        verdict = '' if th['truth'] is None else ('  ✓' if ok else f"  ✗ ManGo {s['raw'] - th['truth']:+d}")
        tc = '' if th['truth_count'] is None else f" ({th['truth_count']})"
        mc = '' if s['count'] is None else f" ({s['count']})"
        froze = next((st[0] for st in states if st[0] >= th['their'] - 0.5 and st[1] == 'stopped'), None)
        late = '' if froze is None else f", this phone froze {froze - th['their']:+.2f}s after"
        event(th['their'], s['time'], side, 96, f"THEY THREW {s['move']}: their buttons went{late}", 18, YELLOW, 1)
        event(s['time'], s['time'] + 5, side, 96,
              f"{s['species']} {s['move']}: truth {th['truth'] if th['truth'] is not None else '?'}{tc}, ManGo {s['raw']}{mc}{verdict}",
              20, GREY if th['truth'] is None else GREEN if ok else RED, 1)
    # ManGo's notes, newest at the bottom, each for 4 s
    for k, (t, text) in enumerate(notes):
        shown = [n for n in notes if n[0] <= t and t - n[0] < 4]
        event(t, min(t + 4, notes[k + 1][0] if k + 1 < len(notes) else t + 4), side, 150,
              '\n'.join(f"{int(n[0] // 60)}:{n[0] % 60:05.2f} {n[1]}" for n in shown[-4:]), 15, WHITE, 0)
# the stream clock
for k in range(int(duration * 10) + 1):
    events.append(f"Dialogue: 1,{ass_time(k / 10)},{ass_time((k + 1) / 10)},Clock,,0,8,8,,Gdańsk stream, Day 2, {hms(start + k / 10)}")

ass = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {W['L'] + W['R']}
PlayResY: {H + PANEL}
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica,20,&HFFFFFF&,&HFFFFFF&,&H000000&,&H000000&,0,0,0,0,100,100,0,0,1,1,0,7,8,8,8,1
Style: Clock,Helvetica,18,&HFFFFFF&,&HFFFFFF&,&H000000&,&H80000000&,1,0,0,0,100,100,0,0,3,4,0,9,8,8,8,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
""" + '\n'.join(events) + '\n'
ass_path = f'{d}/{g}-overlay.ass'
open(ass_path, 'w').write(ass)
r = subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', f'{d}/{g}-L.mp4', '-i', f'{d}/{g}-R.mp4', '-filter_complex',
                    f"[0:v][1:v]hstack=inputs=2,pad={W['L'] + W['R']}:{H + PANEL}:0:0:black,"
                    f"subtitles='{ass_path}',fps=30[v]", '-map', '[v]', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '24',
                    '-pix_fmt', 'yuv420p', out], capture_output=True, text=True)
if r.returncode:
    sys.exit(r.stderr)
os.remove(ass_path)
print(out)
