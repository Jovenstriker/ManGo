# ManGo POMDP: planning to win Great League battles

An exploration of the AA228/CS238 project proposal *ManGo: Gotta Predict 'Em All*: treat a
Pokémon GO trainer battle as a POMDP and plan against an opponent whose team, moves, energy
and play style are hidden.

It's separate from the app. Nothing here is imported by `App/`, `PvPCore/` or `Extension/`,
and nothing there is changed. It's plain Python (3.10+, standard library only) with its own
copy of PvPoke's data in `data/`. The link to ManGo is conceptual: ManGo's screen reader
produces the observations a player gets, and its `OpponentTracker` does the energy counting
that `belief.EnergyCounter` does here.

    cd POMDP
    python3 -m experiments.demo --seed 3 --opponent nuker      # one battle, narrated
    python3 -m experiments.tournament --games 150               # win rates
    python3 -m unittest discover tests

## The model

| POMDP piece | Here |
|---|---|
| State | Both teams' HP, energy and buff stages, shields, switch timers, who is mid fast move, the battle clock, plus the opponent's hidden team, movesets and play style |
| Actions | When your fast move finishes: fast move, a charged move you can afford, or a switch. When a charged move comes in: shield or not. After a faint: which Pokémon to bring in |
| Transitions | `battle.py`: deterministic 0.5s turns following PvPoke's `Battle.js` (damage formula, CMP, charged-move lag, floating fast moves, 45s switch timer, 4-minute clock). Randomness comes only from buff chances, CMP ties, and the opponent's policy |
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

## The planner

`planner.py` is online lookahead with rollouts (Kochenderfer et al., *Algorithms for Decision
Making*, ch. 22). At each decision that matters:

1. Sample K = 12 hypotheses from the belief and turn each into a full battle state.
2. For every candidate action, play it, then roll out to the end of the battle. You play the
   *baiter* heuristic; the opponent plays the sampled style.
3. Score every action on the same hypotheses and random seeds (common random numbers).

The planner keeps the rollout policy's own choice unless a paired test says another action is
better by more than one standard error. Without that test, in an earlier run, the planner lost
to its own rollout policy (0.52 vs baiter's 0.58). With it, the planner beats baiter clearly.

Ablations, by player name:

| Player | What it is |
|---|---|
| `random`, `shielder`, `baiter`, `nuker`, `casual` | Baselines: the heuristics on their own |
| `planner` | The full belief: structured prior plus four styles |
| `planner-1style` | Structured prior, but assumes every opponent is a baiter |
| `planner-flat` | Flat prior (uniform over the top 100 species, uniform moves) and one style |
| `oracle` | Same planner, but knows the opponent's real team and style. An upper bound, and not legal |

## Results

`python3 -m experiments.tournament --games 150 --players random shielder baiter nuker casual planner-flat planner-1style planner oracle`:
each player plays 300 battles. Each game is 2 battles with the teams swapped, and the opponent
style is drawn uniformly. Ties count as half a win. The full run took 8.5 minutes on 8 cores.

| Player | Win rate | vs shielder | vs baiter | vs nuker | vs casual |
|---|---|---|---|---|---|
| random | 0.333 ± 0.027 | 0.331 | 0.230 | 0.401 | 0.366 |
| shielder | 0.545 ± 0.029 | 0.485 | 0.432 | 0.625 | 0.622 |
| baiter | 0.555 ± 0.029 | 0.559 | 0.453 | 0.599 | 0.604 |
| nuker | 0.465 ± 0.029 | 0.412 | 0.372 | 0.421 | 0.634 |
| casual | 0.400 ± 0.028 | 0.368 | 0.311 | 0.414 | 0.494 |
| planner-flat | 0.763 ± 0.025 | 0.824 | 0.662 | 0.724 | 0.841 |
| planner-1style | 0.753 ± 0.025 | 0.794 | 0.662 | 0.730 | 0.823 |
| **planner** | **0.765 ± 0.024** | 0.824 | 0.642 | 0.789 | 0.805 |
| oracle | 0.887 ± 0.018 | 0.897 | 0.811 | 0.921 | 0.915 |

What this says so far:

- **Lookahead is most of the win.** Every planner beats every heuristic by about 20 points,
  including baiter, which is the planner's own rollout policy. Its worst matchup is against
  baiters (0.64).
- **The belief isn't paying for itself yet.** The full belief, the single-style belief and the
  flat prior are within one standard error of each other. Style inference does help against
  nukers (0.79 vs 0.72–0.73), but that's not significant at this sample size.
- **There's real value in information left to capture.** The oracle wins 12 points more.
  Telling apart what it gains from knowing the team and moves versus knowing the style is the
  obvious next ablation. Candidate improvements: more rollouts per decision; reweighting on
  switches and replacements; and rollout opponents built from the opponent's own belief about
  you, rather than a fixed style.

## Layout

    data/great_league.json     PvPoke's top 200 Great League Pokémon (stats, types, move usage, counters) and their moves
    scripts/update_data.sh     re-download and trim PvPoke's data (scripts/trim_data.py)
    mango_pomdp/gamedata.py    types, moves, damage formula
    mango_pomdp/battle.py      the simulator and the player's View
    mango_pomdp/team_prior.py  the structured team and moveset prior
    mango_pomdp/policies.py    opponent styles, matchup heuristics, baselines
    mango_pomdp/belief.py      energy counting and the particle belief (plus the Oracle)
    mango_pomdp/planner.py     the rollout planner
    mango_pomdp/match.py       building players by name, playing one battle
    experiments/               tournament.py (win rates), demo.py (one narrated battle)
    tests/                     simulator, prior, belief and planner checks

## Simplifications and next steps

- **Mechanics.** No Charged Attack minigame (every charged move hits at full power), no
  form changes (Aegislash, Morpeko), no mega moves. Fast moves in progress land when a charged
  move is thrown rather than on the following turn. Everyone uses PvPoke's default CP 1500 IVs.
- **Opponents.** Opponents are the four heuristic styles, so "hard to exploit" is only tested
  against them: the lowest per-style win rate is a crude exploitability number. Next steps are
  playing the planner against itself, and running a best-response search against it.
- **Planner.** It decides one action at a time with fixed rollout policies. POMCP (a search
  tree over action–observation histories) or longer open-loop sequences would make it look
  further ahead, for example to bait now in order to nuke later.
- **Real battles.** ManGo's battle logs (`../Battle Logs/`) record the opponent's moves and the
  counted energy. Replaying them through `Belief` would check the style model against real
  people and show what the planner would have done at each decision.
