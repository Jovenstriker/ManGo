"""POMCP-style planning: the rollout planner, with a search tree over your later decisions.

The rollout planner (planner.py) looks one decision ahead. It tries each option now and then
plays the fixed rollout policy for both sides to the end, so an option is valued as "this now,
then the rollout policy", not "this now, then play well". More rollouts make that estimate less
noisy but no less biased. An option whose payoff depends on what you do afterwards (a lead
switch that sets up a shield bait, a hold that sets up a farm down) is undervalued.

POMCP (Silver and Veness, 2010) grows a search tree from the current belief instead. Each
simulation samples a full hidden state from the particle belief, plays down the tree choosing
actions with UCB1, adds one node where it leaves the tree, finishes with the rollout policy,
and backs the result up the path. Decisions further down are conditioned on what was observed
on the way, so the tree learns how to follow up each option.

Here:
- **The root is the rollout planner's.** Every root option is played on the same sampled
  hypothesis and seed in each round (common random numbers), and the choice is the same z-test
  against the default policy. Only what happens after the first decision changes: your later
  decisions follow the tree, one per option, while it has visits there, then the rollout
  policy. With `depth=0` this is exactly the rollout planner.
- **Nodes are decisions that matter,** not every half-second turn: a free turn where a
  charged move is affordable, a switch moment (a new matchup or a 0-turn switch), or a catch
  window (their counted energy within one fast move of a throw), plus shield prompts and
  replacements. Between them, fast moves. That keeps a battle to tens of nodes, not hundreds.
- **Observations are what's on screen at the next decision,** coarsened so that similar
  positions share a node: who's in on both sides, shields, HP in quarters, which charged moves
  are affordable, whether a switch is possible, whether their throw is near. Exact energy and
  damage would make every node unique.
- **The opponent is part of the simulation,** played by each particle's style (or the learned
  model), as in the rollouts. So this is planning against the belief about them, not a
  game-theoretic search.
- **The tree starts as the rollout policy and moves off it on evidence.** Actions are chosen
  by PUCT (as in AlphaZero): Q(a) + c·P(a)·√N / (1 + n(a)), with prior P = `lean` on the
  rollout policy's choice and the rest shared by the others. An action not tried yet counts as
  the node's mean value less `fpu`. Plain UCB1 would try every action once at every node,
  and with a few dozen visits a node, those tries (a random switch, say) would drag down the
  value of the option at the root. Values are the rollout planner's: ±1 for the result, plus
  the HP margin.
"""
from __future__ import annotations

import math

from .battle import FAST, WAIT, Battle, View
from .gamedata import Move
from .planner import Planner, _Catch, _Farm, _First, next_throw


class _ActionNode:
    __slots__ = ("n", "total", "children")

    def __init__(self):
        self.n, self.total, self.children = 0, 0.0, {}

    @property
    def q(self) -> float:
        return self.total / self.n if self.n else 0.0


class _DecisionNode:
    __slots__ = ("n", "total", "actions")

    def __init__(self):
        self.n, self.total, self.actions = 0, 0.0, {}


def _quarter(hp: int, max_hp: int) -> int:
    return 0 if hp <= 0 else 1 + min(3, 4 * hp // max(max_hp, 1))


def _seen(view: View) -> tuple:
    """What's on screen that matters for the next decision, coarsened."""
    me, mon = view.me, view.mon
    return (mon.species.id, view.foe_species.id, me.shields, view.foe_shields,
            _quarter(mon.hp, mon.max_hp), _quarter(view.foe_hp, view._b.sides[1 - view.side].mon.max_hp),
            me.remaining(), view.foe_remaining)


class _TreeCtl:
    """Our side in one simulation: decisions follow the search tree while it has visits there,
    then the rollout policy."""

    def __init__(self, search: "POMCP", root: _ActionNode, battle: Battle, style: str, rollout):
        self.s, self.b, self.style, self.rollout = search, battle, style, rollout
        self.at = root            # the action node whose consequences we're in
        self.path = [root]        # every node this simulation passed through, for the backup
        self.depth = 0
        self.live = search.max_depth > 0

    def _choose(self, key, cands, default):
        """The tree's choice at a decision point, or None for the rollout policy's."""
        if not self.live or len(cands) < 2:
            return None
        node = self.at.children.get(key)
        if node is None:
            # New: add it, take the rollout policy's action there, and roll out from it.
            node = self.at.children[key] = _DecisionNode()
            node.n = 1
            self.at = node.actions[default] = _ActionNode()
            self.path += [node, self.at]
            self.live = False
            return None
        mean = node.total / node.n
        node.n += 1
        root_n = math.sqrt(node.n)
        others = (1 - self.s.lean) / (len(cands) - 1)
        cands = [default] + [a for a in cands if a != default]

        def score(a):
            an = node.actions.get(a)
            q = an.q if an is not None and an.n else mean - self.s.fpu
            return q + self.s.c * (self.s.lean if a == default else others) * root_n / (1 + (an.n if an else 0))

        choice = max(cands, key=score)
        self.at = node.actions.setdefault(choice, _ActionNode())
        self.path += [node, self.at]
        self.depth += 1
        if self.depth >= self.s.max_depth:
            self.live = False
        return choice

    def act(self, view):
        default = self.rollout.act(view)
        if not self.live:
            return default
        legal = view.legal_actions()
        cands = [a for a in legal if a[0] in ("fast", "charged")]
        switches = [a for a in legal if a[0] == "switch"]
        moment = max(view.me.entered, view.foe_entered) >= view.turn - 2 or view.turn == view.last_charged + 1
        near = bool(switches) and next_throw(self.b, 1 - view.side, self.style) is not None
        if switches and (moment or near):
            cands += switches
        if near:
            cands.append(WAIT)
        if len(cands) < 2:
            return default
        if default not in cands:
            cands.append(default)
        key = ("act", _seen(view), tuple(a[1] for a in cands if a[0] == "charged"), bool(switches), near)
        choice = self._choose(key, cands, default)
        return default if choice is None else choice

    def shield(self, view, move: Move):
        default = self.rollout.shield(view, move)
        if not self.live or view.me.shields == 0:
            return default
        choice = self._choose(("shield", move.id, _seen(view)), [False, True], bool(default))
        return default if choice is None else choice

    def replace(self, view):
        default = self.rollout.replace(view)
        bench = view.me.bench()
        if not self.live or len(bench) < 2:
            return default
        choice = self._choose(("replace", _seen(view), tuple(view.me.mons[i].species.id for i in bench)),
                              bench, default)
        return default if choice is None else choice


class _Handoff:
    """Under a catch: its fast moves are the rollout policy's; once it's done, the tree's."""

    def __init__(self, tree: _TreeCtl, rollout):
        self.tree, self.rollout, self.catch = tree, rollout, None

    def act(self, view):
        return self.tree.act(view) if self.catch is None or self.catch.slot is None else self.rollout.act(view)

    def shield(self, view, move):
        return self.tree.shield(view, move)

    def replace(self, view):
        return self.tree.replace(view)


class POMCP(Planner):
    """The rollout planner with a search tree over your later decisions (see the module docs).
    `rollouts` is the number of rounds: each root option is played once a round, as in the
    rollout planner, so the cost per decision is about the same."""

    def __init__(self, *args, depth: int = 8, c: float = 1.0, lean: float = 0.5, fpu: float = 0.1, **kwargs):
        super().__init__(*args, **kwargs)
        self.max_depth, self.c, self.lean, self.fpu = depth, c, lean, fpu

    def _tree_controllers(self, first, root: _ActionNode, seed: int, style: str, b: Battle):
        rollout = self._rollout_policy(seed, style, b)
        tree = _TreeCtl(self, root, b, style, rollout)
        if first is not None and first[0] == "catch":
            hand = _Handoff(tree, rollout)
            hand.catch = _Catch(first[1], hand, b, self.side, style)
            mine = _First(WAIT, hand.catch)
        elif first is not None and first[0] == "farm":
            mine = _Farm(tree, b, self.side)
        elif first is not None:
            mine = _First(first, tree)
        else:
            mine = tree
        theirs = self._theirs(seed, style, b)
        return ([mine, theirs] if self.side == 0 else [theirs, mine]), tree

    def _playouts(self, view, cands, apply, first, incoming, n, roots, score):
        out = [[] for _ in cands]
        for _ in range(n):
            p = self.belief.sample(self.rng)
            seed = self.rng.randrange(1 << 30)
            start = self.belief.determinize(view, p, incoming=incoming)
            for j, c in enumerate(cands):
                b = start.clone(seed)
                ctrls, tree = self._tree_controllers(c if first else None, roots[j], seed, p.style, b)
                apply(b, c, ctrls)
                b.play(ctrls)
                v = self._value(b)
                for node in tree.path:
                    node.n += 1
                    node.total += v
                out[j].append(score(b, v))
        return out

    def _values(self, view, cands, apply, first, incoming):
        roots = [_ActionNode() for _ in cands]
        return self._playouts(view, cands, apply, first, incoming, self.rollouts, roots, lambda b, v: v)

    def outcomes(self, view, cands, apply=None, first=False, incoming=None, rollouts=None, keep=None):
        self.belief.see(view)
        if keep is not None:
            roots = keep.setdefault("roots", [_ActionNode() for _ in cands])
        else:
            roots = [_ActionNode() for _ in cands]
        win = {1: 1.0, 0: 0.5, -1: 0.0}
        return self._playouts(view, cands, apply or (lambda b, a, ctrls: None), first, incoming,
                              rollouts or self.rollouts, roots, lambda b, v: win[b.reward(self.side)])
