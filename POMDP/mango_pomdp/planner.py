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

The actions, on every turn your Pokémon is free: a fast move (which locks it in for the move's
length), a charged move it has the energy for, a switch to either bench Pokémon (when the switch
timer allows), or waiting. When they throw: shield or not, while you have shields. After a
faint: which Pokémon comes in. `switch_at` decides which of those the planner weighs with
rollouts on a given free turn (the rest of the time it fast moves):
  "start"      fast and charged moves whenever a charged move is affordable; switches within 2
               turns of a new matchup
  "zero-turn"  that, and switches on the turn right after any charged move (thrown, shielded or
               taken), when cooldowns have just reset: a 0-turn switch, which costs no fast move
  "catch"      that, and catching. Whenever their counted energy is within one fast move of a
               charged move, it also weighs switching now, and for each bench Pokémon "wait,
               then switch to it the turn they throw", so the throw lands on the new Pokémon.
               Waiting keeps it free to switch that turn instead of being locked into a fast
               move. Choices are simultaneous, so the throw turn is a prediction: in each
               rollout `turns_to_throw` gets it from the counted energy and the sampled style.
  "any"        every legal action on every free turn (the default): fast, each affordable
               charged move, each switch the timer allows, and waiting, plus the catch plans
               above when they're near a throw

With "catch" or "any", our side's rollout policy catches too (`_Catcher`, unless
`rollout_catch=False`): the baiter heuristic, except that when the opponent is about to throw a
big hit that a bench Pokémon takes much less of, it stays free and switches on the throw turn.
So a rollout values a catch the planner would make later, not only one it starts now.

This is the "lookahead with rollouts" online method for POMDPs (Kochenderfer et al.,
Algorithms for Decision Making, ch. 22), with the opponent's play folded into the transition
model through the belief over styles. Swapping `Belief` for `Oracle` gives the same planner
with perfect information, which bounds what better inference could buy.
"""
from __future__ import annotations

import random

from .battle import FAST, SWITCH, WAIT, Battle, View
from .belief import Belief, Oracle
from .gamedata import MAX_ENERGY, GameData, Move, damage
from .policies import STYLES, Heuristic, ThrowContext, Timed, preferred_throw
from .team_prior import TeamPrior, TeamSpec

SWITCH_AT = ("start", "zero-turn", "catch", "any")
FARM = ("farm", 0)   # a candidate: farm their Pokémon down with fast moves (_Farm)


def _learned_throw(b: Battle, s: int, energy: int) -> Move | None:
    """The learned opponent's most likely choice at this energy: a charged move, or None to hold."""
    from .opponent_model import allowed_throws, cheap_big, default_model
    mon, model = b.sides[s].mon, default_model()
    if model is None or cheap_big(mon) is None:
        return None
    saved, mon.energy = mon.energy, energy
    try:
        if not allowed_throws(mon)[1]:
            return None
        p = model.p_throw(b, s)
    finally:
        mon.energy = saved
    choice = max(range(3), key=lambda k: p[k])
    return None if choice == 0 else mon.charged[cheap_big(mon)[choice - 1]]


def next_throw(b: Battle, s: int, style: str) -> tuple[int, Move] | None:
    """(turns until side s throws a charged move, which move), if it plays `style` and throws
    within its next fast move; None if it won't be ready that soon. Reads s's real energy, so in a
    rollout (a determinized belief state) that is the counted energy."""
    side, other = b.sides[s], b.sides[1 - s]
    mon, target, t = side.mon, other.mon, b.turn

    def throw(energy: int) -> Move | None:
        if style == "learned":
            return _learned_throw(b, s, min(energy, MAX_ENERGY))
        ctx = ThrowContext(mon.species, mon.charged, min(energy, MAX_ENERGY), mon.atk_stage,
                           target.species, target.hp, target.def_stage, other.shields)
        i = preferred_throw(style, ctx)
        return None if i is None else mon.charged[i]

    if side.busy_until <= t:   # free now: throws now, or fast moves once more first
        now = throw(mon.energy)
        if now:
            return 0, now
        later = throw(mon.energy + mon.fast.energy_gain)
        return (mon.fast.turns, later) if later else None
    gain = mon.fast.energy_gain if side.fast_due >= t else 0
    later = throw(mon.energy + gain)
    return (side.busy_until - t, later) if later else None


def turns_to_throw(b: Battle, s: int, style: str) -> int | None:
    nxt = next_throw(b, s, style)
    return None if nxt is None else nxt[0]


class _Catcher:
    """Our rollout policy: the baiter heuristic, plus catching. When the opponent (playing the
    sampled style, with the counted energy) is about to throw a move that would take at least
    `big` of our Pokémon's HP, and a bench Pokémon would take at most `ratio` of that damage,
    it stays free (fast moving only if that ends in time, else waiting) and switches to that
    Pokémon the turn they throw."""

    def __init__(self, base, battle: Battle, side: int, style: str, ratio: float = 0.6, big: float = 0.25):
        self.base, self.b, self.side, self.style, self.ratio, self.big = base, battle, side, style, ratio, big

    def target(self, view) -> tuple[int, int] | None:
        """(bench slot to catch with, turns until the throw), or None."""
        if not view.can_switch:
            return None
        nxt = next_throw(self.b, 1 - self.side, self.style)
        if nxt is None:
            return None
        when, move = nxt
        foe = self.b.sides[1 - self.side].mon
        mine = view.mon
        hit = damage(move, foe.species, mine.species, foe.atk_stage, mine.def_stage)
        if hit < self.big * mine.hp:
            return None
        bench = view.me.bench()
        taken = {i: damage(move, foe.species, view.me.mons[i].species, foe.atk_stage, view.me.mons[i].native[1])
                 for i in bench}
        slot = min(bench, key=lambda i: (taken[i], -view.me.mons[i].hp))
        return (slot, when) if taken[slot] <= self.ratio * hit else None

    def act(self, view):
        plan = self.target(view)
        if plan is None:
            return self.base.act(view)
        slot, when = plan
        if when == 0:
            return SWITCH(slot)
        if view.mon.fast.turns > when:
            return WAIT
        a = self.base.act(view)
        return FAST if a[0] == "switch" else a

    def shield(self, view, move):
        return self.base.shield(view, move)

    def replace(self, view):
        return self.base.replace(view)


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


class _Farm:
    """Rollout policy for "farm down": fast moves only, no charged moves and no switches, until the
    opponent's Pokémon in now faints or leaves, banking the energy for the next matchup. Then it
    hands over to `then`. A win condition the default rollout policy never plays, since it throws
    whenever it can."""

    def __init__(self, then, battle: Battle, side: int):
        self.then, self.b, self.side = then, battle, side
        self.target = battle.sides[1 - side].mon

    def act(self, view):
        if self.target is not None and self.target.hp > 0 and self.b.sides[1 - self.side].mon is self.target:
            return FAST
        self.target = None
        return self.then.act(view)

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
                 z: float = 1.0, margin_weight: float = 0.2, switch_at: str = "any",
                 rollout_catch: bool = True, timing: bool = True, z_extra: float = 3.0, farm: bool = True):
        if switch_at not in SWITCH_AT:
            raise ValueError(f"switch_at must be one of {SWITCH_AT}")
        self.switch_at = switch_at
        self.farm = farm   # weigh farming down (fast moves only until their Pokémon goes down) every free turn
        self.rollout_catch = rollout_catch
        self.last_charged = -10   # turn of the last charged move either side threw
        self.gd, self.prior = gd, prior
        self.rollouts, self.particles, self.styles, self.eps = rollouts, particles, styles, eps
        self.rollout_style = rollout_style
        self.timing = timing
        self.default = self._ours(seed)
        self.z, self.z_extra, self.margin_weight = z, z_extra, margin_weight
        self.rng = random.Random(seed)
        self.oracle = oracle
        self.name = name
        self.belief: Belief | None = None
        self.decisions = 0

    def _ours(self, seed):
        """Our default policy (also our rollout policy): the rollout style, throwing on good timing."""
        base = Heuristic(self.rollout_style, eps=0.0, seed=seed)
        return Timed(base) if self.timing else base

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

    def before_turn(self, view) -> None:
        """Called at the start of every turn (Battle.play): the belief keeps the battle as you see
        it then, to score the opponent's choices this turn under the learned model."""
        self.belief.before_turn(view)

    # Decisions ----------------------------------------------------------------------------

    def may_switch(self, view: View) -> bool:
        if not view.can_switch:
            return False
        if self.switch_at == "any" or max(view.me.entered, view.foe_entered) >= view.turn - 2:
            return True
        return self.switch_at != "start" and view.turn == self.last_charged + 1

    def catch_window(self, view: View) -> bool:
        """Their counted energy is within one fast move of the cheapest charged move they might have."""
        if self.switch_at not in ("catch", "any") or not view.can_switch:
            return False
        sid = view.foe_species.id
        costs = [self.gd.moves[m].energy for m, w in self.belief.moves_posterior(sid) if w > 0 and m in self.gd.moves]
        fast = view.foe_seen().get(sid, {}).get("fast")
        gain = fast.energy_gain if fast else max(m.energy_gain for m in self.gd.moves.values())
        return bool(costs) and self.belief.counter.energy.get(sid, 0) + gain >= min(costs)

    def key_moment(self, view: View) -> bool:
        """A turn where the mechanics make a switch natural: a new matchup, or a 0-turn switch."""
        if max(view.me.entered, view.foe_entered) >= view.turn - 2:
            return True
        return self.switch_at != "start" and view.turn == self.last_charged + 1

    def act(self, view: View) -> tuple[str, int]:
        legal = view.legal_actions()
        cands = [a for a in legal if a[0] == "fast" or a[0] == "charged"]
        switches = [a for a in legal if a[0] == "switch"]
        if switches and self.key_moment(view):
            cands += switches
        if switches and self.catch_window(view):
            cands += [a for a in switches if a not in cands] + [("catch", a[1]) for a in switches]
        zs = [self.z] * len(cands)
        if self.switch_at == "any":
            # Every legal action, every free turn. Switching or waiting at any other moment is rarely
            # right, so it has to clear a higher bar: with a dozen noisy rollouts at every turn, a
            # plain one-standard-error test would wander off the default by chance.
            extra = [a for a in switches + [WAIT] if a not in cands]
            cands += extra
            zs += [self.z_extra] * len(extra)
        if self.farm and len(cands) > 1:   # the farm-down line: fast moves until their Pokémon in now goes down
            cands.append(FARM)
            zs.append(self.z)
        if len(cands) == 1:
            return FAST
        default = self.default.act(view)
        if default not in cands:
            cands.append(default)
            zs.append(self.z)
        best = self._best(view, cands, lambda b, a, ctrls: None, cands.index(default), first=True, zs=zs)
        return WAIT if best[0] == "catch" else FAST if best[0] == "farm" else best

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
        mine = self._rollout_policy(seed, style, b)
        if first is not None and first[0] == "catch":
            mine = _First(WAIT, _Catch(first[1], mine, b, self.side, style))
        elif first is not None and first[0] == "farm":
            mine = _Farm(mine, b, self.side)
        elif first is not None:
            mine = _First(first, mine)
        theirs = self._theirs(seed, style, b)
        return [mine, theirs] if self.side == 0 else [theirs, mine]

    def _rollout_policy(self, seed: int, style: str, b: Battle):
        """Our side's rollout policy in one rollout."""
        mine = self._ours(seed)
        if self.rollout_catch and self.switch_at in ("catch", "any"):
            mine = _Catcher(mine, b, self.side, style)
        return mine

    def _theirs(self, seed: int, style: str, b: Battle):
        """The opponent in one rollout: the sampled style, or the learned model."""
        if style == "learned":   # the model fitted on your recorded opponents (opponent_model)
            from .opponent_model import Learned, default_model
            model = default_model()
            if model is None:
                raise RuntimeError("no opponent model: run python3 -m experiments.opponent_model first")
            return Learned(model, b, 1 - self.side, seed + 1)
        return Heuristic(style, eps=self.eps, seed=seed + 1)

    def _value(self, b: Battle) -> float:
        hp = [sum(m.hp for m in side.mons) / sum(m.max_hp for m in side.mons) for side in b.sides]
        return b.reward(self.side) + self.margin_weight * (hp[self.side] - hp[1 - self.side])

    def outcomes(self, view: View, cands: list, apply=None, first: bool = False,
                 incoming: Move | None = None, rollouts: int | None = None,
                 keep: dict | None = None) -> list[list[float]]:
        """For each candidate, its rollout results as wins (1, ½ for a tie, 0), on the same
        sampled hypotheses and seeds for every candidate: a win-probability estimate of each
        action, for judging decisions rather than making them. Calling it again draws new
        rollouts, so results can be added up. (`keep` lets a planner that learns as it rolls
        out, like POMCP, carry on from an earlier call on the same decision.)"""
        self.belief.see(view)
        apply = apply or (lambda b, a, ctrls: None)
        out = [[] for _ in cands]
        for _ in range(rollouts or self.rollouts):
            p = self.belief.sample(self.rng)
            seed = self.rng.randrange(1 << 30)
            root = self.belief.determinize(view, p, incoming=incoming)
            for j, c in enumerate(cands):
                b = root.clone(seed)
                ctrls = self._controllers(c if first else None, seed, p.style, b)
                apply(b, c, ctrls)
                b.play(ctrls)
                out[j].append({1: 1.0, 0: 0.5, -1: 0.0}[b.reward(self.side)])
        return out

    def _best(self, view: View, cands: list, apply, default: int, first: bool = False,
              incoming: Move | None = None, zs: list[float] | None = None):
        self.decisions += 1
        self.belief.see(view)   # an opponent that 0-turn switched in this turn is already on screen
        values = self._values(view, cands, apply, first, incoming)
        best, best_gain = default, 0.0
        for j in range(len(cands)):
            if j == default:
                continue
            diffs = [a - d for a, d in zip(values[j], values[default])]
            mean = sum(diffs) / len(diffs)
            se = (sum((x - mean) ** 2 for x in diffs) / max(len(diffs) - 1, 1) / len(diffs)) ** 0.5
            if mean > (zs[j] if zs else self.z) * se and mean > best_gain:
                best, best_gain = j, mean
        return cands[best]

    def _values(self, view: View, cands: list, apply, first: bool, incoming: Move | None) -> list[list[float]]:
        """Each candidate's rollout values, on common hypotheses and seeds."""
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
        return values
