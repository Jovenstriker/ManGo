"""How real opponents shield and throw, learned from your recorded battles.

Two small logistic models over features of the situation and its history:

  shield  P(shield) when one of your charged moves comes at them and they have a shield
  throw   P(hold, their cheaper charged move, their bigger one) on a turn they choose an action
          with energy for at least the cheaper one

The features (`features_*`) cover:
  the hit and the moves  HP, energy, whether a hit knocks out, its share of HP, whether it's the
                         thrower's cheaper move (a bait), whether a throw would knock you out
  planning ahead         Pokémon left on each side, the HP left on their bench, the matchup
  your energy, timing    your energy (they can count it), whether your charged move is ready,
                         whether your fast move lands this turn or next
  history                shields used, whether their last throw was shielded, whether they
                         shielded the last hit they could have, charged moves thrown and taken

They're read off a Battle, so the same model runs on the rebuilt recordings it's fitted on
(battle_turns.battle_at) and inside the planner's rollouts. `Learned` plays an opponent with it.

The fitted model comes from your recordings, so it lives in data/local/ (git-ignored).
"""
from __future__ import annotations

import json
import math
import random
from pathlib import Path

from .battle import CHARGED, FAST, Battle
from .gamedata import DATA_DIR, Move, damage
from .policies import Heuristic, turns_to_ko

MODEL = DATA_DIR / "local" / "opponent_model.json"

COMMON = ["bias", "hp", "their hp", "shields", "their shields", "left", "their left", "bench hp",
          "matchup", "energy", "their energy", "their charged ready", "their fast lands soon"]
SHIELD = COMMON + ["knocks out", "share of hp", "is their cheaper move", "hits taken", "shielded last one"]
THROW = COMMON + ["big move ready", "cheap knocks out", "big knocks out", "last throw shielded", "throws so far"]
CHOICES = ("hold", "cheap", "big")


def _hist(v: bool | None) -> float:
    return 0.5 if v is None else float(v)


def _matchup(b: Battle, s: int) -> float:
    me, foe = b.sides[s].mon, b.sides[1 - s].mon
    mine = turns_to_ko(me.species, me.fast, me.charged, foe.species, max(foe.hp, 1))
    theirs = turns_to_ko(foe.species, foe.fast, foe.charged, me.species, max(me.hp, 1))
    return max(-2.0, min(2.0, math.log(theirs / mine)))


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


def fit_logistic(X: list[list[float]], y: list[int], l2: float = 1.0, steps: int = 1500, lr: float = 0.5) -> list[float]:
    """Weights maximizing the L2-penalized log-likelihood, by full-batch gradient descent."""
    w = [0.0] * len(X[0])
    n = len(X)
    for _ in range(steps):
        grad = [l2 * wi / n if i else 0.0 for i, wi in enumerate(w)]
        for x, t in zip(X, y):
            err = _sigmoid(sum(a * b for a, b in zip(w, x))) - t
            for i, xi in enumerate(x):
                grad[i] += err * xi / n
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
    def __init__(self, shield: list[float], throw: list[list[float]]):
        self.shield, self.throw = shield, throw

    def p_shield(self, b: Battle, s: int, move: Move) -> float:
        return _sigmoid(sum(a * x for a, x in zip(self.shield, features_shield(b, s, move))))

    def p_throw(self, b: Battle, s: int) -> list[float]:
        """P(hold, cheap, big) for side s's active Pokémon, which has at least two charged moves."""
        x = features_throw(b, s)
        return _softmax([sum(a * v for a, v in zip(row, x)) for row in self.throw], allowed_throws(b.sides[s].mon))

    def save(self, path: Path = MODEL) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"shield": dict(zip(SHIELD, self.shield)),
                                    "throw": [dict(zip(THROW, row)) for row in self.throw]}, indent=1))

    @classmethod
    def load(cls, path: Path = MODEL) -> OpponentModel | None:
        if not path.exists():
            return None
        raw = json.loads(path.read_text())
        return cls([raw["shield"][f] for f in SHIELD], [[row[f] for f in THROW] for row in raw["throw"]])


_cached: dict[str, OpponentModel | None] = {}


def default_model() -> OpponentModel | None:
    if "model" not in _cached:
        _cached["model"] = OpponentModel.load()
    return _cached["model"]


# Playing ------------------------------------------------------------------------------------

class Learned:
    """An opponent that shields and throws as the learned model predicts, sampling its choices,
    and switches and replaces like the baiter heuristic. Reads the battle it's in, so it sees
    what a player counting energy would."""

    def __init__(self, model: OpponentModel, battle: Battle, side: int, seed: int | None = None):
        self.model, self.b, self.side = model, battle, side
        self.base = Heuristic("baiter", eps=0.0, seed=seed)
        self.rng = random.Random(seed)
        self.name = "learned"

    def act(self, view):
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

    def replace(self, view) -> int:
        return self.base.replace(view)
