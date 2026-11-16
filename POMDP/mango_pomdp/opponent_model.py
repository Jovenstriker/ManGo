"""How real opponents shield, throw, switch and bring Pokémon in, learned from your recorded battles.

Four small logistic models over features of the situation and its history:

  shield  P(shield) when one of your charged moves comes at them and they have a shield
  throw   P(hold, their cheaper charged move, their bigger one) on a turn they choose an action
          with energy for at least the cheaper one
  switch  P(switch) on a free turn when they could switch
  pick    which Pokémon they bring in, on a switch or after a faint (a choice among the ones left)

The features (`features_*`) cover:
  the hit and the moves  HP, energy, whether a hit knocks out, its share of HP, whether it's the
                         thrower's cheaper move (a bait), whether a throw would knock you out
  planning ahead         Pokémon left on each side, the HP left on their bench, the matchup
  your energy, timing    your energy (they can count it), whether your charged move is ready,
                         whether your fast move lands this turn or next
  history                shields used, whether their last throw was shielded, whether they
                         shielded the last hit they could have, charged moves thrown and taken
  switching              how much better their best Pokémon in the back matches up, whether a
                         switch is free now (right after a charged move), whether the matchup
                         just started; for a pick, each one's matchup, HP and energy

They're read off a Battle, so the same model runs on the rebuilt recordings it's fitted on
(battle_turns.battle_at) and inside the planner's rollouts. `Learned` plays an opponent with it.

The fitted model comes from your recordings, so it lives in data/local/ (git-ignored).
"""
from __future__ import annotations

import json
import math
import random
from pathlib import Path

from .battle import CHARGED, FAST, SWITCH, Battle, View
from .gamedata import DATA_DIR, Move, damage
from .policies import Heuristic, turns_to_ko

MODEL = DATA_DIR / "local" / "opponent_model.json"

COMMON = ["bias", "hp", "their hp", "shields", "their shields", "left", "their left", "bench hp",
          "matchup", "energy", "their energy", "their charged ready", "their fast lands soon"]
SHIELD = COMMON + ["knocks out", "share of hp", "is their cheaper move", "hits taken", "shielded last one"]
THROW = COMMON + ["big move ready", "cheap knocks out", "big knocks out", "last throw shielded", "throws so far"]
SWITCH_F = COMMON + ["matchup gap", "free switch", "new matchup"]
PICK = ["matchup", "hp", "energy"]   # per Pokémon they could bring in; no bias, it's a choice among them
CHOICES = ("hold", "cheap", "big")


def _hist(v: bool | None) -> float:
    return 0.5 if v is None else float(v)


def _mon_matchup(me, foe) -> float:
    """log(turns `foe` needs to KO `me` / turns `me` needs to KO `foe`), clipped to ±2."""
    mine = turns_to_ko(me.species, me.fast, me.charged, foe.species, max(foe.hp, 1))
    theirs = turns_to_ko(foe.species, foe.fast, foe.charged, me.species, max(me.hp, 1))
    return max(-2.0, min(2.0, math.log(theirs / mine)))


def _matchup(b: Battle, s: int) -> float:
    return _mon_matchup(b.sides[s].mon, b.sides[1 - s].mon)


def _common(b: Battle, s: int) -> list[float]:
    side, other = b.sides[s], b.sides[1 - s]
    me, foe = side.mon, other.mon
    bench = [m.hp / m.max_hp for i, m in enumerate(side.mons) if i != side.active and m.hp > 0]
    foe_cheap = min((c.energy for c in foe.charged), default=101)
    return [1.0, me.hp / me.max_hp, foe.hp / foe.max_hp, side.shields / 2, other.shields / 2,
            side.remaining() / 3, other.remaining() / 3, sum(bench) / len(bench) if bench else 0.0,
            _matchup(b, s) / 2, me.energy / 100, foe.energy / 100, float(foe.energy >= foe_cheap),
            float(other.fast_due in (b.turn, b.turn + 1))]


def cheap_big(mon) -> tuple[int, int] | None:
    """Indexes of the cheaper and bigger charged move, or None with fewer than two."""
    if len(mon.charged) < 2:
        return None
    a, c = mon.charged[0].energy, mon.charged[1].energy
    return (0, 1) if a <= c else (1, 0)


def features_shield(b: Battle, s: int, move: Move) -> list[float]:
    side, other = b.sides[s], b.sides[1 - s]
    me, foe = side.mon, other.mon
    hit = damage(move, foe.species, me.species, foe.atk_stage, me.def_stage)
    order = cheap_big(foe)
    is_cheap = bool(order) and foe.charged[order[0]].energy < foe.charged[order[1]].energy and \
        foe.base_move(foe.charged[order[0]]).id == foe.base_move(move).id
    return _common(b, s) + [float(hit >= me.hp), min(hit / max(me.hp, 1), 2.0) / 2, float(is_cheap),
                            min(me.taken, 3) / 3, _hist(side.shielded_last)]


def features_throw(b: Battle, s: int) -> list[float]:
    side, other = b.sides[s], b.sides[1 - s]
    me, foe = side.mon, other.mon
    cheap, big = cheap_big(me)
    dmg = [damage(c, me.species, foe.species, me.atk_stage, foe.def_stage) for c in me.charged]
    return _common(b, s) + [float(me.energy >= me.charged[big].energy), float(dmg[cheap] >= foe.hp),
                            float(dmg[big] >= foe.hp), _hist(side.last_shielded), min(me.thrown, 3) / 3]


def features_switch(b: Battle, s: int) -> list[float]:
    side, other = b.sides[s], b.sides[1 - s]
    now = _matchup(b, s)
    gap = max((_mon_matchup(side.mons[i], other.mon) for i in side.bench()), default=now) - now
    return _common(b, s) + [gap / 4, float(b.last_charged == b.turn - 1),
                            float(max(side.entered, other.entered) >= b.turn - 2)]


def features_pick(b: Battle, s: int, i: int) -> list[float]:
    mon, foe = b.sides[s].mons[i], b.sides[1 - s].mon
    return [_mon_matchup(mon, foe) / 2, mon.hp / mon.max_hp, mon.energy / 100]


def allowed_throws(mon) -> list[bool]:
    cheap, big = cheap_big(mon)
    return [True, mon.energy >= mon.charged[cheap].energy, mon.energy >= mon.charged[big].energy]


# Fitting ------------------------------------------------------------------------------------

def _sigmoid(z: float) -> float:
    return 1 / (1 + math.exp(-max(-30.0, min(30.0, z))))


def _softmax(zs: list[float], mask: list[bool]) -> list[float]:
    top = max(z for z, m in zip(zs, mask) if m)
    es = [math.exp(z - top) if m else 0.0 for z, m in zip(zs, mask)]
    total = sum(es)
    return [e / total for e in es]


def _solve(A: list[list[float]], b: list[float]) -> list[float]:
    """x with A x = b, by Gaussian elimination with partial pivoting."""
    n = len(b)
    M = [row[:] + [v] for row, v in zip(A, b)]
    for c in range(n):
        piv = max(range(c, n), key=lambda r: abs(M[r][c]))
        M[c], M[piv] = M[piv], M[c]
        if abs(M[c][c]) < 1e-12:
            continue
        for r in range(c + 1, n):
            f = M[r][c] / M[c][c]
            if f:
                M[r] = [a - f * bb for a, bb in zip(M[r], M[c])]
    x = [0.0] * n
    for c in range(n - 1, -1, -1):
        if abs(M[c][c]) >= 1e-12:
            x[c] = (M[c][n] - sum(M[c][k] * x[k] for k in range(c + 1, n))) / M[c][c]
    return x


def fit_logistic(X: list[list[float]], y: list[int], l2: float = 1.0, iters: int = 30) -> list[float]:
    """Weights maximizing the log-likelihood with an L2 penalty on all but the first (the bias),
    by Newton's method. The objective is the mean log loss plus l2 / (2n) times the squared weights."""
    d, n = len(X[0]), len(X)
    w = [0.0] * d
    for _ in range(iters):
        g = [l2 * wi / n if i else 0.0 for i, wi in enumerate(w)]
        H = [[(l2 / n if i else 1e-9) if i == j else 0.0 for j in range(d)] for i in range(d)]
        for x, t in zip(X, y):
            p = _sigmoid(sum(a * b for a, b in zip(w, x)))
            e, r = (p - t) / n, p * (1 - p) / n
            for i, xi in enumerate(x):
                if xi:
                    g[i] += e * xi
                    row, rx = H[i], r * xi
                    for j, xj in enumerate(x):
                        row[j] += rx * xj
        step = _solve(H, g)
        w = [wi - si for wi, si in zip(w, step)]
        if max(abs(v) for v in step) < 1e-7:
            break
    return w


def fit_choice(groups: list[list[list[float]]], chosen: list[int], l2: float = 1.0,
               steps: int = 2000, lr: float = 1.0) -> list[float]:
    """A conditional logit: one weight vector scores each option in a group (the Pokémon they could
    bring in), and P(option) is a softmax over the group. Gradient descent on the penalized log loss."""
    d, n = len(groups[0][0]), len(groups)
    w = [0.0] * d
    for _ in range(steps):
        grad = [l2 * wi / n for wi in w]
        for opts, c in zip(groups, chosen):
            p = _softmax([sum(a * b for a, b in zip(w, x)) for x in opts], [True] * len(opts))
            for k, x in enumerate(opts):
                err = (p[k] - (k == c)) / n
                for i, xi in enumerate(x):
                    grad[i] += err * xi
        w = [wi - lr * g for wi, g in zip(w, grad)]
    return w


def fit_softmax(X: list[list[float]], y: list[int], masks: list[list[bool]], l2: float = 1.0,
                steps: int = 1500, lr: float = 0.5) -> list[list[float]]:
    """One weight vector per choice (the first is fixed at 0), with unavailable choices masked."""
    k, d, n = len(masks[0]), len(X[0]), len(X)
    W = [[0.0] * d for _ in range(k)]
    for _ in range(steps):
        grad = [[l2 * w / n if i else 0.0 for i, w in enumerate(row)] for row in W]
        for x, t, mask in zip(X, y, masks):
            p = _softmax([sum(a * b for a, b in zip(row, x)) for row in W], mask)
            for c in range(1, k):
                err = p[c] - (c == t)
                for i, xi in enumerate(x):
                    grad[c][i] += err * xi / n
        W = [W[0]] + [[w - lr * g for w, g in zip(W[c], grad[c])] for c in range(1, k)]
    return W


class OpponentModel:
    def __init__(self, shield: list[float], throw: list[list[float]], switch: list[float] | None = None,
                 pick: list[float] | None = None):
        self.shield, self.throw, self.switch, self.pick = shield, throw, switch, pick

    def p_shield(self, b: Battle, s: int, move: Move) -> float:
        return _sigmoid(sum(a * x for a, x in zip(self.shield, features_shield(b, s, move))))

    def p_throw(self, b: Battle, s: int) -> list[float]:
        """P(hold, cheap, big) for side s's active Pokémon, which has at least two charged moves."""
        x = features_throw(b, s)
        return _softmax([sum(a * v for a, v in zip(row, x)) for row in self.throw], allowed_throws(b.sides[s].mon))

    def p_switch(self, b: Battle, s: int) -> float:
        """P(side s switches) on a free turn when it can."""
        return _sigmoid(sum(a * x for a, x in zip(self.switch, features_switch(b, s))))

    def p_pick(self, b: Battle, s: int, options: list[int]) -> list[float]:
        """P(each of `options`, indexes into side s's team, is the one brought in)."""
        return _softmax([sum(a * x for a, x in zip(self.pick, features_pick(b, s, i))) for i in options],
                        [True] * len(options))

    def save(self, path: Path = MODEL) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        raw = {"shield": dict(zip(SHIELD, self.shield)), "throw": [dict(zip(THROW, row)) for row in self.throw]}
        if self.switch is not None:
            raw["switch"] = dict(zip(SWITCH_F, self.switch))
        if self.pick is not None:
            raw["pick"] = dict(zip(PICK, self.pick))
        path.write_text(json.dumps(raw, indent=1))

    @classmethod
    def load(cls, path: Path = MODEL) -> OpponentModel | None:
        if not path.exists():
            return None
        raw = json.loads(path.read_text())
        return cls([raw["shield"][f] for f in SHIELD], [[row[f] for f in THROW] for row in raw["throw"]],
                   [raw["switch"][f] for f in SWITCH_F] if "switch" in raw else None,
                   [raw["pick"][f] for f in PICK] if "pick" in raw else None)


_cached: dict[str, OpponentModel | None] = {}


def default_model() -> OpponentModel | None:
    if "model" not in _cached:
        _cached["model"] = OpponentModel.load()
    return _cached["model"]


# Playing ------------------------------------------------------------------------------------

class Learned:
    """An opponent that shields, throws, switches and brings Pokémon in as the learned model
    predicts, sampling its choices. A model fitted without the switch or pick part switches and
    replaces like the baiter heuristic instead, and a Pokémon with one charged move throws like
    it. Reads the battle it's in, so it sees what a player counting energy would."""

    def __init__(self, model: OpponentModel, battle: Battle, side: int, seed: int | None = None):
        self.model, self.b, self.side = model, battle, side
        self.base = Heuristic("baiter", eps=0.0, seed=seed, switches=model.switch is None)
        self.rng = random.Random(seed)
        self.name = "learned"

    def act(self, view):
        if self.model.switch is not None and view.can_switch:
            if self.rng.random() < self.model.p_switch(self.b, self.side):
                return SWITCH(self._pick(view.me.bench()))
        a = self.base.act(view)
        mon = view.mon
        if a[0] == "switch" or cheap_big(mon) is None or not allowed_throws(mon)[1]:
            return a
        p = self.model.p_throw(self.b, self.side)
        choice = self.rng.choices(range(3), p)[0]
        if choice == 0:
            return FAST
        cheap, big = cheap_big(mon)
        return CHARGED(cheap if choice == 1 else big)

    def shield(self, view, move) -> bool:
        if view.me.shields == 0 or view.mon.form == "disguised":
            return False
        return self.rng.random() < self.model.p_shield(self.b, self.side, move)

    def _pick(self, options: list[int]) -> int:
        if len(options) == 1:
            return options[0]
        if self.model.pick is None:
            return self.base.replace(View(self.b, self.side))
        return self.rng.choices(options, self.model.p_pick(self.b, self.side, options))[0]

    def replace(self, view) -> int:
        return self._pick(view.me.bench())
