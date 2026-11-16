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
    python3 -m experiments.play --hints                        # play a 3v3 against the planner
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

**The actions.** On every turn your Pokémon is free, you can:
- fast move, which locks it in for that move's length;
- throw a charged move you have the energy for;
- switch to either bench Pokémon, when the 45-second switch timer allows;
- wait: do nothing, and stay free next turn.

When they throw, you shield or don't, while you have shields. After a faint, you pick who comes
in. A switch on the turn the opponent throws takes the throw on the incoming Pokémon
("catching" it). Both sides choose blind, so catching means predicting the throw turn from
counted energy. Waiting keeps a Pokémon with a multi-turn fast move free for that turn.

By default (`any`) the planner weighs every legal action on every free turn. Its `switch_at`
option can narrow that to save rollouts; append `@start`, `@zero-turn`, `@catch` or `@any` to a
planner's name:

| `switch_at` | Besides fast and charged moves, the planner weighs |
|---|---|
| `start` | switches within 2 turns of a new matchup |
| `zero-turn` | that, and switches on the turn right after any charged move (thrown, shielded or taken): a 0-turn switch, which costs no fast move |
| `catch` | that, and whenever their counted energy is within one fast move of a charged move: switching now, or waiting and switching the turn they throw |
| `any` (default) | every legal action on every free turn: all of the above, plus switching or waiting on any other turn |

With `any`, a wait or switch at a moment the mechanics don't favor has to beat the default by
3 standard errors instead of 1. With a dozen noisy rollouts on every turn, a plain one-standard-
error test let the planner wander off its default by chance. It then played worse (0.805,
below).

**Farming down.** The planner weighs one more line on every free turn: fast moves only, no
charged moves and no switches, until the opponent's Pokémon in now faints (`planner._Farm`).
That banks the energy for the next matchup. A plain fast move can't show what this is worth,
because its rollouts then go back to the default policy, which throws whenever it can. The
planner with this line beats the same planner without it 0.552 ± 0.021. That's
`planner-list-mixed`, over 250 random pairs of listed Mega Great League teams, played from both
sides.

**Good timing.** The planner's default, which is also its rollout policy, is the baiter
heuristic with two additions:
- *Throw timing* (`policies.Timed`). A charged move registers the opponent's fast move in
  progress on the spot and resets cooldowns, which hands them the turns they had left. So it
  holds a throw until their fast move lands, fast moving meanwhile if its own move ends in
  time, and waiting otherwise.
- *Catching.* When a big hit is coming that a bench Pokémon takes much less of, it stays free
  and switches on the throw turn.

These are heuristics, and sometimes throwing at once is better. Each free turn the planner
weighs throwing now against them. On 100 paired Great League games against the heuristic
styles:

| Planner | Win rate | Seconds per battle |
|---|---|---|
| `catch`, no good timing (the previous default) | 0.828 ± 0.025 | 2.7 |
| `catch` with good timing | 0.845 ± 0.025 | 2.8–3.4 |
| `any`, plain one-standard-error test | 0.805 ± 0.027 | 3.8 |
| `any`, waits and switches off key moments need 2 standard errors | 0.843 ± 0.024 | 4.0 |
| **`any`, 3 standard errors (default)** | **0.858 ± 0.024** | 4.7 |

The two tables above, and the switching comparisons just below, come from earlier versions:
before free 0-turn switches, and (below) before good timing and `any`, when `catch` was the
default. The 3v3 tournament, team #25's results and your battles further down were rerun with
the current rules and planner. With `catch`, measured on paired games:

| Switching | Great League tournament | #25 vs heuristic styles | #25 vs the planner (`@start`) | Catches per game |
|---|---|---|---|---|
| `start` | 0.798 ± 0.023 | 0.961 | 0.721 | 0.00–0.01 |
| `zero-turn` | 0.807 ± 0.023 | | | |
| `catch`, plain rollouts | | 0.963 | 0.697 | 0.05–0.06 |
| `catch`, catching rollouts | 0.803 ± 0.023 | 0.960 | 0.676 | 0.07–0.09 |

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

`python3 -m experiments.tournament --games 150 --players random shielder baiter nuker casual planner-flat planner-1style planner planner-mixed oracle`:
each player plays 300 battles. Each game is 2 battles with the teams swapped, and the opponent
style is drawn uniformly. Ties count as half a win. The run took about 18 minutes on 10 cores.
These numbers use the final rules and planner: charged moves reset cooldowns, both sides choose
simultaneously, 0-turn switches are free, and the planner weighs every legal action on every
free turn, with good timing as its default and the farm-down line.

| Player | Win rate | vs shielder | vs baiter | vs nuker | vs casual |
|---|---|---|---|---|---|
| random | 0.353 ± 0.028 | 0.309 | 0.284 | 0.421 | 0.390 |
| shielder | 0.545 ± 0.029 | 0.471 | 0.439 | 0.632 | 0.622 |
| baiter | 0.565 ± 0.029 | 0.603 | 0.453 | 0.605 | 0.598 |
| nuker | 0.452 ± 0.029 | 0.382 | 0.345 | 0.441 | 0.616 |
| casual | 0.400 ± 0.028 | 0.368 | 0.297 | 0.388 | 0.530 |
| planner-flat | 0.820 ± 0.022 | 0.794 | 0.770 | 0.803 | 0.902 |
| planner-1style | 0.780 ± 0.024 | 0.765 | 0.743 | 0.750 | 0.854 |
| **planner** | **0.830 ± 0.022** | 0.853 | 0.757 | 0.829 | 0.878 |
| planner-mixed | 0.827 ± 0.022 | 0.824 | 0.797 | 0.816 | 0.866 |
| oracle | 0.910 ± 0.017 | 0.926 | 0.811 | 0.961 | 0.939 |

**What these win rates are, and aren't.** The opponents are the four heuristic styles, and
the planner's opponent model is those same four styles, so its belief soon finds which one it
faces and its rollouts predict it closely. The styles are weak: fixed rules for throws and
shields, switching only at a new matchup, no waiting and no throw timing. So 0.83 means much
stronger than simple rule-based play, not that it would beat people 83% of the time. Against an
equally strong planner it's 0.5 by symmetry, and the Mega Great League experiments below play it
against itself. It hasn't been played against people. Automated live play is against Niantic's
terms, so the real-world checks are your recorded battles and decision regret.

What this says:

- **Lookahead is most of the win.** Every planner beats every heuristic by over 20 points,
  including baiter, which is the planner's own rollout policy.
- **Farming down helps everyone.** Adding the farm-down line raised every planner by 1–3
  points, the planner from 0.800 to 0.830. The planner's worst style, baiter, went from 0.703
  to 0.757.
- **A prior over all Great League teams isn't paying for itself yet.** The full belief, the
  single-style belief and the flat prior are within about two standard errors of each other
  (0.78–0.83). When the opponent's team is known to come from a short list, the belief does
  pay: see the Mega Great League experiment below.
- **The learned opponent doesn't cost anything here.** `planner-mixed` adds the opponent
  model learned from your recordings (below) as a fifth type, and plays these opponents as well
  as `planner` does (0.827), with the best result against baiter.
- **There's real value in information left to capture.** The oracle wins 8 points more.
  Telling apart what it gains from knowing the team and moves versus knowing the style is the
  obvious next ablation. The 1v1 solver offers a cleaner way in: with the opponent's moveset as
  the only hidden information, it can measure exactly what knowing their moves is worth.

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
   / Stunfisk (#25) is strongest: it wins 0.66 and beats 34 of 47. PvPoke's team rating barely
   agrees with simulated strength; its top-rated team (#1) comes 31st.

Steps 2 and 3, which picked team #25 and its lead, ran on an earlier planner (`catch`, before
free 0-turn switches, good timing and farming down). They weren't rerun.

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

**Team #25, Cramorant / Thievul / Stunfisk, leading Cramorant**, with the final rules and
planner (farming down included). Against the heuristic styles, 4 games per opponent per style;
against the planner, 16 games per opponent. The opponent planner is `planner-list-mixed`, which
knows the list too:

| Our player | vs heuristic styles | Beaten | vs the planner | Beaten |
|---|---|---|---|---|
| baiter heuristic | 0.686 ± 0.017 | 34 | | |
| planner (format prior) | 0.916 ± 0.010 | 47 | | |
| planner-list | 0.959 ± 0.007 | 47 | 0.639 ± 0.017 | 32 |
| **planner-list-mixed** (styles + learned) | **0.975 ± 0.006** | **47** | **0.608 ± 0.018** | **31** |
| oracle (knows team and style) | 0.983 ± 0.005 | 47 | | |

Before farming down and the learned opponent, planner-list won 0.949 against the heuristics, and
0.625 (beating 31) against planner-list.

The opening book (`top_teams book 25 --lead 2`) was learned with an earlier planner. For each
lead the opponents can show, it played every opening against every listed team with that lead:
the planner's own opening, or a swap to either bench Pokémon on turn 0. It kept a swap only if
the swap won 0.1 more. It swaps to Stunfisk against Araquanid, Marowak, Ninetales and Sableyeˢ
leads, and to Thievul against Charjabug, Ursalunaˢ and Dusknoirˢ; against the rest the planner
chooses. Measured on games it wasn't built from, it added nothing (0.640 vs 0.638 for plain
planner-list then), so it wasn't rerun.

What this says:

- **Against heuristic opponents, the strategy beats every team.** planner-list-mixed wins
  97.5%, within 1 point of the oracle. Its worst matchup is #32 Cramorant / Marowak /
  Tinkaton, at 0.75. The same team played by the baiter heuristic wins only 69% and fails to
  beat 13 teams. These are wins against the heuristics, though, which the planner models
  exactly (see the 3v3 results).
- **Against an equally strong opponent, #25 still wins about 61–64%,** but nothing found beats
  all 47. It beats 31–32. The hardest are #29 Morpeko / Florges / Mimikyu, #4 Charjabug /
  Cradily / Empoleon and #17 Mimikyu / Sableyeˢ / Tinkaton, each won under a third of the time.
- **Knowing the list pays** against the heuristics: 4 points over the format prior (0.959 vs
  0.916).
- **The learned opponent doesn't help against a planner.** On our side it scores 0.608 against
  0.639 without it, within noise. That's expected, since the opponent here is a planner and not
  someone like your recorded opponents.
- **A better planner helps both sides.** Each improvement (waiting, catching, timing, farming
  down) improved the opponent planner as much as ours. Against an equally strong opponent, the
  best team's win rate fell from 0.72 with the earliest planner to about 0.6, so team choice
  matters less once both sides play well.

## Your battles, replayed

Your recorded battles are in two files, with species only and lead first: no recording names
or screen text.
- `data/mega_great_league_my_battles.csv` has each battle's two teams. Pokémon you didn't bring
  out are filled in from your usual team.
- `data/mega_great_league_faced_teams.csv` has the distinct teams: your 4, and the 63 full
  teams you faced. It leaves out 8 battles where fewer than three opponents were seen, and 1
  misread.

They're simulated as Mega Great League battles with PvPoke's recommended movesets, since the
table lists species only.

**Every team against every other** (`top_teams rank --pool all`): PvPoke's 48, your 4, and the
63 you faced, with heuristic play.

| Rank of 115 | Team | Win rate |
|---|---|---|
| 1 | Forretressˢ / Carbink / Marowak (faced) | 0.717 |
| 2 | Sandslash (Alolan) / Marowak / Carbink (faced) | 0.696 |
| 3 | Turtonator / Mimikyu / Forretressˢ (faced) | 0.684 |
| 4 | #25 Thievul / Cramorant / Stunfisk (PvPoke's best) | 0.664 |
| 7 | **Nidoqueen / Mandibuzz / Clodsire (yours)** | 0.640 |
| 63 | **Altaria / Melmetal / Mimikyu (yours)** | 0.489 |
| 88 | **Thievul / Blaziken / Jumpluff (yours, the most used)** | 0.448 |
| 109 | **Blaziken / Jumpluff / Fearow (yours)** | 0.350 |

**Each battle replayed with the planner on your side** (`python3 -m experiments.my_battles
--games 4`). In each of the 63 battles with a full opponent team, your team that day plays that
day's opponent. It's replayed 4 times against each heuristic style and 4 times against the
planner, from both sides. Your side is the final planner, `planner-list-mixed`, and so is the
opponent planner. Each knows only PvPoke's list, not your opponents. The baiter heuristic plays
the same games for comparison. A battle counts as won if more than half its replays are wins,
and as a split if exactly half are:

| Your side played by | vs heuristic opponents | vs the planner |
|---|---|---|
| **planner** | **wins 59 of 63** (0.834 ± 0.012) | **wins 21, splits 20** (0.498 ± 0.031) |
| baiter heuristic | wins 34 of 63 (0.548 ± 0.016) | wins 4, splits 6 (0.188 ± 0.025) |

| Your team | Battles | Planner vs heuristics | Planner vs the planner |
|---|---|---|---|
| Thievul / Jumpluff / Blaziken | 34 | wins 32 (0.82) | wins 11 (0.48) |
| Altaria / Melmetal / Mimikyu | 23 | wins 21 (0.84) | wins 6 (0.48) |
| Nidoqueen / Mandibuzz / Clodsire | 4 | wins 4 (0.97) | wins 3 (0.78) |
| Blaziken / Jumpluff / Fearow | 2 | wins 2 (0.75) | wins 1 (0.50) |

What this says:
- **Against simple opponents, the planner wins nearly all of your battles:** 59 of 63, where
  the baiter heuristic playing the same teams wins 34.
- **Against an equally strong opponent, your teams now break even.** With the planner on both
  sides, your side wins 0.50 of the replays. With the planner before farming down and the
  learned opponent, it won 0.41. The shift is about two standard errors. It doesn't hold with
  your real movesets, though. Replayed from the local Battle Turns export with the movesets your
  buttons showed, the planner on your side still loses the even matchup, about as often as
  before. So the break-even depends on PvPoke's recommended movesets, or is partly noise.
- **Nidoqueen / Mandibuzz / Clodsire is your strongest team here.** It ranks 7th in the round
  robin and does best against the planner too (0.78). It's also your least used.

These are simulations, with PvPoke's recommended movesets. Some battles may have been in other
formats, such as testV3 in the Fantasy Cup. Against the planner, each battle has only 4
replays, so per-battle rates are coarse. The full table is in `results/my_battles.txt`. A
second set of experiments uses the local Battle Turns export: your real movesets, real
results, and the opponents' recorded decisions (`experiments/recorded_battles.py`,
`experiments/recorded_paths.py`). Its output names your recordings, so it stays on the Mac.

## Decision regret on your recorded battles

`python3 -m experiments.regret --rollouts 128` scores your real decisions, like a chess engine's
accuracy score. Each recorded battle in the local Battle Turns export is rebuilt at the start of
every turn where you decided something:
- HP, rebuilt from the recorded moves, and energy, buffs, shields and switch timers;
- whether the opponent was mid fast move;
- what each side had seen so far.

The planner's belief is fed everything you'd seen up to then, so it knows what you knew. It then
estimates each option's chance of winning by rollouts:
- *act*, on a free turn: fast move (a hold, if you could have thrown), each charged move you
  could afford, or each switch;
- *shield*, when they threw at you: shield or not;
- *replace*, after a faint: who comes in.

Regret is P(win) with the planner's best option minus P(win) with yours. Half the rollouts pick
the best option and the other half score both, so noise doesn't inflate the regret. The output
gives mean regret and the share of blunders (over 5 points) for each kind of decision, total
regret per battle split by whether you really won, and the costliest decisions. It names your
recordings, so it stays on the Mac.

**Rebuilding the recordings right mattered most.** At first the planner was strongly
overconfident: in positions it called nearly lost, you went on to win close to half the time.
Most of that came from the rebuilt states, not the planner. Three problems in
`battle_turns.py`, now fixed:
- *HP drifted.* The damage formula uses PvPoke's default IVs, and the export misses some hits,
  so rebuilt HP hit 0 for Pokémon that were still in (in most battles) or left a third of it
  when they really fainted. Each faint is now an anchor: a Pokémon's damage is scaled so its HP
  reaches 0 on the turn it fainted. Until then it keeps at least 1 HP.
- *Faints were missed.* The export often records a faint and its replacement as a plain
  switch. In most of the battles you lost, one of your faints was missing, so your last
  Pokémon always seemed to have a teammate behind it. A switch marked "(0 turns)" without a
  charged move just before can only be a replacement, unless that Pokémon comes back later.
  The losing side's three all fainted. With both rules, nearly every battle's faints fit its
  result, up from fewer than half.
- *The active column lags.* On a turn with a switch, it can still show the Pokémon that left,
  and the rebuild switched it back in for a turn. The recorded switch now wins.

With those fixed, the opponent model fits better on every part. The planner's raw estimates
also beat always guessing your win rate.

**Calibration by stage.** At 3v3 the estimates say little: it's too early to call a battle,
and they're overconfident there. After the first faint they say much more. Where the planner
called a 2v1 or 1v2 lost, you never won. So `regret.py` corrects the estimates with a separate
Platt fit for each stage: P(won) = σ(a + b·logit(estimate)), for 3v3, one down, and later. It
uses 5-fold cross-validation by battle. Everything is reported twice, as estimated and as
corrected, with tables by stage: Brier score, and how often a position called lost (under 0.1)
or won (over 0.9) went the other way. The output lists those positions.

The confident misses that remain cluster in a few battles, and the ones checked are data:
- Galarian and regular Stunfisk show the same name on screen, so the export can't tell them
  apart. That turns a winning matchup into a losing one.
- Some opponents' Pokémon hit harder than default IVs allow.

Read regret as regret by the planner's model of the battle, not ground truth.

**Win conditions.** On every free turn, `regret.py` also rolls out two lines a single action
can't show:
- *farm down:* fast moves until their Pokémon goes, banking energy;
- *catch:* stay free and switch the turn they throw, with each Pokémon on your bench.

It lists the turns where a line beats every single action by over 10 points. Farming down is
rare, about 1% of your free turns, but where it shows up it's worth a lot. On nearly all of
those turns you were fast moving, so the line was probably your plan. Those turns are still
scored as plain fast moves, which overstates the regret on them. A catch almost never stands
out this way, because the planner already weighs catches every turn.

## A model of your opponents, learned from your recordings

The heuristic styles follow fixed rules, so they can't capture decisions that depend on what
just happened. `python3 -m experiments.opponent_model` instead learns how your recorded
opponents really play. Each of their decisions in the local Battle Turns export becomes a case:
the battle rebuilt at that turn from their side, and what they did. Four small models are
fitted with an L2 penalty:

| Part | Decision | Model |
|---|---|---|
| shield | shield your charged move or not | logistic |
| throw | hold, throw the cheaper move, or throw the bigger one, with energy for the cheaper | softmax over the moves they can afford |
| switch | switch or stay, on a free turn when they could switch | logistic |
| pick | which Pokémon they bring in, on a switch or after a faint | conditional logit |

The features cover the situation and its history:
- HP, shields, and Pokémon left on each side;
- the HP left on their bench, and the matchup;
- your energy, whether your charged move is ready, and whether your fast move lands soon;
- whether a hit knocks out, and whether it's a bait;
- whether their last throw was shielded, and whether they shielded the last one they could;
- charged moves thrown and taken;
- for switches, how much better their best Pokémon in the back matches up, whether a switch is
  free right now, and whether the matchup just started.

Five-fold cross-validation by battle compares the model with the four styles and with base
rates. The model has the lowest held-out log loss on all four parts; on most of them the margin
is small. On throws the styles do much worse than base rates: people hold far more often than
any style does. What the model picks up:
- **Timing:** they throw when your fast move is about to land.
- **Planning ahead:** they shield less with a healthy bench.
- **Switching:** they switch more out of a bad matchup and when your charged move is ready.
- **Picks:** they bring in the better matchup but the lower-HP Pokémon, keeping the healthy
  one for last.

The cases and the fitted model (`data/local/opponent_model.json`) stay on the Mac. So the
`-mixed` and `-learned` planners run only where the model has been fitted. Anywhere else they
stop with a message to run `experiments.opponent_model` first.

**In the planner**, "learned" is a fifth opponent type next to the four styles:
- *In the belief*, each particle with that type is reweighted by the model's probability of
  what the opponent did. That probability is read off the battle as the planner saw it at the
  start of the turn they chose in (`Belief.before_turn`), so the model sees the same energy,
  timing and history the opponent did.
- *In rollouts*, those particles play `opponent_model.Learned`.

Each recorded battle was scored with a model fitted on the other folds. On your recorded
opponents, the belief ends up putting most of its weight on "learned" in most battles. The
belief also now tracks the opponent's history (charged moves thrown and taken, and shields), so
determinized states, the full states it fills in for rollouts, carry it.

| Win rate vs | `planner-list` (styles) | `planner-list-mixed` (styles + learned) | `planner-list-learned` (learned only) |
|---|---|---|---|
| an opponent that plays like the model | 0.950 ± 0.012 | **0.973 ± 0.009** | 0.970 ± 0.010 |
| shielder | 0.967 ± 0.010 | 0.967 ± 0.010 | 0.785 ± 0.024 |
| baiter | 0.878 ± 0.017 | 0.905 ± 0.017 | 0.702 ± 0.024 |
| nuker | 0.915 ± 0.015 | 0.912 ± 0.016 | 0.763 ± 0.025 |
| casual | 0.957 ± 0.011 | 0.952 ± 0.012 | 0.882 ± 0.018 |
| `planner-list` | — | **0.554 ± 0.020** | 0.453 ± 0.020 |

The table covers 150 random pairs of listed Mega Great League teams, played from both sides,
and 250 pairs for the last row. It uses the final planner, farming down included, and the
model fitted on the rebuilt recordings described under decision regret.

What it shows:
- **Against an opponent that plays like the model,** the mixture beats the styles planner
  (+0.023 ± 0.013, paired).
- **Against the styles themselves,** the differences are all within noise.
- **Head to head,** the mixture now beats the styles planner, 0.554 ± 0.020. Before the rebuild
  fixes and farming down it was even (0.515 ± 0.019).
- **Relying on the learned model alone is a mistake.** Against the styles it loses 0.08 to
  0.18, and it loses to the styles planner head to head, because it no longer recognizes
  simpler opponents.

## Top players, from a tournament stream

The Pokémon GO Day 2 stream of the 2027 Gdańsk Regional Championships shows both players'
phones side by side. Each phone, cropped out of the stream, was read by ManGo like one of your
recordings and exported by battle-turns. `scripts/stream_fixtures.py` gathers the reads, which
stay local. Games with Dunsparce are left out, as you asked, and so are games the stream joined
late, which leaves 31 games. Each phone is one player's battle, so a top player's decisions are
scored from their own screen, the same way yours are.

Having both phones allows some cleaning:
- **Results.** Many views miss the results screen, so the other phone's result is used, flipped.
  Two games where both phones claimed the win are left without a result.
- **Forms.** One phone can only guess the opponent's form from the moves it saw: a Weather Ball
  doesn't say fire or ice. Where it names a different form from the one on the opponent's own
  screen (Shadow Ninetales for Alolan), that view is set aside.
- **Species.** Poliwrath, Ursaluna and Lokix were added to `great_league.json`, with every
  existing entry unchanged. One view with a name the data lacks (a misread) is set aside.

That leaves 59 player views of 32 battles. Fewer than half have a result, because the stream
often cuts away before the end. These are Great League battles, and the belief over a top
player's opponent uses the ordinary Great League prior, not the open team sheets. Yours are
Mega Great League, so the two sets aren't played under quite the same conditions.

**Regret** (`python3 -m experiments.top_players regret`) is the same measure as for your
battles: same planner, same rollouts. It's shown side by side by stage and by decision type,
with intervals from resampling whole battles.
- **Overall, the top players and you look the same** by the planner's measure. Mean regret,
  blunder rate (about one decision in six) and agreement (about half) all match.
- **At 3v3, the top players blunder less,** by about 5 points, though the interval just reaches
  zero. Later in the battle they're no better by its measure.
- **Switching is where they part.** The planner agrees with only about a fifth of the top
  players' switches, against half of yours, and scores them as costlier. That's the one clear
  difference. Most are lead switches in the first three turns, where the planner would usually
  have stayed in. The planner may undervalue what a lead switch buys, or it may be right.
- **So the planner's judgment doesn't track expertise here.** Top players don't agree with it
  more than you do, and its blunders aren't what separates them from you.
- **The results can't yet say who was right.** Where top players went against the planner, they
  won about as often as it predicted for the choice they made, the same as where they agreed.
  The same holds for you. With results for only 15 games, the interval is too wide to settle
  it either way.
- Where it called a choice a blunder, players won somewhat more often than it predicted. That
  holds for you and the top players alike, which hints that its blunder calls are too harsh,
  but it's within noise.

**Your opponent model on top players** (`python3 -m experiments.top_players model`). The model
fitted on your opponents is scored on the top players' decisions. Next to it are the same
model refitted on the top players (5-fold, by battle), one fitted on both, the styles and the
base rates.
- **Shields and throws transfer.** Your model predicts the top players' shields and throws as
  well as a model fitted on them, and better than the base rates and the styles. Fitting on
  both is a little better still for shields. Top players shield less than your opponents,
  about a third of the time against over two-fifths, and hold a little more.
- **Switches don't transfer.** A switch is a once-a-battle decision. The 45-second timer
  outlasts the rest of most battles, so nobody in either set ever got a second chance to
  switch. That's why the rate per free turn is low, about 4%. It doesn't mean there's nothing
  to learn: a switch model fitted on the top players beats their base rate. Yours is slightly
  worse than that base rate, because it expects switches later in the battle than top players
  make them. Telling the model the turn (the opening turns, or how far in) didn't help either set.
- **Picks are too few to say.** Your model gets about half of the 87 picks right, like a coin
  flip, and the styles' best-matchup rule about 60%. With so few, that's within noise
  (± 5 points).

So the planner's learned opponent is fine for top players' shields and throws. Their switches
and picks would need their own data, which means more games.

## Playing against the planner

`python3 -m experiments.play` is a 3v3 battle in the terminal: you play one side, and the
planner (or a heuristic style, `--opponent baiter`) plays the other. Teams are labels as in
`top_teams` (`--you M1 --them F3`), and `--lead` picks who you lead with. On each free turn:
- Enter fast moves once, and `a` keeps fast moving until something changes;
- `1` or `2` throws a charged move, `s1` or `s2` switches, and `w` waits;
- with `--hints`, `h` asks the planner what it would do in your place.

When they throw at you, the game says how much the hit would do and asks whether to shield. You
see what the screen would show, plus their energy counted from their moves the way ManGo does.
At the end you get the result and a timeline of the battle.

## Layout

    data/great_league.json     PvPoke's top 200 Great League Pokémon (stats, types, move usage, counters) and their moves,
                               plus three seen on the Gdańsk stream (Poliwrath, Ursaluna, Lokix)
    data/mega_great_league.json          the same for Mega Great League, plus its top teams, decoded
    data/mega_great_league_top_teams.csv PvPoke's top Mega Great League teams export
    data/mega_great_league_faced_teams.csv  your teams and the full teams you faced (species, lead first)
    data/mega_great_league_my_battles.csv   each of your battles: your team and theirs (species, lead first)
    data/openings_25.json      the opening book for team #25, Cramorant leading (top_teams book 25 --lead 2)
    results/mega_team25.txt    team #25's full results and per-opponent game plans
    results/my_battles.txt     your battles, replayed with the planner (experiments/my_battles.py)
    results/rank_all.txt       every team (PvPoke's, yours, the ones you faced) against every other
    scripts/update_data.sh     re-download and trim PvPoke's data (scripts/trim_data.py)
    scripts/stream_fixtures.py a tournament stream's per-phone ManGo reads, gathered for battle-turns
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
    mango_pomdp/battle_turns.py  your recorded battles (local Battle Turns): rebuilt HP, opponent decisions in context
    mango_pomdp/opponent_model.py  how your opponents shield, throw, switch and pick, learned from Battle Turns
    experiments/               duel.py (one 1v1, solved), meta.py (every 1v1 among the top N),
                               tournament.py (3v3 win rates), demo.py (one narrated 3v3 battle),
                               top_teams.py (pick one of PvPoke's top teams and plan against the rest),
                               my_battles.py (your own battles, replayed with the planner),
                               recorded_battles.py, recorded_paths.py (the same from Battle Turns, local),
                               regret.py (your decisions scored, local), play.py (you against the planner),
                               opponent_model.py (fit and check the opponent model, local),
                               top_players.py (top players' regret next to yours; your opponent model on them, local)
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
- **Real battles.** The learned opponent model comes from about 60 battles, so more recordings
  would tighten it most. The planner's win estimates are overconfident against real results,
  which makes regret only a rough measure. Two things could fix that: a value estimate learned
  from real results, and rollouts that play your own side less deterministically.
