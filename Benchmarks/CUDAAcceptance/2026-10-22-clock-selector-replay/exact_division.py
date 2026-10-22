"""Nearest-even Float32 division reference for positive finite captured selector inputs."""
from fractions import Fraction
import math
import struct


def value(word):
    return struct.unpack('<f', struct.pack('<I', word))[0]


def word(number):
    return struct.unpack('<I', struct.pack('<f', number))[0]


def rounded(rational):
    if rational <= 0:
        raise ValueError('positive rational required')
    candidate = word(float(rational))
    choices = range(max(1, candidate-2), min(0x7f800000, candidate+3))
    # The exact rational distance decides rounding; an even low bit wins a tie.
    return min(choices, key=lambda w: (abs(Fraction(value(w))-rational), w & 1))


def select(cfl, dx, fastest):
    if not all(math.isfinite(x) and x > 0 for x in [cfl, dx, fastest]):
        raise ValueError('positive finite input required')
    numerator = value(rounded(Fraction(cfl)*Fraction(dx)))
    return rounded(Fraction(numerator)/Fraction(fastest))
