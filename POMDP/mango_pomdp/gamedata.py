"""Great League game data and the damage formula, following PvPoke's DamageCalculator.

    damage = floor(power × STAB × attack / defense × effectiveness × 0.5 × 1.3) + 1

Attack and defense include buff stages ((4 + s) / 4 up, 4 / (4 − s) down) and the shadow
multipliers, which data/great_league.json already folds into each shadow's stats.
"""
from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data" / "great_league.json"

BONUS = 1.2999999523162841796875
STAB = 1.2000000476837158203125
SE, NVE, IMMUNE = 1.60000002384185791015625, 0.625, 0.390625
MAX_ENERGY = 100
MAX_STAGE = 4

# Attacking type -> {defending type: multiplier}; anything missing is 1.
_S, _N, _X = SE, NVE, IMMUNE
TYPE_CHART: dict[str, dict[str, float]] = {
    "normal": {"rock": _N, "ghost": _X, "steel": _N},
    "fire": {"fire": _N, "water": _N, "grass": _S, "ice": _S, "bug": _S, "rock": _N, "dragon": _N, "steel": _S},
    "water": {"fire": _S, "water": _N, "grass": _N, "ground": _S, "rock": _S, "dragon": _N},
    "electric": {"water": _S, "electric": _N, "grass": _N, "ground": _X, "flying": _S, "dragon": _N},
    "grass": {"fire": _N, "water": _S, "grass": _N, "poison": _N, "ground": _S, "flying": _N, "bug": _N,
              "rock": _S, "dragon": _N, "steel": _N},
    "ice": {"fire": _N, "water": _N, "grass": _S, "ice": _N, "ground": _S, "flying": _S, "dragon": _S, "steel": _N},
    "fighting": {"normal": _S, "ice": _S, "poison": _N, "flying": _N, "psychic": _N, "bug": _N, "rock": _S,
                 "ghost": _X, "dark": _S, "steel": _S, "fairy": _N},
    "poison": {"grass": _S, "poison": _N, "ground": _N, "rock": _N, "ghost": _N, "steel": _X, "fairy": _S},
    "ground": {"fire": _S, "electric": _S, "grass": _N, "poison": _S, "flying": _X, "bug": _N, "rock": _S, "steel": _S},
    "flying": {"electric": _N, "grass": _S, "fighting": _S, "bug": _S, "rock": _N, "steel": _N},
    "psychic": {"fighting": _S, "poison": _S, "psychic": _N, "dark": _X, "steel": _N},
    "bug": {"fire": _N, "grass": _S, "fighting": _N, "poison": _N, "flying": _N, "psychic": _S, "ghost": _N,
            "dark": _S, "steel": _N, "fairy": _N},
    "rock": {"fire": _S, "ice": _S, "fighting": _N, "ground": _N, "flying": _S, "bug": _S, "steel": _N},
    "ghost": {"normal": _X, "psychic": _S, "ghost": _S, "dark": _N},
    "dragon": {"dragon": _S, "steel": _N, "fairy": _X},
    "dark": {"fighting": _N, "psychic": _S, "ghost": _S, "dark": _N, "fairy": _N},
    "steel": {"fire": _N, "water": _N, "electric": _N, "ice": _S, "rock": _S, "steel": _N, "fairy": _S},
    "fairy": {"fire": _N, "fighting": _S, "poison": _N, "dragon": _S, "dark": _S, "steel": _N},
}
TYPES = tuple(TYPE_CHART)


def effectiveness(move_type: str, defender_types: tuple[str, ...]) -> float:
    m = 1.0
    for t in defender_types:
        m *= TYPE_CHART[move_type].get(t, 1.0)
    return m


def stage_multiplier(stage: int) -> float:
    return (4 + stage) / 4 if stage > 0 else 4 / (4 - stage)


@dataclass(frozen=True, slots=True)
class Move:
    id: str
    name: str
    type: str
    power: int
    energy: int        # cost, for a charged move
    energy_gain: int   # for a fast move
    turns: int         # fast move length in 0.5s turns
    buff_chance: float = 0.0
    buff_self: tuple[int, int] = (0, 0)       # (attack, defense) stage changes
    buff_opponent: tuple[int, int] = (0, 0)

    @property
    def is_fast(self) -> bool:
        return self.energy_gain > 0


@dataclass(frozen=True, slots=True)
class Species:
    id: str
    name: str
    dex: int
    rank: int
    types: tuple[str, ...]
    atk: float
    def_: float
    hp: int
    fast_usage: tuple[tuple[str, int], ...]     # (move id, PvPoke usage count)
    charged_usage: tuple[tuple[str, int], ...]
    moveset: tuple[str, ...]                    # PvPoke's recommended [fast, charged, charged]
    counters: tuple[str, ...] = field(default=())

    @property
    def weaknesses(self) -> frozenset[str]:
        return frozenset(t for t in TYPES if effectiveness(t, self.types) > 1.01)


class GameData:
    def __init__(self, path: Path = DATA):
        raw = json.loads(Path(path).read_text())
        self.moves: dict[str, Move] = {}
        for m in raw["moves"]:
            self.moves[m["moveId"]] = Move(
                m["moveId"], m["name"], m["type"], m["power"], m["energy"], m["energyGain"], m["turns"],
                m.get("buffChance", 0.0), tuple(m.get("buffSelf", (0, 0))), tuple(m.get("buffOpponent", (0, 0))))
        self.species: dict[str, Species] = {}
        for p in raw["pokemon"]:
            self.species[p["id"]] = Species(
                p["id"], p["name"], p["dex"], p["rank"], tuple(p["types"]), p["atk"], p["def"], p["hp"],
                tuple(p["fast"].items()), tuple(p["charged"].items()), tuple(p["moveset"]), tuple(p["counters"]))
        self.ranked = sorted(self.species.values(), key=lambda s: s.rank)

    def recommended(self, species_id: str) -> tuple[Move, tuple[Move, ...]]:
        s = self.species[species_id]
        return self.moves[s.moveset[0]], tuple(self.moves[m] for m in s.moveset[1:] if m in self.moves)


@lru_cache(maxsize=1 << 18)
def damage(move: Move, attacker: Species, defender: Species, atk_stage: int = 0, def_stage: int = 0) -> int:
    stab = STAB if move.type in attacker.types else 1.0
    atk = attacker.atk * stage_multiplier(atk_stage)
    df = defender.def_ * stage_multiplier(def_stage)
    return math.floor(move.power * stab * atk / df * effectiveness(move.type, defender.types) * 0.5 * BONUS) + 1


_default: GameData | None = None


def load() -> GameData:
    global _default
    if _default is None:
        _default = GameData()
    return _default
