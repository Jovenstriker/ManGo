import json, subprocess, sys
import numpy as np
# How full a phone crop's two charge buttons are on every frame, measured against the buttons'
# real circles (found per crop), for the truth: a button of cost C fills e / C of its height.
#
#   truthpix.py <crop.mp4> <out.json>     -> [[time, fill left, fill right, edge left, edge right], ...]
#
# Each button: a few vertical lines either side of its icon; on each, the fill's top is where
# it turns from the dark empty part (above) to the move's color (below). The fill is the
# median line's height above the circle's bottom, over its diameter. With no clear edge, it's
# empty (dark down to the rim) or full (bright up to the top): fill 0 or 1, edge strength 0.
v, out = sys.argv[1], sys.argv[2]
probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height',
                        '-of', 'csv=p=0', v], capture_output=True, text=True).stdout.strip().split(',')
W, H = int(probe[0]), int(probe[1])
Y0 = int(0.83 * H) // 2 * 2
BH = (int(0.96 * H) - Y0) // 2 * 2  # even, as ffmpeg crops 4:2:0 video
Y1 = Y0 + BH


def frames(fps):
    p = subprocess.Popen(['ffmpeg', '-loglevel', 'error', '-i', v, '-vf', f'fps={fps},crop={W}:{BH}:0:{Y0}',
                          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
    n = W * BH * 3
    k = 0
    while True:
        buf = p.stdout.read(n)
        if len(buf) < n:
            break
        yield k / fps, np.frombuffer(buf, np.uint8).reshape(BH, W, 3).astype(np.float32)
        k += 1
    p.wait()


# The circles: where the averaged edges of many frames make the strongest ring near ManGo's
# button positions. The rim stays put while the scene behind it moves.
acc, n = None, 0
for t, a in frames(2):
    g = a.sum(2)
    gy, gx = np.gradient(g)
    m = np.hypot(gx, gy)
    acc = m if acc is None else acc + m
    n += 1
acc /= max(n, 1)
circles = []
# Measured on the Gdańsk stream's right phone (g02518): centers (0.307, 0.8974) and (0.6936,
# 0.8974), radius 0.0783 of the width; each crop is searched a few pixels around that.
for nx in (0.307, 0.6936):
    best = None
    for R in np.arange(0.0763, 0.0804, 0.001) * W:
        ang = np.linspace(0, 2 * np.pi, 96, endpoint=False)
        for cx in np.arange(nx * W - 5, nx * W + 5.1, 1):
            for cy in np.arange(0.8974 * H - Y0 - 6, 0.8974 * H - Y0 + 6.1, 1):
                xs = np.clip((cx + R * np.cos(ang)).astype(int), 0, W - 1)
                ys = np.clip((cy + R * np.sin(ang)).astype(int), 0, BH - 1)
                s = acc[ys, xs].mean()
                if best is None or s > best[0]:
                    best = (s, cx, cy, R)
    circles.append(best[1:])
# The search drifts onto the scene; until it's reliable, the measured circles as they are.
circles = [(nx * W, 0.8974 * H - Y0, 0.0783 * W) for nx in (0.307, 0.6936)]

rows = []
for t, a in frames(30):
    b = a.sum(2)
    vals, edges = [], []
    for cx, cy, R in circles:
        fills, strength = [], []
        for f in (-0.68, -0.56, -0.44, 0.44, 0.56, 0.68):
            x = int(round(cx + f * R))
            half = np.sqrt(R * R - (f * R) ** 2)
            top, bot = int(np.ceil(cy - half + 2)), int(np.floor(cy + half - 2))
            col = b[top:bot + 1, x - 1:x + 2].mean(1)
            if len(col) < 12:
                continue
            # the step from dark (above) to bright (below) with the most contrast
            c = np.cumsum(np.concatenate([[0], col]))
            w = 3
            ys = np.arange(w, len(col) - w + 1)
            d = (c[ys + w] - c[ys]) / w - (c[ys] - c[ys - w]) / w
            j = int(np.argmax(d))
            best = (float(d[j]), int(ys[j]))
            if best[1] is not None and best[0] > 60:
                ye = top + best[1]
                fills.append((cy + R - ye) / (2 * R))
                strength.append(best[0])
            else:
                fills.append(None)
                strength.append(0)
        got = [x for x in fills if x is not None]
        if len(got) >= 3:
            vals.append(float(np.median(got)))
            edges.append(float(np.median([s for s in strength if s])))
        else:
            # no edge on most lines: all dark (empty) or all bright (full)
            vals.append(None)
            edges.append(0.0)
    rows.append([round(t, 3), vals[0], vals[1], round(edges[0]), round(edges[1])])
json.dump(dict(circles=[[float(x) for x in c] for c in circles], band=[Y0, Y1], size=[W, H], frames=rows), open(out, 'w'))
print('circles', [[round(float(x), 1) for x in c] for c in circles])
