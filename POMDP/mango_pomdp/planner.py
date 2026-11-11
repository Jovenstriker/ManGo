"""Online POMDP planning: belief-sampled Monte Carlo rollouts.

At each decision that matters (a charged move is affordable, a switch makes sense, a shield,
a replacement), for each candidate action a and k = 1..K:

    sample a hypothesis h_k ~ b                     (back line, movesets, style)
    s_k = determinize(b, h_k)                       (your real state + h_k, counted energy)
    G_k(a) = reward of playing a, then the rollout policy for you and h_k's style for them

Every action is scored on the same K hypotheses and random seeds (common random numbers),
so the comparison is between actions, not between luck. The planner starts from what the
rollout policy itself would do and moves off it only when the paired differences say another
action is better by more than `z` standard errors. Taking the plain argmax of a dozen noisy
win/loss samples turned out to throw away good defaults often enough to lose to the rollout
policy; with the test, one-step lookahead keeps its policy-improvement property in practice.

A rollout scores +1 / 0 / −1 for the result plus `margin_weight` × the HP difference left
(as a fraction of each team's total), which separates close wins from blowouts.

Switching is legal on any turn the switch timer allows; `switch_at` decides when the planner
spends rollouts on it:
  "start"      within 2 turns of a new matchup
  "zero-turn"  that, and the turn right after any charged move (thrown, shielded or taken), when
               cooldowns have just reset: a 0-turn switch, which costs no fast move
  "catch"      that, and catching (the default). Whenever their counted energy is within one
               fast move of a charged move, it also weighs switching now, and for each bench
               Pokémon "wait, then switch to it the turn they throw", so the throw lands on the
               new Pokémon. Waiting keeps it free to switch that turn instead of being locked
               into a fast move. Choices are simultaneous, so the throw turn is a prediction:
               in each rollout `turns_to_throw` gets it from the counted energy and the style
               sampled from the belief.
  "any"        every turn

This is the "lookahead with rollouts" online method for POMDPs (Kochenderfer et al.,
Algorithms for Decision Making, ch. 22), with the opponent's play folded into the transition
model through the belief over styles. Swapping `Belief` for `Oracle` gives the same planner
with perfect information, which bounds what better inference could buy.
"""
from __future__ import annotations

import random

from .battle import FAST, SWITCH, WAIT, Battle, View
from .belief import Belief, Oracle
from .gamedata import MAX_ENERGY, GameData, Move
from .policies import STYLES, Heuristic, ThrowContext, preferred_throw
from .team_prior import TeamPrior, TeamSpec

SWITCH_AT = ("start", "zero-turn", "catch", "any")


def turns_to_throw(b: Battle, s: int, style: str) -> int | None:
    """Turns until side s throws a charged move, if it plays `style` and throws within its next
    fast move; None if it won't be ready that soon. Reads s's real energy, so in a rollout
    (a determinized belief state) that is the counted energy."""
    side, other = b.sides[s], b.sides[1 - s]
    mon, target, t = side.mon, other.mon, b.turn

    def throws(energy: int) -> bool:
        ctx = ThrowContext(mon.species, mon.charged, min(energy, MAX_ENERGY), mon.atk_stage,
                           target.species, target.hp, target.def_stage, other.shields)
        return preferred_throw(style, ctx) is not None

    if side.busy_until <= t:   # free now: throws now, or fast moves once more first
        if throws(mon.energy):
            return 0
        return mon.fast.turns if throws(mon.energy + mon.fast.energy_gain) else None
    gain = mon.fast.energy_gain if side.fast_due >= t else 0
    return side.busy_until - t if throws(mon.energy + gain) else None


class _Catch:
    """Rollout policy for "stay free, then switch to `slot` the turn they throw". It fast moves
    (or throws) while that leaves it free again in time, waits when a fast move would still be
    going on the turn they throw, and switches on that turn. Then it hands over to `then`."""

    def __init__(self, slot: int, then, battle: Battle, side: int, style: str, patience: int = 12):
        self.slot, self.then, self.b, self.side, self.style = slot, then, battle, side, style
        self.until = battle.turn + patience

    def act(self, view):
        if self.slot is None or not view.can_switch or self.slot not in view.me.bench() or view.turn > self.until:
            self.slot = None
            return self.then.act(view)
        when = turns_to_throw(self.b, 1 - self.side, self.style)
        if when == 0:
            slot, self.slot = self.slot, None
            return SWITCH(slot)
        if when is not None and view.mon.fast.turns > when:
            return WAIT
        a = self.then.act(view)
        return FAST if a[0] == "switch" else a

    def shield(self, view, move):
        return self.then.shield(view, move)

    def replace(self, view):
        return self.then.replace(view)


class _First:
    """Plays a fixed first action, then hands over."""

    def __init__(self, action, then):
        self.action, self.then = action, then

    def act(self, view):
        if self.action is not None:
            a, self.action = self.action, None
            return a
        return self.then.act(view)

    def shield(self, view, move):
        return self.then.shield(view, move)

    def replace(self, view):
        return self.then.replace(view)


class Planner:
    def __init__(self, gd: GameData, prior: TeamPrior, rollouts: int = 12, particles: int = 200,
                 styles: tuple[str, ...] = STYLES, eps: float = 0.1, rollout_style: str = "baiter",
                 seed: int | None = None, oracle: tuple[TeamSpec, str] | None = None, name: str = "planner",
                 z: float = 1.0, margin_weight: float = 0.2, switch_at: str = "catch"):
        if switch_at not in SWITCH_AT:
            raise ValueError(f"switch_at must be one of {SWITCH_AT}")
        self.switch_at = switch_at
        self.last_charged = -10   # turn of the last charged move either side threw
        self.gd, self.prior = gd, prior
        self.rollouts, self.particles, self.styles, self.eps = rollouts, particles, styles, eps
        self.rollout_style = rollout_style
        self.default = Heuristic(rollout_style, eps=0.0, seed=seed)
        self.z, self.margin_weight = z, margin_weight
        self.rng = random.Random(seed)
        self.oracle = oracle
        self.name = name
        self.belief: Belief | None = None
        self.decisions = 0

    # Match hooks --------------------------------------------------------------------------

    def start(self, side: int) -> None:
        self.side = side
        self.last_charged = -10
        seed = self.rng.randrange(1 << 30)
        if self.oracle:
            self.belief = Oracle(self.gd, self.prior, side, *self.oracle, seed=seed)
        else:
            self.belief = Belief(self.gd, self.prior, side, self.particles, self.styles, self.eps, seed=seed)

    def observe(self, events) -> None:
        for e in events:
            if e.kind == "charged":
                self.last_charged = e.turn
        self.belief.observe(events)

    # Decisions ----------------------------------------------------------------------------

    def may_switch(self, view: View) -> bool:
        if not view.can_switch:
            return False
        if self.switch_at == "any" or max(view.me.entered, view.foe_entered) >= view.turn - 2:
            return True
        return self.switch_at != "start" and view.turn == self.last_charged + 1

    def catch_window(self, view: View) -> bool:
        """Their counted energy is within one fast move of the cheapest charged move they might have."""
        if self.switch_at != "catch" or not view.can_switch:
            return False
        sid = view.foe_species.id
        costs = [self.gd.moves[m].energy for m, w in self.belief.moves_posterior(sid) if w > 0 and m in self.gd.moves]
        fast = view.foe_seen().get(sid, {}).get("fast")
        gain = fast.energy_gain if fast else max(m.energy_gain for m in self.gd.moves.values())
        return bool(costs) and self.belief.counter.energy.get(sid, 0) + gain >= min(costs)

    def act(self, view: View) -> tuple[str, int]:
        cands = [a for a in view.legal_actions() if a[0] == "fast" or a[0] == "charged"]
        switches = [a for a in view.legal_actions() if a[0] == "switch"]
        if self.may_switch(view):
            cands += switches
        if switches and self.catch_window(view):
            cands += [a for a in switches if a not in cands] + [("catch", a[1]) for a in switches]
        if len(cands) == 1:
            return FAST
        default = self.default.act(view)
        if default not in cands:
            cands.append(default)
        best = self._best(view, cands, lambda b, a, ctrls: None, cands.index(default), first=True)
        return WAIT if best[0] == "catch" else best

    def shield(self, view: View, move: Move) -> bool:
        if view.me.shields == 0:
            return False
        foe = 1 - view.side

        def apply(b: Battle, choice: bool, ctrls) -> None:
            b.land_charged(foe, move, ctrls, shield=choice)
            b.handle_faints(ctrls)
            b.end_turn(True)

        default = int(self.default.shield(view, move))
        return self._best(view, [False, True], apply, default, incoming=move)

    def replace(self, view: View) -> int:
        bench = view.me.bench()
        if len(bench) == 1:
            return bench[0]
        default = bench.index(self.default.replace(view))
        return self._best(view, bench, lambda b, i, ctrls: b.switch_in(view.side, i, timer=False), default)

    # Rollouts -----------------------------------------------------------------------------

    def _controllers(self, first, seed: int, style: str, b: Battle):
        mine = Heuristic(self.rollout_style, eps=0.0, seed=seed)
        if first is not None and first[0] == "catch":
            mine = _First(WAIT, _Catch(first[1], mine, b, self.side, style))
        elif first is not None:
            mine = _First(first, mine)
        theirs = Heuristic(style, eps=self.eps, seed=seed + 1)
        return [mine, theirs] if self.side == 0 else [theirs, mine]

    def _value(self, b: Battle) -> float:
        hp = [sum(m.hp for m in side.mons) / sum(m.max_hp for m in side.mons) for side in b.sides]
        return b.reward(self.side) + self.margin_weight * (hp[self.side] - hp[1 - self.side])

    def _best(self, view: View, cands: list, apply, default: int, first: bool = False,
              incoming: Move | None = None):
        self.decisions += 1
        values = [[] for _ in cands]
        for _ in range(self.rollouts):
            p = self.belief.sample(self.rng)
            seed = self.rng.randrange(1 << 30)
            root = self.belief.determinize(view, p, incoming=incoming)
            for j, c in enumerate(cands):
                b = root.clone(seed)
                ctrls = self._controllers(c if first else None, seed, p.style, b)
                apply(b, c, ctrls)
                b.play(ctrls)
                values[j].append(self._value(b))
        best, best_gain = default, 0.0
        for j in range(len(cands)):
            if j == default:
                continue
            diffs = [a - d for a, d in zip(values[j], values[default])]
            mean = sum(diffs) / len(diffs)
            se = (sum((x - mean) ** 2 for x in diffs) / max(len(diffs) - 1, 1) / len(diffs)) ** 0.5
            if mean > self.z * se and mean > best_gain:
                best, best_gain = j, mean
        return cands[best]
