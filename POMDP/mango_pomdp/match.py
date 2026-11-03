"""Playing battles: building players by name and running one battle between two of them."""
from __future__ import annotations

from .battle import Battle
from .gamedata import GameData
from .planner import Planner
from .policies import STYLES, Heuristic, RandomPlayer
from .team_prior import TeamPrior, TeamSpec, build_team

PLAYERS = ("random", *STYLES, "planner", "planner-flat", "planner-1style", "oracle")


def make_player(name: str, gd: GameData, prior: TeamPrior, seed: int,
                truth: TeamSpec | None = None, truth_style: str | None = None, rollouts: int = 12):
    """`truth` and `truth_style` (the opponent's real team and style) are only read by "oracle"."""
    if name == "random":
        return RandomPlayer(seed)
    if name in STYLES:
        return Heuristic(name, seed=seed)
    if name == "planner":
        return Planner(gd, prior, rollouts=rollouts, seed=seed)
    if name == "planner-flat":
        # No structure: flat prior over the top 100, and every opponent assumed to be a baiter.
        flat = TeamPrior(gd, top_n=prior.pool.__len__(), structured=False)
        return Planner(gd, flat, rollouts=rollouts, styles=("baiter",), seed=seed, name=name)
    if name == "planner-1style":
        return Planner(gd, prior, rollouts=rollouts, styles=("baiter",), seed=seed, name=name)
    if name == "oracle":
        return Planner(gd, prior, rollouts=rollouts, seed=seed, oracle=(truth, truth_style), name=name)
    raise ValueError(f"unknown player {name!r}; pick from {PLAYERS}")


def play(gd: GameData, teams: list[TeamSpec], players: list, seed: int) -> Battle:
    battle = Battle([build_team(gd, teams[0]), build_team(gd, teams[1])], seed=seed)
    for side, p in enumerate(players):
        if hasattr(p, "start"):
            p.start(side)
    observers = [p for p in players if hasattr(p, "observe")]
    for o in observers:
        o.observe(battle.log)
    battle.play(players, observers)
    return battle
