"""Your recorded battles, from `Battle Turns/` (made on the Mac from your screen recordings by
`swift run battle-turns`; git-ignored, never committed).

`battles.csv` has each battle's teams in the order they came in, with your movesets (from your
buttons), the charged moves the opponent threw, and the result. `turns.csv` has every turn: each
side's actions (fast and charged moves, shields, switches, faints), energy and shields left.

From those turns, `Habits` keeps two things about each opponent, and nothing else:
  shields  for each of your charged moves they could have shielded, in order: did they?
  baits    for each charged move they threw while you still had a shield: was it their
           cheaper move (a bait), or the bigger one?

`HabitOpponent` is the strong planner playing their team with those habits on top. It shields
your charged moves the way they did, in the same order, and once those run out at their overall
rate. While you have shields, a baiter throws its cheaper move as soon as it can afford it, and
a non-baiter holds for its bigger one. Fast moves, timing, switches and everything else are the
planner's own. It doesn't replay the battle turn by turn.
"""
from __future__ import annotations

import csv
import random
from dataclasses import dataclass, field
from pathlib import Path

from .battle import CHARGED, FAST, View
from .gamedata import GameData, Move

TeamSpec = list[tuple[str, str, tuple[str, ...]]]


@dataclass
class Habits:
    shields: list[bool] = field(default_factory=list)
    baits: list[bool] = field(default_factory=list)

    @property
    def shield_rate(self) -> float | None:
        return sum(self.shields) / len(self.shields) if self.shields else None

    @property
    def bait_rate(self) -> float | None:
        return sum(self.baits) / len(self.baits) if self.baits else None


@dataclass
class RecordedBattle:
    id: str
    result: str          # "won", "lost", "draw", or "" if the recording ends first
    you: TeamSpec        # in the order they came in (lead first)
    them: TeamSpec
    habits: Habits
    seen: int            # how many of their Pokémon came in


def _spec(gd: GameData, row: dict, side: str, own_moves: bool) -> tuple[TeamSpec, int]:
    team, seen = [], 0
    for k in (1, 2, 3):
        sid = row[f"{side}_{k}"]
        if not sid:
            continue
        seen += 1
        fast, charged = gd.recommended(sid)
        moves = [m for m in row[f"{side}_{k}_charged"].split(";") if m]
        if not own_moves:   # theirs: the moves they threw, then PvPoke's to make two
            moves += [c.id for c in charged if c.id not in moves]
        team.append((sid, row[f"{side}_{k}_fast"] or fast.id, tuple(moves[:2])))
    return team, seen


def load(gd: GameData, folder: Path) -> list[RecordedBattle]:
    rows = list(csv.DictReader((folder / "battles.csv").open()))
    turns: dict[str, list[dict]] = {}
    for t in csv.DictReader((folder / "turns.csv").open()):
        turns.setdefault(t["battle_id"], []).append(t)
    out = []
    for row in rows:
        you, _ = _spec(gd, row, "you", True)
        them, seen = _spec(gd, row, "them", False)
        cost = {sid: [gd.moves[c].energy for c in cs] for sid, _, cs in them}
        habits = Habits()
        prev = {"you": 2, "them": 2}   # shields left at the end of the turn before
        for t in sorted(turns.get(row["battle_id"], []), key=lambda t: int(t["turn"])):
            for a in filter(None, t["you_action"].split(";")):
                if a.startswith("charged:") and not a.endswith("(disguise)") and prev["them"] > 0:
                    habits.shields.append(a.endswith("(shielded)"))
            for a in filter(None, t["them_action"].split(";")):
                if a.startswith("charged:") and prev["you"] > 0:
                    move = a[len("charged:"):].split("(")[0]
                    sid = t["them_active"]
                    costs = cost.get(sid, [])
                    if move in gd.moves and len(costs) == 2 and costs[0] != costs[1]:
                        habits.baits.append(gd.moves[move].energy == min(costs))
            prev = {"you": int(t["you_shields"] or 0), "them": int(t["them_shields"] or 0)}
        out.append(RecordedBattle(row["battle_id"], row["result"], you, them, habits, seen))
    return out


class HabitOpponent:
    """The planner, shielding and baiting the way this opponent did."""

    def __init__(self, planner, habits: Habits, seed: int | None = None):
        self.planner, self.habits = planner, habits
        self.rng = random.Random(seed)
        self.asked = 0   # shield decisions so far
        self.name = "habits"

    def start(self, side: int) -> None:
        self.planner.start(side)

    def observe(self, events) -> None:
        self.planner.observe(events)

    def shield(self, view: View, move: Move) -> bool:
        if view.me.shields == 0 or view.mon.form == "disguised":
            return False
        k, self.asked = self.asked, self.asked + 1
        if k < len(self.habits.shields):
            return self.habits.shields[k]
        rate = self.habits.shield_rate
        return self.planner.shield(view, move) if rate is None else self.rng.random() < rate

    def act(self, view: View) -> tuple[str, int]:
        a = self.planner.act(view)
        rate = self.habits.bait_rate
        mon = view.mon
        if rate is None or view.foe_shields == 0 or len(mon.charged) < 2 or a[0] == "switch":
            return a
        costs = [c.energy for c in mon.charged]
        if costs[0] == costs[1]:
            return a
        cheap, big = (0, 1) if costs[0] < costs[1] else (1, 0)
        if rate >= 0.5:   # a baiter: the cheap move as soon as it's affordable
            return CHARGED(cheap) if mon.energy >= costs[cheap] else a
        if a == CHARGED(cheap):   # holds for the big one
            return CHARGED(big) if mon.energy >= costs[big] else FAST
        return a

    def replace(self, view: View) -> int:
        return self.planner.replace(view)
