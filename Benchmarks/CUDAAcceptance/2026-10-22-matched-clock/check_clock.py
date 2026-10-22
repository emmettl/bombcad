import unittest
from clock_model import simulate, f32, origin_ticks


class ClockControls(unittest.TestCase):
    def test_batch_stop_does_not_consume_schedule(self):
        r = simulate([.5, .5], 1.)
        self.assertTrue(r['exact'])
        self.assertEqual([e['dt'] for e in r['events']], [.5, 0., .5])
        self.assertEqual(r['events'][-1]['clockTicks'], 2**40)

    def test_clipping_is_a_mismatch_not_a_fitted_schedule(self):
        r = simulate([.6, .6], 1.)
        self.assertFalse(r['exact'])
        self.assertEqual(r['differentIndices'], [1])
        self.assertEqual(r['realized'][-1], f32(1. - f32(.6)))

    def test_exhaustion_does_not_disable_stopping(self):
        r = simulate([.25], 1.)
        self.assertFalse(r['exact'])
        self.assertNotEqual(r['stopped'], 2)

    def test_refusal_and_origin_rounding(self):
        for values in [[], [0], [-1], [float('nan')]]:
            with self.assertRaises(ValueError):
                simulate(values, 1)
        self.assertEqual(origin_ticks(2.5 / 2**40), 3)
        self.assertEqual(origin_ticks(2.25 / 2**40), 2)


if __name__ == '__main__':
    unittest.main()
