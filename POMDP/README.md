# ManGo POMDP: planning to win Great League battles

An exploration of the AA228/CS238 project proposal *ManGo: Gotta Predict 'Em All*: treat a
Pokémon GO trainer battle as a POMDP and plan against an opponent whose team, moves, energy
and play style are hidden.

It's separate from the app. Nothing here is imported by `App/`, `PvPCore/` or `Extension/`,
and nothing there is changed. It's Python 3.10+ (standard library only; `python3` on a Mac can
be the system 3.9) with one C file for speed, compiled automatically when a C compiler is around.
It has its own copy of PvPoke's data in `data/`. The link to ManGo is conceptual: ManGo's screen
reader produces the observations a player gets, and its `OpponentTracker` does the energy
counting that `belief.EnergyCounter` does here.

    cd POMDP
    python3 -m experiments.duel medicham azumarill             # a 1v1, solved
    python3 -m experiments.duel medicham azumarill --grid      # all 9 shield scenarios
    python3 -m experiments.meta --top 12                       # every 1v1 among the top 12
    python3 -m experiments.demo --seed 3 --opponent nuker      # a 3v3 battle, narrated
    python3 -m experiments.tournament --games 150              # 3v3 win rates
    python3 -m experiments.top_teams select                    # pick a top Mega Great League team
    python3 -m experiments.top_teams evaluate 25 --lead 2 --plan   # and a game plan against the rest
    python3 -m unittest discover tests

The work starts with 1v1s, which can be solved exactly, then builds up to full 3v3 battles with
hidden teams.

## Solving 1v1 matchups

A 1v1 like PvPoke's sandbox has both movesets known and 0–2 shields each. Both Pokémon fast
move to build energy. Each time a fast move finishes, its player picks one more fast move or a
charged move it can afford now; holding energy is just picking the fast move again. When a charged
move comes in, the defender picks whether to shield. Winning is pacing: how many fast moves
before each throw, which move to throw, and which hits to shield.

**Rules.** `battle.py` follows PvPoke's
[guide to fast move registration](https://pvpoke.com/articles/strategy/guide-to-fast-move-registration/):

- A fast move's damage and energy register on its last turn, duration − 1 turns after it's
  used. A 1-turn move registers on the turn it's used.
- A charged move interrupts every fast move in progress. Each one registers on the spot,
  including one the opponent starts that same turn (a "sneak"). Then both cooldowns reset, so
  both Pokémon act again on the next turn. Interrupting a long fast move early grants its user
  "free" turns; throwing on the turn it registers grants none.
- Charged moves thrown on the same turn go in CMP order (higher attack first). A charged move
  fails if a fast move registering that turn knocks out its user.

**The game.** With energy counted (ManGo's job), nothing is hidden in a 1v1. But both players
choose each turn's action at the same time, which makes it a finite zero-sum stochastic game.
Because cooldowns reset after every charged move, a state is just HP, energy, shields and buff
stages for both sides, plus where the turn falls in the fast-move rhythm (turns since the last
charged move, mod the lcm of the two durations). `duel.py` solves it by memoized backward
induction:

- a max/min node when only one side can choose;
- a matrix game, solved for its mixed equilibrium, when both can;
- a max/min node for each shield decision;
- chance nodes for buff rolls and CMP ties.

The payoff is 0.9 × result + 0.1 × HP% margin. Any win beats any loss, and among wins, more HP
left is better. PvPoke's battle rating is 500 + 500 × margin, so the two line up.

**Speed.** `duel.c` is the same solver in C. It's compiled on first use and cached in
`~/Library/Caches/ManGo-pomdp`; without a compiler, `make_duel` falls back to Python. The tests
require the two to agree exactly.

| Matchup | States | C | Python |
|---|---|---|---|
| Medicham vs Azumarill, 1-1 shields | 0.4M | 0.2 s | 50 s |
| Medicham vs Azumarill, all 9 shield scenarios | 1.8M | 1.1 s | about 280 s |
| Melmetal vs Altaria, 2-2 (the heaviest so far; random buffs multiply states) | 23M | 17 s | — |

**Checks.** Playing the solution in the simulator reproduces the solver's value exactly. The
solution also can't be exploited: against every heuristic style and a random player, from
either side, it scores at least the game value.

**What it finds.**

- *Medicham vs Azumarill, 1-1:* Azumarill wins either way. But optimal Medicham holds its energy
  for 11 turns and throws Dynamic Punch at 100, finishing at a 335 rating against the baiter
  heuristic's 291.
- *Medicham vs Azumarill, 2-0:* optimal play wins (730) where the heuristic loses (416).
- *All 66 pairs among the top 12, 1-1 shields* (`experiments.meta --top 12`):
  - Optimal play changes the winner in 12 of 66 matchups, compared with both sides playing the
    baiter heuristic.
  - A solved player facing the heuristic gains 46 rating points on average (median 12, max 456).
  - Only 2 matchups need a mixed strategy on the optimal line; the rest are pure.
- *The biggest swing, Corviknight vs Shadow Hydreigon:* 650 with optimal play, 194 with the
  heuristic. Both sides farm to 100 energy and throw back to back. Corviknight resists Dragon
  Breath and Fly, so it survives the exchange. The heuristic spends its energy baiting with Air
  Cutter instead.

**Next for 1v1.** The opponent's moveset is the hidden information left (until they throw).
Each moveset hypothesis is its own solved game. So the natural next step is a QMDP-style player
that weights each hypothesis's action values by the belief. The same per-hypothesis values also
measure what knowing their moves is worth.

## 3v3 battles as a POMDP

| POMDP piece | Here |
|---|---|
| State | Both teams' HP, energy and buff stages, shields, switch timers, who is mid fast move, the battle clock, plus the opponent's hidden team, movesets and play style |
| Actions | When your fast move finishes: fast move, a charged move you can afford, or a switch. When a charged move comes in: shield or not. After a faint: which Pokémon to bring in |
| Transitions | `battle.py`: deterministic 0.5s turns following PvPoke's `Battle.js` and its fast move registration guide (damage formula, fast moves register on their last turn, charged moves interrupt fast moves and reset cooldowns, CMP, 45s switch timer, 4-minute clock). Randomness comes only from buff chances, CMP ties, and the opponent's policy |
| Observations | `battle.View`: your team in full; the opponent's active Pokémon, its HP and buff stages, shields, Pokémon left, and every move they've used. Never their energy, bench or unused moves |
| Reward | +1 win, −1 loss, 0 tie, at the end |

## Sources of uncertainty, and how each is handled

**Energy** is hidden but deterministically inferable. You see every fast move and know its
energy and length, so `EnergyCounter` counts it exactly; ManGo does the same from the screen.
Their switch timer is counted the same way. The tests check that the count always equals the
true energy.

**Team and movesets** come from a structured prior (`team_prior.py`). Species are weighted
by PvPoke rank. Teams are reweighted against shared weaknesses and against counters all
three members share, so "three Pokémon that all lose to one meta threat" is unlikely, as in the
proposal. Shared counters are weighted by rarity, because Mimikyu and Cramorant beat almost
everything and so carry no signal. Movesets follow PvPoke's usage counts.

**Play style** is a distribution over four opponent models (`policies.py`): *shielder*,
*baiter*, *nuker* and *casual*. Each one is stochastic (ε = 0.1), so it defines a likelihood
for every decision you see the opponent make.

`belief.py` combines these into a particle filter (200 particles). Each particle is one full
hypothesis: three species, their movesets, and a style.

- When a reveal contradicts a particle, that particle is repaired from the conditional prior.
- Each decision you see the opponent make reweights the particles by how likely it was under
  each particle's style: fast moving when they could have thrown, which move they threw, and
  whether they shielded.

## The 3v3 planner

`planner.py` is online lookahead with rollouts (Kochenderfer et al., *Algorithms for Decision
Making*, ch. 22). At each decision that matters:

1. Sample K = 12 hypotheses from the belief and turn each into a full battle state.
2. For every candidate action, play it, then roll out to the end of the battle. You play the
   *baiter* heuristic; the opponent plays the sampled style.
3. Score every action on the same hypotheses and random seeds (common random numbers).

The planner keeps the rollout policy's own choice unless a paired test says another action is
better by more than one standard error. Without that test, in an earlier run, the planner lost
to its own rollout policy (0.52 vs baiter's 0.58). With it, the planner beats baiter clearly.

**Switching, waiting and catching.** Switching is legal on any turn the 45-second switch timer
allows, and a Pokémon can also wait: do nothing for a turn and stay free. A switch on the turn
the opponent throws takes the throw on the incoming Pokémon ("catching" it). Both sides choose
blind, so catching means predicting the throw turn from counted energy, and waiting keeps a
Pokémon with a multi-turn fast move free for that turn. Rollouts are the expensive part, so the
planner only weighs a switch at some moments. Its `switch_at` option sets them; append
`@start`, `@zero-turn`, `@catch` or `@any` to a planner's name:

| `switch_at` | The planner weighs a switch |
|---|---|
| `start` | within 2 turns of a new matchup |
| `zero-turn` | that, and the turn right after any charged move (thrown, shielded or taken): a 0-turn switch, which costs no fast move |
| `catch` (default) | that, and whenever their counted energy is within one fast move of a charged move: switching now, or waiting and switching the turn they throw |
| `any` | every turn |

With `catch`, our own rollout policy catches too: it stays free and switches when the
predicted throw is a big hit that a bench Pokémon takes much less of. Measured on paired games:

| Switching | Great League tournament | #25 vs heuristic styles | #25 vs the planner (`@start`) | Catches per game |
|---|---|---|---|---|
| `start` | 0.798 ± 0.023 | 0.961 | 0.721 | 0.00–0.01 |
| `zero-turn` | 0.807 ± 0.023 | | | |
| `catch`, plain rollouts | | 0.963 | 0.697 | 0.05–0.06 |
| `catch` (default) | 0.803 ± 0.023 | 0.960 | 0.676 | 0.07–0.09 |

Head to head, the same planner (`planner-list`) on 250 random pairs of the listed Mega Great
League teams, each played from both sides so team strength cancels:

| Matchup | Win rate |
|---|---|
| `catch` vs `start` | 0.512 ± 0.021 |
| `zero-turn` vs `start` | 0.532 ± 0.018 |

The planner does use these options. With `catch` it waits about 0.1–0.2 times a game, and about
half of its catches land on a Pokémon that resists the move. They don't change the win rate,
though. The switch timer allows only about one switch a game, and without these options the
planner spends it at the start of a matchup anyway. Team #25's dip against the planner
(rightmost column, 376 games each, about ±0.023) doesn't show up head to head. The bug fix that
came with catching mattered more: rollouts now know when the opponent is mid fast move. That
fix alone took the planner from 0.753 to 0.798 on the tournament's games.

Ablations, by player name:

| Player | What it is |
|---|---|
| `random`, `shielder`, `baiter`, `nuker`, `casual` | Baselines: the heuristics on their own |
| `planner` | The full belief: structured prior plus four styles |
| `planner-1style` | Structured prior, but assumes every opponent is a baiter |
| `planner-flat` | Flat prior (uniform over the top 100 species, uniform moves) and one style |
| `oracle` | Same planner, but knows the opponent's real team and style. An upper bound, and not legal |

## 3v3 results

`python3 -m experiments.tournament --games 150 --players random shielder baiter nuker casual planner-flat planner-1style planner oracle`:
each player plays 300 battles. Each game is 2 battles with the teams swapped, and the opponent
style is drawn uniformly. Ties count as half a win. The run took about 4 minutes on 10 cores.
These numbers use the current rules and planner: charged moves reset cooldowns, both sides
choose simultaneously, and the planner can wait and catch (above).

| Player | Win rate | vs shielder | vs baiter | vs nuker | vs casual |
|---|---|---|---|---|---|
| random | 0.367 ± 0.028 | 0.324 | 0.297 | 0.447 | 0.390 |
| shielder | 0.555 ± 0.029 | 0.471 | 0.466 | 0.645 | 0.622 |
| baiter | 0.555 ± 0.029 | 0.574 | 0.426 | 0.618 | 0.598 |
| nuker | 0.455 ± 0.029 | 0.397 | 0.318 | 0.467 | 0.616 |
| casual | 0.403 ± 0.028 | 0.338 | 0.297 | 0.428 | 0.530 |
| planner-flat | 0.780 ± 0.024 | 0.794 | 0.743 | 0.737 | 0.841 |
| planner-1style | 0.795 ± 0.023 | 0.846 | 0.743 | 0.763 | 0.829 |
| **planner** | **0.803 ± 0.023** | 0.794 | 0.662 | 0.868 | 0.878 |
| oracle | 0.900 ± 0.017 | 0.912 | 0.797 | 0.934 | 0.951 |

What this says so far:

- **Lookahead is most of the win.** Every planner beats every heuristic by about 22–25
  points, including baiter, which is the planner's own rollout policy.
- **A prior over all Great League teams isn't paying for itself yet.** The full belief, the
  single-style belief and the flat prior are within about one standard error of each other
  (0.78–0.80). When the opponent's team is known to come from a short list, the belief does
  pay: see the Mega Great League experiment below.
- **There's real value in information left to capture.** The oracle wins 10 points more.
  Telling apart what it gains from knowing the team and moves versus knowing the style is the
  obvious next ablation. The 1v1 solver offers a cleaner way in: with the opponent's moveset as
  the only hidden information, it can measure exactly what knowing their moves is worth.
  Other candidate improvements: more rollouts per decision, reweighting on switches and
  replacements, and rollout opponents built from the opponent's own belief about you rather
  than a fixed style.

## Picking a team from PvPoke's top Mega Great League teams

`data/mega_great_league_top_teams.csv` is PvPoke's export of its 48 top Mega Great League teams
(1500 CP, Mega Evolutions allowed). The task: pick one, and find a way to play it that beats
the other 47. `experiments/top_teams.py` does it, and `results/mega_team25.txt` has the full
outputs, including a game plan for every opponent.

**What it needed.**

- *Data.* `data/mega_great_league.json` comes from PvPoke's Mega Great League rankings, keeping
  every Pokémon and move on the listed teams. The export abbreviates moves ("DbI", "WBF").
  `trim_data.py` decodes them with PvPoke's own abbreviations: the game master's, else the
  initials of the move id. Each decodes to exactly one move in that species' movepool.
- *Form changes.* 14 of the 48 teams run Mimikyu and 11 run Cramorant, so the simulator now has
  Disguise, Gulp Missile and Hunger Switch (Morpeko), as PvPoke's Battle.js implements them.
- *A belief over the list.* With `TeamListPrior`, the opponent brings one of the other 47 teams,
  weighted by usage. Seeing their lead narrows it to the teams that fit. `planner-list` is the
  3v3 planner with that belief.
- *Simultaneous choices.* Both sides now choose from the start-of-turn state. Before, the second
  side saw the first side's switch on the same turn, and the planner's belief hadn't seen the
  new Pokémon yet. The tournament above always seated the planner first, so it never hit this.

**Picking the team** (`top_teams rank`, then `select`):

1. *Round robin with heuristic play* (all pairs, both sides the same style). Thievul / Cramorant
   / Stunfisk (#25) is strongest: it wins 0.67 and beats 35 of 47. PvPoke's team rating barely
   agrees with simulated strength; its top-rated team (#1) comes 29th.
2. *The planner against the heuristic styles*, with each of the top 6 teams and each lead. This
   doesn't separate them: every team's best lead scores 0.955–0.979 and beats all 47.
3. *The tiebreak is a stronger opponent:* the same planner, which also knows the list. Each
   team with its best lead, 8 games per opponent:

| Team, lead | vs heuristic styles | vs the planner | Beaten (of 47) vs the planner |
|---|---|---|---|
| #25 Thievul / Cramorant / Stunfisk, Cramorant lead | 0.969 | 0.649 | 30 |
| #33 Melmetal / Corsola-G / Cramorant, Melmetal lead | 0.975 | 0.644 | 36 |
| #26 Cramorant / Marowak / Sableyeˢ, Cramorant lead | 0.971 | 0.577 | 25 |
| #33 again, Cramorant lead | 0.979 | 0.574 | 27 |
| #32 Cramorant / Marowak / Tinkaton, Cramorant lead | 0.959 | 0.564 | 25 |
| #36 Cramorant / Marowak / Mimikyu, Cramorant lead | 0.964 | 0.533 | 23 |
| #45 Cramorant / Mimikyu / Thievul, Cramorant lead | 0.955 | 0.505 | 18 |

The top two are close, so they were rerun at 16 games per opponent: #25 with a Cramorant lead
wins 0.638 ± 0.017 and beats 35. #33 with a Melmetal lead wins 0.630 ± 0.018 and also beats
35. #25 with a Thievul lead wins 0.624 ± 0.018 and beats 31. It's a near tie. #25 with a
Cramorant lead edges it on win rate, and it beats #33 head to head (#33 wins 0.06). With the
earlier planner (before waiting, catching and the rollout timing fix), #25 led by Thievul came
first, at 0.741 against that planner.

**Team #25, Cramorant / Thievul / Stunfisk, leading Cramorant.** Against the heuristic styles,
4 games per opponent per style; against the planner, 16 games per opponent:

| Our player | vs heuristic styles | Beaten | vs the planner | Beaten |
|---|---|---|---|---|
| baiter heuristic | 0.676 ± 0.017 | 33 | | |
| planner (format prior) | 0.894 ± 0.011 | 45 | 0.557 ± 0.018 | 26 |
| **planner-list** | **0.961 ± 0.007** | **47** | **0.638 ± 0.017** | **35** |
| planner-list + opening book | | | 0.640 ± 0.017 | 35 |
| oracle (knows team and style) | 0.987 ± 0.004 | 47 | | |

The opening book is learned (`top_teams book 25 --lead 2`). For each lead the opponents can
show, it plays every opening against every listed team with that lead: the planner's own
opening, or a swap to either bench Pokémon on turn 0. It keeps a swap only if the swap wins 0.1
more. It swaps to Stunfisk against Araquanid, Marowak, Ninetales and Sableyeˢ leads, and to
Thievul against Charjabug, Ursalunaˢ and Dusknoirˢ. Against the rest the planner chooses. It
was then measured on games it wasn't built from.

What this says:

- **Against heuristic opponents, the strategy beats every team.** planner-list wins 96.1%,
  within 3 points of the oracle. Its worst matchup is #32 Cramorant / Marowak / Tinkaton, at
  0.56. The same team played by the baiter heuristic wins only 68% and fails to beat 14 teams.
  The heuristic plays a Cramorant lead badly; the planner doesn't.
- **Knowing the list pays:** 8 points against the planner (0.638 vs 0.557), 7 against the
  heuristics (0.961 vs 0.894).
- **Against an equally strong opponent, nothing found beats all 47.** #25 beats 35. #17
  Mimikyu / Sableyeˢ / Tinkaton wins 15 of 16 games. #10, #12, #29 and #32 each win 12 of 16.
- **The opening book adds nothing** (0.640 vs 0.638).
- **A better planner helps both sides.** The waiting, catching and timing fix improved the
  opponent planner as much as ours. Against an equally strong opponent, the best team's win
  rate fell from 0.72 to 0.64, so team choice matters less once both sides play well.

## Layout

    data/great_league.json     PvPoke's top 200 Great League Pokémon (stats, types, move usage, counters) and their moves
    data/mega_great_league.json          the same for Mega Great League, plus its top teams, decoded
    data/mega_great_league_top_teams.csv PvPoke's top Mega Great League teams export
    data/openings_25.json      the opening book for team #25, Cramorant leading (top_teams book 25 --lead 2)
    results/mega_team25.txt    team #25's full results and per-opponent game plans
    scripts/update_data.sh     re-download and trim PvPoke's data (scripts/trim_data.py)
    mango_pomdp/gamedata.py    types, moves, damage formula
    mango_pomdp/battle.py      the simulator and the player's View
    mango_pomdp/duel.py        the exact 1v1 solver, the player that plays its solution, and CDuel
    mango_pomdp/duel.c         the same solver in C
    mango_pomdp/timeline.py    a battle drawn as text, like PvPoke's timeline
    mango_pomdp/team_prior.py  the structured team and moveset prior, and the prior over a list of teams
    mango_pomdp/policies.py    opponent styles, matchup heuristics, baselines
    mango_pomdp/belief.py      energy counting and the particle belief (plus the Oracle)
    mango_pomdp/planner.py     the rollout planner
    mango_pomdp/match.py       building players by name, playing one battle
    experiments/               duel.py (one 1v1, solved), meta.py (every 1v1 among the top N),
                               tournament.py (3v3 win rates), demo.py (one narrated 3v3 battle),
                               top_teams.py (pick one of PvPoke's top teams and plan against the rest)
    tests/                     simulator, solver, prior, belief and planner checks

## Simplifications and next steps

- **Mechanics.** No Charged Attack minigame (every charged move hits at full power) and no
  mega moves (the "+" moves; no listed team runs one). Only the planner waits; the heuristic
  styles always act when free.
  The 3v3 simulator has PvPoke's form changes for Mimikyu, Cramorant and Morpeko, but not
  Aegislash or Minior, and the 1v1 solver has none. Everyone uses PvPoke's default CP 1500
  IVs. The 1v1 solver ignores the 4-minute clock.
- **Opponents.** In the Great League tournament, opponents are the four heuristic styles, so
  "hard to exploit" is only tested against them: the lowest per-style win rate is a crude
  exploitability number. The Mega Great League experiment also plays the planner against
  itself. A best-response search against it is the next step.
- **Planner.** It decides one action at a time with fixed rollout policies, and its catches
  rely on the opponent throwing when its style model says it will. POMCP (a search
  tree over action–observation histories) or longer open-loop sequences would make it look
  further ahead, for example to bait now in order to nuke later.
- **Real battles.** ManGo's battle logs (`../Battle Logs/`) record the opponent's moves and the
  counted energy. Replaying them through `Belief` would check the style model against real
  people and show what the planner would have done at each decision.
