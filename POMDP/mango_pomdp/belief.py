"""The player's belief about the opponent.

It has two parts, because the hidden information comes in two kinds:

Hidden but deterministically inferable: energy. `EnergyCounter` does in a few lines what
ManGo's OpponentTracker (PvPCore) does from the screen: every fast move you see adds its energy,
every charged move subtracts its cost, a Pokémon keeps its energy on the bench. The opponent's
switch timer is counted the same way. No particles needed.

Hidden and only probabilistically inferable: the back line, moves not yet thrown, and how the
opponent plays. `Belief` keeps weighted particles, each a full hypothesis (three species,
their movesets, one style from policies.STYLES, or "learned": plays like the opponent model
fitted on your recorded opponents), and updates them on public events:

  • reveals (a Pokémon comes in, a move is used): particles that contradict it are repaired
    by redrawing the contradicted part from the prior conditioned on everything seen so far
    (rejection then refill, so the population tracks the conditional prior);
  • decisions (they fast moved with energy for a charged move, threw this move rather than that,
    shielded or not): each particle is reweighted by how likely its style was to do that,
    given its moveset and the counted energy. For "learned", that's the opponent model's
    probability, read off the battle as you saw it at the start of the turn they chose in
    (`before_turn`), so it can count your energy and timing and the history the way they did.

When the effective sample size drops below half, the particles are resampled, with a small
chance each of switching style so no style dies out for good.
"""
from __future__ import annotations

import random
from collections import Counter
from dataclasses import dataclass

from .battle import SWITCH_TURNS, Battle, Event, Mon, Side, View
from .gamedata import MAX_ENERGY, GameData, Move
from .opponent_model import allowed_throws, cheap_big, default_model
from .policies import STYLES, ShieldContext, ThrowContext, shield_prob, throw_probs
from .team_prior import TeamPrior, TeamSpec


class EnergyCounter:
    """Opponent energy from what's on screen, the way ManGo counts it."""

    def __init__(self) -> None:
        self.energy: dict[str, int] = {}
        self.switch_ready = 0   # turn the opponent's switch timer runs out

    def observe(self, e: Event) -> None:
        if e.kind == "enter":
            self.energy.setdefault(e.species, 0)
            if e.info.get("switch"):
                self.switch_ready = e.turn + SWITCH_TURNS
        elif e.kind == "fast":
            self.energy[e.species] = min(MAX_ENERGY, self.energy.get(e.species, 0) + e.move.energy_gain)
        elif e.kind == "charged":
            self.energy[e.species] = max(0, self.energy.get(e.species, 0) - e.move.energy)


@dataclass(slots=True)
class Particle:
    team: list[str]
    moves: dict[str, tuple[str, tuple[str, ...]]]
    style: str

    def copy(self) -> Particle:
        return Particle(list(self.team), dict(self.moves), self.style)


class Belief:
    def __init__(self, gd: GameData, prior: TeamPrior, me: int, n: int = 200,
                 styles: tuple[str, ...] = STYLES, eps: float = 0.1, rejuvenate: float = 0.03,
                 seed: int | None = None):
        self.gd, self.prior, self.me = gd, prior, me
        self.n, self.styles, self.eps, self.rejuvenate = n, styles, eps, rejuvenate
        self.rng = random.Random(seed)
        self.counter = EnergyCounter()
        self.seen_order: list[str] = []
        self.revealed: dict[str, dict] = {}
        self.particles: list[Particle] = []
        self.weights: list[float] = []
        self.model = default_model() if "learned" in styles else None
        self._pre: dict[int, Battle] = {}   # turn -> the battle as you saw it at its start (for "learned")
        self._cache: dict = {}
        # Their history, as the screen shows it: charged moves each has thrown and taken, whether
        # their last throw was shielded, whether they shielded the last one they could have.
        self.thrown: Counter = Counter()
        self.taken: Counter = Counter()
        self.last_shielded: bool | None = None
        self.shielded_last: bool | None = None

    # Updates ------------------------------------------------------------------------------

    def observe(self, events: list[Event]) -> None:
        for e in events:
            if e.side != self.me:
                self._foe_event(e)
            elif e.kind == "charged":
                if e.info["target_shields"] > 0:
                    self._foe_shield_decision(e)
                    self.shielded_last = e.info["shielded"]
                self.taken[e.info["target"]] += 1

    @property
    def side(self) -> int:   # the side whose view it takes, as an observer of Battle.play
        return self.me

    def before_turn(self, view: View) -> None:
        """Keeps the battle as you see it at the start of this turn: the state the opponent chooses
        in, for scoring their choices under the learned model. Only needed with "learned"."""
        if self.model is None:
            return
        self.see(view)
        if not self.particles:
            return
        top = max(range(len(self.weights)), key=self.weights.__getitem__)
        self._pre[view.turn] = self.determinize(view, self.particles[top])
        for t in [t for t in self._pre if t < view.turn - 8]:
            del self._pre[t]

    def _foe_event(self, e: Event) -> None:
        self._cache = {}
        if e.kind == "enter":
            if e.species not in self.revealed:
                self.revealed[e.species] = {"fast": None, "charged": set()}
                self.seen_order.append(e.species)
            if not self.particles:
                self._init_particles()
            else:
                self._repair_species(e.species)
        elif e.kind == "fast":
            self.revealed[e.species]["fast"] = e.move.id
            self._repair_moves(e.species)
            # Fast moving now was a choice, if they had the energy to throw.
            self._reweight(lambda p: self._mixed(
                p, lambda st: throw_probs(st, self._throw_ctx(p, e), self.eps)[None],
                lambda: self._learned(p, e, "hold")))
        elif e.kind == "charged":
            self.revealed[e.species]["charged"].add(e.move.id)
            self._repair_moves(e.species)
            self._reweight(lambda p: self._mixed(p, lambda st: self._throw_likelihood(p, e, st),
                                                 lambda: self._learned(p, e, "throw")))
            self.thrown[e.species] += 1
            self.last_shielded = e.info["shielded"]
        self.counter.observe(e)

    def _foe_shield_decision(self, e: Event) -> None:
        if e.info.get("target_form") == "disguised":
            return   # no style shields into Mimikyu's Disguise, so it says nothing
        self._cache = {}
        target = self.gd.species[e.info["target"]]
        ctx = ShieldContext(e.info["target_hp"], target.hp, e.info["full_damage"], e.info["target_shields"])
        shielded = e.info["shielded"]
        self._reweight(lambda p: self._mixed(
            p, lambda st: shield_prob(st, ctx, self.eps) if shielded else 1 - shield_prob(st, ctx, self.eps),
            lambda: self._learned(p, e, "shield")))

    def _mixed(self, p: Particle, style_likelihood, learned_likelihood) -> float:
        """The likelihood of what they did under p's style. For "learned", the opponent model's,
        or when it can't be read (a Pokémon with one charged move, or no state for that turn),
        the styles' average, which leaves "learned" neither favored nor penalized."""
        if p.style != "learned":
            return style_likelihood(p.style)
        q = learned_likelihood()
        return q if q is not None else sum(style_likelihood(st) for st in STYLES) / len(STYLES)

    def _learned(self, p: Particle, e: Event, kind: str) -> float | None:
        """P(what they did) under the learned model, with p's moveset for their Pokémon, from the
        battle as you saw it when they chose. kind: "hold" (a fast move), "throw" or "shield"."""
        if self.model is None:
            return None
        foe = 1 - self.me
        sid = e.info["target"] if kind == "shield" else e.species
        turn = e.info.get("started", e.turn) if kind == "hold" else e.turn
        b = self._pre.get(turn)
        if b is None or b.sides[foe].mon.species.id != sid or sid not in p.moves:
            return None
        if kind == "shield" and b.sides[self.me].mon.species.id != e.species:
            return None
        key = p.moves[sid]
        if key in self._cache:
            return self._cache[key]
        side = b.sides[foe]
        old = side.mon
        m = Mon.build(self.gd, sid, *key)
        m.set_form(old.form)
        m.hp, m.energy, m.atk_stage, m.def_stage, m.native = old.hp, old.energy, old.atk_stage, old.def_stage, old.native
        m.thrown, m.taken = old.thrown, old.taken
        side.mons[side.active] = m
        try:
            q = self._learned_prob(b, foe, m, e, kind)
        finally:
            side.mons[side.active] = old
        self._cache[key] = q
        return q

    def _learned_prob(self, b: Battle, foe: int, m: Mon, e: Event, kind: str) -> float | None:
        if kind == "shield":
            mine = b.sides[self.me].mon
            move = next((c for c in mine.charged if mine.base_move(c).id == e.move.id), e.move)
            q = self.model.p_shield(b, foe, move)
            return q if e.info["shielded"] else 1 - q
        order = cheap_big(m)
        if order is None:
            return None   # one charged move: the learned opponent throws it like the baiter
        if kind == "hold":
            return self.model.p_throw(b, foe)[0] if allowed_throws(m)[1] else 1.0
        ids = [m.base_move(c).id for c in m.charged]
        if e.move.id not in ids:
            return self.eps   # a move outside p's moveset, as in _throw_likelihood
        m.energy = max(m.energy, e.move.energy)   # a miscount shouldn't zero it out
        return self.model.p_throw(b, foe)[1 if ids.index(e.move.id) == order[0] else 2]

    def _throw_ctx(self, p: Particle, e: Event) -> ThrowContext:
        fast, charged = p.moves[e.species]
        return ThrowContext(self.gd.species[e.species], tuple(self.gd.moves[c] for c in charged),
                            self.counter.energy.get(e.species, 0), 0,
                            self.gd.species[e.info["target"]], e.info["target_hp"], 0, e.info["target_shields"])

    def _throw_likelihood(self, p: Particle, e: Event, style: str) -> float:
        ctx = self._throw_ctx(p, e)
        # A miscount (or a move outside the particle) shouldn't zero everything out.
        ctx.energy = max(ctx.energy, e.move.energy)
        idx = next((i for i, c in enumerate(ctx.charged) if c.id == e.move.id), None)
        return throw_probs(style, ctx, self.eps).get(idx, self.eps) if idx is not None else self.eps

    def _reweight(self, likelihood) -> None:
        if not self.particles:
            return
        self.weights = [w * max(likelihood(p), 1e-9) for w, p in zip(self.weights, self.particles)]
        total = sum(self.weights)
        self.weights = [w / total for w in self.weights]
        if 1.0 / sum(w * w for w in self.weights) < self.n / 2:
            self._resample()

    def _resample(self) -> None:
        step, u = 1.0 / self.n, self.rng.random() / self.n
        out, cum, i = [], self.weights[0], 0
        for _ in range(self.n):
            while u > cum and i < self.n - 1:
                i += 1
                cum += self.weights[i]
            p = self.particles[i].copy()
            if self.rng.random() < self.rejuvenate:
                p.style = self.rng.choice(self.styles)
            out.append(p)
            u += step
        self.particles, self.weights = out, [step] * self.n

    # Reveals ------------------------------------------------------------------------------

    def _moveset(self, sid: str) -> tuple[str, tuple[str, ...]]:
        r = self.revealed.get(sid, {"fast": None, "charged": set()})
        return self.prior.sample_moveset(self.rng, sid, r["fast"], tuple(sorted(r["charged"])))

    def _init_particles(self) -> None:
        self.particles = []
        for _ in range(self.n):
            team = self.prior.complete_team(self.rng, self.seen_order)
            self.particles.append(Particle(team, {s: self._moveset(s) for s in team}, self.rng.choice(self.styles)))
        self.weights = [1.0 / self.n] * self.n

    def _repair_species(self, sid: str) -> None:
        for p in self.particles:
            if sid in p.team:
                continue
            team = self.prior.complete_team(self.rng, self.seen_order)
            p.moves = {s: p.moves[s] if s in p.moves and s in self.revealed else self._moveset(s) for s in team}
            p.team = team

    def _repair_moves(self, sid: str) -> None:
        r = self.revealed[sid]
        for p in self.particles:
            fast, charged = p.moves[sid]
            if (r["fast"] and fast != r["fast"]) or not r["charged"] <= set(charged):
                p.moves[sid] = self._moveset(sid)

    # Reading the belief -------------------------------------------------------------------

    def sample(self, rng: random.Random) -> Particle:
        return rng.choices(self.particles, self.weights)[0]

    def style_posterior(self) -> dict[str, float]:
        out = dict.fromkeys(self.styles, 0.0)
        for p, w in zip(self.particles, self.weights):
            out[p.style] += w
        return out

    def unseen_posterior(self) -> list[tuple[str, float]]:
        """Probability each unseen species is on the opponent's team."""
        c: Counter = Counter()
        for p, w in zip(self.particles, self.weights):
            for s in p.team:
                if s not in self.revealed:
                    c[s] += w
        return c.most_common()

    def moves_posterior(self, sid: str) -> list[tuple[str, float]]:
        c: Counter = Counter()
        for p, w in zip(self.particles, self.weights):
            if sid in p.moves:
                for m in p.moves[sid][1]:
                    c[m] += w
        return c.most_common()

    # Determinizing ------------------------------------------------------------------------

    def see(self, view: View) -> None:
        """Takes in an opponent Pokémon that's on screen before its "enter" event arrives: one
        that came in with a 0-turn switch and acts on the same turn, before the turn's events
        are reported."""
        sid = view.foe_species.id
        if sid not in self.revealed:
            self._foe_event(Event(view.turn, 1 - self.me, "enter", sid))

    def determinize(self, view: View, p: Particle, seed: int | None = None, incoming: Move | None = None) -> Battle:
        """A full battle state: your side as it is, the opponent's filled in from particle p.

        `incoming` is a charged move the opponent is throwing right now (for a shield decision),
        so the active opponent must have it and the energy for it.
        """
        gd = self.gd
        order = self.seen_order + [s for s in p.team if s not in self.revealed]
        mons = []
        for sid in order:
            fast, charged = p.moves[sid]
            m = Mon.build(gd, sid, fast, charged)
            if sid in self.revealed:
                seen_hp = view.foe_hp_of(sid)
                if seen_hp is not None:   # None: a Pokémon not on their real team (a misread report)
                    m.hp = seen_hp
                m.energy = self.counter.energy.get(sid, 0)
                m.set_form(view.foe_form_of(sid))
                m.thrown, m.taken = self.thrown[sid], self.taken[sid]
            mons.append(m)
        foe = Side(mons, view.foe_shields)
        foe.last_shielded, foe.shielded_last = self.last_shielded, self.shielded_last
        foe.active = order.index(view.foe_species.id)
        active = foe.mon
        active.atk_stage, active.def_stage = view.foe_stages
        if incoming is not None:
            if incoming not in active.charged:
                active.charged = (incoming,) + active.charged[1:]
            active.energy = max(active.energy, incoming.energy)
        foe.switch_timer = max(0, self.counter.switch_ready - view.turn)
        # Their fast move in progress, as the screen shows it: they can't throw until it's done.
        wait, lands = view.foe_timer
        foe.busy_until = view.turn + wait
        foe.fast_due = view.turn + lands if lands >= 0 else -1
        foe.entered = view.foe_entered
        sides = [view.me.clone(), foe] if view.side == 0 else [foe, view.me.clone()]
        return Battle.from_sides(sides, view.turn, view.clock, view.seen_copy(), seed, view.last_charged)


class Oracle(Belief):
    """Cheats: knows the opponent's real team and style. An upper bound on what belief is worth."""

    def __init__(self, gd: GameData, prior: TeamPrior, me: int, truth: TeamSpec, style: str, **kw):
        super().__init__(gd, prior, me, n=1, **kw)
        self.particles = [Particle([s for s, _, _ in truth], {s: (f, tuple(c)) for s, f, c in truth}, style)]
        self.weights = [1.0]

    def _init_particles(self) -> None:
        pass

    def _repair_species(self, sid: str) -> None:
        pass

    def _repair_moves(self, sid: str) -> None:
        pass

    def _reweight(self, likelihood) -> None:
        pass
