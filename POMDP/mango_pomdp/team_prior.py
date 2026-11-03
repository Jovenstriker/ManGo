"""A structured prior over the opponent's team and movesets.

Species: weighted by PvPoke rank, exp(−(rank − 1) / temperature), with no two of the same
Pokédex number (a shadow and its regular form count as the same species, as in GO).

Teams: real players don't bring three Pokémon that all lose to the same thing. A team's weight
is multiplied by exp(−penalty), where the penalty grows with
  • weaknesses the team shares (two members weak to Ground costs 1, all three costs 2), and
  • PvPoke "counters" the members share (one Pokémon that beats all three is costly). A few
    meta Pokémon (Mimikyu, Cramorant) are in nearly every counter list, so each shared counter
    is weighted by how rare it is across the pool, log(pool size / lists it appears in).
Teams are drawn by sampling–importance–resampling: draw candidates from the rank prior, keep one
in proportion to its synergy weight. `complete_team` does the same with some members fixed,
which is how the belief fills in the back line after the lead is revealed.

Movesets: fast and charged moves drawn in proportion to PvPoke's usage counts, conditioned on
whatever moves have been seen.

`structured=False` gives the flat baseline: uniform over the pool, uniform over moves, no synergy.
"""
from __future__ import annotations

import math
import random

from .battle import Mon
from .gamedata import TYPES, GameData, Species

TeamSpec = list[tuple[str, str, tuple[str, ...]]]   # [(species id, fast id, (charged ids))]


class TeamPrior:
    def __init__(self, gd: GameData, top_n: int = 100, temperature: float = 30.0,
                 weakness_weight: float = 0.7, counter_weight: float = 1.5,
                 structured: bool = True, candidates: int = 24):
        self.gd = gd
        self.pool: list[Species] = gd.ranked[:top_n]
        self.structured = structured
        self.weakness_weight = weakness_weight
        self.counter_weight = counter_weight
        self.candidates = candidates
        self.weights = [math.exp(-(s.rank - 1) / temperature) if structured else 1.0 for s in self.pool]
        lists: dict[str, int] = {}
        for sp in self.pool:
            for c in sp.counters:
                lists[c] = lists.get(c, 0) + 1
        self.rarity = {c: math.log(len(self.pool) / n) for c, n in lists.items()}

    # Species ------------------------------------------------------------------------------

    def synergy_penalty(self, team: list[Species]) -> float:
        if not self.structured:
            return 0.0
        pen = 0.0
        for t in TYPES:
            k = sum(t in s.weaknesses for s in team)
            pen += self.weakness_weight * max(0, k - 1)
        if len(team) == 3:
            shared = set(team[0].counters) & set(team[1].counters) & set(team[2].counters)
            pen += self.counter_weight * sum(self.rarity.get(c, 0.0) for c in shared)
        for i in range(len(team)):
            for j in range(i + 1, len(team)):
                shared = set(team[i].counters) & set(team[j].counters)
                pen += 0.25 * self.counter_weight * sum(self.rarity.get(c, 0.0) for c in shared)
        return pen

    def _draw_species(self, rng: random.Random, exclude_dex: set[int]) -> Species:
        while True:
            s = rng.choices(self.pool, self.weights)[0]
            if s.dex not in exclude_dex:
                return s

    def complete_team(self, rng: random.Random, known: list[str]) -> list[str]:
        """Three species ids including `known`, drawn from the prior conditioned on them."""
        fixed = [self.gd.species[k] for k in known]
        if len(fixed) >= 3:
            return list(known)[:3]
        options, scores = [], []
        for _ in range(self.candidates if self.structured else 1):
            team = list(fixed)
            dex = {s.dex for s in team}
            while len(team) < 3:
                s = self._draw_species(rng, dex)
                team.append(s)
                dex.add(s.dex)
            options.append(team)
            scores.append(-self.synergy_penalty(team))
        top = max(scores)
        pick = rng.choices(options, [math.exp(x - top) for x in scores])[0]
        return [s.id for s in pick]

    # Moves --------------------------------------------------------------------------------

    def sample_moveset(self, rng: random.Random, species_id: str, fast: str | None = None,
                       charged: tuple[str, ...] | set[str] = ()) -> tuple[str, tuple[str, ...]]:
        s = self.gd.species[species_id]
        if fast is None:
            ids, uses = zip(*s.fast_usage)
            fast = rng.choices(ids, [max(u, 1) for u in uses] if self.structured else None)[0]
        picked = list(charged)[:2]
        rest = [(m, u) for m, u in s.charged_usage if m not in picked]
        while len(picked) < 2 and rest:
            i = rng.choices(range(len(rest)), [max(u, 1) for _, u in rest] if self.structured else None)[0]
            picked.append(rest.pop(i)[0])
        return fast, tuple(picked)

    # Whole teams --------------------------------------------------------------------------

    def sample_team(self, rng: random.Random) -> TeamSpec:
        ids = self.complete_team(rng, [])
        rng.shuffle(ids)
        return [(sid, *self.sample_moveset(rng, sid)) for sid in ids]


def build_team(gd: GameData, spec: TeamSpec) -> list[Mon]:
    return [Mon(gd.species[sid], gd.moves[f], tuple(gd.moves[c] for c in cs)) for sid, f, cs in spec]


def describe(gd: GameData, spec: TeamSpec) -> str:
    return ", ".join(
        f"{gd.species[sid].name} ({gd.moves[f].name} / {' + '.join(gd.moves[c].name for c in cs)})"
        for sid, f, cs in spec)
