"""A battle as text, laid out like PvPoke's timeline: one row per side, one column per turn.

    ■       a 1-turn fast move           ●  a charged move
    [==]    a longer one, start to hit   ◆  a shield
    X       a faint                      ◉  a charged move and a shield on the same turn

A fast move a charged move interrupted is drawn up to the turn it registered.
"""
from __future__ import annotations

from .battle import Battle

WIDTH = 100


def render(battle: Battle, names: tuple[str, str], width: int = WIDTH) -> str:
    turns = battle.turn + 1
    rows = [[" "] * turns for _ in (0, 1)]
    for e in battle.log or []:
        row = rows[e.side]
        if e.kind == "fast":
            start = max(e.info.get("started", e.turn), 0)
            span = e.turn - start + 1
            cells = "■" if span == 1 else "[" + "=" * (span - 2) + "]"
            row[start:e.turn + 1] = list(cells)
        elif e.kind == "charged":
            row[e.turn] = "◉" if row[e.turn] == "◆" else "●"
            if e.info["shielded"]:
                other = rows[1 - e.side]
                other[e.turn] = "◉" if other[e.turn] == "●" else "◆"
        elif e.kind == "faint":
            row[e.turn] = "X"
    label = max(len(n) for n in names) + 2
    out = []
    for lo in range(0, turns, width):
        hi = min(turns, lo + width)
        ruler = "".join(str(t // 10 % 10) if t % 10 == 0 else ("·" if t % 5 == 0 else " ") for t in range(lo, hi))
        out.append(" " * label + ruler + "   (turn ÷ 10)")
        for name, row in zip(names, rows):
            out.append(f"{name:<{label}}" + "".join(row[lo:hi]).rstrip())
        out.append("")
    return "\n".join(out).rstrip()
