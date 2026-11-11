"""cd POMDP && python3 -m unittest discover tests"""
import random
import unittest

from mango_pomdp.battle import CHARGED, FAST, SWITCH, SWITCH_TURNS, Battle, Mon
from mango_pomdp.belief import Belief
from mango_pomdp.duel import CDuel, Duel, DuelPlayer, Fighter, _library, play_out, solve_matrix
from mango_pomdp import gamedata
from mango_pomdp.gamedata import IMMUNE, SE, damage, effectiveness, load
from mango_pomdp.match import make_player, play
from mango_pomdp.policies import Heuristic
from mango_pomdp.team_prior import TeamPrior, build_team

gd = load()
prior = TeamPrior(gd)


def mon(sid, fast=None, charged=None):
    f, cs = gd.recommended(sid)
    return Mon(gd.species[sid], gd.moves[fast] if fast else f, tuple(gd.moves[c] for c in charged) if charged else cs)


class Scripted:
    """Plays a list of actions, then fast moves. Always shields if `shields`."""

    def __init__(self, actions=(), shields=False):
        self.actions, self.shields = list(actions), shields

    def act(self, view):
        return self.actions.pop(0) if self.actions else FAST

    def shield(self, view, move):
        return self.shields

    def replace(self, view):
        return view.me.bench()[0]


class GameDataTests(unittest.TestCase):
    def test_type_chart(self):
        self.assertEqual(effectiveness("ground", ("flying",)), IMMUNE)
        self.assertAlmostEqual(effectiveness("ice", ("dragon", "flying")), SE * SE)
        self.assertEqual(effectiveness("fighting", ("ghost",)), IMMUNE)

    def test_damage_formula(self):
        # floor(power × STAB × atk/def × eff × 0.5 × 1.3) + 1
        a, d = gd.species["medicham"], gd.species["azumarill"]
        counter = gd.moves["COUNTER"]
        expected = int(counter.power * 1.2 * a.atk / d.def_ * 0.625 * 0.5 * 1.3) + 1
        self.assertEqual(damage(counter, a, d), expected)


class BattleTests(unittest.TestCase):
    def test_fast_move_lands_on_its_last_turn(self):
        b = Battle([[mon("medicham")], [mon("azumarill")]], seed=0)
        turns = b.sides[0].mon.fast.turns
        hp = b.sides[1].mon.hp
        for _ in range(turns - 1):
            b.step([Scripted(), Scripted()])
        if turns > 1:
            self.assertEqual(b.sides[1].mon.hp, hp)
        b.step([Scripted(), Scripted()])
        self.assertLess(b.sides[1].mon.hp, hp)
        self.assertEqual(b.sides[0].mon.energy, b.sides[0].mon.fast.energy_gain)

    def test_energy_caps_at_100(self):
        b = Battle([[mon("medicham")], [mon("azumarill")]], seed=0)
        b.sides[0].mon.energy = 99
        b.sides[1].mon.hp = 10_000
        for _ in range(10):
            b.step([Scripted(), Scripted()])
        self.assertEqual(b.sides[0].mon.energy, 100)

    def test_shield_takes_one_damage(self):
        b = Battle([[mon("medicham")], [mon("azumarill")]], seed=0)
        b.sides[0].mon.energy = 100
        hp = b.sides[1].mon.hp
        b.step([Scripted([CHARGED(0)]), Scripted(shields=True)])
        self.assertEqual(b.sides[1].shields, 1)
        self.assertEqual(hp - b.sides[1].mon.hp, 1)

    def test_charged_move_interrupts_fast_moves_and_resets_cooldowns(self):
        # PvPoke's fast move registration guide: Incinerate (5 turns) used on turn 0 would hit on
        # turn 4, but a charged move on turn 1 makes it register on turn 1, and Talonflame acts
        # again on turn 2 (3 "free" turns).
        b = Battle([[mon("registeel")], [mon("azumarill", fast="INCINERATE")]], seed=0)   # Lock-On: 1 turn
        b.sides[0].mon.energy = 100
        hp = b.sides[0].mon.hp
        incinerate = b.sides[1].mon.fast
        b.step([Scripted(), Scripted()])
        self.assertEqual(b.sides[1].busy_until, 5)
        hp_after_turn0 = b.sides[0].mon.hp
        self.assertEqual(hp_after_turn0, hp)    # nothing registered yet
        b.step([Scripted([CHARGED(0)]), Scripted()])
        self.assertEqual(b.sides[1].mon.energy, incinerate.energy_gain)
        self.assertLess(b.sides[0].mon.hp, hp)
        self.assertEqual((b.sides[0].busy_until, b.sides[1].busy_until), (2, 2))
        self.assertEqual(b.view(0).legal_actions()[0], FAST)   # no dead turn after a charged move

    def test_cmp_higher_attack_goes_first_and_can_ko(self):
        fast_hitter, slow = mon("medicham"), mon("azumarill")
        self.assertGreater(fast_hitter.species.atk, slow.species.atk)
        fast_hitter.energy = slow.energy = 100
        slow.hp = 1
        b = Battle([[slow], [fast_hitter]], seed=0)
        b.step([Scripted([CHARGED(0)]), Scripted([CHARGED(0)])])
        self.assertTrue(b.done)
        self.assertEqual(b.winner, 1)
        self.assertEqual(sum(e.kind == "charged" for e in b.log), 1)

    def test_switch_timer(self):
        b = Battle([[mon("medicham"), mon("azumarill"), mon("registeel")], [mon("swampert")]], seed=0)
        b.step([Scripted([SWITCH(1)]), Scripted()])
        self.assertEqual(b.sides[0].active, 1)
        self.assertEqual(b.sides[0].switch_timer, SWITCH_TURNS - 1)
        self.assertFalse(b.view(0).can_switch)

    def test_choices_are_simultaneous(self):
        # Side 1 decides turn 0 without seeing side 0's switch on that same turn.
        seen = []

        class Watcher(Scripted):
            def act(self, view):
                seen.append(view.foe_species.id)
                return FAST

        b = Battle([[mon("medicham"), mon("azumarill")], [mon("swampert")]], seed=0)
        b.step([Scripted([SWITCH(1)]), Watcher()])
        self.assertEqual(seen, ["medicham"])
        self.assertEqual(b.sides[0].mon.species.id, "azumarill")

    def test_battles_finish_and_are_reproducible(self):
        rng = random.Random(3)
        teams = [prior.sample_team(rng), prior.sample_team(rng)]
        results = {play(gd, teams, [Heuristic("baiter", seed=1), Heuristic("nuker", seed=2)], seed=9).turn
                   for _ in range(2)}
        self.assertEqual(len(results), 1)


class PriorTests(unittest.TestCase):
    def test_no_duplicate_species_and_moves_are_legal(self):
        rng = random.Random(0)
        for _ in range(50):
            team = prior.sample_team(rng)
            self.assertEqual(len({gd.species[s].dex for s, _, _ in team}), 3)
            for sid, f, cs in team:
                self.assertIn(f, dict(gd.species[sid].fast_usage))
                self.assertEqual(len(set(cs)), len(cs))

    def test_structure_prefers_balanced_teams(self):
        # Three Pokémon that all fear Grass score worse than a team with nothing in common.
        weakness_only = TeamPrior(gd, counter_weight=0)
        lopsided = [gd.species[s] for s in ("azumarill", "quagsire", "swampert")]
        mixed = [gd.species[s] for s in ("azumarill", "registeel", "medicham")]
        self.assertGreater(weakness_only.synergy_penalty(lopsided), weakness_only.synergy_penalty(mixed))

    def test_common_counters_cost_less_than_rare_ones(self):
        self.assertLess(prior.rarity["mimikyu"], max(prior.rarity.values()))


class BeliefTests(unittest.TestCase):
    def test_counted_energy_matches_true_energy_and_reveals_hold(self):
        rng = random.Random(11)
        teams = [prior.sample_team(rng), prior.sample_team(rng)]
        battle = Battle([build_team(gd, teams[0]), build_team(gd, teams[1])], seed=4)
        belief = Belief(gd, prior, me=0, n=100, seed=1)
        belief.observe(battle.log)
        ctrls = [Heuristic("baiter", seed=1), Heuristic("shielder", seed=2)]
        while not battle.done:
            start = len(battle.log)
            battle.step(ctrls)
            belief.observe(battle.log[start:])
            for m in battle.sides[1].mons:
                if m.species.id in belief.revealed:
                    self.assertEqual(belief.counter.energy[m.species.id], m.energy, m.species.id)
            for p in belief.particles:
                self.assertTrue(set(belief.revealed) <= set(p.team))
                for sid, r in belief.revealed.items():
                    if r["fast"]:
                        self.assertEqual(p.moves[sid][0], r["fast"])
                    self.assertTrue(r["charged"] <= set(p.moves[sid][1]))

    def test_style_posterior_finds_a_shielder(self):
        rng = random.Random(2)
        hits = 0
        for g in range(6):
            teams = [prior.sample_team(rng), prior.sample_team(rng)]
            battle = Battle([build_team(gd, teams[0]), build_team(gd, teams[1])], seed=g)
            belief = Belief(gd, prior, me=0, n=200, seed=g)
            belief.observe(battle.log)
            battle.play([Heuristic("nuker", seed=g), Heuristic("shielder", seed=g + 1)], [belief])
            post = belief.style_posterior()
            hits += max(post, key=post.get) == "shielder"
        self.assertGreaterEqual(hits, 4)


class PlannerTests(unittest.TestCase):
    def test_zero_turn_switches_are_candidates_mid_matchup(self):
        from mango_pomdp.planner import Planner
        b = Battle([[mon("medicham"), mon("azumarill"), mon("registeel")], [mon("swampert")]], seed=0)
        b.turn = 30   # well into the matchup
        view = b.view(0)
        for switch_at, after_charged, later in (("start", False, False), ("zero-turn", True, False),
                                                ("any", True, True)):
            p = Planner(gd, prior, switch_at=switch_at)
            p.last_charged = 29   # a charged move last turn: cooldowns just reset
            self.assertEqual(p.may_switch(view), after_charged, switch_at)
            p.last_charged = 20
            self.assertEqual(p.may_switch(view), later, switch_at)
        b.sides[0].switch_timer = 10
        self.assertFalse(Planner(gd, prior, switch_at="any").may_switch(view))   # the timer still rules

    def test_planner_beats_random(self):
        rng = random.Random(7)
        score = 0.0
        for g in range(6):
            teams = [prior.sample_team(rng), prior.sample_team(rng)]
            for mine, theirs in ((teams[0], teams[1]), (teams[1], teams[0])):
                b = play(gd, [mine, theirs], [make_player("planner", gd, prior, g, rollouts=6),
                                              make_player("random", gd, prior, g)], seed=g)
                score += {0: 1, -1: 0.5, 1: 0}[b.winner]
        self.assertGreaterEqual(score / 12, 0.7)


mega = load("mega_great_league")


def mega_mon(sid, fast, *charged):
    return Mon.build(mega, sid, fast, charged)


class FormTests(unittest.TestCase):
    """Form changes, checked against PvPoke's Battle.js."""

    def test_disguise_blocks_the_first_charged_move_and_stays_busted(self):
        mimikyu = mega_mon("mimikyu", "SHADOW_CLAW", "SHADOW_SNEAK", "PLAY_ROUGH")
        melmetal = mega_mon("melmetal", "THUNDER_SHOCK", "DOUBLE_IRON_BASH", "DYNAMIC_PUNCH")
        melmetal.energy = 100
        b = Battle([[melmetal], [mimikyu, mega_mon("altaria", "DRAGON_BREATH", "FLAMETHROWER", "MOONBLAST")]], seed=0)
        hp = mimikyu.hp
        self.assertFalse(Heuristic("shielder", eps=0).shield(b.view(1), melmetal.charged[0]))
        b.step([Scripted([CHARGED(0)]), Scripted()])
        self.assertEqual(hp - mimikyu.hp, 1)       # Melmetal threw instead of fast moving: just the block
        self.assertEqual((mimikyu.form, mimikyu.def_stage), ("busted", -1))
        self.assertEqual(b.sides[1].shields, 2)    # Disguise isn't a shield
        b.step([Scripted([CHARGED(0)]), Scripted()])
        self.assertGreater(hp - 1 - mimikyu.hp, 1)
        b.step([Scripted(), Scripted([SWITCH(1)])])
        self.assertEqual(mimikyu.def_stage, -1)    # a switch doesn't clear Busted's −1 defense

    def test_cramorant_spits_its_catch_at_whoever_hits_it(self):
        for hp_share, catch, stages in ((1.0, "gulping", (0, -1)), (0.4, "gorging", (-2, 0))):
            cramorant = mega_mon("cramorant", "PECK", "DIVE", "FLY")
            melmetal = mega_mon("melmetal", "THUNDER_SHOCK", "DOUBLE_IRON_BASH", "DYNAMIC_PUNCH")
            cramorant.hp = int(cramorant.max_hp * hp_share)
            cramorant.energy = melmetal.energy = 100
            b = Battle([[cramorant], [melmetal]], seed=0)
            b.step([Scripted([CHARGED(0)]), Scripted()])
            self.assertEqual(cramorant.form, catch)
            b.step([Scripted(), Scripted([CHARGED(0)])])
            gulp = [e for e in b.log if e.kind == "gulp"]
            self.assertEqual(len(gulp), 1)
            self.assertEqual(gulp[0].info["damage"], int(0.15 * melmetal.max_hp) + 1)
            self.assertEqual(gulp[0].info["target_hp"] - melmetal.hp, gulp[0].info["damage"])
            self.assertEqual((melmetal.atk_stage, melmetal.def_stage), stages)
            self.assertEqual(cramorant.form, "")

    def test_shielding_keeps_cramorants_catch(self):
        cramorant = mega_mon("cramorant", "PECK", "DIVE", "FLY")
        melmetal = mega_mon("melmetal", "THUNDER_SHOCK", "DOUBLE_IRON_BASH", "DYNAMIC_PUNCH")
        cramorant.energy = melmetal.energy = 100
        b = Battle([[cramorant], [melmetal]], seed=0)
        b.step([Scripted([CHARGED(0)]), Scripted()])
        b.step([Scripted(shields=True), Scripted([CHARGED(0)])])
        self.assertEqual(cramorant.form, "gulping")
        self.assertFalse(any(e.kind == "gulp" for e in b.log))

    def test_morpeko_alternates_aura_wheel_types(self):
        morpeko = mega_mon("morpeko_full_belly", "THUNDER_SHOCK", "AURA_WHEEL_ELECTRIC", "PSYCHIC_FANGS")
        quagsire = mega_mon("quagsire", "MUD_SHOT", "AQUA_TAIL", "STONE_EDGE")
        quagsire.hp = 10_000
        morpeko.energy = 100
        b = Battle([[morpeko, mega_mon("altaria", "DRAGON_BREATH", "FLAMETHROWER", "MOONBLAST")], [quagsire]], seed=0)
        types = []
        for _ in range(2):
            b.step([Scripted([CHARGED(0)]), Scripted()])
            types.append(next(e for e in reversed(b.log) if e.kind == "charged").info["type"])
        self.assertEqual(types, ["electric", "dark"])
        self.assertEqual(morpeko.form, "")
        morpeko.energy = 100
        b.step([Scripted([CHARGED(0)]), Scripted()])
        self.assertEqual(morpeko.form, "hangry")
        b.step([Scripted([SWITCH(1)]), Scripted()])
        self.assertEqual((morpeko.form, morpeko.charged[0].id), ("", "AURA_WHEEL_ELECTRIC"))
        self.assertEqual({e.move.id for e in b.log if e.kind == "charged"}, {"AURA_WHEEL_ELECTRIC"})


class TopTeamTests(unittest.TestCase):
    def test_every_team_decodes_to_legal_moves(self):
        self.assertEqual(len(mega.teams), 48)
        for t in mega.teams:
            self.assertEqual(len(t.spec), 3)
            for sid, f, cs in t.spec:
                self.assertTrue(mega.moves[f].is_fast)
                self.assertEqual(len(cs), 2)
                self.assertTrue(all(not mega.moves[c].is_fast for c in cs))

    def test_list_prior_narrows_to_teams_with_that_lead(self):
        from mango_pomdp.team_prior import TeamListPrior
        listed = TeamListPrior(mega, mega.teams, fallback=TeamPrior(mega))
        rng = random.Random(0)
        leads = [listed.complete_team(rng, ["cramorant"]) for _ in range(300)]
        fits = {tuple(t.species) for t in mega.teams if "cramorant" in t.species}
        self.assertTrue(all(any(set(team) == set(f) for f in fits) for team in leads))
        led = sum(any(team == list(f) for f in fits if f[0] == "cramorant") for team in leads)
        self.assertGreater(led / len(leads), 0.7)
        # Nothing listed fits: the structured prior fills it in instead.
        self.assertEqual(len(listed.complete_team(rng, ["carbink"])), 3)

    def test_planner_with_the_list_plays_either_side(self):
        gamedata.use("mega_great_league")
        try:
            for g in range(2):
                mine, theirs = list(mega.teams[24].spec), list(mega.teams[g].spec)
                me = make_player("planner-list", mega, TeamPrior(mega), g, rollouts=4, teams=mega.teams[:24])
                teams, players = ([mine, theirs], [me, Heuristic("baiter", seed=g)]) if g == 0 else \
                    ([theirs, mine], [Heuristic("baiter", seed=g), me])
                b = play(mega, teams, players, seed=g)
                self.assertTrue(b.done)
        finally:
            gamedata.use("great_league")


def payoff(battle, duel):
    a, b = duel.f
    margin = battle.sides[0].mon.hp / a.species.hp - battle.sides[1].mon.hp / b.species.hp
    return (1 - duel.w) * {0: 1, -1: 0, 1: -1}[battle.winner] + duel.w * margin


class DuelTests(unittest.TestCase):
    def test_matrix_games(self):
        x, y, v = solve_matrix([[1, -1], [-1, 1]])   # matching pennies
        self.assertAlmostEqual(v, 0)
        self.assertAlmostEqual(x[0], 0.5)
        x, y, v = solve_matrix([[0, -1, 1], [1, 0, -1], [-1, 1, 0]])   # rock paper scissors
        self.assertAlmostEqual(v, 0)
        for p in x + y:
            self.assertAlmostEqual(p, 1 / 3)
        x, y, v = solve_matrix([[3, 1], [4, 2]])     # saddle point
        self.assertEqual((x, y, v), ([0.0, 1.0], [0.0, 1.0], 2))

    def test_solver_predicts_the_simulator(self):
        for a, b, shields in (("registeel", "swampert", (1, 1)), ("medicham", "azumarill", (0, 0))):
            duel = Duel(Fighter.of(gd, a), Fighter.of(gd, b))
            v = duel.value(duel.start(shields))
            self.assertAlmostEqual(payoff(play_out(duel, shields, seed=1), duel), v, places=9)

    @unittest.skipUnless(_library(), "no C compiler")
    def test_c_solver_matches_python_exactly(self):
        # Includes a mirror match (CMP ties are coin flips) and moves with buff chances.
        cases = (("medicham", "azumarill", (1, 0)), ("medicham", "medicham", (0, 0)),
                 ("melmetal", "altaria", (0, 1)), ("registeel", "swampert", (1, 1)))
        for a, b, shields in cases:
            fa, fb = Fighter.of(gd, a), Fighter.of(gd, b)
            py, c = Duel(fa, fb), CDuel(fa, fb)
            s = py.start(shields)
            self.assertEqual(py.value(s), c.value(s), (a, b))
            sp, sc = py.strategy(s, 0), c.strategy(s, 0)
            self.assertEqual((sp.payoffs, sp.mix), (sc.payoffs, sc.mix), (a, b))

    def test_solution_cannot_be_exploited(self):
        duel = Duel(Fighter.of(gd, "registeel"), Fighter.of(gd, "swampert"))
        v = duel.value(duel.start((1, 1)))
        for seed in range(3):
            for foe in ("shielder", "baiter", "nuker", "casual", "random"):
                opponent = make_player(foe, gd, prior, seed)
                as0 = payoff(play_out(duel, (1, 1), [DuelPlayer(duel, seed), opponent], seed), duel)
                as1 = payoff(play_out(duel, (1, 1), [make_player(foe, gd, prior, seed), DuelPlayer(duel, seed)], seed), duel)
                self.assertGreaterEqual(as0, v - 1e-9, foe)
                self.assertLessEqual(as1, v + 1e-9, foe)


if __name__ == "__main__":
    unittest.main()
