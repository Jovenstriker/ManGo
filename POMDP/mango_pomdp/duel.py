"""Solving 1v1 matchups exactly.

A 1v1 with both movesets known is the battle PvPoke's sandbox shows. Both Pokémon fast move to
build energy. Each time a fast move finishes, its player decides: one more fast move, or a charged
move they can afford now (holding energy is just picking the fast move again). When a charged
move comes in, the defender decides whether to shield it. Winning is pacing: how many fast moves
before each throw, which move, and which hits to shield.

The rules are PvPoke's guide to fast move registration (see battle.py). Two of them shape the
state space:
  • a fast move registers on its last turn, so between charged moves each side's fast moves
    follow a fixed rhythm set by its duration;
  • a charged move interrupts every fast move in progress (they register on the spot) and resets
    both cooldowns, so after every charged move both sides start the rhythm over together.
So a battle state is just HP, energy, shields and buff stages for both sides, plus the turn's place
in the rhythm: turns since the last charged move, mod lcm(fast move durations). On turn k a side
can act iff k is a multiple of its duration.

With energy counted (as ManGo does) nothing is hidden, but both players pick their action for a
turn at the same time. That makes a 1v1 a finite zero-sum stochastic game, solved here exactly by
backward induction:
  • a turn where one side can choose is a max (or min) node,
  • a turn where both can is a matrix game, solved for its mixed equilibrium,
  • a shield decision is a max/min node for the defender after seeing the move,
  • buff chances and CMP ties are chance nodes.
Only states at the start of the rhythm are memoized; the turns of one rhythm cycle are walked as a
chain. Every fast and charged move does at least 1 damage, so the recursion always ends. The
battle clock is ignored (a 1v1 never gets near 4 minutes).

Payoff to side 0: (1 − w)·result + w·(its HP% left − their HP% left), result +1 / 0 / −1, w = 0.1.
Any win beats any loss; among wins, more HP left is better (PvPoke's battle rating is
500 + 500·(HP% left − their HP% left)).

Playing the equilibrium can't be exploited: against any opponent at all, side 0 scores at least
the game value in expectation, and exactly that or better when its strategy is pure and no buff
is random.
"""
from __future__ import annotations

import math
import random
import sys
from dataclasses import dataclass
from itertools import combinations

from .battle import CHARGED, FAST, Battle, Mon, View
from .gamedata import MAX_ENERGY, MAX_STAGE, GameData, Move, Species, damage, stage_multiplier

# A state is a tuple of 10 ints: field + side.
HP, E, SH, ATK, DEF = 0, 2, 4, 6, 8
FAST_ACTION = -1   # an action is FAST_ACTION, a charged move index, or None (busy this turn)

sys.setrecursionlimit(max(sys.getrecursionlimit(), 50_000))


@dataclass(frozen=True)
class Fighter:
    species: Species
    fast: Move
    charged: tuple[Move, ...]

    @classmethod
    def of(cls, gd: GameData, species_id: str, moves: list[str] | None = None) -> Fighter:
        """PvPoke's recommended moveset unless `moves` ([fast, charged, charged]) is given."""
        if moves:
            return cls(gd.species[species_id], gd.moves[moves[0]], tuple(gd.moves[m] for m in moves[1:]))
        fast, charged = gd.recommended(species_id)
        return cls(gd.species[species_id], fast, charged)

    def mon(self) -> Mon:
        return Mon(self.species, self.fast, self.charged)

    def action_name(self, a: int | None) -> str:
        return "fast move" if a in (FAST_ACTION, None) else self.charged[a].name

    def __str__(self) -> str:
        return f"{self.species.name} ({self.fast.name} / {' + '.join(c.name for c in self.charged)})"


# Zero-sum matrix games ---------------------------------------------------------------------

def solve_matrix(M: list[list[float]]) -> tuple[list[float], list[float], float]:
    """Equilibrium (x, y, value) of a zero-sum game, ≤ 3 strategies a side. M[i][j] pays the row player."""
    m, n = len(M), len(M[0])
    i = max(range(m), key=lambda r: min(M[r]))
    j = min(range(n), key=lambda c: max(M[r][c] for r in range(m)))
    if min(M[i]) >= max(M[r][j] for r in range(m)) - 1e-12:
        return [float(r == i) for r in range(m)], [float(c == j) for c in range(n)], M[i][j]
    x = _maximin(M)
    y = _maximin([[-M[r][c] for r in range(m)] for c in range(n)])
    return x, y, min(sum(x[r] * M[r][c] for r in range(m)) for c in range(n))


def _maximin(M: list[list[float]]) -> list[float]:
    """The row player's optimal mix. min_j (xM)_j is concave and piecewise linear over the simplex,
    so its maximum is at a point where m − 1 of {x_i = 0} ∪ {column j pays the same as column k} hold."""
    m, n = len(M), len(M[0])
    if m == 1:
        return [1.0]
    forms = [[float(r == i) for r in range(m)] for i in range(m)]
    forms += [[M[r][j] - M[r][k] for r in range(m)] for j in range(n) for k in range(j + 1, n)]
    best, best_x = -math.inf, None
    for combo in combinations(forms, m - 1):
        x = _linsolve([list(f) for f in combo] + [[1.0] * m], [0.0] * (m - 1) + [1.0])
        if x is None or min(x) < -1e-9:
            continue
        x = [max(0.0, v) for v in x]
        total = sum(x)
        x = [v / total for v in x]
        val = min(sum(x[r] * M[r][c] for r in range(m)) for c in range(n))
        if val > best + 1e-12:
            best, best_x = val, x
    return best_x


def _linsolve(A: list[list[float]], b: list[float]) -> list[float] | None:
    n = len(A)
    A = [row + [b[i]] for i, row in enumerate(A)]
    for col in range(n):
        piv = max(range(col, n), key=lambda r: abs(A[r][col]))
        if abs(A[piv][col]) < 1e-12:
            return None
        A[col], A[piv] = A[piv], A[col]
        for r in range(n):
            if r != col:
                f = A[r][col] / A[col][col]
                A[r] = [a - f * c for a, c in zip(A[r], A[col])]
    return [A[i][n] / A[i][i] for i in range(n)]


# The solver ----------------------------------------------------------------------------------

@dataclass
class Strategy:
    """Both sides' equilibrium play on one turn."""
    actions: tuple[list, list]          # per side: FAST_ACTION / charged indices, or [None] if busy
    mix: tuple[list[float], list[float]]
    payoffs: list[list[float]]          # payoffs[i][j]: side 0 plays actions[0][i], side 1 actions[1][j]
    value: float


class Duel:
    def __init__(self, a: Fighter, b: Fighter, margin_weight: float = 0.1):
        self.f = (a, b)
        self.n = (a.fast.turns, b.fast.turns)
        self.period = math.lcm(*self.n)
        self.w = margin_weight
        self.memo: dict[tuple, float] = {}
        self._dmg: dict[tuple, int] = {}

    def start(self, shields: tuple[int, int] = (1, 1), energy: tuple[int, int] = (0, 0)) -> tuple:
        return (self.f[0].species.hp, self.f[1].species.hp, *energy, *shields, 0, 0, 0, 0)

    # Values ---------------------------------------------------------------------------------

    def value(self, s: tuple, k: int = 0) -> float:
        """Game value for side 0 from state s on turn k of the rhythm."""
        if k:
            return self._cycle(s, k)
        v = self.memo.get(s)
        if v is None:
            v = self.memo[s] = self._cycle(s, 0)
        return v

    def strategy(self, s: tuple, k: int) -> Strategy:
        acts = self.actions(s, k)
        cont = None
        rows = []
        for a0 in acts[0]:
            row = []
            for a1 in acts[1]:
                if _quiet(a0) and _quiet(a1):
                    if cont is None:
                        cont = self._continue(s, k)
                    row.append(cont)
                else:
                    row.append(self._resolve(s, k, a0, a1))
            rows.append(row)
        x, y, v = solve_matrix(rows)
        return Strategy(acts, (x, y), rows, v)

    def actions(self, s, k: int) -> tuple[list, list]:
        out = []
        for x in (0, 1):
            if k % self.n[x]:
                out.append([None])
            else:
                out.append([FAST_ACTION] + [i for i, c in enumerate(self.f[x].charged) if s[E + x] >= c.energy])
        return out[0], out[1]

    def hit(self, st, x: int, i: int, rest: list, shield: bool) -> float:
        """Side x's charged move i landing on st (energy already paid, fast moves already registered),
        shielded or not, then whatever charged moves are still queued this turn."""
        o = 1 - x
        move = self.f[x].charged[i]
        b = list(st)
        if shield:
            b[SH + o] -= 1
        b[HP + o] = max(0, b[HP + o] - (1 if shield else self._damage(x, move, b[ATK + x], b[DEF + o])))
        p = move.buff_chance
        if p <= 0:
            return self._charges(b, rest, ())
        buffed = list(b)
        buffed[ATK + x] = _clamp(buffed[ATK + x] + move.buff_self[0])
        buffed[DEF + x] = _clamp(buffed[DEF + x] + move.buff_self[1])
        buffed[ATK + o] = _clamp(buffed[ATK + o] + move.buff_opponent[0])
        buffed[DEF + o] = _clamp(buffed[DEF + o] + move.buff_opponent[1])
        if p >= 1:
            return self._charges(buffed, rest, ())
        return p * self._charges(buffed, rest, ()) + (1 - p) * self._charges(b, rest, ())

    # One rhythm cycle: turns k .. period − 1 ---------------------------------------------------

    def _cycle(self, s: tuple, k: int) -> float:
        chain = []
        st = list(s)
        end = None
        for j in range(k, self.period):
            chain.append(st)
            st = self._quiet_turn(st, j)
            if st[HP] <= 0 or st[HP + 1] <= 0:
                end = self._terminal(st)
                break
        if end is None:
            end = self.value(tuple(st))
        v = end
        for idx in range(len(chain) - 1, -1, -1):
            v = self._turn(chain[idx], k + idx, v)
        return v

    def _continue(self, s, k: int) -> float:
        """Value if nobody throws on turn k."""
        st = self._quiet_turn(list(s), k)
        if st[HP] <= 0 or st[HP + 1] <= 0:
            return self._terminal(st)
        return self.value(tuple(st), (k + 1) % self.period)

    def _quiet_turn(self, st: list, k: int) -> list:
        """Turn k with no charged move: fast moves due register."""
        st = list(st)
        for x in (0, 1):
            if k % self.n[x] == self.n[x] - 1:
                self._register(st, x)
        return st

    def _turn(self, st: list, k: int, cont: float) -> float:
        acts = self.actions(st, k)
        if len(acts[0]) == 1 and len(acts[1]) == 1:
            return cont
        rows = [[cont if _quiet(a0) and _quiet(a1) else self._resolve(st, k, a0, a1) for a1 in acts[1]]
                for a0 in acts[0]]
        if len(acts[1]) == 1:
            return max(r[0] for r in rows)
        if len(acts[0]) == 1:
            return min(rows[0])
        return solve_matrix(rows)[2]

    # A turn with a charged move, the way battle.Battle.step plays it ----------------------------

    def _resolve(self, s, k: int, a0, a1) -> float:
        st = list(s)
        acts = (a0, a1)
        floating = []
        for x in (0, 1):
            if not _quiet(acts[x]):
                continue          # throwing: no fast move in progress
            if k % self.n[x] == self.n[x] - 1:
                self._register(st, x)    # due this turn anyway
            else:
                floating.append(x)       # interrupted by the charged move
        queue = [(x, acts[x]) for x in (0, 1) if not _quiet(acts[x])]
        if len(queue) == 2:
            atk = [self.f[x].species.atk * stage_multiplier(st[ATK + x]) for x in (0, 1)]
            if atk[1] > atk[0]:
                queue.reverse()
            elif atk[1] == atk[0]:
                return 0.5 * self._charges(st, queue, floating) + 0.5 * self._charges(st, queue[::-1], floating)
        return self._charges(st, queue, floating)

    def _charges(self, st, queue: list, floating) -> float:
        if not queue:
            if st[HP] <= 0 or st[HP + 1] <= 0:
                return self._terminal(st)
            return self.value(tuple(st))   # cooldowns reset: the rhythm starts over
        (x, i), rest = queue[0], queue[1:]
        o = 1 - x
        if st[HP + x] <= 0 or st[HP + o] <= 0:
            return self._charges(st, rest, floating)
        st = list(st)
        for y in floating:
            self._register(st, y)
        if st[HP + x] <= 0 or st[HP + o] <= 0:
            return self._charges(st, rest, ())
        st[E + x] -= self.f[x].charged[i].energy
        if st[SH + o] == 0:
            return self.hit(st, x, i, rest, False)
        no, yes = self.hit(st, x, i, rest, False), self.hit(st, x, i, rest, True)
        # The defender picks; on a tie it keeps the shield.
        if o == 0:
            return yes if yes > no else no
        return yes if yes < no else no

    def _terminal(self, st) -> float:
        hp0, hp1 = st[HP], st[HP + 1]
        result = 0 if hp0 <= 0 and hp1 <= 0 else (1 if hp1 <= 0 else -1)
        return (1 - self.w) * result + self.w * (hp0 / self.f[0].species.hp - hp1 / self.f[1].species.hp)

    def _register(self, st: list, x: int) -> None:
        o = 1 - x
        if st[HP + o] <= 0:
            return
        st[HP + o] = max(0, st[HP + o] - self._damage(x, self.f[x].fast, st[ATK + x], st[DEF + o]))
        st[E + x] = min(MAX_ENERGY, st[E + x] + self.f[x].fast.energy_gain)

    def _damage(self, x: int, move: Move, atk_stage: int, def_stage: int) -> int:
        key = (x, move.id, atk_stage, def_stage)
        d = self._dmg.get(key)
        if d is None:
            d = self._dmg[key] = damage(move, self.f[x].species, self.f[1 - x].species, atk_stage, def_stage)
        return d


def _quiet(a) -> bool:
    return a is None or a == FAST_ACTION


def _clamp(stage: int) -> int:
    return max(-MAX_STAGE, min(MAX_STAGE, stage))


# Playing the solution in the simulator --------------------------------------------------------

class DuelPlayer:
    """Plays a solved Duel in battle.py, for either side.

    Full information, like PvPoke's sandbox: it knows the opponent's moveset and sees their fast
    move animations start. Their energy it counts from what it sees, as ManGo would.
    """

    def __init__(self, duel: Duel, seed: int | None = None):
        self.duel = duel
        self.rng = random.Random(seed)
        self.queued: tuple[int, int, int] | None = None   # (turn, charged index, energy when queued)
        self.foe_energy = 0
        self.decisions: list[tuple[int, Strategy]] = []

    def start(self, side: int) -> None:
        self.side = side

    def observe(self, events) -> None:
        for e in events:
            if e.side != self.side and e.kind == "fast":
                self.foe_energy = min(MAX_ENERGY, self.foe_energy + e.move.energy_gain)
            elif e.side != self.side and e.kind == "charged":
                self.foe_energy -= e.move.energy

    def state(self, view: View) -> list[int]:
        mine = (view.mon.hp, view.mon.energy, view.me.shields, view.mon.atk_stage, view.mon.def_stage)
        theirs = (view.foe_hp, self.foe_energy, view.foe_shields, *view.foe_stages)
        pair = (mine, theirs) if self.side == 0 else (theirs, mine)
        return [v for field in zip(*pair) for v in field]

    def rhythm(self, view: View) -> int:
        """The turn's place in the rhythm, worked out from when each side can act next."""
        waits = [max(0, view.me.busy_until - view.turn), view.foe_timer[0]]
        if self.side == 1:
            waits.reverse()
        n = self.duel.n
        return next(k for k in range(self.duel.period) if all((k + waits[x]) % n[x] == 0 for x in (0, 1)))

    def act(self, view: View) -> tuple[str, int]:
        strat = self.duel.strategy(tuple(self.state(view)), self.rhythm(view))
        acts, mix = strat.actions[self.side], strat.mix[self.side]
        if len(acts) > 1:
            self.decisions.append((view.turn, strat))
        a = self.rng.choices(acts, mix)[0]
        if _quiet(a):
            return FAST
        self.queued = (view.turn, a, view.mon.energy)
        return CHARGED(a)

    def shield(self, view: View, move: Move) -> bool:
        st = self.state(view)
        foe = 1 - self.side
        st[E + foe] = max(st[E + foe] - move.energy, 0)   # they've paid; the count catches up at turn end
        rest = []
        if self.queued and self.queued[0] == view.turn and view.mon.energy == self.queued[2]:
            rest = [(self.side, self.queued[1])]           # my own throw this turn hasn't gone yet
        i = next(k for k, c in enumerate(self.duel.f[foe].charged) if c.id == move.id)
        no, yes = self.duel.hit(st, foe, i, rest, False), self.duel.hit(st, foe, i, rest, True)
        return yes > no if self.side == 0 else yes < no

    def replace(self, view: View) -> int:
        return view.me.bench()[0]


def play_out(duel: Duel, shields: tuple[int, int] = (1, 1), players: list | None = None,
             seed: int | None = None) -> Battle:
    """One battle in the simulator, both sides playing the solution unless `players` says otherwise."""
    a, b = duel.f
    battle = Battle([[a.mon()], [b.mon()]], seed=seed, shields=0)
    battle.sides[0].shields, battle.sides[1].shields = shields
    rng = random.Random(seed)
    players = players or [DuelPlayer(duel, rng.randrange(1 << 30)), DuelPlayer(duel, rng.randrange(1 << 30))]
    for side, p in enumerate(players):
        if hasattr(p, "start"):
            p.start(side)
    observers = [p for p in players if hasattr(p, "observe")]
    battle.play(players, observers)
    return battle
