"""Playing battles: building players by name and running one battle between two of them."""
from __future__ import annotations

from .battle import Battle
from .gamedata import GameData, TopTeam
from .planner import SWITCH_AT, Planner
from .pomcp import POMCP
from .policies import STYLES, Heuristic, RandomPlayer
from .team_prior import TeamListPrior, TeamPrior, TeamSpec, build_team

PLAYERS = ("random", *STYLES, "planner", "planner-flat", "planner-1style", "planner-list", "oracle",
           "planner-learned", "planner-list-learned", "planner-mixed", "planner-list-mixed",
           "pomcp", "pomcp-mixed", "pomcp-list-mixed")


POMCP_SETTINGS = {"depth": int, "c": float, "lean": float, "fpu": float}


def pomcp_settings(text: str) -> dict:
    """"depth=4,lean=0.75" -> {"depth": 4, "lean": 0.75}: POMCP's settings, from a player name."""
    out = {}
    for part in filter(None, text.split(",")):
        key, _, value = part.partition("=")
        if key not in POMCP_SETTINGS:
            raise ValueError(f"unknown POMCP setting {key!r}; pick from {tuple(POMCP_SETTINGS)}")
        out[key] = POMCP_SETTINGS[key](value)
    return out


def valid_player(name: str) -> bool:
    name, _, settings = name.partition(":")
    base, _, switch_at = name.partition("@")
    if settings:
        try:
            pomcp_settings(settings)
        except ValueError:
            return False
    return base in PLAYERS and (not switch_at or (base not in ("random", *STYLES) and switch_at in SWITCH_AT)) \
        and (not settings or base.startswith("pomcp"))


def make_player(name: str, gd: GameData, prior: TeamPrior, seed: int,
                truth: TeamSpec | None = None, truth_style: str | None = None, rollouts: int = 12,
                teams: list[TopTeam] | None = None):
    """`truth` and `truth_style` (the opponent's real team and style) are only read by "oracle".
    `teams` is the list of teams "planner-list" knows the opponent picks from.

    A planner's name can end in "@start", "@zero-turn", "@catch" or "@any" for when it considers
    switching (planner.SWITCH_AT); the default is any: every legal action, every free turn.
    A POMCP player's name can end in its settings after a colon, e.g. "pomcp-list-mixed:depth=4,lean=0.75"
    (POMCP_SETTINGS: tree depth, exploration c, prior lean on the rollout policy, fpu)."""
    full = name
    name, _, settings = name.partition(":")
    name, _, switch_at = name.partition("@")
    kw = {"switch_at": switch_at} if switch_at else {}
    if settings:
        if not name.startswith("pomcp"):
            raise ValueError(f"settings after ':' are only for POMCP players, not {full!r}")
        kw.update(pomcp_settings(settings))
        name_kw = {"name": full}
    else:
        name_kw = {"name": name}
    if name == "random":
        return RandomPlayer(seed)
    if name in STYLES:
        return Heuristic(name, seed=seed)
    if name == "planner":
        return Planner(gd, prior, rollouts=rollouts, seed=seed, **kw)
    if name == "planner-flat":
        # No structure: flat prior over the top 100, and every opponent assumed to be a baiter.
        flat = TeamPrior(gd, top_n=prior.pool.__len__(), structured=False)
        return Planner(gd, flat, rollouts=rollouts, styles=("baiter",), seed=seed, name=name, **kw)
    if name == "planner-1style":
        return Planner(gd, prior, rollouts=rollouts, styles=("baiter",), seed=seed, name=name, **kw)
    if name == "planner-learned":   # rollouts against the opponent model fitted on your recordings
        return Planner(gd, prior, rollouts=rollouts, styles=("learned",), seed=seed, name=name, **kw)
    if name == "planner-list-learned":
        return Planner(gd, TeamListPrior(gd, teams, fallback=prior), rollouts=rollouts, styles=("learned",),
                       seed=seed, name=name, **kw)
    if name == "planner-mixed":    # the four styles and the learned opponent, weighed by the belief
        return Planner(gd, prior, rollouts=rollouts, styles=STYLES + ("learned",), seed=seed, name=name, **kw)
    if name == "planner-list-mixed":
        return Planner(gd, TeamListPrior(gd, teams, fallback=prior), rollouts=rollouts,
                       styles=STYLES + ("learned",), seed=seed, name=name, **kw)
    if name == "planner-list":
        return Planner(gd, TeamListPrior(gd, teams, fallback=prior), rollouts=rollouts, seed=seed, name=name, **kw)
    # POMCP: the same planners with a search tree over your later decisions (pomcp.py).
    if name == "pomcp":
        return POMCP(gd, prior, rollouts=rollouts, seed=seed, **name_kw, **kw)
    if name == "pomcp-mixed":
        return POMCP(gd, prior, rollouts=rollouts, styles=STYLES + ("learned",), seed=seed, **name_kw, **kw)
    if name == "pomcp-list-mixed":
        return POMCP(gd, TeamListPrior(gd, teams, fallback=prior), rollouts=rollouts,
                     styles=STYLES + ("learned",), seed=seed, **name_kw, **kw)
    if name == "oracle":
        return Planner(gd, prior, rollouts=rollouts, seed=seed, oracle=(truth, truth_style), name=name, **kw)
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
