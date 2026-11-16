import subprocess, sys
import numpy as np
# Finds where the stream shows the two phone screens side by side: once a second, the green
# divider between them and the green frame on their outer edges, at 144p (256x144). Prints
# each stretch as "start end" in seconds, merged across gaps under 20s.
video = sys.argv[1]
W, H = 256, 144
p = subprocess.Popen(['ffmpeg', '-loglevel', 'error', '-i', video, '-vf', f'fps=1,scale={W}:{H}',
                      '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
flags = []
while True:
    buf = p.stdout.read(W * H * 3)
    if len(buf) < W * H * 3:
        break
    a = np.frombuffer(buf, np.uint8).reshape(H, W, 3).astype(int)

    def col(x):
        return a[20:130, x].mean(0)

    def pale(c, g=185, d=25):
        return c[1] > g and c[1] - c[0] > d and c[1] - c[2] > 5

    divider = max(col(127)[1], col(128)[1]) > 165
    flags.append(divider and pale(col(66)) and pale(col(189)))
p.wait()
runs, start = [], None
for i, f in enumerate(flags + [False]):
    if f and start is None:
        start = i
    if not f and start is not None:
        runs.append([start, i])
        start = None
merged = []
for r in runs:
    if merged and r[0] - merged[-1][1] < 20:
        merged[-1][1] = r[1]
    else:
        merged.append(r)
for s, e in merged:
    if e - s >= 30:
        print(s, e)
