"""Opponent models and baseline players.

The proposal models the opponent's policy as a distribution over styles. Each style here is
a small stochastic policy over two decisions the belief can see the opponent make:

  throw:  with this much energy, against that target, fast move or which charged move?
  shield: this charged move is coming in; shield it?

Each style picks its preferred choice with probability 1 − ε and anything legal otherwise,
so `throw_probs` and `shield_prob` double as likelihoods for the belief update.

  shielder  shields everything while it has shields; throws its cheapest move as soon as it can
  baiter    baits with the cheap move while you have shields, then nukes; shields big hits only
  nuker     saves for its hardest-hitting move; shields only what would knock it out
  casual    throws whatever it has as soon as it can; shields half the time

Switching and replacements use a type-matchup estimate and aren't part of the likelihood.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass

from .battle import CHARGED, FAST, SWITCH, Mon, View
from .gamedata import Move, Species, damage, load

STYLES = ("shielder", "baiter", "nuker", "casual")


@dataclass(slots=True)
class ThrowContext:
    species: Species
    charged: tuple[Move, ...]
    energy: int
    atk_stage: int
    target: Species
    target_hp: int
    target_def_stage: int
    target_shields: int


@dataclass(slots=True)
class ShieldContext:
    hp: int
    max_hp: int
    full_damage: int
    shields: int


# Matchups ---------------------------------------------------------------------------------

def turns_to_ko(att: Species, fast: Move, charged: tuple[Move, ...], dfn: Species, hp: int) -> float:
    """Rough turns for `att` to take `hp` off `dfn`: fast move damage plus energy spent on its best move."""
    fdmg = damage(fast, att, dfn) / fast.turns
    ept = fast.energy_gain / fast.turns
    dpe = max((damage(c, att, dfn) / c.energy for c in charged if c.energy), default=0.0)
    return hp / max(fdmg + ept * dpe, 1e-6)


def likely_moves(species_id: str, seen: dict | None) -> tuple[Move, tuple[Move, ...]]:
    """An opponent's moves as a player would guess them: what's been seen, PvPoke's moveset for the rest."""
    gd = load()
    fast, charged = gd.recommended(species_id)
    if seen:
        fast = seen["fast"] or fast
        known = tuple(gd.moves[c] for c in seen["charged"])
        charged = (known + tuple(c for c in charged if c.id not in seen["charged"]))[:2]
    return fast, charged


def matchup(mon: Mon, hp: int, foe: Species, foe_hp: int, foe_seen: dict | None) -> float:
    """log(how long they take to KO you / how long you take to KO them). Positive is good for you."""
    ffast, fcharged = likely_moves(foe.id, foe_seen)
    # Both can be at 0 when both faint on the same turn and the replacements are being picked.
    mine = turns_to_ko(mon.species, mon.fast, mon.charged, foe, max(foe_hp, 1))
    theirs = turns_to_ko(foe, ffast, fcharged, mon.species, max(hp, 1))
    return math.log(theirs / mine)


# Styles -----------------------------------------------------------------------------------

def preferred_throw(style: str, ctx: ThrowContext) -> int | None:
    """Index of the charged move this style throws now, or None to keep fast moving."""
    affordable = [i for i, c in enumerate(ctx.charged) if ctx.energy >= c.energy]
    if not affordable:
        return None
    dmg = [damage(c, ctx.species, ctx.target, ctx.atk_stage, ctx.target_def_stage) for c in ctx.charged]
    cheapest = min(affordable, key=lambda i: (ctx.charged[i].energy, -dmg[i]))
    best = max(range(len(ctx.charged)), key=lambda i: dmg[i])
    kills = [i for i in affordable if dmg[i] >= ctx.target_hp]
    if style == "shielder":
        return cheapest if ctx.target_shields else max(affordable, key=lambda i: dmg[i])
    if style == "baiter":
        if ctx.target_shields:
            return cheapest
        if kills:
            return min(kills, key=lambda i: ctx.charged[i].energy)
        return best if best in affordable else None
    if style == "nuker":
        if kills and not ctx.target_shields:
            return min(kills, key=lambda i: ctx.charged[i].energy)
        return best if best in affordable else None
    if style == "casual":
        return affordable[0]
    raise ValueError(style)


def throw_probs(style: str, ctx: ThrowContext, eps: float) -> dict[int | None, float]:
    options: list[int | None] = [None] + [i for i, c in enumerate(ctx.charged) if ctx.energy >= c.energy]
    if style == "casual" and len(options) > 1:
        # Throws something as soon as it can, any of them.
        probs = {o: eps / len(options) for o in options}
        for o in options[1:]:
            probs[o] += (1 - eps) / (len(options) - 1)
        return probs
    pref = preferred_throw(style, ctx)
    probs = {o: eps / len(options) for o in options}
    probs[pref] += 1 - eps
    return probs


def shield_prob(style: str, ctx: ShieldContext, eps: float) -> float:
    if ctx.shields <= 0:
        return 0.0
    lethal = ctx.full_damage >= ctx.hp
    if style == "shielder":
        want = True
    elif style == "baiter":
        want = lethal or ctx.full_damage >= 0.4 * ctx.max_hp
    elif style == "nuker":
        want = lethal
    elif style == "casual":
        return 0.5
    else:
        raise ValueError(style)
    return 1 - eps if want else eps


SWITCH_THRESHOLD = {"shielder": -0.6, "baiter": -0.5, "nuker": -0.8, "casual": None}


class Heuristic:
    """A player that follows one style. Plays from a View only, so it never sees your energy."""

    def __init__(self, style: str, eps: float = 0.1, seed: int | None = None, switches: bool = True):
        self.style = style
        self.eps = eps
        self.rng = random.Random(seed)
        self.switches = switches
        self.name = style

    def throw_context(self, view: View) -> ThrowContext:
        mon = view.mon
        return ThrowContext(mon.species, mon.charged, mon.energy, mon.atk_stage,
                            view.foe_species, view.foe_hp, view.foe_stages[1], view.foe_shields)

    def act(self, view: View) -> tuple[str, int]:
        if self.switches and view.can_switch:
            sw = self.switch_choice(view)
            if sw is not None:
                return SWITCH(sw)
        probs = throw_probs(self.style, self.throw_context(view), self.eps)
        choice = self.rng.choices(list(probs), list(probs.values()))[0]
        return FAST if choice is None else CHARGED(choice)

    def switch_choice(self, view: View) -> int | None:
        threshold = SWITCH_THRESHOLD[self.style]
        # Only reconsider when a new matchup starts, the way a player would.
        if threshold is None or max(view.me.entered, view.foe_entered) < view.turn - 2:
            return None
        seen = view.foe_seen().get(view.foe_species.id)
        now = matchup(view.mon, view.mon.hp, view.foe_species, view.foe_hp, seen)
        if now >= threshold:
            return None
        scored = [(matchup(view.me.mons[i], view.me.mons[i].hp, view.foe_species, view.foe_hp, seen), i)
                  for i in view.me.bench()]
        best, i = max(scored)
        return i if best > now + 0.5 else None

    def shield(self, view: View, move: Move) -> bool:
        mon = view.mon
        if mon.form == "disguised":
            return False   # Mimikyu's Disguise takes this one for free
        full = damage(move, view.foe_species, mon.species, view.foe_stages[0], mon.def_stage)
        p = shield_prob(self.style, ShieldContext(mon.hp, mon.max_hp, full, view.me.shields), self.eps)
        return self.rng.random() < p

    def replace(self, view: View) -> int:
        seen = view.foe_seen().get(view.foe_species.id)
        return max(view.me.bench(),
                   key=lambda i: matchup(view.me.mons[i], view.me.mons[i].hp, view.foe_species, view.foe_hp, seen))


class RandomPlayer:
    name = "random"

    def __init__(self, seed: int | None = None):
        self.rng = random.Random(seed)

    def act(self, view: View) -> tuple[str, int]:
        return self.rng.choice(view.legal_actions())

    def shield(self, view: View, move: Move) -> bool:
        return self.rng.random() < 0.5

    def replace(self, view: View) -> int:
        return self.rng.choice(view.me.bench())
