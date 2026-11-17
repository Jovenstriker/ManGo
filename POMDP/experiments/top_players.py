"""Top players against the planner, and your opponent model on top players.

    cd POMDP && python3 -m experiments.top_players regret --rollouts 128
    cd POMDP && python3 -m experiments.top_players model
    cd POMDP && python3 -m experiments.top_players compare rollout:128:2048 pomcp:128:2048

The top players' battles come from a tournament stream that showed both players' phones,
read by ManGo and exported by battle-turns (scripts/stream_fixtures.py, then battle-turns into
data/local/tournament/turns). Each phone is one player's view, so every battle is in the
export twice, once from each side. A player's own decisions are scored from their view. Their
opponent's decisions, for the opponent model, are the "them" side of each view.

regret   The same decision regret as experiments/regret.py, with the same planner and
         settings, for your recorded battles (Mega Great League) and the top players' (Great
         League). The belief over a top player's opponent uses the ordinary Great League
         prior, not their team sheets. Side by side, by stage and by decision type:
         decisions, mean regret, blunder rate (over 5 points), and how often the planner's
         pick was what the player did. Differences are top players minus you, with 95%
         intervals from resampling whole battles.

         Then, where a player went against the planner, who was right? The results can
         check one side of that: the planner's estimate for what the player did. If the
         player was right and the planner wrong, they should win more often than that
         estimate says. So it compares won − estimate (calibrated by stage, cross-validated
         by battle) where the player disagreed with where they agreed.

         Last, the planner's estimates against the real results, by stage: how well they
         rank positions from battles that were won above ones that were lost (AUC), and
         their squared error (Brier), as estimated and calibrated.

compare  The same check on the real results for two or more planner settings, scored on the
         same decisions, with paired intervals for the differences. A setting is
         planner:rollouts[:adaptive cap]: rollout:128, rollout:128:2048, pomcp:128:2048
         (POMCP's tree depth is --depth). It's the one measure of a planner against how real
         battles went, so it's how to tell whether a planner change helps off the simulator.
         Settings without cached rows are run first, as by regret.

model   The opponent model fitted on your opponents (data/local/opponent_model.json, what
         the planner's "learned" opponent uses), scored on the top players' decisions. Next
         to it: the same model refitted on the top players (5-fold cross-validation by
         battle), one fitted on both, the four heuristic styles, and the base rates.

Rows are cached in data/local (the regret run takes a few minutes for each set); --fresh
reruns them. Everything here comes from your recordings or the stream reads, so it stays local.
"""
from __future__ import annotations

import argparse
import bisect
import json
import math
import random
import statistics
import time
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from mango_pomdp import gamedata
from mango_pomdp.battle_turns import load, partner
from mango_pomdp.gamedata import DATA_DIR
from mango_pomdp.opponent_model import CHOICES, OpponentModel, _sigmoid, _softmax
from mango_pomdp.policies import STYLES

from experiments import opponent_model as om
from experiments import regret

MINE = regret.TURNS
STREAM = DATA_DIR / "local" / "tournament" / "turns"
MINE_FORMAT, STREAM_FORMAT = "mega_great_league", "great_league"
CACHE = {"you": DATA_DIR / "local" / "regret_rows.json",
         "top": DATA_DIR / "local" / "tournament" / "regret_rows.json"}
WHO = {"you": "you", "top": "top players"}


def game(bid: str) -> str:
    """Both views of a stream battle share a game; a recording is its own."""
    rec, _, n = bid.rpartition("#")
    return f"{rec[:-2]}#{n}" if partner(bid) else bid


def battles_of(fmt, folder):
    gd = gamedata.use(fmt)
    return gd, [b for b in load(gd, folder) if b.seen == 3 and not b.misread]


# Regret ------------------------------------------------------------------------------------

def rows_for(who, folder, opts, workers, fresh):
    """Every scored decision, as regret.evaluate gives them, cached by settings (one file per
    planner, rollouts and cap)."""
    plain = opts["cap"] == 0 and opts["planner"] == "rollout"
    settings = ({k: opts[k] for k in ("rollouts", "styles", "format")} if plain else opts)
    tag = "" if plain else f"-{opts['planner']}" + (f"{opts['depth']}" if opts["planner"] == "pomcp" else "") \
        + f"-{opts['rollouts']}-{opts['cap']}"
    path = CACHE[who].with_name(f"regret_rows{tag}.json")
    if not fresh and path.exists():
        raw = json.loads(path.read_text())
        if raw["settings"] == settings:
            return [tuple(r[:10]) + (tuple(r[10]),) + tuple(r[11:]) for r in raw["rows"]], raw["complete"]
    _, battles = battles_of(opts["format"], folder)
    battles = [b for b in battles if b.decisions]
    start = time.time()
    with ProcessPoolExecutor(workers) as pool:
        res = list(pool.map(regret.evaluate, [(b, opts) for b in battles]))
    rows = [(bid, result, *r) for bid, result, out in res for r in out]
    complete = sorted(b.id for b in battles if b.complete)
    print(f"  {WHO[who]}: {len(rows)} decisions in {len(battles)} battles, {time.time() - start:.0f}s")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"settings": settings, "rows": rows, "complete": complete}))
    return rows, complete


def boot(groups, stats, n=1000, seed=0):
    """95% intervals of stat(top rows) − stat(your rows) for each of `stats`, resampling whole
    games in each set."""
    rng = random.Random(seed)
    by = [defaultdict(list) for _ in groups]
    for b, rows in zip(by, groups):
        for r in rows:
            b[game(r[0])].append(r)
    keys = [list(b) for b in by]
    diffs = [[] for _ in stats]
    for _ in range(n):
        picks = [[r for k in (rng.choice(ks) for _ in ks) for r in b[k]] for b, ks in zip(by, keys)]
        for d, stat in zip(diffs, stats):
            d.append(stat(picks[1]) - stat(picks[0]))
    out = []
    for d in diffs:
        d.sort()
        out += [d[int(0.025 * n)], d[int(0.975 * n) - 1]]
    return out


def agree(rows):
    return statistics.mean(r[6] == r[7] for r in rows) if rows else float("nan")


def blunders(rows):
    return statistics.mean(r[3] > regret.BLUNDER for r in rows) if rows else float("nan")


def mean_regret(rows):
    return statistics.mean(r[3] for r in rows) if rows else float("nan")


def not_worse(rows):
    """Share of decisions the planner can't tell from its best: the best other option isn't
    ahead of the player's by over 2 standard errors (needs adaptive rollouts' rows)."""
    return statistics.mean(not regret.clearly_worse(r) for r in rows) if rows else float("nan")


def side_by_side(title, groups, keep, names):
    print(title)
    stats = [("mean regret", mean_regret, "+.3f"), ("blunders", blunders, "+.0%"), ("agrees", agree, ".0%")]
    if all(len(r) > 16 for rows in groups for r in rows):
        stats.append(("not worse", not_worse, ".0%"))
    w = 11
    print(f"  {'':<14}{'':<12}{'decisions':>9}" + "".join(f"  {h:>{w}}" for h, _, _ in stats))
    for name, k in zip(names, keep):
        sets = [[r for r in rows if k(r)] for rows in groups]
        if not all(sets):
            continue
        for who, xs in zip(("you", "top players"), sets):
            print(f"  {name if who == 'you' else '':<14}{who:<12}{len(xs):>9}"
                  + "".join(f"  {format(f(xs), fmt.lstrip('+')):>{w}}" for _, f, fmt in stats))
        ci = boot(sets, [f for _, f, _ in stats])
        print(f"  {'':<14}{'difference':<12}{'':>9}"
              + "".join(f"  {format(f(sets[1]) - f(sets[0]), fmt if fmt[0] == '+' else '+' + fmt):>{w}}"
                        for _, f, fmt in stats))
        print(f"  {'':<14}{'  95%':<12}{'':>9}"
              + "".join(f"  {format(ci[2 * i], '+.3f' if fmt.endswith('f') else '+.0%') + '..' + format(ci[2 * i + 1], '+.3f' if fmt.endswith('f') else '+.0%'):>{w}}"
                        for i, (_, _, fmt) in enumerate(stats)))
    print()


def who_was_right(rows, rollouts, title):
    """won − calibrated P(win) of the player's choice, where they disagreed with the planner and
    where they agreed."""
    known = [r for r in rows if r[1] in ("won", "lost")]
    fs, _ = regret.calibrate(known, rollouts)
    res = [(r, (r[1] == "won") - f(r[4]), r[6] != r[7]) for r, f in zip(known, fs)]
    dis = [x for x in res if x[2]]
    agr = [x for x in res if not x[2]]
    big = [x for x in dis if x[0][3] > regret.BLUNDER]

    def m(xs):
        return statistics.mean(x[1] for x in xs) if xs else float("nan")

    rng = random.Random(1)
    by = defaultdict(list)
    for x in res:
        by[game(x[0][0])].append(x)
    ks = list(by)
    diffs = []
    for _ in range(1000):
        pick = [x for k in (rng.choice(ks) for _ in ks) for x in by[k]]
        diffs.append(m([x for x in pick if x[2]]) - m([x for x in pick if not x[2]]))
    diffs.sort()
    print(f"  {title}: {len(dis)} decisions against the planner, {len(agr)} with it.")
    print(f"    won − estimate for their choice: {m(dis):+.3f} where they disagreed, {m(agr):+.3f} where they "
          f"agreed; difference {m(dis) - m(agr):+.3f} (95% {diffs[25]:+.3f}..{diffs[974]:+.3f})")
    if big:
        print(f"    where the planner called it a blunder ({len(big)}): {m(big):+.3f}")
    per = defaultdict(list)
    for x in dis:
        per[x[0][2]].append(x)
    print("    by decision, where they disagreed: " + "; ".join(
        f"{k} {len(v)}, {m(v):+.3f}" for k, v in sorted(per.items(), key=lambda kv: -len(kv[1]))))


# Against real results ----------------------------------------------------------------------


def auc(pairs) -> float:
    """Of (estimate, won) pairs: the chance that a decision from a battle that was won has a
    higher estimate than one from a battle that was lost, ties counting half. It measures how well
    the estimates rank positions, whatever their calibration: 0.5 is chance, 1 is perfect."""
    won = sorted(p for p, w in pairs if w)
    lost = [p for p, w in pairs if not w]
    if not won or not lost:
        return float("nan")
    below = sum(bisect.bisect_left(won, x) + 0.5 * (bisect.bisect_right(won, x) - bisect.bisect_left(won, x))
                for x in lost)
    return 1 - below / (len(won) * len(lost))


def brier(pairs) -> float:
    return statistics.mean((p - w) ** 2 for p, w in pairs) if pairs else float("nan")


def scored(rows, rollouts):
    """Each decision in a battle with a result: (row, estimate, calibrated estimate, won). The
    estimate is the planner's P(win) for what the player chose. The calibration is
    regret.calibrate's: one Platt fit per stage, cross-validated by battle."""
    known = [r for r in rows if r[1] in ("won", "lost")]
    if not known:
        return []
    fs, _ = regret.calibrate(known, rollouts)
    return [(r, r[4], f(r[4]), r[1] == "won") for r, f in zip(known, fs)]


REAL = (("ranking (AUC)", lambda xs: auc([(x[1], x[3]) for x in xs]), "higher is better"),
        ("Brier", lambda xs: brier([(x[1], x[3]) for x in xs]), "lower is better"),
        ("Brier, calibrated", lambda xs: brier([(x[2], x[3]) for x in xs]), "lower is better"))
STAGE_KEEP = [(name, lambda r, g=g: regret.stage(r[10]) == g) for g, name in enumerate(regret.STAGES)] \
    + [("all", lambda r: True)]


def against_real_results(title, xs):
    """One planner's estimates against the real results, by stage."""
    if not xs:
        return
    rate = statistics.mean(x[3] for x in xs)
    print(f"  {title}: {len(xs)} decisions in {len({game(x[0][0]) for x in xs})} battles with a result "
          f"(always guessing the base rate scores Brier {rate * (1 - rate):.3f})")
    print(f"    {'':<12}{'decisions':>9}" + "".join(f"{name:>20}" for name, _, _ in REAL))
    for name, keep in STAGE_KEEP:
        sub = [x for x in xs if keep(x[0])]
        if sub:
            print(f"    {name:<12}{len(sub):>9}" + "".join(f"{f(sub):>20.3f}" for _, f, _ in REAL))


def paired_boot(sets, stat, n=1000, seed=0):
    """95% intervals of stat(sets[k]) − stat(sets[0]) for k ≥ 1, the sets being the same
    decisions scored by different planners, resampling whole games."""
    by = defaultdict(list)
    for i, x in enumerate(sets[0]):
        by[game(x[0][0])].append(i)
    keys = list(by)
    rng = random.Random(seed)
    diffs = [[] for _ in sets[1:]]
    for _ in range(n):
        idx = [i for k in (rng.choice(keys) for _ in keys) for i in by[k]]
        base = stat([sets[0][i] for i in idx])
        for d, s in zip(diffs, sets[1:]):
            d.append(stat([s[i] for i in idx]) - base)
    out = []
    for d in diffs:
        d = sorted(x for x in d if x == x)   # a resample can lack a won or a lost battle
        out.append((d[int(0.025 * len(d))], d[int(0.975 * len(d)) - 1]) if d else (float("nan"),) * 2)
    return out


def spec_options(spec: str, args) -> dict:
    """"rollout:128", "rollout:128:2048" or "pomcp:128:2048": planner, rollouts, adaptive cap."""
    parts = spec.split(":")
    if parts[0] not in ("rollout", "pomcp") or not 2 <= len(parts) <= 3:
        raise SystemExit(f"bad setting {spec!r}: use planner:rollouts[:cap], e.g. rollout:128 or pomcp:128:2048")
    return {"rollouts": int(parts[1]), "styles": list(args.styles), "cap": int(parts[2]) if len(parts) == 3 else 0,
            "planner": parts[0], "depth": args.depth}


def run_compare(args):
    if len(args.settings) < 2:
        raise SystemExit("compare needs two or more settings, e.g. compare rollout:128:2048 pomcp:128:2048")
    specs = [(s, spec_options(s, args)) for s in args.settings]
    print("Against real results: each planner's P(win) for the choice the player made, scored against who "
          "really won, on the same decisions.")
    print("  ranking (AUC): the chance a decision from a battle that was won gets a higher estimate than one "
          "from a battle that was lost (higher is better; calibration doesn't affect it).")
    print("  Brier: squared error (lower is better), as estimated and after the per-stage calibration.")
    print(f"  Differences are each setting minus {specs[0][0]}, with 95% intervals from resampling whole games.\n")
    for who, folder, fmt in (("you", args.mine, MINE_FORMAT), ("top", args.stream, args.stream_format)):
        rows = [rows_for(who, folder, {**o, "format": fmt}, args.workers, args.fresh)[0] for _, o in specs]
        # The same decisions in each: match them by battle, turn, kind and order.
        keyed = []
        for rs in rows:
            seen, d = defaultdict(int), {}
            for r in rs:
                k = (r[0], r[11], r[2])
                d[k + (seen[k],)] = r
                seen[k] += 1
            keyed.append(d)
        common = [k for k in keyed[0] if all(k in d for d in keyed[1:])]
        sets = []
        for (_, o), d in zip(specs, keyed):
            by = {id(x[0]): x for x in scored([d[k] for k in common], o["rollouts"])}
            sets.append([by[id(d[k])] for k in common if id(d[k]) in by])
        if not sets[0]:
            continue
        rate = statistics.mean(x[3] for x in sets[0])
        print(f"{WHO[who].capitalize()}: {len(sets[0])} decisions in {len({game(x[0][0]) for x in sets[0]})} "
              f"battles with a result (always guessing the base rate scores Brier {rate * (1 - rate):.3f})")
        w = max(16, *(len(s) + 2 for s, _ in specs))
        dw = [max(26, len(s) + 14) for s, _ in specs[1:]]
        for name, f, better in REAL:
            print(f"  {name} ({better})")
            print(f"    {'':<12}{'decisions':>9}" + "".join(f"{s:>{w}}" for s, _ in specs)
                  + "".join(f"{'difference, ' + s:>{x}}" for (s, _), x in zip(specs[1:], dw)))
            for stage_name, keep in STAGE_KEEP:
                subs = [[x for x in xs if keep(x[0])] for xs in sets]
                if not subs[0]:
                    continue
                cis = paired_boot(subs, f)
                vals = [f(xs) for xs in subs]
                diffs = [f"{v - vals[0]:+.3f} ({lo:+.3f}..{hi:+.3f})" for v, (lo, hi) in zip(vals[1:], cis)]
                print(f"    {stage_name:<12}{len(subs[0]):>9}" + "".join(f"{v:>{w}.3f}" for v in vals)
                      + "".join(f"{d:>{x}}" for d, x in zip(diffs, dw)))
        print()


def run_regret(args):
    opts = {"rollouts": args.rollouts, "styles": list(args.styles), "cap": args.adaptive, "planner": args.planner,
            "depth": args.depth}
    print(f"Decision regret, {args.planner} planner" + (f" (tree depth {args.depth})" if args.planner == "pomcp" else "")
          + f", {args.rollouts} rollouts" + (f", doubled up to {args.adaptive} until settled" if args.adaptive else "")
          + f", opponents in the belief and rollouts: {', '.join(args.styles)}.")
    mine, _ = rows_for("you", args.mine, {**opts, "format": MINE_FORMAT}, args.workers, args.fresh)
    top, _ = rows_for("top", args.stream, {**opts, "format": args.stream_format}, args.workers, args.fresh)
    for who, rows in (("You", mine), ("Top players", top)):
        if rows and len(rows[0]) > 16:
            n = [r[14] for r in rows]
            print(f"  {who}: {statistics.mean(n):.0f} rollouts a decision on average, "
                  f"{sum(x >= args.adaptive for x in n) / len(n):.0%} reached the cap")
    games = {game(r[0]) for r in top}
    print(f"You: {len(mine)} decisions in {len({r[0] for r in mine})} battles (Mega Great League). Top players: "
          f"{len(top)} decisions in {len({r[0] for r in top})} player views of {len(games)} battles (Great League).\n")
    groups = (mine, top)
    side_by_side("By stage (Pokémon left, yours v theirs):", groups,
                 [lambda r, g=g: regret.stage(r[10]) == g for g in range(3)] + [lambda r: True],
                 list(regret.STAGES) + ["all"])
    kinds = ("throw", "hold", "shield", "switch", "replace")
    side_by_side("By decision:", groups, [lambda r, k=k: r[2] == k for k in kinds], kinds)
    side_by_side("By decision, after 3v3:", groups,
                 [lambda r, k=k: r[2] == k and r[10] != (3, 3) for k in kinds], kinds)
    print("Who was right, where a player went against the planner:")
    who_was_right(mine, args.rollouts, "You")
    who_was_right(top, args.rollouts, "Top players")
    print()
    print("Against real results: the planner's P(win) for the choice made, against who really won "
          "(ranking: higher is better; Brier: lower is better; compare scores two planners):")
    against_real_results("You", scored(mine, args.rollouts))
    against_real_results("Top players", scored(top, args.rollouts))
    print()
    worst = sorted(top, key=lambda r: -r[3])[:12]
    print("Top players' costliest decisions by the planner (view, turn, left):")
    for r in worst:
        print(f"  {r[0]:<30} turn {r[11]:>3}  {r[10][0]}v{r[10][1]}  {r[2]:<8} regret {r[3]:+.2f}: "
              f"{r[6]} (P(win) {r[4]:.2f}), planner {r[7]} ({r[5]:.2f}); {r[1] or 'result unknown'}")


# Opponent model ----------------------------------------------------------------------------

def predictor(model: OpponentModel, kind):
    if kind == "shield":
        return lambda r: (lambda q: [1 - q, q])(_sigmoid(sum(a * x for a, x in zip(model.shield, r[2]))))
    if kind == "switch":
        return lambda r: (lambda q: [1 - q, q])(_sigmoid(sum(a * x for a, x in zip(model.switch, r[2]))))
    if kind == "throw":
        return lambda r: _softmax([sum(a * x for a, x in zip(row, r[2])) for row in model.throw], r[4])
    return lambda r: _softmax([sum(a * x for a, x in zip(model.pick, opt)) for opt in r[2]], [True] * len(r[2]))


def run_model(args):
    saved = OpponentModel.load()
    if saved is None or saved.switch is None or saved.pick is None:
        raise SystemExit("No full opponent model saved: run python3 -m experiments.opponent_model first.")
    gd, mine_b = battles_of(MINE_FORMAT, args.mine)
    mine = om.cases(gd, mine_b)
    gd, top_b = battles_of(args.stream_format, args.stream)
    top = om.cases(gd, top_b)
    games = sorted({game(r[0]) for r in top})
    random.Random(0).shuffle(games)
    fold = {g: k % args.folds for k, g in enumerate(games)}
    print(f"Top players' decisions as an opponent, in {len({r[0] for r in top})} player views of "
          f"{len(games)} battles: " + ", ".join(f"{sum(r[1] == k for r in top)} {k}" for k in om.KINDS)
          + f". Your opponents': " + ", ".join(f"{sum(r[1] == k for r in mine)} {k}" for k in om.KINDS)
          + f". Refits use {args.folds}-fold cross-validation by battle.\n")

    names = {"shield": ("no", "yes"), "throw": CHOICES, "switch": ("stay", "switch")}
    for kind in om.KINDS:
        rows = [r for r in top if r[1] == kind]
        theirs = [r for r in mine if r[1] == kind]
        if len(rows) < args.folds:
            continue
        yours = predictor(saved, kind)
        held = {k: [] for k in ("your model", "refit on top players", "fitted on both", "styles", "base rates")}
        for k in range(args.folds):
            train = [r for r in rows if fold[game(r[0])] != k]
            test = [r for r in rows if fold[game(r[0])] == k]
            if not test or not train:
                continue
            _, own = om.fit(kind, train, args.l2)
            _, both = om.fit(kind, train + theirs, args.l2)
            styles, base = om.baselines(kind, train)
            for name, f in (("your model", yours), ("refit on top players", own), ("fitted on both", both),
                            ("styles", styles), ("base rates", base)):
                held[name] += [(r, f(r)) for r in test]
        if kind == "pick":
            print(f"pick: {len(rows)} decisions between two Pokémon")
        else:
            share = lambda xs, c: sum(r[3] == c for r in xs) / len(xs)
            print(f"{kind}: {len(rows)} decisions; top players "
                  + ", ".join(f"{names[kind][c]} {share(rows, c):.0%}" for c in range(len(names[kind])))
                  + "; your opponents "
                  + ", ".join(f"{names[kind][c]} {share(theirs, c):.0%}" for c in range(len(names[kind]))))
        print(f"  {'model':<22}{'log loss':>10}{'accuracy':>10}")
        for name, pairs in held.items():
            loss, acc = om.scores(pairs)
            print(f"  {name:<22}{loss:>10.3f}{acc:>10.1%}")
        # Is your model worse than one fitted on them? Per-decision log loss differences,
        # resampled by battle.
        diff = defaultdict(list)
        for (r, p), (_, q) in zip(held["your model"], held["refit on top players"]):
            diff[game(r[0])].append(-math.log(max(p[r[3]], 1e-6)) + math.log(max(q[r[3]], 1e-6)))
        ks = list(diff)
        rng = random.Random(2)
        bs = sorted(statistics.mean([d for k in (rng.choice(ks) for _ in ks) for d in diff[k]])
                    for _ in range(1000))
        d = statistics.mean([x for v in diff.values() for x in v])
        print(f"  your model − refit: {d:+.3f} log loss (95% {bs[25]:+.3f}..{bs[974]:+.3f})\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=("regret", "model", "compare"))
    ap.add_argument("settings", nargs="*", help="for compare: planner:rollouts[:cap], e.g. rollout:128:2048")
    ap.add_argument("--mine", type=Path, default=MINE, help="your Battle Turns export")
    ap.add_argument("--stream", type=Path, default=STREAM, help="the stream's battle-turns export")
    ap.add_argument("--stream-format", default=STREAM_FORMAT)
    ap.add_argument("--rollouts", type=int, default=128)
    ap.add_argument("--styles", nargs="+", default=list(STYLES) + ["learned"])
    ap.add_argument("--workers", type=int, default=None)
    ap.add_argument("--fresh", action="store_true", help="rerun the regret instead of using cached rows")
    ap.add_argument("--adaptive", type=int, default=0, metavar="CAP",
                    help="adaptive rollouts: double them on a decision until it's settled, up to CAP")
    ap.add_argument("--planner", choices=("rollout", "pomcp"), default="rollout")
    ap.add_argument("--depth", type=int, default=8, help="POMCP's tree depth, in decisions")
    ap.add_argument("--folds", type=int, default=5)
    ap.add_argument("--l2", type=float, default=1.0)
    args = ap.parse_args()
    {"regret": run_regret, "model": run_model, "compare": run_compare}[args.what](args)


if __name__ == "__main__":
    main()
