"""The player's belief about the opponent.

It has two parts, because the hidden information comes in two kinds:

Hidden but deterministically inferable: energy. `EnergyCounter` does in a few lines what
ManGo's OpponentTracker (PvPCore) does from the screen: every fast move you see adds its energy,
every charged move subtracts its cost, a Pokémon keeps its energy on the bench. The opponent's
switch timer is counted the same way. No particles needed.

Hidden and only probabilistically inferable: the back line, moves not yet thrown, and how the
opponent plays. `Belief` keeps weighted particles, each a full hypothesis (three species,
their movesets, one style from policies.STYLES), and updates them on public events:

  • reveals (a Pokémon comes in, a move is used): particles that contradict it are repaired
    by redrawing the contradicted part from the prior conditioned on everything seen so far
    (rejection then refill, so the population tracks the conditional prior);
  • decisions (they fast moved with energy for a charged move, threw this move rather than that,
    shielded or not): each particle is reweighted by how likely its style was to do that,
    given its moveset and the counted energy.

When the effective sample size drops below half, the particles are resampled, with a small
chance each of switching style so no style dies out for good.
"""
from __future__ import annotations

import random
from collections import Counter
from dataclasses import dataclass

from .battle import SWITCH_TURNS, Battle, Event, Mon, Side, View
from .gamedata import MAX_ENERGY, GameData, Move
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

    # Updates ------------------------------------------------------------------------------

    def observe(self, events: list[Event]) -> None:
        for e in events:
            if e.side != self.me:
                self._foe_event(e)
            elif e.kind == "charged" and e.info["target_shields"] > 0:
                self._foe_shield_decision(e)

    def _foe_event(self, e: Event) -> None:
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
            self._reweight(lambda p: throw_probs(p.style, self._throw_ctx(p, e), self.eps)[None])
        elif e.kind == "charged":
            self.revealed[e.species]["charged"].add(e.move.id)
            self._repair_moves(e.species)
            self._reweight(lambda p: self._throw_likelihood(p, e))
        self.counter.observe(e)

    def _foe_shield_decision(self, e: Event) -> None:
        target = self.gd.species[e.info["target"]]
        ctx = ShieldContext(e.info["target_hp"], target.hp, e.info["full_damage"], e.info["target_shields"])
        shielded = e.info["shielded"]
        self._reweight(lambda p: shield_prob(p.style, ctx, self.eps) if shielded
                       else 1 - shield_prob(p.style, ctx, self.eps))

    def _throw_ctx(self, p: Particle, e: Event) -> ThrowContext:
        fast, charged = p.moves[e.species]
        return ThrowContext(self.gd.species[e.species], tuple(self.gd.moves[c] for c in charged),
                            self.counter.energy.get(e.species, 0), 0,
                            self.gd.species[e.info["target"]], e.info["target_hp"], 0, e.info["target_shields"])

    def _throw_likelihood(self, p: Particle, e: Event) -> float:
        ctx = self._throw_ctx(p, e)
        # A miscount (or a move outside the particle) shouldn't zero everything out.
        ctx.energy = max(ctx.energy, e.move.energy)
        idx = next((i for i, c in enumerate(ctx.charged) if c.id == e.move.id), None)
        return throw_probs(p.style, ctx, self.eps).get(idx, self.eps) if idx is not None else self.eps

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
            m = Mon(gd.species[sid], gd.moves[fast], tuple(gd.moves[c] for c in charged))
            if sid in self.revealed:
                m.hp = view.foe_hp_of(sid)
                m.energy = self.counter.energy.get(sid, 0)
            mons.append(m)
        foe = Side(mons, view.foe_shields)
        foe.active = order.index(view.foe_species.id)
        active = foe.mon
        active.atk_stage, active.def_stage = view.foe_stages
        if incoming is not None:
            if incoming not in active.charged:
                active.charged = (incoming,) + active.charged[1:]
            active.energy = max(active.energy, incoming.energy)
        foe.switch_timer = max(0, self.counter.switch_ready - view.turn)
        foe.busy_until = view.turn
        foe.entered = view.foe_entered
        sides = [view.me.clone(), foe] if view.side == 0 else [foe, view.me.clone()]
        return Battle.from_sides(sides, view.turn, view.clock, view.lag_turn, view.seen_copy(), seed)


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
