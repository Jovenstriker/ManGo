"""cd POMDP && python3 -m unittest discover tests"""
import csv
import random
import unittest

from mango_pomdp.battle import CHARGED, FAST, SWITCH, SWITCH_TURNS, WAIT, Battle, Mon
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

    def test_waiting_stays_free_and_a_switch_catches_the_throw(self):
        b = Battle([[mon("medicham"), mon("registeel")], [mon("azumarill")]], seed=0)
        b.sides[1].mon.energy = 100
        b.step([Scripted([WAIT]), Scripted([WAIT])])
        self.assertEqual((b.sides[0].mon.energy, b.sides[0].busy_until), (0, 1))   # idle, free next turn
        registeel = b.sides[0].mons[1]
        hp = registeel.hp
        b.step([Scripted([SWITCH(1)]), Scripted([CHARGED(0)])])   # switch the turn they throw
        hit = next(e for e in b.log if e.kind == "charged")
        self.assertEqual(hit.info["target"], "registeel")
        self.assertLess(registeel.hp, hp)

    def test_a_switch_costs_a_turn_unless_right_after_a_charged_move(self):
        # Mid-matchup: Azumarill comes in and does nothing until next turn.
        b = Battle([[mon("medicham"), mon("azumarill")], [mon("swampert")]], seed=0)
        b.turn = 10
        b.step([Scripted([SWITCH(1)]), Scripted()])
        self.assertEqual((b.sides[0].mon.species.id, b.sides[0].busy_until, b.sides[0].fast_due), ("azumarill", 11, -1))
        # The turn after a charged move: the switch is free and Azumarill starts its fast move now.
        b = Battle([[mon("medicham"), mon("azumarill")], [mon("swampert")]], seed=0)
        b.sides[1].mon.energy = 100
        b.step([Scripted(), Scripted([CHARGED(0)])])          # turn 0: Swampert throws
        self.assertEqual(b.last_charged, 0)
        b.step([Scripted([SWITCH(1)]), Scripted()])           # turn 1: 0-turn switch
        bubble = b.sides[0].mon.fast.turns
        self.assertEqual((b.sides[0].mon.species.id, b.sides[0].busy_until), ("azumarill", 1 + bubble))

    def test_planner_shields_against_a_pokemon_that_just_0_turn_switched_in(self):
        # Swampert throws; the opponent then 0-turn switches to Azumarill and throws at
        # once: the planner has to decide on a shield before the turn's "enter" event reaches it.
        from mango_pomdp.planner import Planner
        b = Battle([[mon("registeel")], [mon("swampert"), mon("azumarill")]], seed=0)
        b.sides[1].mons[0].energy = b.sides[1].mons[1].energy = 100
        p = Planner(gd, prior, rollouts=2, seed=1)
        p.start(0)
        p.observe(b.log)
        foe = Scripted([CHARGED(0), SWITCH(1), CHARGED(0)])
        for _ in range(2):
            start = len(b.log)
            b.step([p, foe])
            p.observe(b.log[start:])
        self.assertEqual(b.sides[1].mon.species.id, "azumarill")
        self.assertEqual(sum(e.kind == "charged" and e.side == 1 for e in b.log), 2)

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
                                                ("catch", True, False), ("any", True, True)):
            p = Planner(gd, prior, switch_at=switch_at)
            p.last_charged = 29   # a charged move last turn: cooldowns just reset
            self.assertEqual(p.may_switch(view), after_charged, switch_at)
            p.last_charged = 20
            self.assertEqual(p.may_switch(view), later, switch_at)
        b.sides[0].switch_timer = 10
        self.assertFalse(Planner(gd, prior, switch_at="any").may_switch(view))   # the timer still rules

    def test_good_timing_holds_a_throw_until_their_fast_move_lands(self):
        from mango_pomdp.policies import Timed
        # Psycho Cut: 2 turns. Their Incinerate: 5 turns, already under way.
        b = Battle([[mon("medicham")], [mon("azumarill", fast="INCINERATE")]], seed=0)
        b.sides[0].mon.energy = 100
        timed = Timed(Heuristic("baiter", eps=0))
        foe = b.sides[1]
        for busy, lands, expected in ((2, 1, WAIT), (3, 2, FAST), (1, 0, "charged")):
            foe.busy_until, foe.fast_due = busy, lands
            a = timed.act(b.view(0))
            self.assertEqual(a[0] if expected == "charged" else a, expected, (busy, lands))

    def test_every_free_turn_weighs_every_legal_action(self):
        from mango_pomdp.planner import Planner
        b = Battle([[mon("medicham"), mon("azumarill"), mon("registeel")], [mon("swampert")]], seed=0)
        b.turn = 30   # mid-matchup, not a 0-turn moment
        p = Planner(gd, prior, rollouts=2, seed=1)
        p.start(0)
        p.observe(b.log)
        seen = {}
        p._best = lambda view, c, *a, zs=None, **k: seen.update(zip(c, zs)) or c[0]
        p.act(b.view(0))
        self.assertTrue({FAST, WAIT, SWITCH(1), SWITCH(2)} <= set(seen))
        self.assertEqual((seen[FAST], seen[WAIT], seen[SWITCH(1)]), (p.z, p.z_extra, p.z_extra))

    def test_turns_to_throw_reads_energy_cooldown_and_style(self):
        from mango_pomdp.planner import turns_to_throw
        b = Battle([[mon("medicham")], [mon("azumarill")]], seed=0)   # Azumarill: Bubble, 3 turns
        azu = b.sides[1].mon
        cheap = min(c.energy for c in azu.charged)
        azu.energy = cheap
        self.assertEqual(turns_to_throw(b, 1, "baiter"), 0)            # free, and can afford it
        b.sides[1].busy_until, b.sides[1].fast_due = 2, 1               # mid Bubble: free on turn 2
        self.assertEqual(turns_to_throw(b, 1, "baiter"), 2)
        azu.energy = 0
        self.assertIsNone(turns_to_throw(b, 1, "baiter"))               # one Bubble won't get there

    def test_rollout_policy_catches_a_big_hit_on_a_resist(self):
        from mango_pomdp.planner import _Catcher
        b = Battle([[mon("medicham"), mon("registeel")], [mon("azumarill", charged=["ICE_BEAM", "HYDRO_PUMP"])]],
                   seed=0)
        b.sides[1].mon.energy = 55   # Ice Beam, which a baiter throws now while we have shields
        catcher = _Catcher(Heuristic("baiter", eps=0), b, 0, "baiter")
        self.assertEqual(catcher.act(b.view(0)), SWITCH(1))
        b.sides[1].busy_until, b.sides[1].fast_due = 1, 0   # mid Bubble: throws next turn
        self.assertEqual(catcher.act(b.view(0)), WAIT)       # Psycho Cut would still be going then
        b.sides[1].mon.energy = 0
        b.turn = 10   # mid-matchup, where the baiter heuristic itself doesn't switch
        self.assertNotIn(catcher.act(b.view(0)), (WAIT, SWITCH(1)))   # nothing coming: plays on

    def test_planner_waits_to_catch(self):
        # Azumarill can throw next turn, when its Bubble ends. Medicham (Psycho Cut: 2 turns) can't
        # both fast move and be free then; Registeel on the bench resists Ice Beam. Waiting, then
        # switching on the throw turn, catches it.
        from mango_pomdp.planner import Planner
        b = Battle([[mon("medicham"), mon("registeel")], [mon("azumarill", charged=["ICE_BEAM", "HYDRO_PUMP"])]],
                   seed=0)
        b.sides[1].mon.energy = 55
        b.sides[1].busy_until, b.sides[1].fast_due = 1, 0
        p = Planner(gd, prior, rollouts=4, seed=1, styles=("baiter",))
        p.start(0)
        p.observe(b.log)
        p.belief.counter.energy["azumarill"] = 55
        cands = []
        p._best = lambda view, c, *a, **k: cands.extend(c) or c[0]
        p.act(b.view(0))
        self.assertIn(("catch", 1), cands)
        self.assertIn(SWITCH(1), cands)

    def test_farm_down_fast_moves_until_their_pokemon_goes_down(self):
        from mango_pomdp.planner import FARM, Planner, _Farm
        b = Battle([[mon("medicham"), mon("azumarill")], [mon("registeel"), mon("skarmory")]], seed=0)
        b.sides[0].mon.energy = 100
        farm = _Farm(Scripted([CHARGED(0)]), b, 0)
        self.assertEqual(farm.act(b.view(0)), FAST)        # energy for a charged move, but farming
        b.sides[1].mon.hp = 0
        self.assertEqual(farm.act(b.view(0)), CHARGED(0))  # their Pokémon is down: back to the plan
        p = Planner(gd, prior, rollouts=4, seed=0)
        p.start(0)
        b = Battle([[mon("medicham"), mon("azumarill")], [mon("registeel"), mon("skarmory")]], seed=0)
        p.observe(b.log)
        b.sides[0].mon.energy = 100
        self.assertIn(p.act(b.view(0)), b.view(0).legal_actions())
        self.assertEqual(FARM, ("farm", 0))

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
        self.assertEqual([len(mega.team_pool(s)) for s in ("pvpoke", "mine", "faced")], [48, 4, 63])
        self.assertEqual(mega.team_pool("pvpoke"), list(range(48)))   # PvPoke's rows keep their numbers
        for t in mega.teams:
            self.assertEqual(len(t.spec), 3)
            for sid, f, cs in t.spec:
                self.assertTrue(mega.moves[f].is_fast)
                self.assertEqual(len(cs), 2)
                self.assertTrue(all(not mega.moves[c].is_fast for c in cs))

    def test_your_battles_decode_to_the_right_forms(self):
        mine = [mega.teams[k].species for k in mega.team_pool("mine")]
        self.assertEqual(mine[0], ("thievul", "blaziken", "jumpluff"))   # the team you used most, lead first
        faced = {s for k in mega.team_pool("faced") for s in mega.teams[k].species}
        self.assertTrue({"stunfisk_galarian", "stunfisk", "forretress_shadow", "ninetales_alolan",
                         "morpeko_full_belly"} <= faced)

    def test_list_prior_narrows_to_teams_with_that_lead(self):
        from mango_pomdp.team_prior import TeamListPrior
        pvpoke = [mega.teams[k] for k in mega.team_pool("pvpoke")]
        listed = TeamListPrior(mega, pvpoke, fallback=TeamPrior(mega))
        rng = random.Random(0)
        leads = [listed.complete_team(rng, ["cramorant"]) for _ in range(300)]
        fits = {tuple(t.species) for t in pvpoke if "cramorant" in t.species}
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


class PlayTests(unittest.TestCase):
    def test_a_human_can_play_a_whole_battle(self):
        from experiments.play import Human
        said, asked = [], []

        def ask(prompt):
            asked.append(prompt)
            if "Shield" in prompt:
                return "y"
            if "Bring in" in prompt:
                return "1"
            return ["", "a", "1", "2", "s1", "w", "x"][len(asked) % 7]   # "x" is not a command: asked again

        gamedata.use("mega_great_league")
        try:
            you = Human(mega, ask=ask, say=said.append)
            b = play(mega, [list(mega.teams[24].spec), list(mega.teams[2].spec)], [you, Heuristic("baiter", seed=1)], seed=2)
        finally:
            gamedata.use("great_league")
        self.assertTrue(b.done)
        self.assertTrue(any("YOU" in s and "THEM" in s for s in said))
        self.assertTrue(any("Shield" in a for a in asked))


class RecordedBattleTests(unittest.TestCase):
    """Habits from a made-up Battle Turns folder (the real one stays local)."""

    def test_stream_views_share_their_result(self):
        from mango_pomdp.battle_turns import fill_paired_results, partner
        self.assertEqual(partner("battle-gdansk-g03648-L#1"), "battle-gdansk-g03648-R#1")
        self.assertEqual(partner("battle-gdansk-g03648-R#2"), "battle-gdansk-g03648-L#2")
        self.assertIsNone(partner("battle-2026-10-23-132243#1"))
        rows = [{"battle_id": "battle-g1-L#1", "result": ""}, {"battle_id": "battle-g1-R#1", "result": "won"},
                {"battle_id": "battle-g2-L#1", "result": ""}, {"battle_id": "battle-2026-10-23#1", "result": ""}]
        fill_paired_results(rows)
        self.assertEqual([r["result"] for r in rows], ["lost", "won", "", ""])
        both = [{"battle_id": "battle-g3-L#1", "result": "won"}, {"battle_id": "battle-g3-R#1", "result": "won"}]
        fill_paired_results(both)
        self.assertEqual([r["result"] for r in both], ["", ""])

    def test_stream_view_that_misnames_a_pokemon_is_set_aside(self):
        from mango_pomdp.battle_turns import disagrees_with_owner
        cols = {f"{s}_{k}": "" for s in ("you", "them") for k in (1, 2, 3)}
        left = {**cols, "battle_id": "battle-g1-L#1", "you_1": "ninetales_alolan", "them_1": "empoleon"}
        right = {**cols, "battle_id": "battle-g1-R#1", "you_1": "empoleon", "them_1": "ninetales_shadow"}
        by_id = {r["battle_id"]: r for r in (left, right)}
        self.assertFalse(disagrees_with_owner(left, by_id))
        self.assertTrue(disagrees_with_owner(right, by_id))
        right["them_1"] = "carbink"   # a different species: either could be the misread
        self.assertFalse(disagrees_with_owner(right, by_id))

    def folder(self):
        import tempfile
        from pathlib import Path
        d = Path(tempfile.mkdtemp())
        cols = ["battle_id", "result"] + [f"{s}_{k}{x}" for s in ("you", "them") for k in (1, 2, 3)
                                           for x in ("", "_fast", "_charged")]
        row = dict.fromkeys(cols, "")
        row.update(battle_id="b#1", result="lost", you_1="medicham", you_1_fast="COUNTER",
                   you_1_charged="ICE_PUNCH;DYNAMIC_PUNCH", them_1="azumarill", them_1_fast="BUBBLE",
                   them_1_charged="ICE_BEAM;PLAY_ROUGH")
        with (d / "battles.csv").open("w", newline="") as f:
            w = csv.DictWriter(f, cols)
            w.writeheader()
            w.writerow(row)
        turns = [  # turn, you_shields, them_shields, you_action, them_action, their energy after
            (0, 2, 2, "", "charged:ICE_BEAM", 0),                          # thrown at 55, while you had 2
            (1, 2, 1, "charged:ICE_PUNCH(shielded)", "shield", 0),          # they shielded at full HP
            (2, 2, 1, "charged:DYNAMIC_PUNCH", "", 0),                      # with one left, they didn't
        ]
        with (d / "turns.csv").open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["battle_id", "turn", "you_active", "them_active", "you_1", "you_1_energy", "them_1",
                        "them_1_energy", "you_shields", "them_shields", "you_action", "them_action", "charged_first"])
            for t, ys, ts, ya, ta, e in turns:
                w.writerow(["b#1", t, "medicham", "azumarill", "medicham", 0, "azumarill", e, ys, ts, ya, ta, ""])
        return d

    def test_decisions_are_kept_with_their_context(self):
        from mango_pomdp.battle_turns import load as load_turns
        b = load_turns(gd, self.folder())[0]
        self.assertEqual(b.you[0], ("medicham", "COUNTER", ("ICE_PUNCH", "DYNAMIC_PUNCH")))
        first, second = b.shields
        self.assertEqual((first.move, first.shields, first.faced, first.shielded, first.hp),
                         ("ICE_PUNCH", (2, 2), 0, True, 1.0))
        self.assertEqual((second.move, second.shields, second.faced, second.shielded), ("DYNAMIC_PUNCH", (1, 2), 1, False))
        throw = next(c for c in b.throws if c.choice)
        self.assertEqual((throw.choice, throw.energy, throw.shields), ("ICE_BEAM", 55, (2, 2)))

    def test_their_switches_and_replacements_are_kept(self):
        import tempfile
        from pathlib import Path
        from mango_pomdp.battle_turns import ReplaceCase, SwitchCase, battle_at, load as load_turns
        d = Path(tempfile.mkdtemp())
        cols = ["battle_id", "result"] + [f"{s}_{k}{x}" for s in ("you", "them") for k in (1, 2, 3)
                                           for x in ("", "_fast", "_charged")]
        row = dict.fromkeys(cols, "")
        row.update(battle_id="b#2", result="won", you_1="medicham", you_1_fast="COUNTER",
                   you_1_charged="ICE_PUNCH;DYNAMIC_PUNCH", them_1="azumarill", them_2="registeel", them_3="skarmory")
        with (d / "battles.csv").open("w", newline="") as f:
            w = csv.DictWriter(f, cols)
            w.writeheader()
            w.writerow(row)
        turns = [  # turn, them_active, them_action
            (0, "azumarill", ""),                   # free, could switch, stayed
            (1, "registeel", "switch:registeel"),   # switched
            (2, "registeel", ""),                   # the switch timer is running: no case
            (3, "registeel", "faint"),
            (4, "azumarill", "switch:azumarill"),   # a replacement, not a switch
        ]
        with (d / "turns.csv").open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["battle_id", "turn", "you_active", "them_active", "you_shields", "them_shields",
                        "you_action", "them_action", "charged_first"])
            for t, active, action in turns:
                w.writerow(["b#2", t, "medicham", active, 2, 2, "", action, ""])
        rb = load_turns(gd, d)[0]
        self.assertEqual(rb.switches, [SwitchCase(0, "azumarill", ""), SwitchCase(1, "azumarill", "registeel")])
        self.assertEqual(rb.replaces, [ReplaceCase(4, "registeel", "azumarill")])
        b = battle_at(gd, rb, 2, free="them")
        self.assertEqual((b.sides[1].mon.species.id, b.sides[1].entered, b.sides[1].switch_timer > 0),
                         ("registeel", 1, True))

    def test_missed_faints_are_filled_in_and_hp_reaches_zero_when_they_faint(self):
        import tempfile
        from pathlib import Path
        from mango_pomdp.battle_turns import load as load_turns
        d = Path(tempfile.mkdtemp())
        cols = ["battle_id", "result"] + [f"{s}_{k}{x}" for s in ("you", "them") for k in (1, 2, 3)
                                           for x in ("", "_fast", "_charged")]
        row = dict.fromkeys(cols, "")
        row.update(battle_id="b#3", result="won", you_1="medicham", you_1_fast="COUNTER",
                   you_1_charged="ICE_PUNCH;DYNAMIC_PUNCH", them_1="azumarill", them_2="registeel", them_3="skarmory")
        with (d / "battles.csv").open("w", newline="") as f:
            w = csv.DictWriter(f, cols)
            w.writeheader()
            w.writerow(row)
        # Their Azumarill takes three Counters and goes, with no faint recorded: the "(0 turns)" switch
        # without a charged move before it was a replacement. Registeel then faints, recorded, after
        # one Counter (it really had less HP than the formula says, or a hit was missed). Skarmory's
        # faint, the last, isn't recorded: they lost, so it fainted then.
        turns = [(0, "azumarill", "fast:COUNTER", ""), (1, "azumarill", "fast:COUNTER", ""),
                 (2, "azumarill", "fast:COUNTER", ""), (3, "registeel", "", "switch:registeel(0 turns)"),
                 (4, "registeel", "fast:COUNTER", "faint"), (5, "skarmory", "", "switch:skarmory(0 turns)"),
                 (6, "skarmory", "fast:COUNTER", "")]
        with (d / "turns.csv").open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["battle_id", "turn", "you_active", "them_active", "you_shields", "them_shields",
                        "you_action", "them_action", "charged_first"])
            for t, active, mine, theirs in turns:
                w.writerow(["b#3", t, "medicham", active, 2, 2, mine, theirs, ""])
        rb = load_turns(gd, d)[0]
        self.assertEqual(rb.inferred, [(3, "them", "azumarill")])
        self.assertTrue(rb.complete)
        snap = rb.snapshots[4]
        self.assertEqual(snap["mons"]["them"]["azumarill"][0], 0)
        self.assertGreater(snap["mons"]["them"]["registeel"][0], 0)   # in, and alive, until its faint
        self.assertEqual(rb.scale["them", "registeel"], 2.0)          # a single Counter: scaled up, to the cap
        self.assertEqual(rb.scale["them", "azumarill"],
                         min(2.0, max(0.5, gd.species["azumarill"].hp / rb.dealt_at_faint["them", "azumarill"])))

    def test_a_pokemon_that_comes_back_did_not_faint(self):
        import tempfile
        from pathlib import Path
        from mango_pomdp.battle_turns import load as load_turns
        d = Path(tempfile.mkdtemp())
        cols = ["battle_id", "result"] + [f"{s}_{k}{x}" for s in ("you", "them") for k in (1, 2, 3)
                                           for x in ("", "_fast", "_charged")]
        row = dict.fromkeys(cols, "")
        row.update(battle_id="b#4", result="", you_1="medicham", them_1="azumarill", them_2="registeel",
                   them_3="skarmory")
        with (d / "battles.csv").open("w", newline="") as f:
            w = csv.DictWriter(f, cols)
            w.writeheader()
            w.writerow(row)
        turns = [(0, "azumarill", ""), (1, "registeel", "switch:registeel(0 turns)")] + \
            [(t, "registeel", "") for t in range(2, 9)] + [(9, "azumarill", "switch:azumarill(1 turn)")]   # back
        with (d / "turns.csv").open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["battle_id", "turn", "you_active", "them_active", "you_shields", "them_shields",
                        "you_action", "them_action", "charged_first"])
            for t, active, theirs in turns:
                w.writerow(["b#4", t, "medicham", active, 2, 2, "", theirs, ""])
        rb = load_turns(gd, d)[0]
        self.assertEqual(rb.inferred, [])
        self.assertGreater(rb.snapshots[9]["mons"]["them"]["azumarill"][0], 0)

    def test_context_opponent_copies_only_matching_situations(self):
        from mango_pomdp.battle_turns import ContextOpponent, load as load_turns
        rec = load_turns(gd, self.folder())[0]
        b = Battle([[mon("medicham", fast="COUNTER", charged=["ICE_PUNCH", "DYNAMIC_PUNCH"])],
                    [mon("azumarill", fast="BUBBLE", charged=["ICE_BEAM", "PLAY_ROUGH"])]], seed=0)
        opp = ContextOpponent(Scripted(shields=False), rec)
        view = b.view(1)
        ice_punch = b.sides[0].mon.charged[0]
        self.assertTrue(opp.shield(view, ice_punch))          # same situation as turn 1: they shielded
        opp.faced["azumarill"] = 3
        self.assertFalse(opp.shield(view, ice_punch))         # a different history: the planner decides
        b.sides[1].mon.energy = 55
        self.assertEqual(opp.act(view), CHARGED(0))           # Ice Beam at 55, as they did
        b.sides[0].shields = 0
        self.assertEqual(opp.act(view), FAST)                 # no recorded case with you out of shields


class OpponentModelTests(unittest.TestCase):
    """The learned opponent, on made-up weights (the fitted model stays local)."""

    def battle(self):
        return Battle([[mon("medicham", fast="COUNTER", charged=["ICE_PUNCH", "DYNAMIC_PUNCH"]), mon("azumarill")],
                       [mon("azumarill", fast="BUBBLE", charged=["ICE_BEAM", "PLAY_ROUGH"]), mon("medicham")]], seed=0)

    def model(self, shield=0.0, cheap=0.0, big=0.0):
        from mango_pomdp.opponent_model import SHIELD, THROW, OpponentModel
        return OpponentModel([shield] + [0.0] * (len(SHIELD) - 1),
                             [[0.0] * len(THROW), [cheap] + [0.0] * (len(THROW) - 1), [big] + [0.0] * (len(THROW) - 1)])

    def test_history_is_counted_as_charged_moves_land(self):
        b = self.battle()
        ice_punch = b.sides[0].mon.charged[0]
        b.sides[0].mon.energy = 100
        b.land_charged(0, ice_punch, [Scripted(), Scripted()], shield=True)
        self.assertEqual((b.sides[0].mon.thrown, b.sides[1].mon.taken), (1, 1))
        self.assertTrue(b.sides[0].last_shielded)         # their throw was shielded
        self.assertTrue(b.sides[1].shielded_last)         # we shielded the last one we could
        self.assertIsNone(b.sides[1].last_shielded)
        c = b.clone()
        self.assertEqual((c.sides[0].mon.thrown, c.sides[0].last_shielded, c.sides[1].shielded_last), (1, True, True))

    def test_features_read_the_situation(self):
        from mango_pomdp.opponent_model import SHIELD, THROW, allowed_throws, cheap_big, features_shield, features_throw
        b = self.battle()
        dynamic = b.sides[0].mon.charged[1]
        x = dict(zip(SHIELD, features_shield(b, 1, dynamic)))
        self.assertEqual(len(x), len(SHIELD))
        self.assertEqual((x["bias"], x["hp"], x["shields"], x["left"]), (1.0, 1.0, 1.0, 2 / 3))   # 2 of 3
        self.assertEqual(x["is their cheaper move"], 0.0)   # Dynamic Punch costs more than Ice Punch
        self.assertEqual(x["shielded last one"], 0.5)       # no history yet
        b.sides[1].mon.hp = 1
        self.assertEqual(dict(zip(SHIELD, features_shield(b, 1, dynamic)))["knocks out"], 1.0)
        b.sides[1].mon.energy = 100
        x = dict(zip(THROW, features_throw(b, 1)))
        self.assertEqual(len(x), len(THROW))
        self.assertEqual((x["big move ready"], x["big knocks out"]), (1.0, 0.0))   # azumarill's 1 HP, medicham's full
        mon_ = b.sides[1].mon
        self.assertEqual([mon_.charged[i].id for i in cheap_big(mon_)], ["ICE_BEAM", "PLAY_ROUGH"])
        mon_.energy = mon_.charged[cheap_big(mon_)[0]].energy
        self.assertEqual(allowed_throws(mon_), [True, True, mon_.energy >= mon_.charged[cheap_big(mon_)[1]].energy])

    def test_fitting_recovers_the_signal_and_respects_masks(self):
        from mango_pomdp.opponent_model import _sigmoid, _softmax, fit_logistic, fit_softmax
        rng = random.Random(0)
        X = [[1.0, rng.random()] for _ in range(300)]
        y = [int(rng.random() < _sigmoid(-2 + 4 * x[1])) for x in X]
        w = fit_logistic(X, y, l2=0.1)
        self.assertGreater(w[1], 2)
        self.assertLess(w[0], -0.5)
        # Three choices; the last is only sometimes available, and taken when x is high.
        masks = [[True, True, x[1] > 0.5] for x in X]
        labels = [2 if m[2] and x[1] > 0.7 else int(x[1] > 0.3) for x, m in zip(X, masks)]
        W = fit_softmax(X, labels, masks, l2=0.1)
        self.assertEqual(W[0], [0.0, 0.0])
        p = _softmax([sum(a * b for a, b in zip(row, [1.0, 0.9])) for row in W], [True, True, True])
        self.assertEqual(max(range(3), key=lambda k: p[k]), 2)
        self.assertEqual(_softmax([0.0, 0.0, 9.0], [True, True, False])[2], 0.0)

    def test_learned_opponent_throws_and_shields_as_its_model_says(self):
        import tempfile
        from pathlib import Path
        from mango_pomdp.opponent_model import Learned, OpponentModel
        b = self.battle()
        b.sides[1].mon.energy = 100
        ice_punch = b.sides[0].mon.charged[0]
        bait = Learned(self.model(shield=-30, cheap=30), b, 1, seed=0)
        self.assertEqual(bait.act(b.view(1)), CHARGED(0))       # Ice Beam, the cheaper one
        self.assertFalse(bait.shield(b.view(1), ice_punch))
        nuke = Learned(self.model(shield=30, big=30), b, 1, seed=0)
        self.assertEqual(nuke.act(b.view(1)), CHARGED(1))
        self.assertTrue(nuke.shield(b.view(1), ice_punch))
        b.sides[1].shields = 0
        self.assertFalse(nuke.shield(b.view(1), ice_punch))     # nothing to shield with
        b.sides[1].mon.energy = 0
        self.assertEqual(Learned(self.model(cheap=30), b, 1, seed=0).act(b.view(1)), FAST)   # can't afford one
        path = Path(tempfile.mkdtemp()) / "model.json"
        m = self.model(shield=1.5, cheap=-0.5)
        m.save(path)
        back = OpponentModel.load(path)
        self.assertEqual((back.shield, back.throw), (m.shield, m.throw))

    def test_learned_opponent_switches_and_picks_as_its_model_says(self):
        from mango_pomdp.opponent_model import PICK, SWITCH_F, Learned, features_pick, features_switch
        b = Battle([[mon("medicham"), mon("azumarill"), mon("swampert")],
                    [mon("azumarill"), mon("registeel"), mon("skarmory")]], seed=0)
        self.assertEqual(len(features_switch(b, 1)), len(SWITCH_F))
        self.assertEqual(len(features_pick(b, 1, 2)), len(PICK))
        m = self.model()
        m.switch = [30.0] + [0.0] * (len(SWITCH_F) - 1)
        m.pick = [0.0, -30.0, 0.0]   # brings in the one with the least HP
        b.sides[1].mons[1].hp = 50
        always = Learned(m, b, 1, seed=0)
        self.assertEqual(always.act(b.view(1)), SWITCH(1))
        m.switch[0] = -30.0
        self.assertNotEqual(Learned(m, b, 1, seed=0).act(b.view(1))[0], "switch")
        b.sides[1].mons[0].hp = 0
        self.assertEqual(Learned(m, b, 1, seed=0).replace(b.view(1)), 1)
        self.assertEqual(m.p_pick(b, 1, [1, 2])[0] > 0.99, True)

    def test_belief_picks_out_an_opponent_that_plays_like_the_model(self):
        from mango_pomdp import opponent_model
        from mango_pomdp.opponent_model import Learned
        from mango_pomdp.policies import STYLES
        saved = opponent_model._cached.get("model", "unset")
        model = self.model(shield=30, cheap=-30, big=-30)   # shields everything, never throws
        opponent_model._cached["model"] = model
        try:
            rng = random.Random(3)
            hits = 0
            for g in range(4):
                teams = [prior.sample_team(rng), prior.sample_team(rng)]
                battle = Battle([build_team(gd, teams[0]), build_team(gd, teams[1])], seed=g)
                belief = Belief(gd, prior, me=0, n=200, styles=STYLES + ("learned",), seed=g)
                belief.observe(battle.log)
                battle.play([Heuristic("baiter", seed=g), Learned(model, battle, 1, seed=g)], [belief])
                post = belief.style_posterior()
                hits += max(post, key=post.get) == "learned"
            self.assertGreaterEqual(hits, 3)
        finally:
            if saved == "unset":
                opponent_model._cached.pop("model", None)
            else:
                opponent_model._cached["model"] = saved

    def test_planner_rolls_out_against_the_learned_opponent(self):
        from mango_pomdp import opponent_model
        saved = opponent_model._cached.get("model", "unset")
        opponent_model._cached["model"] = self.model(shield=1.0, cheap=0.5, big=-0.5)
        try:
            me = make_player("planner-learned", gd, prior, 0, rollouts=4)
            b = play(gd, [prior.sample_team(random.Random(1)), prior.sample_team(random.Random(2))],
                     [me, Heuristic("baiter", seed=3)], seed=4)
            self.assertTrue(b.done)
        finally:
            if saved == "unset":
                opponent_model._cached.pop("model", None)
            else:
                opponent_model._cached["model"] = saved


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
