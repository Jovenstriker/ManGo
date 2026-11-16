"""Your recorded battles, from `Battle Turns/` (made on the Mac from your screen recordings by
`swift run battle-turns`; git-ignored, never committed).

`battles.csv` has each battle's teams in the order they came in, with your movesets (from your
buttons), the charged moves the opponent threw, and the result. `turns.csv` has every turn: each
side's actions (fast and charged moves, shields, switches, faints), energy and shields left.

The export has no HP, so `replay` rebuilds it: it plays each turn's recorded actions through the
damage formula (switches, then fast moves, then charged moves in the recorded order; a faint
sets HP to 0). Buffs that always happen are applied; chance ones aren't known, so they're left
out. The formula uses PvPoke's default IVs and the export can miss a hit, so the rebuilt HP
drifts. Each faint is an exact anchor: that Pokémon's HP is 0 on that turn. So `load` replays
each battle twice. The first pass adds up the damage every Pokémon took. The second scales
the damage each one takes (within ×0.5 to ×2) so its HP reaches 0 on the turn it really
fainted. A Pokémon that never fainted but whose hits add up to its HP is scaled to end at 10%.
Until its faint is recorded a Pokémon keeps at least 1 HP, since the export can mark a faint a
turn or two after the hit.

The export also misses faints. Sometimes it records a faint and the replacement after it as a
plain switch, so two rules fill them in:
- a switch while the switch timer is still running can't have been one, so it's taken as a
  faint and its replacement;
- the losing side's three Pokémon all fainted, so one still alive in the back at the end
  fainted when it last left the field, and one still in at the end fainted on the last turn.
`complete` says whether the faints then fit the result: the loser's three all fainted and
the winner's didn't.
Then each opponent decision is kept with its context:

  ShieldCase  one of your charged moves they could have shielded: who was in on each side, the
              move, the share of their HP it would take, both sides' shields, how many of your
              charged moves that Pokémon had already faced, and whether they shielded
  ThrowCase   a turn they chose their next action with enough energy for a charged move: who
              was in, their energy, both sides' shields and HP, whether their last throw was
              shielded, and what they did (which charged move, or held and fast moved)
  SwitchCase  a free turn when they could switch: whom they switched to, or "" if they stayed
  ReplaceCase one of theirs fainted with two left behind it: whom they brought in

`ContextOpponent` is the strong planner playing their team, except where the simulated battle
reaches a situation that matches one of that opponent's recorded decisions: then it does what
they did. A match needs the same Pokémon on both sides, the same shields on both sides, the same
history, and HP (and, for throws, energy) close to the recording. Nothing carries across
situations or across opponents; everywhere else the planner decides.
"""
from __future__ import annotations

import csv
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

from .battle import CHARGED, FAST, SWITCH_TURNS, Battle, Event, Mon, Side, View
from .gamedata import GameData, Move, damage

TeamSpec = list[tuple[str, str, tuple[str, ...]]]
HP_TOLERANCE = 0.2       # share of max HP
ENERGY_TOLERANCE = 10


@dataclass(frozen=True)
class ShieldCase:
    defender: str
    attacker: str
    move: str
    hp: float           # their HP before the hit, as a share of max
    lethal: bool        # the hit would have knocked them out
    shields: tuple[int, int]   # (theirs, yours) before the hit
    faced: int          # your charged moves this Pokémon had already taken (shielded or not)
    shielded: bool
    turn: int = -1


@dataclass(frozen=True)
class ThrowCase:
    active: str
    target: str
    energy: int
    hp: tuple[float, float]    # (theirs, yours), shares of max
    shields: tuple[int, int]   # (theirs, yours)
    last_shielded: bool | None  # their previous throw with this Pokémon: shielded? None if none yet
    choice: str         # the charged move they threw, or "" if they held and fast moved
    turn: int = -1


@dataclass(frozen=True)
class SwitchCase:
    turn: int
    active: str
    choice: str         # the Pokémon they switched to, or "" if they stayed in


@dataclass(frozen=True)
class ReplaceCase:
    turn: int           # the turn whose start (battle_at) is the state they chose in
    fainted: str
    choice: str


@dataclass(frozen=True)
class State:
    """Who's in, shields, and HP (share of max) on both sides, at the end of a turn."""
    you: str
    them: str
    you_shields: int
    them_shields: int
    you_hp: float
    them_hp: float

    def like(self, other: State, hp: float = HP_TOLERANCE) -> bool:
        return (self.you, self.them, self.you_shields, self.them_shields) == \
            (other.you, other.them, other.you_shields, other.them_shields) and \
            abs(self.you_hp - other.you_hp) <= hp and abs(self.them_hp - other.them_hp) <= hp


@dataclass(frozen=True)
class Decision:
    """One of your decisions in a recorded battle.

    kind "act": what you did on a free turn: ("charged", move), ("fast", "") while you had the
    energy to throw (a hold), or ("switch", species). kind "shield": ("shield", True/False) when
    they threw at you. kind "replace": ("replace", species) after one of yours fainted."""
    kind: str
    turn: int
    choice: tuple
    energy: int = -1    # your active's energy at the decision, when it isn't the turn's start
    move: str = ""      # for "shield": their incoming move
    fainted: str = ""   # for "replace": who fainted


@dataclass
class RecordedBattle:
    id: str
    result: str          # "won", "lost", "draw", or "" if the recording ends first
    you: TeamSpec        # in the order they came in (lead first)
    them: TeamSpec
    seen: int            # how many of their Pokémon came in
    shields: list[ShieldCase] = field(default_factory=list)
    throws: list[ThrowCase] = field(default_factory=list)
    switches: list[SwitchCase] = field(default_factory=list)
    replaces: list[ReplaceCase] = field(default_factory=list)
    unplaced: set[str] = field(default_factory=set)   # active Pokémon not on the team list (misreads)
    dealt: dict = field(default_factory=dict)        # (side, species) -> damage taken, unscaled
    dealt_at_faint: dict = field(default_factory=dict)   # (side, species) -> damage taken by its faint
    scale: dict = field(default_factory=dict)        # (side, species) -> the factor its damage was scaled by
    inferred: list = field(default_factory=list)     # (turn, side, species): faints the export missed
    exits: dict = field(default_factory=dict)        # (side, species) -> the last turn it switched out
    end_hp: dict = field(default_factory=dict)       # (side, species) -> rebuilt HP when the recording ends
    end_active: dict = field(default_factory=dict)   # side -> who was in when the recording ends
    complete: bool = False   # the faints fit the result
    path: dict[int, State] = field(default_factory=dict)   # the real battle at the end of each turn
    misread: bool = False   # your Pokémon don't fit any of your teams
    snapshots: dict[int, dict] = field(default_factory=dict)   # turn -> full state at its start
    events: dict[int, list] = field(default_factory=dict)      # turn -> what both sides saw (you are side 0)
    decisions: list[Decision] = field(default_factory=list)    # yours


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


def _stage(s: int) -> int:
    return max(-4, min(4, s))


def replay(gd: GameData, battle: RecordedBattle, turns: list[dict], scale: dict | None = None,
           faint_at: frozenset = frozenset()) -> None:
    """Rebuilds HP turn by turn and fills in battle.shields, .throws, .path, .snapshots, .events
    and .decisions. `scale` multiplies the damage each (side, species) takes, and `faint_at` has
    (turn, side, species) for switches that were really a faint and its replacement."""
    last_in = _last_in(turns)
    scale = scale or {}
    battle.scale = dict(scale)
    dealt: dict = defaultdict(int)
    fainted: set = set()   # (side, species) whose faint has been recorded; the rest stay at 1 HP or more

    def floor(side, sid):
        return 0 if (side, sid) in fainted else 1

    def hit(side, sid, raw):
        """The damage a hit of `raw` does to that Pokémon, scaled; and counted, unscaled."""
        dealt[side, sid] += raw
        return raw if raw <= 1 else max(1, round(raw * scale.get((side, sid), 1.0)))
    moves = {("you", sid): (f, cs) for sid, f, cs in battle.you} | {("them", sid): (f, cs) for sid, f, cs in battle.them}
    hp = {key: gd.species[key[1]].hp for key in moves}
    stages = defaultdict(lambda: [0, 0])
    busted = set()
    other = {"you": "them", "them": "you"}
    index = {"you": 0, "them": 1}
    active = {"you": battle.you[0][0], "them": battle.them[0][0]}
    shields = {"you": 2, "them": 2}
    faced = defaultdict(int)          # their Pokémon -> your charged moves it has taken
    last_shielded: dict[str, bool] = {}
    seen = {"you": {}, "them": {}}    # species -> [fast move or None, set of charged moves]
    last_switch = {"you": -999, "them": -999}
    entered = {"you": 0, "them": 0}   # the turn each side's active Pokémon came in
    last_charged = -10
    my_cheapest = {sid: min(gd.moves[c].energy for c in cs) for sid, _, cs in battle.you if cs}
    my_throws: set[int] = set()
    thrown = defaultdict(int)          # (side, species) -> charged moves thrown
    taken = defaultdict(int)           # (side, species) -> charged moves taken
    history = {"you": [None, None], "them": [None, None]}   # [last throw shielded?, shielded the last one?]
    # When each side's fast moves started and landed, for who's mid fast move at a turn's start.
    landings = {"you": [], "them": []}
    for row in turns:
        for s in ("you", "them"):
            for a in row[f"{s}_action"].split(";"):
                if a.startswith("fast:") and a[len("fast:"):] in gd.moves:
                    land = int(row["turn"])
                    landings[s].append((land - gd.moves[a[len("fast:"):]].turns + 1, land))

    def busy(s, t):
        for begun, land in landings[s]:
            if begun <= t - 1 and land >= t:
                return land + 1, land
        return t, -1

    def note(t, s, kind, sid, move=None, info=None):
        if (s, sid) in moves:   # leave out Pokémon the team list doesn't have (misreads)
            battle.events.setdefault(t, []).append(Event(t, index[s], kind, sid, move, info or {}))

    def look(s, sid):
        return seen[s].setdefault(sid, [None, set()])
    starts: dict[int, tuple] = {}     # turn -> their start-of-turn situation, for hold decisions
    threw_on: set[int] = set()        # turns they threw a charged move
    cheapest = {sid: min(gd.moves[c].energy for c in cs) for sid, _, cs in battle.them if cs}

    def share(side):
        sid = active[side]
        if (side, sid) not in hp or sid not in gd.species:   # not on the team list (a misread): treat as full
            battle.unplaced.add(sid)
            return 1.0
        return hp[side, sid] / gd.species[sid].hp

    def energy_of(row, side, sid):
        for k in (1, 2, 3):
            if row.get(f"{side}_{k}") == sid:
                v = row.get(f"{side}_{k}_energy")
                return int(v) if v not in (None, "") else 0
        return 0

    pending = {"you": False, "them": False}   # a fainted Pokémon is waiting to be replaced

    def missed_faint(t, s, out):
        """The export showed a switch that can't have been one: a faint it missed, then the replacement."""
        if (s, out) in hp:
            hp[s, out] = 0
            fainted.add((s, out))
            battle.dealt_at_faint.setdefault((s, out), dealt[s, out])
        note(t, s, "faint", out)
        battle.inferred.append((t, s, out))
        pending[s] = True
    my_switches: set[int] = set()
    prev_row: dict = {}
    for row in sorted(turns, key=lambda r: int(r["turn"])):
        t = int(row["turn"])
        acts = {s: [a for a in row[f"{s}_action"].split(";") if a] for s in ("you", "them")}
        if t == 0:
            for s in ("you", "them"):
                note(0, s, "enter", active[s], info={"lead": True})
                look(s, active[s])
        battle.snapshots[t] = {
            "mons": {s: {sid: (hp.get((s, sid), 0), energy_of(prev_row, s, sid) if prev_row else 0,
                               tuple(stages[s, sid]), (s, sid) in busted, thrown[s, sid], taken[s, sid])
                               for sid, _, _ in team}
                     for s, team in (("you", battle.you), ("them", battle.them))},
            "active": dict(active), "shields": dict(shields),
            "timer": {s: max(0, SWITCH_TURNS - (t - last_switch[s])) for s in active},
            "busy": {s: busy(s, t) for s in active}, "last_charged": last_charged, "entered": dict(entered),
            "history": {s: tuple(v) for s, v in history.items()},
            "seen": {s: {sid: (v[0], frozenset(v[1])) for sid, v in seen[s].items()} for s in seen}}
        theirs = active["them"]
        start = (theirs, active["you"], energy_of(prev_row, "them", theirs) if prev_row else 0,
                 (share("them"), share("you")), (shields["them"], shields["you"]), last_shielded.get(theirs))
        starts[t] = start
        # Could they switch this turn? Free (not mid fast move), timer run out, one behind them.
        could_switch = (busy("them", t)[0] == t and t - last_switch["them"] >= SWITCH_TURNS and not pending["them"]
                        and hp.get(("them", theirs), 0) > 0
                        and any(hp.get(("them", sid), 0) > 0 for sid, _, _ in battle.them if sid != theirs))
        switched_to = ""
        switched_now = set()   # sides with a switch recorded this turn
        charged_near = any(x.startswith("charged:") for side in ("you", "them")
                           for x in acts[side] + [y for y in prev_row.get(f"{side}_action", "").split(";") if y])
        # Switches.
        for s in ("you", "them"):
            for a in acts[s]:
                if a.startswith("switch:"):
                    switched_now.add(s)
                    out = active[s]
                    # "(0 turns)" is a switch that cost no turn: a replacement, or a 0-turn switch
                    # right after a charged move. With no charged move just before, a replacement.
                    # And only if it never comes back: one that's in again later didn't faint.
                    free = a.endswith("(0 turns)") and not charged_near and last_in.get((s, out), -1) <= t + 2
                    if not pending[s] and ((t, s, out) in faint_at or free):
                        missed_faint(t, s, out)
                    stages[s, out] = [0, -1 if (s, out) in busted else 0]
                    active[s] = a[len("switch:"):].split("(")[0]
                    replacing = pending[s]
                    pending[s] = False
                    if s == "you":
                        battle.decisions.append(Decision("replace", t, ("replace", active[s]), fainted=out)
                                                if replacing else Decision("act", t, ("switch", active[s])))
                        my_switches.add(t)
                    elif replacing:
                        battle.replaces.append(ReplaceCase(t, out, active[s]))
                    else:
                        switched_to = active[s]
                    if not replacing:
                        last_switch[s] = t
                        battle.exits[s, out] = t
                    entered[s] = t
                    note(t, s, "enter", active[s], info={"switch": not replacing})
                    look(s, active[s])
        if could_switch and not any(x[:2] == (t, "them") for x in battle.inferred):   # not if it fainted
            battle.switches.append(SwitchCase(t, theirs, switched_to))
        # Fast moves.
        for s in ("you", "them"):
            for a in acts[s]:
                if a.startswith("fast:") and (s, active[s]) in moves and (other[s], active[other[s]]) in moves:
                    att, dfn = active[s], active[other[s]]
                    mv = gd.moves[a[len("fast:"):]]
                    before_hit = hp[other[s], dfn]
                    dmg = hit(other[s], dfn, damage(mv, gd.species[att], gd.species[dfn], stages[s, att][0],
                                                    stages[other[s], dfn][1]))
                    hp[other[s], dfn] = max(floor(other[s], dfn), before_hit - dmg)
                    look(s, att)[0] = mv.id
                    note(t, s, "fast", att, mv, {"damage": dmg, "target": dfn, "target_hp": before_hit,
                                                 "target_shields": shields[other[s]], "started": t - mv.turns + 1})
                    if s == "you":
                        # The fast move started on t - turns + 1: if you could have thrown then, you held.
                        begun = t - mv.turns + 1
                        snap = battle.snapshots.get(begun)
                        if (snap and snap["active"]["you"] == att and begun not in my_throws | my_switches
                                and snap["mons"]["you"][att][1] >= my_cheapest.get(att, 101)):
                            battle.decisions.append(Decision("act", begun, ("fast", "")))
                    if s == "them":
                        # A fast move that lands on turn t started on t - turns + 1: that was a decision to hold.
                        begun = t - mv.turns + 1
                        ctx = starts.get(begun)
                        if ctx and ctx[0] == att and ctx[2] >= cheapest.get(att, 101) and begun not in threw_on:
                            battle.throws.append(ThrowCase(*ctx, choice="", turn=begun))
        # Charged moves, in the recorded order when both threw.
        order = ["you", "them"] if row.get("charged_first", "") != "them" else ["them", "you"]
        for s in order:
            for a in acts[s]:
                if not a.startswith("charged:"):
                    continue
                body = a[len("charged:"):]
                mid, blocked = body.split("(")[0], body.endswith("(shielded)") or body.endswith("(disguise)")
                att, dfn = active[s], active[other[s]]
                if (s, att) not in moves or (other[s], dfn) not in moves or mid not in gd.moves:
                    continue
                mv = gd.moves[mid]
                raw = damage(mv, gd.species[att], gd.species[dfn], stages[s, att][0], stages[other[s], dfn][1])
                full = raw if raw <= 1 else max(1, round(raw * scale.get((other[s], dfn), 1.0)))
                if s == "you" and shields["them"] > 0 and not body.endswith("(disguise)") and ("them", dfn) in hp:
                    battle.shields.append(ShieldCase(dfn, att, mid, share("them"), full >= hp["them", dfn],
                                                     (shields["them"], shields["you"]), faced[dfn],
                                                     body.endswith("(shielded)"), turn=t))
                if s == "them":
                    # Their energy just before the throw: what's left after it, plus its cost.
                    before = min(100, energy_of(row, "them", att) + mv.energy)
                    ctx = starts[t]
                    battle.throws.append(ThrowCase(att, ctx[1], before, ctx[3], ctx[4], ctx[5], choice=mid, turn=t))
                    last_shielded[att] = body.endswith("(shielded)")
                    threw_on.add(t)
                if s == "you":
                    faced[dfn] += 1
                    before = min(100, energy_of(row, "you", att) + mv.energy)
                    battle.decisions.append(Decision("act", t, ("charged", mid), energy=before))
                    my_throws.add(t)
                if s == "them" and shields["you"] > 0 and not body.endswith("(disguise)"):
                    battle.decisions.append(Decision("shield", t, ("shield", body.endswith("(shielded)")), move=mid))
                before_hit = hp[other[s], dfn]
                look(s, att)[1].add(mid)
                note(t, s, "charged", att, mv, {
                    "shielded": body.endswith("(shielded)"), "damage": 1 if blocked else full, "full_damage": full,
                    "disguise": body.endswith("(disguise)"), "target": dfn, "target_hp": before_hit,
                    "target_shields": shields[other[s]], "target_form": "disguised" if body.endswith("(disguise)") else "",
                    "attacker_hp": hp[s, att], "type": mv.type})
                last_charged = t
                thrown[s, att] += 1
                taken[other[s], dfn] += 1
                history[s][0] = body.endswith("(shielded)")
                if shields[other[s]] > 0:
                    history[other[s]][1] = body.endswith("(shielded)")
                hp[other[s], dfn] = max(floor(other[s], dfn),
                                        hp[other[s], dfn] - (1 if blocked else hit(other[s], dfn, raw)))
                if body.endswith("(disguise)"):
                    busted.add((other[s], dfn))
                    stages[other[s], dfn][1] = _stage(stages[other[s], dfn][1] - 1)
                if mv.buff_chance >= 1.0:
                    stages[s, att][0] = _stage(stages[s, att][0] + mv.buff_self[0])
                    stages[s, att][1] = _stage(stages[s, att][1] + mv.buff_self[1])
                    stages[other[s], dfn][0] = _stage(stages[other[s], dfn][0] + mv.buff_opponent[0])
                    stages[other[s], dfn][1] = _stage(stages[other[s], dfn][1] + mv.buff_opponent[1])
        # Faints, then who's in at the end of the turn.
        for s in ("you", "them"):
            if "faint" in acts[s]:
                if (s, active[s]) in hp:
                    hp[s, active[s]] = 0
                    fainted.add((s, active[s]))
                    battle.dealt_at_faint.setdefault((s, active[s]), dealt[s, active[s]])
                note(t, s, "faint", active[s])
                pending[s] = True
            # Who's in, as the export shows it. On a turn with a switch recorded, the column can
            # still show the one that left, so the switch is trusted over it.
            new = "" if s in switched_now else row[f"{s}_active"]
            if new and new != active[s] and not pending[s]:   # a change of who's in, with no switch recorded
                if (t, s, active[s]) in faint_at:
                    missed_faint(t, s, active[s])
                else:
                    last_switch[s] = t
                    battle.exits[s, active[s]] = t
            if new and new != active[s]:   # a replacement the export shows only as who's in now
                if pending[s] and s == "you":
                    battle.decisions.append(Decision("replace", t, ("replace", new), fainted=active[s]))
                elif pending[s]:   # chosen with the fainted one still in: the state at the next turn's start
                    battle.replaces.append(ReplaceCase(t + 1, active[s], new))
                entered[s] = t
                note(t, s, "enter", new, info={"switch": not pending[s]})
                look(s, new)
                pending[s] = False
            if new:
                active[s] = new
            shields[s] = int(row[f"{s}_shields"] or shields[s])
        battle.path[t] = State(active["you"], active["them"], shields["you"], shields["them"],
                               share("you"), share("them"))
        prev_row = row
    battle.dealt = dict(dealt)
    battle.end_hp = dict(hp)
    battle.end_active = dict(active)
    # A 1-turn fast move that lands the turn you throw isn't a hold: the throw was the decision.
    battle.decisions = sorted((d for d in battle.decisions
                               if not (d.choice[0] == "fast" and d.turn in my_throws | my_switches)),
                              key=lambda d: d.turn)


def battle_at(gd: GameData, rb: RecordedBattle, t: int, energy: int | None = None, active: str | None = None,
              free: str = "you") -> Battle:
    """The rebuilt real battle at the start of turn t, you as side 0. The `free` side ("you" or
    "them") is free to act and the other is as the recording had it; `energy` sets the free side's
    active Pokémon's energy, and `active` who you have in (a fainted one, for a replacement)."""
    snap = rb.snapshots[t]
    sides = []
    for s, spec in (("you", rb.you), ("them", rb.them)):
        mons = []
        for sid, fast, charged in spec:
            m = Mon.build(gd, sid, fast, charged)
            hp, en, (atk, df), busted, thrown, taken = snap["mons"][s][sid]
            if busted:
                m.set_form("busted")
            m.hp, m.energy, m.atk_stage, m.def_stage = hp, en, atk, df
            m.thrown, m.taken = thrown, taken
            mons.append(m)
        side = Side(mons, snap["shields"][s])
        ids = [sid for sid, _, _ in spec]
        who = active if s == "you" and active else snap["active"][s]
        side.active = ids.index(who) if who in ids else 0
        side.switch_timer = snap["timer"][s]
        side.busy_until, side.fast_due = (t, -1) if s == free else snap["busy"][s]
        side.last_shielded, side.shielded_last = snap["history"][s]
        side.entered = snap.get("entered", {}).get(s, 0)
        sides.append(side)
    if energy is not None and energy >= 0:
        sides[0 if free == "you" else 1].mon.energy = energy
    seen = [{sid: {"fast": gd.moves[f] if f else None, "charged": set(cs)} for sid, (f, cs) in snap["seen"][s].items()}
            for s in ("you", "them")]
    return Battle.from_sides(sides, t, t, seen, last_charged=snap["last_charged"])


def _last_in(turns: list[dict]) -> dict:
    """(side, species) -> the last turn the export shows it in, or switching in."""
    out = {}
    for row in turns:
        t = int(row["turn"])
        for s in ("you", "them"):
            names = [row.get(f"{s}_active", "")] + [a[len("switch:"):].split("(")[0]
                                                    for a in row.get(f"{s}_action", "").split(";") if a.startswith("switch:")]
            for sid in names:
                if sid:
                    out[s, sid] = max(out.get((s, sid), -1), t)
    return out


def _loser(rb: RecordedBattle) -> str | None:
    return {"lost": "you", "won": "them"}.get(rb.result)


def loser_faints(rb: RecordedBattle) -> frozenset:
    """(turn, side, species) for the loser's Pokémon still alive in the back when the recording
    ends: each fainted when it last left the field."""
    s = _loser(rb)
    if s is None:
        return frozenset()
    return frozenset((rb.exits[s, sid], s, sid) for (side, sid), hp in rb.end_hp.items()
                     if side == s and hp > 0 and sid != rb.end_active.get(s) and (s, sid) in rb.exits)


def anchor_scale(gd: GameData, rb: RecordedBattle) -> dict:
    """Per (side, species), the factor that makes its rebuilt HP reach 0 on the turn it fainted.
    The loser's Pokémon still in when the recording ends fainted then."""
    out = {}
    loser = _loser(rb)
    for key, total in rb.dealt.items():
        hp = gd.species[key[1]].hp
        at = rb.dealt_at_faint.get(key)
        if at is None and key[0] == loser and rb.end_active.get(loser) == key[1]:
            at = total
        if at is not None:
            out[key] = min(2.0, max(0.5, hp / max(at, 1)))
        elif total >= hp:   # still in at the end, though its hits add up to its HP
            out[key] = max(0.5, 0.9 * hp / total)
    return out


def fits_result(rb: RecordedBattle) -> bool:
    """The loser's three fainted (the one still in at the end counts) and the winner's didn't."""
    loser = _loser(rb)
    if loser is None:
        return False
    winner = "them" if loser == "you" else "you"
    down = {side: {sid for (t, s_, sid) in [(e.turn, e.side, e.species) for evs in rb.events.values() for e in evs
                                               if e.kind == "faint"] if s_ == (0 if side == "you" else 1)}
            for side in ("you", "them")}
    down[loser].add(rb.end_active.get(loser))
    return len(down[loser]) == 3 and len(down[winner]) < 3


def partner(battle_id: str) -> str | None:
    """The same battle seen from the other phone, for a stream export where both players' phones
    were read: `<game>-L#n` and `<game>-R#n`. None for an ordinary recording."""
    rec, _, n = battle_id.rpartition("#")
    for a, b in (("-L", "-R"), ("-R", "-L")):
        if rec.endswith(a):
            return f"{rec[:-2]}{b}#{n}"
    return None


def fill_paired_results(rows: list[dict]) -> None:
    """Where one phone's view missed the results screen, the other's tells it (flipped)."""
    by_id = {r["battle_id"]: r for r in rows}
    flip = {"won": "lost", "lost": "won", "draw": "draw"}
    for r in rows:
        other = by_id.get(partner(r["battle_id"]) or "")
        if not r["result"] and other and other["result"] in flip:
            r["result"] = flip[other["result"]]


def load(gd: GameData, folder: Path) -> list[RecordedBattle]:
    with (folder / "battles.csv").open() as f:
        rows = list(csv.DictReader(f))
    fill_paired_results(rows)
    turns: dict[str, list[dict]] = defaultdict(list)
    with (folder / "turns.csv").open() as f:
        for t in csv.DictReader(f):
            turns[t["battle_id"]].append(t)
    # Your full teams, from the battles where all three of yours came in, and each Pokémon's
    # moves as your buttons showed them.
    specs = [_spec(gd, row, "you", True) for row in rows]
    full = Counter(frozenset(s for s, _, _ in you) for you, n in specs if n == 3)
    known = {s: (s, f, cs) for you, _ in specs for s, f, cs in you}
    out = []
    for row, (you, n) in zip(rows, specs):
        them, seen = _spec(gd, row, "them", False)
        b = RecordedBattle(row["battle_id"], row["result"], you, them, seen)
        if n < 3:
            # You didn't bring all three out: the rest of your team that day.
            mine = {s for s, _, _ in you}
            fits = [(c, team) for team, c in full.items() if mine <= team]
            if fits:
                team = max(fits)[1]
                b.you = you + [known[s] for s in sorted(team - mine)]
            else:
                b.misread = True   # not one of your teams: a misread
        if b.you and them:
            # First the faints the export missed, then how much to scale each one's damage.
            rows_ = turns[row["battle_id"]]
            first = RecordedBattle(b.id, b.result, b.you, b.them, b.seen)
            replay(gd, first, rows_)
            faint_at = loser_faints(first)
            second = RecordedBattle(b.id, b.result, b.you, b.them, b.seen)
            replay(gd, second, rows_, faint_at=faint_at)
            replay(gd, b, rows_, anchor_scale(gd, second), faint_at)
            b.complete = fits_result(b)
        out.append(b)
    return out


class ContextOpponent:
    """The planner, except where the battle matches a decision this opponent made: then theirs."""

    def __init__(self, planner, battle: RecordedBattle):
        self.planner, self.battle = planner, battle
        self.faced = defaultdict(int)
        self.last_shielded: dict[str, bool] = {}
        self.copied = {"shield": 0, "throw": 0}
        self.asked = {"shield": 0, "throw": 0}
        self.name = "context"

    def start(self, side: int) -> None:
        self.side = side
        if hasattr(self.planner, "start"):
            self.planner.start(side)

    def observe(self, events) -> None:
        for e in events:
            if e.kind == "charged" and e.side != self.side:
                self.faced[e.info["target"]] += 1
            elif e.kind == "charged" and e.side == self.side:
                self.last_shielded[e.species] = e.info["shielded"]
        if hasattr(self.planner, "observe"):
            self.planner.observe(events)

    def before_turn(self, view: View) -> None:
        if hasattr(self.planner, "before_turn"):
            self.planner.before_turn(view)

    def shield(self, view: View, move: Move) -> bool:
        mon = view.mon
        if view.me.shields == 0 or mon.form == "disguised":
            return False
        self.asked["shield"] += 1
        hit = damage(move, view.foe_species, mon.species, view.foe_stages[0], mon.def_stage)
        share, lethal = mon.hp / mon.max_hp, hit >= mon.hp
        fits = [c for c in self.battle.shields
                if c.defender == mon.species.id and c.attacker == view.foe_species.id and c.move == move.id
                and c.shields == (view.me.shields, view.foe_shields) and c.faced == self.faced[mon.species.id]
                and c.lethal == lethal and abs(c.hp - share) <= HP_TOLERANCE]
        if not fits:
            return self.planner.shield(view, move)
        self.copied["shield"] += 1
        return min(fits, key=lambda c: abs(c.hp - share)).shielded

    def act(self, view: View) -> tuple[str, int]:
        mon = view.mon
        if not mon.charged or mon.energy < min(c.energy for c in mon.charged):
            return self.planner.act(view)
        self.asked["throw"] += 1
        hp = (mon.hp / mon.max_hp, view.foe_hp / view.foe_species.hp)
        fits = [c for c in self.battle.throws
                if c.active == mon.species.id and c.target == view.foe_species.id
                and c.shields == (view.me.shields, view.foe_shields)
                and c.last_shielded == self.last_shielded.get(mon.species.id)
                and abs(c.energy - mon.energy) <= ENERGY_TOLERANCE
                and all(abs(a - b) <= HP_TOLERANCE for a, b in zip(c.hp, hp))]
        if not fits:
            return self.planner.act(view)
        case = min(fits, key=lambda c: (abs(c.energy - mon.energy), sum(abs(a - b) for a, b in zip(c.hp, hp))))
        if case.choice:
            idx = next((k for k, c in enumerate(mon.charged) if mon.base_move(c).id == case.choice), None)
            if idx is None or mon.energy < mon.charged[idx].energy:
                return self.planner.act(view)
            self.copied["throw"] += 1
            return CHARGED(idx)
        self.copied["throw"] += 1
        return FAST

    def replace(self, view: View) -> int:
        return self.planner.replace(view)
