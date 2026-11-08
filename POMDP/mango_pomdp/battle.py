"""A 3v3 Great League battle in 0.5s turns, following PvPoke's Battle.js and its guide to fast
move registration (pvpoke.com/articles/strategy/guide-to-fast-move-registration).

Each turn:
  1. Every side whose Pokémon isn't mid fast move picks an action: a fast move, a charged move
     it has the energy for, or a switch (once its 45s switch timer has run out).
  2. Switches happen first. The incoming Pokémon takes any fast move that lands this turn.
  3. Fast moves register on their last turn (duration − 1 turns after they're used): damage to
     the opponent, energy to the user. A 1-turn move registers the turn it's used.
  4. Charged moves resolve in CMP order (higher attack first). A charged move interrupts every
     fast move in progress: each registers on the spot, including one the opponent starts this
     same turn (the sneak ManGo counts). Then every cooldown resets, so both Pokémon act again
     next turn; interrupting a long fast move early grants its user "free" turns, and throwing on
     the turn it registers grants none. A charged move fails if a fast move registering that turn
     knocks out its user, and a Pokémon knocked out by the first charged move doesn't throw its own.
  5. Faints: both sides stop attacking, the fainted side picks a replacement (no switch timer).

The battle clock (4 minutes) stops during charged moves. At time-out the side with more Pokémon
left wins, then the one with more HP left.

Controllers decide for each side and only get a `View`: their own team in full, and of the
opponent only what the screen shows (active Pokémon, HP, shields, moves seen so far, Pokémon left).
Energy is never in a view; `belief.EnergyCounter` counts it the way ManGo does.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Protocol

from .gamedata import MAX_ENERGY, MAX_STAGE, Move, Species, damage, stage_multiplier

TIME_LIMIT_TURNS = 480     # 4 minutes
SWITCH_TURNS = 90          # 45 seconds (PvPoke Player.switchTime)
SHIELDS = 2

FAST = ("fast", 0)


def CHARGED(i: int) -> tuple[str, int]:
    return ("charged", i)


def SWITCH(i: int) -> tuple[str, int]:
    return ("switch", i)


class Mon:
    __slots__ = ("species", "fast", "charged", "hp", "energy", "atk_stage", "def_stage")

    def __init__(self, species: Species, fast: Move, charged: tuple[Move, ...], hp: int | None = None, energy: int = 0):
        self.species = species
        self.fast = fast
        self.charged = charged
        self.hp = species.hp if hp is None else hp
        self.energy = energy
        self.atk_stage = 0
        self.def_stage = 0

    @property
    def max_hp(self) -> int:
        return self.species.hp

    def clone(self) -> Mon:
        m = Mon.__new__(Mon)
        m.species, m.fast, m.charged = self.species, self.fast, self.charged
        m.hp, m.energy, m.atk_stage, m.def_stage = self.hp, self.energy, self.atk_stage, self.def_stage
        return m

    def __repr__(self) -> str:
        return f"{self.species.name}({self.hp}/{self.max_hp} hp, {self.energy} energy)"


class Side:
    __slots__ = ("mons", "active", "shields", "switch_timer", "busy_until", "fast_due", "entered")

    def __init__(self, mons: list[Mon], shields: int = SHIELDS):
        self.mons = mons
        self.active = 0
        self.shields = shields
        self.switch_timer = 0
        self.busy_until = 0   # first turn this side can act again
        self.fast_due = -1    # turn its fast move in progress lands, or -1
        self.entered = 0      # turn the active Pokémon came in

    @property
    def mon(self) -> Mon:
        return self.mons[self.active]

    def remaining(self) -> int:
        return sum(m.hp > 0 for m in self.mons)

    def bench(self) -> list[int]:
        return [i for i, m in enumerate(self.mons) if i != self.active and m.hp > 0]

    def clone(self) -> Side:
        s = Side.__new__(Side)
        s.mons = [m.clone() for m in self.mons]
        s.active, s.shields, s.switch_timer = self.active, self.shields, self.switch_timer
        s.busy_until, s.fast_due, s.entered = self.busy_until, self.fast_due, self.entered
        return s


@dataclass(slots=True)
class Event:
    """Something both players see happen. Never carries energy."""
    turn: int
    side: int
    kind: str                  # enter, fast, charged, faint
    species: str
    move: Move | None = None
    info: dict = field(default_factory=dict)


class Controller(Protocol):
    def act(self, view: View) -> tuple[str, int]: ...
    def shield(self, view: View, move: Move) -> bool: ...
    def replace(self, view: View) -> int: ...


class Battle:
    __slots__ = ("sides", "turn", "clock", "done", "winner", "rng", "seen", "log")

    def __init__(self, teams: list[list[Mon]], seed: int | None = None, shields: int = SHIELDS, log: bool = True):
        self.sides = [Side(teams[0], shields), Side(teams[1], shields)]
        self.turn = 0
        self.clock = 0
        self.done = False
        self.winner: int | None = None   # 0, 1, or -1 for a tie
        self.rng = random.Random(seed)
        # Public knowledge: per side, species id -> moves seen so far ({"fast": Move|None, "charged": set}).
        self.seen: list[dict[str, dict]] = [{}, {}]
        self.log: list[Event] | None = [] if log else None
        for s in (0, 1):
            self._reveal(s, self.sides[s].mon.species.id)
            self._event(s, "enter", self.sides[s].mon.species.id, info={"lead": True})

    # Copies -------------------------------------------------------------------------------

    def clone(self, seed: int | None = None) -> Battle:
        b = Battle.__new__(Battle)
        b.sides = [self.sides[0].clone(), self.sides[1].clone()]
        b.turn, b.clock, b.done, b.winner = self.turn, self.clock, self.done, self.winner
        b.rng = random.Random(seed)
        b.seen = [{k: {"fast": v["fast"], "charged": set(v["charged"])} for k, v in d.items()} for d in self.seen]
        b.log = None
        return b

    @classmethod
    def from_sides(cls, sides: list[Side], turn: int, clock: int,
                   seen: list[dict[str, dict]], seed: int | None = None) -> Battle:
        b = Battle.__new__(Battle)
        b.sides = sides
        b.turn, b.clock, b.done, b.winner = turn, clock, False, None
        b.rng = random.Random(seed)
        b.seen = seen
        b.log = None
        return b

    def view(self, side: int) -> View:
        return View(self, side)

    def reward(self, side: int) -> int:
        if self.winner is None or self.winner == -1:
            return 0
        return 1 if self.winner == side else -1

    # Running ------------------------------------------------------------------------------

    def play(self, controllers: list[Controller], observers: list | None = None, max_turns: int = 10_000) -> int | None:
        while not self.done and max_turns > 0:
            start = len(self.log) if self.log is not None else 0
            self.step(controllers)
            if observers and self.log is not None:
                new = self.log[start:]
                for o in observers:
                    o.observe(new)
            max_turns -= 1
        return self.winner

    def step(self, controllers: list[Controller]) -> None:
        if self.done:
            return
        t = self.turn
        queued: list[tuple[int, int]] = []
        for s in (0, 1):
            side = self.sides[s]
            if side.busy_until > t:
                continue
            kind, arg = controllers[s].act(View(self, s))
            if kind == "switch" and side.switch_timer == 0 and arg in side.bench():
                self._switch_in(s, arg, timer=True)
            elif kind == "charged" and 0 <= arg < len(side.mon.charged) and side.mon.energy >= side.mon.charged[arg].energy:
                queued.append((s, arg))
            else:
                side.fast_due = t + side.mon.fast.turns - 1
                side.busy_until = t + side.mon.fast.turns

        for s in (0, 1):
            if self.sides[s].fast_due == t:
                self._land_fast(s)

        if len(queued) == 2:
            a0, a1 = (self._attack_stat(s) for s in (0, 1))
            if a1 > a0 or (a1 == a0 and self.rng.random() < 0.5):
                queued.reverse()
        charged_used = False
        for s, i in queued:
            mon = self.sides[s].mon
            if mon.hp <= 0 or self.sides[1 - s].mon.hp <= 0:
                continue
            charged_used |= self.land_charged(s, mon.charged[i], controllers)

        self.handle_faints(controllers)
        self.end_turn(charged_used)

    # Pieces of a turn, public so a planner can evaluate one decision mid-turn ---------------

    def land_charged(self, s: int, move: Move, controllers: list[Controller], shield: bool | None = None) -> bool:
        """Throws `move` for side s. `shield` forces the defender's choice instead of asking it."""
        t = self.turn
        for x in (0, 1):
            if self.sides[x].fast_due > t:
                self._land_fast(x)
        side, foe = self.sides[s], self.sides[1 - s]
        mon, target = side.mon, foe.mon
        if mon.hp <= 0 or target.hp <= 0 or mon.energy < move.energy:
            return False
        mon.energy -= move.energy
        full = damage(move, mon.species, target.species, mon.atk_stage, target.def_stage)
        shields_before, hp_before = foe.shields, target.hp
        if foe.shields > 0:
            if shield is None:
                shield = bool(controllers[1 - s].shield(View(self, 1 - s), move))
        else:
            shield = False
        if shield:
            foe.shields -= 1
        target.hp = max(0, target.hp - (1 if shield else full))
        if move.buff_chance and self.rng.random() < move.buff_chance:
            mon.atk_stage = _clamp(mon.atk_stage + move.buff_self[0])
            mon.def_stage = _clamp(mon.def_stage + move.buff_self[1])
            target.atk_stage = _clamp(target.atk_stage + move.buff_opponent[0])
            target.def_stage = _clamp(target.def_stage + move.buff_opponent[1])
        self.seen[s][mon.species.id]["charged"].add(move.id)
        for x in self.sides:   # every cooldown resets: both act again next turn
            x.busy_until = t + 1
            x.fast_due = -1
        self._event(s, "charged", mon.species.id, move, {
            "shielded": shield, "damage": 1 if shield else full, "full_damage": full,
            "target": target.species.id, "target_hp": hp_before, "target_shields": shields_before,
            "attacker_hp": mon.hp})
        return True

    def handle_faints(self, controllers: list[Controller]) -> None:
        fainted = [s for s in (0, 1) if self.sides[s].mon.hp <= 0]
        if not fainted:
            return
        for s in fainted:
            self._event(s, "faint", self.sides[s].mon.species.id)
        left = [self.sides[s].remaining() for s in (0, 1)]
        if 0 in left:
            self.done = True
            self.winner = -1 if left == [0, 0] else (0 if left[1] == 0 else 1)
            return
        for side in self.sides:
            side.fast_due = -1
            side.busy_until = self.turn + 1
        for s in fainted:
            bench = self.sides[s].bench()
            pick = controllers[s].replace(View(self, s))
            self._switch_in(s, pick if pick in bench else bench[0], timer=False)

    def end_turn(self, charged_used: bool) -> None:
        if not charged_used:
            self.clock += 1
        for side in self.sides:
            if side.switch_timer > 0:
                side.switch_timer -= 1
        self.turn += 1
        if not self.done and self.clock >= TIME_LIMIT_TURNS:
            self.done = True
            score = [(side.remaining(), sum(m.hp / m.max_hp for m in side.mons)) for side in self.sides]
            self.winner = -1 if score[0] == score[1] else (0 if score[0] > score[1] else 1)

    def switch_in(self, s: int, i: int, timer: bool) -> None:
        self._switch_in(s, i, timer)

    # Internals ------------------------------------------------------------------------------

    def _attack_stat(self, s: int) -> float:
        mon = self.sides[s].mon
        return mon.species.atk * stage_multiplier(mon.atk_stage)

    def _land_fast(self, s: int) -> None:
        side, foe = self.sides[s], self.sides[1 - s]
        started = side.busy_until - side.mon.fast.turns
        side.fast_due = -1
        mon, target = side.mon, foe.mon
        if target.hp <= 0:
            return
        dmg = damage(mon.fast, mon.species, target.species, mon.atk_stage, target.def_stage)
        target.hp = max(0, target.hp - dmg)
        mon.energy = min(MAX_ENERGY, mon.energy + mon.fast.energy_gain)
        self.seen[s][mon.species.id]["fast"] = mon.fast
        self._event(s, "fast", mon.species.id, mon.fast, {
            "damage": dmg, "target": target.species.id, "target_hp": target.hp + dmg,
            "target_shields": foe.shields, "started": started})

    def _switch_in(self, s: int, i: int, timer: bool) -> None:
        side = self.sides[s]
        out = side.mon
        out.atk_stage = out.def_stage = 0
        side.active = i
        side.entered = self.turn
        side.busy_until = self.turn + 1
        side.fast_due = -1
        if timer:
            side.switch_timer = SWITCH_TURNS
        self._reveal(s, side.mon.species.id)
        self._event(s, "enter", side.mon.species.id, info={"switch": timer})

    def _reveal(self, s: int, species_id: str) -> None:
        self.seen[s].setdefault(species_id, {"fast": None, "charged": set()})

    def _event(self, s: int, kind: str, species: str, move: Move | None = None, info: dict | None = None) -> None:
        if self.log is not None:
            self.log.append(Event(self.turn, s, kind, species, move, info or {}))


def _clamp(stage: int) -> int:
    return max(-MAX_STAGE, min(MAX_STAGE, stage))


class View:
    """What one player sees. The opponent's energy, bench and unseen moves aren't here."""
    __slots__ = ("_b", "side")

    def __init__(self, battle: Battle, side: int):
        self._b = battle
        self.side = side

    # Yours, in full.
    @property
    def me(self) -> Side:
        return self._b.sides[self.side]

    @property
    def mon(self) -> Mon:
        return self._b.sides[self.side].mon

    @property
    def can_switch(self) -> bool:
        me = self.me
        return me.switch_timer == 0 and bool(me.bench())

    def legal_actions(self) -> list[tuple[str, int]]:
        me = self.me
        acts = [FAST] + [CHARGED(i) for i, c in enumerate(me.mon.charged) if me.mon.energy >= c.energy]
        if me.switch_timer == 0:
            acts += [SWITCH(i) for i in me.bench()]
        return acts

    # The battle, as the screen shows it.
    @property
    def turn(self) -> int:
        return self._b.turn

    @property
    def clock(self) -> int:
        return self._b.clock

    @property
    def foe_species(self) -> Species:
        return self._b.sides[1 - self.side].mon.species

    @property
    def foe_hp(self) -> int:
        return self._b.sides[1 - self.side].mon.hp

    @property
    def foe_stages(self) -> tuple[int, int]:
        m = self._b.sides[1 - self.side].mon
        return m.atk_stage, m.def_stage

    @property
    def foe_shields(self) -> int:
        return self._b.sides[1 - self.side].shields

    @property
    def foe_remaining(self) -> int:
        return self._b.sides[1 - self.side].remaining()

    @property
    def foe_entered(self) -> int:
        return self._b.sides[1 - self.side].entered

    @property
    def foe_timer(self) -> tuple[int, int]:
        """(turns until they can act, turns until their fast move lands or −1), as of the start of this
        turn: you see their fast move animation start, but not a choice they make this same turn."""
        foe, t = self._b.sides[1 - self.side], self._b.turn
        if foe.busy_until == t + foe.mon.fast.turns and foe.fast_due == foe.busy_until - 1:
            return 0, -1   # started this turn
        return max(0, foe.busy_until - t), (foe.fast_due - t if foe.fast_due >= t else -1)

    def foe_seen(self) -> dict[str, dict]:
        """Species id -> {"fast": Move or None, "charged": set of move ids} for every opponent seen."""
        return self._b.seen[1 - self.side]

    def foe_hp_of(self, species_id: str) -> int | None:
        """HP of an opponent Pokémon you've seen (the game shows it when it's out; you remember it after)."""
        for m in self._b.sides[1 - self.side].mons:
            if m.species.id == species_id:
                return m.hp
        return None

    def seen_copy(self) -> list[dict[str, dict]]:
        return [{k: {"fast": v["fast"], "charged": set(v["charged"])} for k, v in d.items()} for d in self._b.seen]
