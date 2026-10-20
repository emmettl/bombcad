"""The protective-design prototype: its closed forms against the SDOF reference, its loads against
Kingery–Bulmash, its grading, and its searches on a small made-up site.

    python3 Scripts/protective/test-protective.py
"""

import math
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
# The CI Mac's Python has no numpy: skipped there, as the reference scripts' tests are.
try:
    import numpy as np
    import model  # noqa: E402
    import search  # noqa: E402
    import scenarios  # noqa: E402
except ImportError as error:
    print(f"SKIP: {error}")
    sys.exit(0)

sdof = model.sdof
kb = model.kb


class ClosedFormTests(unittest.TestCase):
    """The panes' closed forms are Biggs's undamped elastic responses; set them against the
    reference's own integration of the same system."""

    def system(self, glazing="annealed 6"):
        p = model.pane(1.2, 1.5, model.GLAZINGS[glazing])
        member = sdof.elastic_plastic(p.mass, p.stiffness, 1e15, "simple", "uniform")
        return p, member

    def test_uncracked_pane_matches_the_reference(self):
        p, member = self.system()
        for peak, impulse in [(5e3, 50.0), (20e3, 150.0), (60e3, 600.0)]:
            duration = 2 * impulse / peak
            period = member.natural_period()
            ts, xs, _ = sdof.respond(member, sdof.triangular(peak * p.area, duration),
                                     until=duration + period, dt=period / 2000)
            x, _ = model.elastic_triangular(p.omega, duration, peak * p.area / p.stiffness, ts)
            with self.subTest(peak=peak):
                self.assertAlmostEqual(max(x) / max(xs), 1.0, delta=0.01)

    def test_peak_matches_the_dynamic_load_factor(self):
        p, member = self.system()
        period = member.natural_period()
        for ratio in (0.1, 0.5, 1.0, 3.0):
            duration = ratio * period
            static = 1.0
            times = np.linspace(0, duration + period, 20000)
            x, _ = model.elastic_triangular(p.omega, duration, static, times)
            with self.subTest(ratio=ratio):
                self.assertAlmostEqual(max(x), sdof.elastic_triangular_dlf(ratio), delta=0.005)

    def test_membrane_from_a_moving_start_matches_the_reference(self):
        p = model.pane(1.2, 1.5, model.GLAZINGS["laminated 13.5"])
        stiffness, _ = model.membrane_system(p)
        member = sdof.elastic_plastic(p.mass, stiffness, 1e15, "simple", "uniform")
        factor = sdof.load_mass_factor("simple", "uniform", "elastic")
        omega = math.sqrt(stiffness / (factor * p.mass))
        period = 2 * math.pi / omega
        speed, force, left = 3.0, 20e3 * p.area, 0.01
        spike = period / 2000
        momentum = factor * p.mass * speed
        pulse = [(0.0, 2 * momentum / spike + force), (spike, force * (1 - spike / left)), (left, 0.0)]
        ts, xs, _ = sdof.respond(member, pulse, until=left + 0.75 * period, dt=spike / 10)
        x, _ = model.elastic_triangular(omega, left, force / stiffness, np.asarray(ts))
        x = x + speed / omega * np.sin(omega * np.asarray(ts))
        self.assertAlmostEqual(max(x) / max(xs), 1.0, delta=0.02)


class LoadTests(unittest.TestCase):
    def setUp(self):
        self.building = model.Building("A", 0, 0, 20, 10)
        self.south = model.Side(self.building, "S")
        self.charge = model.Charge(100.0, 10.0, -30.0)

    def test_head_on_is_kingery_bulmash_reflected(self):
        load = model.side_load(self.south, self.charge, [self.building])
        point = kb.at(np.array([load.distance]), 100.0)
        self.assertAlmostEqual(load.peak / float(point["reflected_pressure"][0]), 1.0, places=6)
        self.assertAlmostEqual(load.impulse / float(point["reflected_impulse"][0]), 1.0, places=6)
        self.assertAlmostEqual(load.facing, 1.0, places=6)

    def test_facing_away_is_incident(self):
        north = model.Side(self.building, "N")
        load = model.side_load(north, self.charge, [self.building])
        point = kb.at(np.array([load.distance]), 100.0)
        self.assertLess(load.facing, 0)
        self.assertAlmostEqual(load.peak / float(point["incident_pressure"][0]), 1.0, places=6)

    def test_the_peak_falls_with_the_angle(self):
        peaks = []
        for x in (10.0, 30.0, 50.0, 70.0):
            charge = model.Charge(100.0, x, -30.0)
            load = model.side_load(self.south, charge, [self.building])
            point = kb.at(np.array([load.distance]), 100.0)
            peaks.append(load.peak / float(point["incident_pressure"][0]))
        self.assertTrue(all(a >= b for a, b in zip(peaks, peaks[1:])), peaks)

    def test_each_building_crossed_takes_its_share(self):
        between = model.Building("B", 5, -20, 15, -12)
        shielding = model.Shielding(0.5, 0.75, 0.6, 0.8)
        alone = model.side_load(self.south, self.charge, [self.building], shielding=shielding)
        shielded = model.side_load(self.south, self.charge, [self.building, between],
                                   shielding=shielding)
        self.assertEqual(shielded.crossed, 1)
        self.assertAlmostEqual(shielded.peak / alone.peak, 0.5, places=9)
        self.assertAlmostEqual(shielded.impulse / alone.impulse, 0.75, places=9)
        wall = model.Barrier(0, -25, 20, -25)
        walled = model.side_load(self.south, self.charge, [self.building], (wall,), shielding)
        self.assertEqual(walled.barriers, 1)
        self.assertAlmostEqual(walled.peak / alone.peak, 0.6, places=9)

    def test_beyond_the_curves_no_load(self):
        far = model.side_load(self.south, model.Charge(1.0, 10.0, -60.0), [self.building])
        self.assertEqual(far.peak, 0.0)
        self.assertFalse(far.in_range)


class GradingTests(unittest.TestCase):
    loads = [(m * 10e3, m * 100.0) for m in (0.2, 0.5, 1, 2, 4, 8, 16)]

    def test_conditions_never_improve_as_the_load_grows(self):
        for name, glazing in model.GLAZINGS.items():
            p = None if glazing.infill else model.pane(1.2, 1.5, glazing)
            levels = [0 if p is None else model.glazing_condition(p, a, b) for a, b in self.loads]
            with self.subTest(glazing=name):
                self.assertEqual(levels, sorted(levels))

    def test_the_heavy_laminate_is_never_worse_than_annealed(self):
        annealed = model.pane(1.2, 1.5, model.GLAZINGS["annealed 6"])
        laminated = model.pane(1.2, 1.5, model.GLAZINGS["laminated 13.5"])
        for a, b in self.loads:
            self.assertLessEqual(model.glazing_condition(laminated, a, b),
                                 model.glazing_condition(annealed, a, b))

    def test_landing_by_gsa(self):
        height = 1.65
        fall = math.sqrt(2 * height / model.G)
        self.assertEqual(model.CONDITIONS[model._landing(0.0, height)], "3a")
        self.assertEqual(model.CONDITIONS[model._landing(0.9 / fall, height)], "3a")
        self.assertEqual(model.CONDITIONS[model._landing(2.5 / fall, height)], "3b")
        self.assertEqual(model.CONDITIONS[model._landing(5.8, height)], "4")
        self.assertEqual(model.CONDITIONS[model._landing(30.0, height)], "5")

    def test_walls_by_rotation(self):
        for name, wall in model.WALLS.items():
            levels = [model.wall_level(wall, a, b) for a, b in self.loads]
            with self.subTest(wall=name):
                self.assertEqual(levels, sorted(levels))
        concrete = [model.wall_level(model.WALLS["concrete"], a, b) for a, b in self.loads]
        brick = [model.wall_level(model.WALLS["brick"], a, b) for a, b in self.loads]
        self.assertTrue(all(c <= b for c, b in zip(concrete, brick)))

    def test_the_limit_multiplier_is_where_the_side_first_fails(self):
        building = model.Building("A", 0, 0, 20, 10)
        side = model.Side(building, "S")
        load = model.side_load(side, model.Charge(100.0, 10.0, -40.0), [building])
        m = model.limit_multiplier(side, "annealed 6", "concrete", load, 3, 2)
        self.assertTrue(0.02 < m < 50)
        p = model.pane(*building.pane, model.GLAZINGS["annealed 6"])
        wall = model.WALLS["concrete"]

        def fails(f):
            return (model.glazing_condition(p, f * load.peak, f * load.impulse) > 3 or
                    model.wall_level(wall, f * load.peak, f * load.impulse) > 2)
        self.assertTrue(fails(m * 1.03))
        self.assertFalse(fails(m * 0.97))

    def test_exceedance(self):
        self.assertAlmostEqual(model.exceedance(1.0, 0.25), 0.5)
        self.assertAlmostEqual(model.exceedance(math.exp(0.25), 0.25), 0.1587, places=4)
        self.assertAlmostEqual(model.exceedance(2.0, 0.25) + model.exceedance(0.5, 0.25), 1.0)
        self.assertEqual(model.exceedance(1.2, 0.0), 0.0)


def small_problem(**kw):
    buildings = [model.Building("A", 0, 0, 20, 10), model.Building("B", 30, 0, 50, 10, storeys=2)]
    threats = [search.Threat(model.Charge(60.0, 25.0, -15.0))]
    site = [search.StandOff("keep back", 50.0, ((0, 25.0, -45.0),)),
            search.BarrierWall("wall", 90.0, model.Barrier(-5, -6, 55, -6))]
    return search.Problem("small", buildings, threats, site, ["film, anchored", "laminated 13.5",
                                                               "infill"],
                          ["brick, retrofitted", "concrete"], search.Target(**kw))


class SearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.problem = small_problem()
        cls.ev = search.Evaluator(cls.problem)
        cls.plans = search.exact(cls.problem, cls.ev)
        cls.best = search.best(cls.plans, cls.problem.target)

    def test_every_combination_is_tried(self):
        self.assertEqual(len(self.plans), 4)
        self.assertEqual(sorted(p.site for p in self.plans), [(), (0,), (0, 1), (1,)])

    def test_the_best_plan_meets_the_target(self):
        self.assertTrue(self.best.meets)
        self.assertTrue(all(p <= self.problem.target.chance for p in self.best.chances.values()))
        self.assertFalse(search.as_built(self.problem, self.ev).meets)

    def test_no_search_beats_the_exact_one(self):
        greedy = search.greedy(self.problem, self.ev)
        annealed = search.anneal(self.problem, self.ev, steps=60)
        self.assertTrue(greedy.meets)
        self.assertGreaterEqual(greedy.cost, self.best.cost - 1e-9)
        self.assertAlmostEqual(annealed.cost, self.best.cost)

    def test_a_plan_costs_what_its_changes_cost(self):
        plan = self.best
        again = self.ev.evaluate(plan.site, plan.choices, "check")
        self.assertAlmostEqual(again.cost, plan.cost)
        self.assertEqual(again.meets, plan.meets)

    def test_ranked_puts_the_cheapest_meeting_plan_first(self):
        ranked = search.ranked(self.problem, self.plans)
        self.assertIs(ranked[0], self.best)
        meeting = [p.cost for p in ranked if p.meets]
        self.assertEqual(meeting, sorted(meeting))

    def test_a_stand_off_moves_its_threat(self):
        moved = self.ev.threats((0,))[0].charge
        self.assertEqual((moved.x, moved.y), (25.0, -45.0))
        self.assertEqual(self.ev.threats(())[0].charge.y, -15.0)

    def test_a_looser_target_costs_no_more(self):
        loose = small_problem(chance=0.3)
        cost = search.best(search.exact(loose), loose.target).cost
        self.assertLessEqual(cost, self.best.cost + 1e-9)


class ScenarioTests(unittest.TestCase):
    def test_the_uncertain_charge_is_the_same_every_time(self):
        a, b = scenarios.uncertain(), scenarios.uncertain()
        self.assertEqual([t.charge for t in a.threats], [t.charge for t in b.threats])

    def test_the_courtyard_plans(self):
        problem = scenarios.courtyard()
        ev = search.Evaluator(problem)
        best = search.best(search.exact(problem, ev), problem.target)
        self.assertTrue(best.meets)
        self.assertEqual(search.greedy(problem, ev).cost, best.cost)


if __name__ == "__main__":
    unittest.main()
