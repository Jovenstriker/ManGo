#!/bin/bash
# Fetches one side-by-side stretch of a tournament stream (both players' phones on screen) and
# turns each phone into a fixture, the way the recordings were made, plus the truth reader's
# button fills:
#   - downloads the stretch at 1080p (5s before to 10s after)
#   - crops each phone (left x 501-954, right x 966-1417, y 50-1029 on the Gdańsk 2027 stream),
#     blacking out the stream's caption over the status bars
#   - screen text 4 times a second, then the buttons' fill on every frame, then the HP bar
#   - truthpix.py on both crops
#
#   scripts/stream/fetch.sh <start s> <end s> [video id]
# Stretches come from scan.py on a 144p copy of the stream. Everything lands in
# "Stream Battles/" (git-ignored: kept on this Mac only).
set -uo pipefail
cd "$(dirname "$0")/../.."
HERE=scripts/stream
BUILD=${MANGO_BUILD_DIR:-/tmp/ManGo-PvPCore}
SL="$BUILD/release/screen-log"
GAMES=${STREAM_GAMES:-"Stream Battles/gdansk-2027-day2"}
VIDEO=${3:-Mo6-Evkz_jE}
s=$1; e=$2
name=g$(printf %05d "$s")
out="$GAMES/$name"
mkdir -p "$out"
[ -s "$out/$name-R.pix.json" ] && exit 0
yt-dlp --no-warnings -q -f 299 --download-sections "*$((s - 5))-$((e + 10))" -o "$out/section.%(ext)s" \
  "https://www.youtube.com/watch?v=$VIDEO" || { echo "$name: download failed"; exit 1; }
ffmpeg -loglevel error -y -i "$out/section.mp4" -filter_complex \
  "[0:v]split=2[a][b];[a]crop=454:980:501:50,drawbox=x=0:y=0:w=iw:h=40:color=black:t=fill[l];[b]crop=452:980:966:50,drawbox=x=0:y=0:w=iw:h=40:color=black:t=fill[r]" \
  -map "[l]" -c:v libx264 -crf 20 -preset veryfast -an "$out/$name-L.mp4" \
  -map "[r]" -c:v libx264 -crf 20 -preset veryfast -an "$out/$name-R.mp4" && rm -f "$out/section.mp4"
read_side() {
  v=$1; f=$2
  "$SL" "$v" 0.25 --json > "$f.text" && "$SL" "$v" --fill "$f.text" > "$f.fill" && "$SL" "$v" --hp-all "$f.fill" > "$f"
  rm -f "$f.text" "$f.fill"
  python3 -I "$HERE/truthpix.py" "${v}" "${f%.json}.pix.json" > /dev/null
}
read_side "$out/$name-L.mp4" "$out/$name-L.json" &
read_side "$out/$name-R.mp4" "$out/$name-R.json"
wait
echo "$name: done"
