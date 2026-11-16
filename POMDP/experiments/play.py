"""Play a 3v3 battle against the planner in the terminal.

    cd POMDP
    python3 -m experiments.play                          # PvPoke's #25 against a random top team
    python3 -m experiments.play --you M1 --them F3       # your first team vs a team you faced
    python3 -m experiments.play --you 25 --them 12 --opponent baiter --hints

Teams are labels from experiments.top_teams: #25 (PvPoke's top teams by CSV row), M1… (yours),
F1… (ones you faced). You lead with the first Pokémon listed. The opponent is the planner
(`planner-list`, which knows PvPoke's top teams) or a heuristic style.

On every turn your Pokémon is free, pick an action:
  Enter    fast move once            a     fast move until something changes
  1, 2     throw that charged move   s1    switch to bench Pokémon 1 (s2: the other)
  w        wait a turn               h     ask the planner what it would do (with --hints)
  q        quit
When they throw at you and you have a shield, you're asked whether to use it. You see what the
screen shows, plus their energy counted from their moves, the way ManGo counts it.
"""
from __future__ import annotations

import argparse
import random

from mango_pomdp import gamedata
from mango_pomdp.battle import CHARGED, FAST, SWITCH, TIME_LIMIT_TURNS, WAIT, View
from mango_pomdp.belief import EnergyCounter
from mango_pomdp.gamedata import damage
from mango_pomdp.match import make_player, play
from mango_pomdp.policies import STYLES
from mango_pomdp.team_prior import TeamPrior
from mango_pomdp.timeline import render
from experiments.top_teams import FORMAT, label, team_index


class Quit(Exception):
    pass


class Human:
    """You, at the keyboard. Sees only what a View gives (and counts their energy)."""

    def __init__(self, gd, ask=input, say=print, advisor=None):
        self.gd, self.ask, self.say, self.advisor = gd, ask, say, advisor
        self.counter = EnergyCounter()
        self.auto = False
        self.pending: list = []
        self.name = "you"

    # Match hooks ------------------------------------------------------------------------------

    def start(self, side: int) -> None:
        self.side = side
        if self.advisor:
            self.advisor.start(side)

    def observe(self, events) -> None:
        for e in events:
            if e.side != self.side:
                self.counter.observe(e)
            self.pending.append(e)
            if e.kind in ("charged", "faint", "enter") and e.turn > 0:
                self.auto = False   # something happened: stop auto fast moving
        if self.advisor:
            self.advisor.observe(events)

    # Showing the battle -----------------------------------------------------------------------

    def _name(self, sid: str) -> str:
        return self.gd.species[sid].name

    def _news(self) -> None:
        lines, fast = [], {}
        for e in self.pending:
            who = "You" if e.side == self.side else "They"
            if e.kind == "fast":
                fast[e.side, e.species, e.move.name] = fast.get((e.side, e.species, e.move.name), 0) + 1
                continue
            for (s, sid, mv), n in fast.items():
                lines.append(f"  {'You' if s == self.side else 'They'}: {self._name(sid)} {mv} ×{n}")
            fast = {}
            if e.kind == "enter" and e.turn > 0:
                lines.append(f"  {who}: {self._name(e.species)} comes in" + (" (switch)" if e.info.get("switch") else ""))
            elif e.kind == "charged":
                how = "shielded" if e.info["shielded"] else ("blocked by Disguise" if e.info["disguise"]
                                                              else f"{e.info['damage']} damage")
                lines.append(f"  {who}: {self._name(e.species)} used {e.move.name}: {how}")
            elif e.kind == "gulp":
                lines.append(f"  {who}: Cramorant's Gulp Missile, {e.info['damage']} damage")
            elif e.kind == "faint":
                lines.append(f"  {who}: {self._name(e.species)} fainted")
        for (s, sid, mv), n in fast.items():
            lines.append(f"  {'You' if s == self.side else 'They'}: {self._name(sid)} {mv} ×{n}")
        self.pending = []
        if lines:
            self.say("\n".join(lines))

    def _board(self, view: View) -> None:
        me, mon = view.me, view.mon
        left = max(0, TIME_LIMIT_TURNS - view.clock) / 2
        timer = "ready" if me.switch_timer == 0 else f"{me.switch_timer / 2:.0f}s"
        moves = "  ".join(f"[{i + 1}] {c.name} {c.energy}{' ✓' if mon.energy >= c.energy else ''}"
                          for i, c in enumerate(mon.charged))
        bench = ", ".join(f"[s{k + 1}] {m.species.name} {m.hp}/{m.max_hp}"
                          for k, m in enumerate(me.mons[i] for i in me.bench()))
        foe = view.foe_species
        seen = view.foe_seen().get(foe.id, {})
        shown = ", ".join(filter(None, [seen.get("fast") and seen["fast"].name] +
                                 [self.gd.moves[c].name for c in sorted(seen.get("charged", ()))]))
        self.say(f"\nturn {view.turn}   {left:.0f}s left   switch {timer}\n"
                 f"  YOU   {mon.species.name:<20} HP {mon.hp:>3}/{mon.max_hp:<3}  energy {mon.energy:>3}  "
                 f"shields {'●' * me.shields}{'○' * (2 - me.shields)}\n"
                 f"        {moves}\n"
                 f"        bench: {bench or 'none'}\n"
                 f"  THEM  {foe.name:<20} HP {view.foe_hp:>3}/{foe.hp:<3}  energy ~{self.counter.energy.get(foe.id, 0):>2}  "
                 f"shields {'●' * view.foe_shields}{'○' * (2 - view.foe_shields)}  ({view.foe_remaining} left)\n"
                 f"        seen: {shown or 'nothing yet'}")

    # Decisions --------------------------------------------------------------------------------

    def act(self, view: View):
        if self.auto and view.mon.energy < min((c.energy for c in view.mon.charged), default=101):
            return FAST
        if self.auto and getattr(self, "_auto_energy", None) is not None:
            # Keep going until a charged move becomes affordable that wasn't when "a" was pressed.
            if not any(self._auto_energy < c.energy <= view.mon.energy for c in view.mon.charged):
                self._auto_energy = view.mon.energy
                return FAST
        self.auto = False
        self._news()
        self._board(view)
        legal = view.legal_actions()
        bench = view.me.bench()
        while True:
            cmd = self.ask("> ").strip().lower()
            if cmd == "":
                return FAST
            if cmd == "a":
                self.auto, self._auto_energy = True, view.mon.energy
                return FAST
            if cmd == "q":
                raise Quit
            if cmd == "w":
                return WAIT
            if cmd in ("1", "2") and CHARGED(int(cmd) - 1) in legal:
                return CHARGED(int(cmd) - 1)
            if cmd in ("s1", "s2") and len(bench) >= int(cmd[1]) and SWITCH(bench[int(cmd[1]) - 1]) in legal:
                return SWITCH(bench[int(cmd[1]) - 1])
            if cmd == "h" and self.advisor:
                a = self.advisor.act(view)
                self.say(f"  The planner would {self._describe(view, a)}.")
                continue
            self.say("  Enter fast, a auto, 1/2 charged, s1/s2 switch, w wait" + (", h hint" if self.advisor else "")
                     + ", q quit" + ("  (that move isn't affordable, or the switch timer isn't ready)"
                                     if cmd in ("1", "2", "s1", "s2") else ""))

    def _describe(self, view, a) -> str:
        kind, arg = a
        if kind == "charged":
            return f"throw {view.mon.charged[arg].name}"
        if kind == "switch":
            return f"switch to {view.me.mons[arg].species.name}"
        return {"fast": "fast move", "wait": "wait"}[kind]

    def shield(self, view: View, move) -> bool:
        self._news()
        mon = view.mon
        if mon.form == "disguised":
            self.say(f"  They throw {move.name}: Mimikyu's Disguise takes it.")
            return False
        hit = damage(move, view.foe_species, mon.species, view.foe_stages[0], mon.def_stage)
        note = " (that would knock you out)" if hit >= mon.hp else ""
        hint = ""
        if self.advisor:
            hint = f"  [the planner would {'shield' if self.advisor.shield(view, move) else 'take it'}]"
        ans = self.ask(f"  They throw {move.name}: {hit} damage to your {mon.species.name} at {mon.hp} HP{note}. "
                       f"Shield ({view.me.shields} left)? [y/N]{hint} ").strip().lower()
        if ans == "q":
            raise Quit
        return ans.startswith("y")

    def replace(self, view: View) -> int:
        self._news()
        bench = view.me.bench()
        if len(bench) == 1:
            return bench[0]
        options = "  ".join(f"[{k + 1}] {view.me.mons[i].species.name} {view.me.mons[i].hp}/{view.me.mons[i].max_hp}"
                            for k, i in enumerate(bench))
        while True:
            ans = self.ask(f"  Your {view.mon.species.name} fainted. Bring in: {options} > ").strip().lower()
            if ans == "q":
                raise Quit
            if ans in [str(k + 1) for k in range(len(bench))]:
                return bench[int(ans) - 1]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--you", default="25", help="your team: #25, M1, F3 (default PvPoke's #25)")
    ap.add_argument("--them", default=None, help="their team (default: a random PvPoke top team)")
    ap.add_argument("--lead", type=int, default=1, choices=(1, 2, 3), help="which of yours leads")
    ap.add_argument("--opponent", default="planner-list", choices=("planner-list", "planner", *STYLES))
    ap.add_argument("--hints", action="store_true", help="let h ask the planner for advice")
    ap.add_argument("--rollouts", type=int, default=12)
    ap.add_argument("--seed", type=int, default=None)
    args = ap.parse_args()
    gd = gamedata.use(FORMAT)
    rng = random.Random(args.seed)
    mine = team_index(gd, args.you)
    theirs = team_index(gd, args.them) if args.them else rng.choice([k for k in gd.team_pool("pvpoke") if k != mine])
    ours = list(gd.teams[mine].spec)
    ours = [ours[args.lead - 1]] + ours[:args.lead - 1] + ours[args.lead:]
    pvpoke = [gd.teams[k] for k in gd.team_pool("pvpoke")]
    prior = TeamPrior(gd)
    foe = make_player(args.opponent, gd, prior, rng.randrange(1 << 30), rollouts=args.rollouts,
                      teams=[t for k, t in enumerate(gd.teams) if t.source == "pvpoke" and k != theirs])
    advisor = make_player("planner-list", gd, prior, rng.randrange(1 << 30), rollouts=args.rollouts,
                          teams=pvpoke) if args.hints else None
    you = Human(gd, advisor=advisor)
    names = ("You", "Them")
    print(f"You: {' / '.join(gd.species[s].name for s, _, _ in ours)}  ({label(gd, mine)})")
    print(f"Against {args.opponent}, who leads {gd.species[gd.teams[theirs].species[0]].name}. "
          f"Their team ({label(gd, theirs)}) is hidden until it comes in.")
    try:
        battle = play(gd, [ours, list(gd.teams[theirs].spec)], [you, foe], seed=rng.randrange(1 << 30))
    except Quit:
        print("\nQuit.")
        return
    except EOFError:
        print("\nNo more input.")
        return
    you._news()
    result = {0: "You win!", 1: "You lose.", -1: "A tie."}[battle.winner]
    print(f"\n{result}  Their team was {' / '.join(gd.species[s].name for s in gd.teams[theirs].species)}.\n")
    print(render(battle, names))


if __name__ == "__main__":
    main()
