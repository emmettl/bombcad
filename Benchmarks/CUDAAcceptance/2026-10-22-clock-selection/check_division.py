import unittest
from fractions import Fraction

from exact_division import rounded, select, value, word


class DivisionControls(unittest.TestCase):
    def test_exact_and_quotient(self):
        self.assertEqual(select(.5, 4., 2.), word(1.))
        self.assertEqual(select(.5, 1., 3.), word(1./6))

    def test_ties_to_even(self):
        a, b, c = map(Fraction, [value(0x3f800000), value(0x3f800001), value(0x3f800002)])
        self.assertEqual(rounded((a+b)/2), 0x3f800000)
        self.assertEqual(rounded((b+c)/2), 0x3f800002)

    def test_refuses_invalid(self):
        for speed in [0., -1., float('nan'), float('inf')]:
            with self.assertRaises(ValueError):
                select(.5, 1., speed)


if __name__ == '__main__':
    unittest.main()
