"""PvPoke's top Mega Great League teams: pick one, and plan to beat all the others.

    cd POMDP
    python3 -m experiments.top_teams rank                  # every team vs every other, heuristic play
    python3 -m experiments.top_teams select                # the planner on the strongest few
    python3 -m experiments.top_teams evaluate 3            # team 3 (CSV row) vs the other 47
    python3 -m experiments.top_teams evaluate 3 --lead 2   # lead with its second Pokémon instead
    python3 -m experiments.top_teams evaluate 3 --plan     # plus a game plan per opponent
    python3 -m experiments.top_teams book 3                # the best opening against each lead
    python3 -m experiments.top_teams evaluate 3 --players planner-list planner-book \
        --book data/openings_3.json --opponents planner-list

The teams are data/mega_great_league_top_teams.csv, PvPoke's top teams export, numbered by row.
Opponents lead with the first Pokémon listed, the way the export lists them, and play one of the
heuristic styles (policies.STYLES), or with `--opponents planner-list`, the planner itself.
Each game is played from both sides of the board in turn.

Players for our team (match.PLAYERS): a heuristic style plays the team as that style would;
"planner" is the 3v3 POMDP planner with the format's structured team prior; "planner-list" is
the same planner, but its belief is over the 47 other listed teams (weighted by usage), so once
it sees their lead it mostly knows their back line and movesets; "oracle" knows the opponent's
team and style outright.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import time
import zlib
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from mango_pomdp import gamedata
from mango_pomdp.battle import SWITCH
from mango_pomdp.match import PLAYERS, make_player, play
from mango_pomdp.policies import STYLES, Heuristic
from mango_pomdp.team_prior import TeamPrior

FORMAT = "mega_great_league"
SCORE = {0: 1.0, -1: 0.5, 1: 0.0}   # from side 0's point of view


def short(gd, team) -> str:
    return "/".join(gd.species[s].name.replace(" (Shadow)", "ˢ").replace(" (Galarian)", "-G")
                    .replace(" (Alolan)", "-A").replace(" (Hisuian)", "-H").replace(" (Mega)", "-Mega")
                    .replace(" (Full Belly)", "") for s in team.species)


def rotate(spec, lead: int):
    """The team with member `lead` (1-based) in front and the rest in listed order."""
    spec = list(spec)
    return [spec[lead - 1]] + spec[:lead - 1] + spec[lead:]


# Jobs (run in worker processes) -------------------------------------------------------------

def heuristic_game(job):
    i, j, style, game = job
    gd = gamedata.use(FORMAT)
    rng = random.Random((i * 100 + j) * 1000 + game * 10 + STYLES.index(style))
    teams = [list(gd.teams[i].spec), list(gd.teams[j].spec)]
    if game % 2:   # alternate sides
        teams.reverse()
    battle = play(gd, teams, [Heuristic(style, seed=rng.randrange(1 << 30)),
                              Heuristic(style, seed=rng.randrange(1 << 30))], seed=rng.randrange(1 << 30))
    s = SCORE[battle.winner]
    return i, j, (1 - s) if game % 2 else s


class Opening:
    """Plays a fixed first action chosen from the opponent's lead (an opening book), then hands
    every decision to the planner. `book` maps their lead to the bench slot to swap to, or 0 to
    let the planner choose its own opening (as it does for leads the book doesn't list)."""

    def __init__(self, planner, book: dict[str, int], name: str):
        self.planner, self.book, self.name, self.first = planner, book, name, True

    def start(self, side):
        self.planner.start(side)

    def observe(self, events):
        self.planner.observe(events)

    def act(self, view):
        if self.first:
            self.first = False
            slot = self.book.get(view.foe_species.id, 0)
            if slot and view.can_switch and slot in view.me.bench():
                return SWITCH(slot)
        return self.planner.act(view)

    def shield(self, view, move):
        return self.planner.shield(view, move)

    def replace(self, view):
        return self.planner.replace(view)


def planned_game(job):
    """`player` is a match.PLAYERS name, "open:K" (planner-list that opens by swapping to slot K
    whatever they lead; 0 is the planner's own opening), or "planner-book" (planner-list with `book`)."""
    player, mine, lead, j, style, game, (rollouts, foe_rollouts), book = job
    gd = gamedata.use(FORMAT)
    prior = TeamPrior(gd)
    # planner-book plays the same games as planner-list (common random numbers): wherever the book
    # doesn't step in, the game is identical, so the comparison is paired.
    key = "planner-list" if player == "planner-book" else player
    rng = random.Random(zlib.crc32(repr((key, mine, lead, j, style, game)).encode()))
    others = [t for k, t in enumerate(gd.teams) if k != mine]
    ours, theirs = rotate(gd.teams[mine].spec, lead), list(gd.teams[j].spec)
    side = game % 2
    base = "planner-list" if player.startswith("open:") or player == "planner-book" else player
    me = make_player(base, gd, prior, rng.randrange(1 << 30), truth=theirs,
                     truth_style=style if style in STYLES else "baiter", rollouts=rollouts, teams=others)
    if player.startswith("open:"):
        slot = int(player[5:])
        me = Opening(me, {t.species[0]: slot for t in gd.teams}, player)
    elif player == "planner-book":
        me = Opening(me, book, player)
    if style in STYLES:
        foe = Heuristic(style, seed=rng.randrange(1 << 30))
    else:   # a planner opponent, which knows the list as well (every team but its own)
        foe = make_player(style, gd, prior, rng.randrange(1 << 30), rollouts=foe_rollouts,
                          teams=[t for k, t in enumerate(gd.teams) if k != j])
    teams, players = ([ours, theirs], [me, foe]) if side == 0 else ([theirs, ours], [foe, me])
    battle = play(gd, teams, players, seed=rng.randrange(1 << 30))
    s = SCORE[battle.winner]
    score = s if side == 0 else 1 - s
    # How the game went for us, for the game plan.
    entries = [e for e in battle.log if e.side == side and e.kind == "enter"]
    order = [entries[0].species]
    for e in entries[1:]:
        if e.species != order[-1]:
            order.append(e.species)
    early_switch = next((e.species for e in entries[1:] if e.info.get("switch") and e.turn <= 3), None)
    shields = Counter(e.info["target"] for e in battle.log
                      if e.side != side and e.kind == "charged" and e.info["shielded"])
    alive = [m.species.id for m in battle.sides[side].mons if m.hp > 0]
    return player, mine, lead, j, style, score, order, early_switch, dict(shields), alive


def pool_map(fn, jobs, workers):
    with ProcessPoolExecutor(workers) as pool:
        yield from pool.map(fn, jobs, chunksize=max(1, len(jobs) // (8 * (workers or 10))))


# Commands -----------------------------------------------------------------------------------

def round_robin(gd, games: int, workers):
    n = len(gd.teams)
    jobs = [(i, j, st, g) for i in range(n) for j in range(i + 1, n) for st in STYLES for g in range(games)]
    total = defaultdict(float)
    count = defaultdict(int)
    for i, j, s in pool_map(heuristic_game, jobs, workers):
        total[i, j] += s
        total[j, i] += 1 - s
        count[i, j] += 1
        count[j, i] += 1
    return {k: total[k] / count[k] for k in total}


def rank(gd, games: int, workers, show: int = 48):
    start = time.time()
    w = round_robin(gd, games, workers)
    n = len(gd.teams)
    rows = []
    for i in range(n):
        vs = [w[i, j] for j in range(n) if j != i]
        usage = sum(gd.teams[j].usage for j in range(n) if j != i)
        weighted = sum(w[i, j] * gd.teams[j].usage for j in range(n) if j != i) / usage
        worst = min((w[i, j], j) for j in range(n) if j != i)
        rows.append((sum(vs) / len(vs), weighted, sum(v > 0.5 for v in vs), worst, i))
    rows.sort(reverse=True)
    print(f"Round robin: {n} teams, each pair {games} games per style × {len(STYLES)} styles, both sides "
          f"playing the same heuristic style. {time.time() - start:.0f}s\n")
    print(f"{'#':>3}  {'team':<38}{'PvPoke':>7}{'win rate':>10}{'usage-wt':>10}{'beats':>7}   worst matchup")
    for mean, weighted, beats, (wv, wj), i in rows[:show]:
        print(f"{i + 1:>3}  {short(gd, gd.teams[i]):<38}{gd.teams[i].rating:>7.0f}{mean:>10.3f}{weighted:>10.3f}"
              f"{beats:>4}/{n - 1}   {wv:.2f} vs #{wj + 1} {short(gd, gd.teams[wj])}")
    return rows


def run_eval(gd, players, mine, leads, styles, games, rollouts, workers, book=None):
    n = len(gd.teams)
    jobs = [(p, mine, lead, j, st, g, rollouts, book) for p in players for lead in leads
            for j in range(n) if j != mine for st in styles for g in range(games)]
    return list(pool_map(planned_game, jobs, workers))


def build_book(gd, mine: int, lead: int, styles, games, rollouts, workers, margin: float, out: Path):
    """For each lead the opponents can show, the opening (the planner's own, or a swap to either
    bench slot on turn 0) that wins most against the listed teams with that lead. The planner
    plays everything after it."""
    ours = rotate(gd.teams[mine].spec, lead)
    names = [gd.species[s].name for s, _, _ in ours]
    print(f"Opening book for team #{mine + 1} ({' / '.join(names)}, lead first), against "
          f"{', '.join(styles)}, {games} games per opponent per opening\n")
    start = time.time()
    results = run_eval(gd, ["open:0", "open:1", "open:2"], mine, [lead], styles, games, rollouts, workers)
    per = defaultdict(list)   # (opening, opponent) -> scores
    for r in results:
        per[int(r[0][5:]), r[3]].append(r[5])
    leads = defaultdict(list)
    for j, t in enumerate(gd.teams):
        if j != mine:
            leads[t.species[0]].append(j)
    book = {}
    label = ["planner's choice", f"swap to {names[1]}", f"swap to {names[2]}"]
    print(f"  {'their lead':<24}{'teams':>6}" + "".join(f"{x:>22}" for x in label) + "   book")
    for sid, js in sorted(leads.items(), key=lambda kv: -len(kv[1])):
        means = [sum(sum(per[k, j]) / len(per[k, j]) for j in js) / len(js) for k in range(3)]
        k = max(range(3), key=lambda i: means[i])
        if means[k] < means[0] + margin:
            k = 0   # only override the planner when a swap is clearly better
        book[sid] = k
        print(f"  {gd.species[sid].name:<24}{len(js):>6}" + "".join(f"{m:>22.2f}" for m in means) + f"   {label[k]}")
    out.write_text(json.dumps({"team": mine + 1, "lead": lead, "opponents": list(styles), "games": games,
                               "book": book}, indent=1) + "\n")
    print(f"\n{time.time() - start:.0f}s. Wrote {out}.")


def mean_se(xs):
    m = sum(xs) / len(xs)
    se = math.sqrt(sum((x - m) ** 2 for x in xs) / max(len(xs) - 1, 1) / len(xs))
    return m, se


def select(gd, shortlist: int, games: int, rollouts: int, workers):
    rows = rank(gd, games=4, workers=workers, show=shortlist)
    picks = [i for *_, i in rows[:shortlist]]
    print(f"\nThe planner (planner-list) with each of the top {shortlist}, every lead, against all "
          f"{len(gd.teams) - 1} other teams × {len(STYLES)} styles × {games} games:\n")
    start = time.time()
    results = []
    for i in picks:
        results += run_eval(gd, ["planner-list"], i, [1, 2, 3], STYLES, games, (rollouts, rollouts), workers)
    print(f"{'#':>3}  {'team':<38}{'lead':<22}{'win rate':>16}{'opponents beaten':>18}   worst")
    best = None
    for i in picks:
        for lead in (1, 2, 3):
            rs = [r for r in results if r[1] == i and r[2] == lead]
            m, se = mean_se([r[5] for r in rs])
            per = defaultdict(list)
            for r in rs:
                per[r[3]].append(r[5])
            per = {j: sum(v) / len(v) for j, v in per.items()}
            beaten = sum(v > 0.5 for v in per.values())
            wv, wj = min((v, j) for j, v in per.items())
            lead_name = gd.species[gd.teams[i].species[lead - 1]].name
            print(f"{i + 1:>3}  {short(gd, gd.teams[i]):<38}{lead_name:<22}{f'{m:.3f} ± {se:.3f}':>16}"
                  f"{beaten:>11}/{len(per)}       {wv:.2f} vs #{wj + 1} {short(gd, gd.teams[wj])}")
            key = (beaten, m)
            if best is None or key > best[0]:
                best = (key, i, lead)
    print(f"\n{time.time() - start:.0f}s. Most opponents beaten (then best win rate): team #{best[1] + 1} "
          f"{short(gd, gd.teams[best[1]])}, leading with {gd.species[gd.teams[best[1]].species[best[2] - 1]].name}.")


def evaluate(gd, mine: int, lead: int, players, styles, games, rollouts, workers, plan: bool, book=None):
    team = gd.teams[mine]
    ours = rotate(team.spec, lead)
    print(f"Team #{mine + 1}: {' / '.join(gd.species[s].name for s, _, _ in ours)} (lead first)")
    print(f"against the other {len(gd.teams) - 1} teams × styles {', '.join(styles)} × {games} games, "
          f"{rollouts[0]} rollouts" + (f" (opponent planners {rollouts[1]})" if rollouts[1] != rollouts[0] else "")
          + "\n")
    start = time.time()
    results = run_eval(gd, players, mine, [lead], styles, games, rollouts, workers, book)
    print(f"{'player':<16}{'win rate':>16}" + "".join(f"{'vs ' + s:>14}" for s in styles) + f"{'opponents beaten':>20}")
    per = {p: defaultdict(list) for p in players}
    for r in results:
        per[r[0]][r[3]].append(r[5])
    for p in players:
        rs = [r for r in results if r[0] == p]
        m, se = mean_se([r[5] for r in rs])
        row = f"{p:<16}{f'{m:.3f} ± {se:.3f}':>16}"
        for st in styles:
            vs = [r[5] for r in rs if r[4] == st]
            row += f"{sum(vs) / len(vs):>14.3f}"
        beaten = sum(sum(v) / len(v) > 0.5 for v in per[p].values())
        print(row + f"{beaten:>13}/{len(per[p])}")
    print(f"\n{time.time() - start:.0f}s\n")

    # Per opponent, worst first for the last player listed.
    last = players[-1]
    opps = sorted(per[last], key=lambda j: sum(per[last][j]) / len(per[last][j]))
    print("Per opponent (win rate over styles and games):")
    print(f"  {'#':>3}  {'opponent':<38}" + "".join(f"{p:>14}" for p in players))
    for j in opps:
        print(f"  {j + 1:>3}  {short(gd, gd.teams[j]):<38}"
              + "".join(f"{sum(per[p][j]) / len(per[p][j]):>14.2f}" for p in players))
    if plan:
        game_plan(gd, [r for r in results if r[0] == last], opps)


def game_plan(gd, results, opps):
    name = lambda sid: gd.species[sid].name   # noqa: E731
    print(f"\nGame plan, from how {results[0][0]} played each opponent:")
    by = defaultdict(list)
    for r in results:
        by[r[3]].append(r)
    for j in opps:
        rs = by[j]
        wins = [r for r in rs if r[5] == 1.0]
        # The usual opening (stay in, or an early swap), then the usual line among games that opened that way.
        swap, k = Counter(r[7] for r in rs).most_common(1)[0]
        line, n = Counter(" → ".join(name(s) for s in r[6]) for r in rs if r[7] == swap).most_common(1)[0]
        shields = Counter()
        for r in rs:
            shields.update(r[8])
        closers = Counter(s for r in wins for s in r[9])
        opener = f"swap to {name(swap)} at the start" if swap else "stay in"
        print(f"\n  vs #{j + 1} {short(gd, gd.teams[j])}: won {len(wins)}/{len(rs)}")
        print(f"     opening: {opener} ({k}/{len(rs)}), then usually {line} ({n}/{k})")
        print("     shields per game: " + ", ".join(f"{name(s)} {c / len(rs):.1f}" for s, c in shields.most_common())
              + (f"; left standing in wins: " + ", ".join(f"{name(s)} {c}" for s, c in closers.most_common())
                 if closers else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("rank")
    r.add_argument("--games", type=int, default=4, help="games per pair per style")
    s = sub.add_parser("select")
    s.add_argument("--shortlist", type=int, default=6)
    s.add_argument("--games", type=int, default=2, help="games per opponent per style")
    s.add_argument("--rollouts", type=int, default=12)
    e = sub.add_parser("evaluate")
    e.add_argument("team", type=int, help="CSV row, from 1")
    e.add_argument("--lead", type=int, default=1, choices=(1, 2, 3))
    e.add_argument("--players", nargs="+", default=["baiter", "planner", "planner-list"],
                   choices=(*PLAYERS, "planner-book"), help="planner-book is planner-list with --book")
    e.add_argument("--book", type=Path, help="opening book from the book command")
    e.add_argument("--opponents", nargs="+", default=list(STYLES), choices=(*STYLES, "planner", "planner-list"),
                   help="heuristic styles, or planners (which know the list too)")
    e.add_argument("--games", type=int, default=4, help="games per opponent per style")
    e.add_argument("--rollouts", type=int, default=12)
    e.add_argument("--opponent-rollouts", type=int, default=12, help="for planner opponents")
    e.add_argument("--plan", action="store_true", help="print a game plan per opponent")
    b = sub.add_parser("book")
    b.add_argument("team", type=int, help="CSV row, from 1")
    b.add_argument("--lead", type=int, default=1, choices=(1, 2, 3))
    b.add_argument("--opponents", nargs="+", default=["planner-list"], choices=(*STYLES, "planner", "planner-list"))
    b.add_argument("--games", type=int, default=8, help="games per opponent per opening")
    b.add_argument("--rollouts", type=int, default=12)
    b.add_argument("--margin", type=float, default=0.1, help="how much better a swap must be than staying in")
    b.add_argument("--out", type=Path, default=None, help="default data/openings_<team>.json")
    for p in (r, s, e, b):
        p.add_argument("--workers", type=int, default=None)
    args = ap.parse_args()
    gd = gamedata.use(FORMAT)
    if args.cmd == "rank":
        rank(gd, args.games, args.workers)
    elif args.cmd == "select":
        select(gd, args.shortlist, args.games, args.rollouts, args.workers)
    elif args.cmd == "book":
        out = args.out or gamedata.DATA_DIR / f"openings_{args.team}.json"
        build_book(gd, args.team - 1, args.lead, args.opponents, args.games, (args.rollouts, args.rollouts),
                   args.workers, args.margin, out)
    else:
        book = json.loads(args.book.read_text())["book"] if args.book else None
        if "planner-book" in args.players and not book:
            ap.error("planner-book needs --book")
        evaluate(gd, args.team - 1, args.lead, args.players, args.opponents, args.games,
                 (args.rollouts, args.opponent_rollouts), args.workers, args.plan, book)


if __name__ == "__main__":
    main()
