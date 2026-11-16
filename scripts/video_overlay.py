import argparse, json, os, re, subprocess, sys
# One battle video with ManGo drawn under it, to watch what it did: its count of the opponent
# as it goes, its notes as it makes them, what the player says (YouTube's captions, word by
# word) and each count they say against ManGo's then. The video's own clock (where the match
# sits in the original video) is in the top corner.
#   video_overlay.py <video.mp4> <screen text .json> <out.mp4> --label "ItsAXN video 2" --offset 588
#       [--vtt captions.vtt] [--checkpoints counts.json]
# counts.json: [{"time": s into the match, "energy": their energy then, "note": "… \"what they said\" …"}]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + '/'
BUILD = os.environ.get('MANGO_BUILD_DIR', '/tmp/ManGo-PvPCore')
BR = BUILD + '/release/battle-report'
EMPTY = '/tmp/mango-no-hand-counts.json'
if not os.path.exists(EMPTY):
    open(EMPTY, 'w').write('{}')
a = argparse.ArgumentParser()
a.add_argument('video'); a.add_argument('fixture'); a.add_argument('out')
a.add_argument('--label', default=''); a.add_argument('--offset', type=float, default=0)
a.add_argument('--vtt'); a.add_argument('--checkpoints')
a = a.parse_args()
clock = lambda s: int(s.split(':')[0]) * 60 + float(s.split(':')[1])
mmss = lambda s: f"{int(s // 3600)}:{int(s % 3600 // 60):02d}:{s % 60:04.1f}" if s >= 3600 else f"{int(s // 60)}:{s % 60:04.1f}"
W, H = map(int, subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height',
                                '-of', 'csv=p=0', a.video], capture_output=True, text=True).stdout.strip().split(','))
duration = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', a.video],
                                capture_output=True, text=True).stdout.strip())
PANEL = 330

p = subprocess.run([BR, a.fixture, ROOT + 'App/ManGo/Resources', EMPTY, 'none'], capture_output=True, text=True,
                   env=dict(os.environ, TRACE='0-100000'))
states = [(clock(m.group(1)), m.group(2), m.group(3), int(m.group(4)))
          for m in (re.match(r'(\d+:\d+\.\d+) (\S+) (.*) (\d+)$', l) for l in p.stderr.splitlines()) if m]
notes = [(clock(m.group(1)), m.group(2).strip())
         for m in (re.match(r'\s+(\d+:\d+\.\d+)\s+(.*)', l) for l in p.stdout.split('TIMELINE')[-1].split('VALIDATION')[0].splitlines())
         if m and not re.match(r'(stopped|running)\s', m.group(2).strip())]
gain = {}  # each opponent's fast move energy, as ManGo has it (it can change during the battle)
for l in p.stdout.split('OPPONENT FAST MOVES ASSUMED')[-1].split('\n\n')[0].splitlines()[1:]:
    m = re.match(r'\s+(.+?)\s{2,}(.+?): \+(\d+) energy', l)
    if m:
        gain[m.group(1).strip()] = int(m.group(3))


def at(t):
    best = None
    for s in states:
        if s[0] <= t + 0.01:
            best = s
    return best


def ass_time(s):
    s = max(0.0, s)
    return f"{int(s // 3600)}:{int(s % 3600 // 60):02d}:{s % 60:05.2f}"


WHITE, GREEN, RED, GREY, YELLOW = '&HFFFFFF&', '&H66DD66&', '&H5555FF&', '&H999999&', '&H44DDFF&'
events = []


def event(t0, t1, y, text, size=20, colour=WHITE, bold=0, style='Default'):
    if t1 > t0:
        text = text.replace('{', '(').replace('}', ')').replace('\n', '\\N')
        events.append(f"Dialogue: 0,{ass_time(t0)},{ass_time(t1)},{style},,10,10,{H + y},,{{\\fs{size}\\c{colour}\\b{bold}}}{text}")


for k, (t, state, who, e) in enumerate(states):
    t1 = states[k + 1][0] if k + 1 < len(states) else duration
    E = gain.get(who)
    moves = f"  = {e // E} fast moves" + (f" + {e % E}" if e % E else '') if E else ''
    event(t, t1, 8, f"ManGo  {who}  {e}{moves}   {'(frozen)' if state == 'stopped' else ''}", 24, WHITE, 1)
for k, (t, text) in enumerate(notes):
    shown = [n for n in notes if n[0] <= t and t - n[0] < 5]
    event(t, min(t + 5, notes[k + 1][0] if k + 1 < len(notes) else t + 5), 150,
          '\n'.join(f"{int(n[0] // 60)}:{n[0] % 60:05.2f} {n[1]}" for n in shown[-4:]), 15)
if a.checkpoints:
    for c in json.load(open(a.checkpoints)):
        s = at(c['time'])
        m = re.search(r'"(.*)"', c['note'])
        quote = m.group(1) if m else ''
        n = re.search(r'= \d+ \((\d+) ×', c['note'])
        if not s:
            continue
        E = gain.get(s[2])
        diff = s[3] - c['energy']
        verdict = '✓' if diff == 0 else f"✗ ManGo {diff // E:+d}" if E and diff % E == 0 else f"✗ ManGo {diff:+d} energy"
        said = f"{n.group(1)} fast moves ({c['energy']})" if n else str(c['energy'])
        event(c['time'] - 0.25, c['time'] + 4, 44, f"He says \"{quote}\": {said}, ManGo {s[3]}  {verdict}",
              19, GREEN if diff == 0 else RED, 1)


def words(vtt):
    """Each spoken word's time from YouTube's auto-captions (<hh:mm:ss.mmm><c> word</c>; a line's
    first word at the line's start)."""
    tsec = lambda s: sum(float(x) * f for x, f in zip(s.split(':'), (3600, 60, 1)))
    out = []
    for block in open(vtt).read().split('\n\n'):
        m = re.search(r'(\d+:\d+:[\d.]+) -->', block)
        line = [l for l in block.split('\n') if '<c>' in l]
        if not m or not line:
            continue
        first = re.match(r'([^<]+)', line[0])
        if first:
            out.append((tsec(m.group(1)), first.group(1).strip()))
        out += [(tsec(t), w.strip()) for t, w in re.findall(r'<(\d+:\d+:[\d.]+)><c>([^<]*)</c>', line[0])]
    return sorted(out)


if a.vtt:
    ws = [(t - a.offset, w) for t, w in words(a.vtt) if -5 <= t - a.offset <= duration]
    for k, (t, w) in enumerate(ws):
        t1 = ws[k + 1][0] if k + 1 < len(ws) else t + 2
        recent = [x for x in ws[:k + 1] if t - x[0] < 4]
        event(t, min(t1, t + 3), 100, 'He says: ' + ' '.join(x[1] for x in recent[-12:]), 17, YELLOW, 0)
for k in range(int(duration * 10) + 1):
    events.append(f"Dialogue: 1,{ass_time(k / 10)},{ass_time((k + 1) / 10)},Clock,,0,8,8,,{a.label} {mmss(a.offset + k / 10)}")

ass = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {W}
PlayResY: {H + PANEL}
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica,20,&HFFFFFF&,&HFFFFFF&,&H000000&,&H000000&,0,0,0,0,100,100,0,0,1,1,0,7,10,10,10,1
Style: Clock,Helvetica,18,&HFFFFFF&,&HFFFFFF&,&H000000&,&H80000000&,1,0,0,0,100,100,0,0,3,4,0,9,8,8,8,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
""" + '\n'.join(events) + '\n'
ass_path = os.path.splitext(a.out)[0] + '.ass'
open(ass_path, 'w').write(ass)
r = subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', a.video, '-vf',
                    f"pad={W}:{H + PANEL}:0:0:black,subtitles='{ass_path}',fps=30", '-c:v', 'libx264', '-preset', 'veryfast',
                    '-crf', '24', '-pix_fmt', 'yuv420p', '-an', a.out], capture_output=True, text=True)
if r.returncode:
    sys.exit(r.stderr)
os.remove(ass_path)
print(a.out)
