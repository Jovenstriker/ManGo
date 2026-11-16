"""Gathers a tournament stream's per-phone ManGo reads into one fixtures folder for battle-turns.

    python3 -I scripts/stream_fixtures.py <games dir> data/local/tournament/fixtures

<games dir> holds one folder per game (g01598/, ...), each with the two phones' reads
(g01598-L.json, g01598-R.json: ManGo ScreenRead fixtures of the left and right player's phone).
They're copied as battle-gdansk-g01598-L.json and so on, the names battle-turns picks up. Games
are left out, as for the stream counting checks, when:

  - any Pokémon in them is Dunsparce (the user asked to ignore those games), or
  - either phone has no countdown (3, 2, GO) in its first 25 seconds: the stream joined late.

Then, from ManGo's folder (the user runs it):

    swift run battle-turns <fixtures> ../App/ManGo/Resources none <out dir>

The reads come from a public stream, but they're large and derived from a video, so like the
recordings they stay in data/local.
"""
import json
import shutil
import sys
from pathlib import Path


def mid(line):
    (x, y), (w, h) = line["box"]
    return x + w / 2, y + h / 2


def has_countdown(reads):
    t0 = reads[0]["time"] if reads else 0
    for r in reads:
        if r["time"] > t0 + 25:
            break
        for line in r["lines"]:
            x, y = mid(line)
            if line["text"].strip() in ("GO", "3", "2") and 0.3 < x < 0.7 and 0.35 < y < 0.65:
                return True
    return False


def mentions(reads, word):
    return any(word in line["text"].lower() for r in reads for line in r["lines"])


def main():
    games, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    kept, skipped = [], []
    for d in sorted(games.glob("g*")):
        g = d.name
        fx = {s: d / f"{g}-{s}.json" for s in "LR"}
        if not all(f.exists() for f in fx.values()):
            continue
        reads = {s: json.loads(f.read_text()) for s, f in fx.items()}
        if any(mentions(r, "dunsparce") for r in reads.values()):
            skipped.append((g, "Dunsparce"))
            continue
        if not all(has_countdown(r) for r in reads.values()):
            skipped.append((g, "no countdown"))
            continue
        for s, f in fx.items():
            shutil.copyfile(f, out / f"battle-gdansk-{g}-{s}.json")
        kept.append(g)
    print(f"{len(kept)} games ({2 * len(kept)} phone views) copied to {out}; skipped {len(skipped)}:")
    for g, why in skipped:
        print(f"  {g}: {why}")


if __name__ == "__main__":
    main()
