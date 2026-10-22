import unittest
import numpy as np
from analyze import fma, f32, replay


class ReplayControls(unittest.TestCase):
    def test_float32_fma_keeps_exact_residual(self):
        # Exact product (1+2^-23)(1-2^-23) = 1-2^-46.
        a, b = 1 + 2**-23, 1 - 2**-23
        self.assertEqual(fma(a, b, -1), -2**-46)
        self.assertEqual(f32(f32(a * b) - 1), 0)

    def test_seeded_two_phase_contract_and_word_refusal(self):
        p, dt = [1, 2, -1, 3, -1], [0, 1, 1, 1, 1]
        expected = np.array([[1, 0, 0, 1, 1], [2, 2, 2, 2, 1], [2, 2, 2, 2, 0],
                             [3, 5, 2, 2, 0], [3, 5, 2, 2, 0]], dtype=np.float32)
        for policy in ['fused', 'separate']:
            result = replay(p, dt, [0] * 5, list(range(5)), policy, expected)
            self.assertEqual(result['recordWordDifferences'], 0)
            self.assertEqual(result['final'], [3, 5, 2, 2, 0])
            changed = expected.copy()
            changed.view(np.uint32)[1, 1] += 1
            self.assertEqual(replay(p, dt, [0] * 5, list(range(5)), policy, changed)['recordWordDifferences'], 1)

    def test_initial_sample_is_retained(self):
        result = replay([.01, -.01], [0, 1], [0] * 5, [5, 6], 'fused')
        self.assertEqual([(t['sample'], t['open']) for t in result['transitions']], [(0, 1), (1, 0)])
        self.assertEqual(result['final'][2], 0)


if __name__ == '__main__':
    unittest.main()
