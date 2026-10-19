"""Biggs's elastic–plastic single degree of freedom for one-way members under a blast pulse.

    python3 Scripts/reference/sdof.py

prints the closed-form elastic dynamic load factor of a triangular pulse and the elastic–plastic
ductility against t_d / T for a few resistance ratios, the axes of Biggs's response charts.

The method is J. M. Biggs, *Introduction to Structural Dynamics*, McGraw-Hill, 1964, chapters 2
and 5, as UFC 3-340-02 (2008) §3-12 to §3-19 restates it. A member of total mass M under a total
load F(t) is replaced by one mass on a spring,

    K_LM M x'' + R(x) = F(t),

x the deflection at the point of largest deflection (mid-span, or the cantilever's tip), R the
member's resistance as a total load, and K_LM = K_M / K_L its load–mass factor, which changes as
the member passes from elastic to plastic (Biggs Table 5.1, UFC Table 3-12). The resistance is
elastic, then elastic–plastic for a fixed member once its supports yield, then perfectly plastic;
unloading is elastic, and the member rebounds to the same resistance the other way.

Pulses are piecewise linear in time: `triangular` (a peak decaying linearly to zero, Biggs's chart
load) and `bilinear` (a peak, a knee, and zero, UFC's fictitious bilinear form, Figure 3-216's).

Integration is Newmark's average acceleration, with each step's resistance taken from the state at
its start and corrected by an equilibrium iteration; the step defaults to a thousandth of the
natural period, ample for the 0.5% the tests ask. No damping by default, as UFC takes none.
"""

import math
import sys
from dataclasses import dataclass

# Biggs (1964) Table 5.1 and UFC 3-340-02 Table 3-12: (K_L, K_M) by support, load and range.
# Ranges: "elastic", "elastoplastic" (fixed members only, after the supports yield), "plastic".
FACTORS = {
    ("simple", "uniform"): {"elastic": (0.64, 0.50), "plastic": (0.50, 0.33)},
    ("simple", "point"): {"elastic": (1.0, 0.49), "plastic": (1.0, 0.33)},
    ("fixed", "uniform"): {"elastic": (0.53, 0.41), "elastoplastic": (0.64, 0.50),
                           "plastic": (0.50, 0.33)},
    ("fixed", "point"): {"elastic": (1.0, 0.37), "plastic": (1.0, 0.33)},
    ("cantilever", "uniform"): {"elastic": (0.40, 0.26), "plastic": (0.50, 0.33)},
    ("cantilever", "point"): {"elastic": (1.0, 0.24), "plastic": (1.0, 0.33)},
}


def load_mass_factor(support, load, regime):
    factors = FACTORS[(support, load)]
    kl, km = factors.get(regime, factors["plastic"] if regime != "elastic" else factors["elastic"])
    return km / kl


@dataclass
class Member:
    """A one-way member as an SDOF system. `points` is the resistance backbone, (deflection m,
    total resistance N) beyond the origin, each segment's regime in `regimes`; past the last point
    the resistance stays at the last value."""

    mass: float  # total mass, kg
    points: list  # [(x1, R1), (x2, R2)...], x increasing
    regimes: list  # regime name of each segment
    support: str
    load: str

    @property
    def stiffness(self):
        return self.points[0][1] / self.points[0][0]

    @property
    def elastic_limit(self):
        return self.points[0][0]

    @property
    def ultimate(self):
        return self.points[-1][1]

    @property
    def equivalent_elastic_deflection(self):
        """Biggs's X_E: the elastic deflection of the elastic–perfectly plastic backbone that
        reaches R_u with the same energy absorbed as the real one at its last point, so that
        R_u (x_last - X_E / 2) equals the area under the backbone (UFC 3-340-02 §3-15.3; it gives
        UFC Table 3-8's K_E = 307 EI / L^4 for a fixed member under a uniform load with equal
        moments). X_el itself for an elastic–perfectly plastic member."""
        pts = [(0.0, 0.0)] + list(self.points)
        if len(pts) == 2:
            return pts[1][0]
        area = sum(0.5 * (r0 + r1) * (x1 - x0) for (x0, r0), (x1, r1) in zip(pts, pts[1:]))
        ru, xl = pts[-1][1], pts[-1][0]
        return 2.0 * (ru * xl - area) / ru

    def natural_period(self, regime="elastic"):
        km = load_mass_factor(self.support, self.load, regime) * self.mass
        return 2.0 * math.pi * math.sqrt(km / self.stiffness)


def beam(span, mass_per_length, EI, support, load, mp, mp_support=None):
    """A prismatic one-way member: span (m), mass per length (kg/m), flexural rigidity EI (N m^2),
    `support` "simple", "fixed" or "cantilever", `load` "uniform" or "point" (at mid-span, or at the
    cantilever's tip), plastic moment mp (N m) at mid-span and mp_support at the supports (fixed
    members; mp if not given). Resistances and stiffnesses from UFC 3-340-02 Table 3-1 and Biggs
    Table 5.1, as total loads."""
    L, M = span, mass_per_length * span
    ms = mp if mp_support is None else mp_support
    if support == "simple":
        ru, k = (8.0 * mp / L, 384.0 * EI / (5.0 * L**3)) if load == "uniform" else (4.0 * mp / L, 48.0 * EI / L**3)
        return Member(M, [(ru / k, ru)], ["elastic"], support, load)
    if support == "cantilever":
        ru, k = (2.0 * mp / L, 8.0 * EI / L**3) if load == "uniform" else (mp / L, 3.0 * EI / L**3)
        return Member(M, [(ru / k, ru)], ["elastic"], support, load)
    if support == "fixed":
        if load == "uniform":
            re, ke = 12.0 * ms / L, 384.0 * EI / L**3
            ru, kep = 8.0 * (ms + mp) / L, 384.0 * EI / (5.0 * L**3)
            x1 = re / ke
            return Member(M, [(x1, re), (x1 + (ru - re) / kep, ru)], ["elastic", "elastoplastic"],
                          support, load)
        ru, k = 4.0 * (ms + mp) / L, 192.0 * EI / L**3
        return Member(M, [(ru / k, ru)], ["elastic"], support, load)
    raise ValueError(support)


def elastic_plastic(mass, stiffness, ultimate, support="simple", load="uniform"):
    """An elastic–perfectly plastic member given directly by its total mass, stiffness and
    ultimate resistance."""
    return Member(mass, [(ultimate / stiffness, ultimate)], ["elastic"], support, load)


def triangular(peak, duration):
    """A load rising at once to `peak` (N) and falling linearly to zero at `duration` (s)."""
    return [(0.0, peak), (duration, 0.0)]


def bilinear(peak, knee_time, knee_load, duration):
    """A load rising at once to `peak`, falling linearly to `knee_load` at `knee_time`, then to zero
    at `duration`."""
    return [(0.0, peak), (knee_time, knee_load), (duration, 0.0)]


def _load_at(pulse, t):
    if t < pulse[0][0] or t > pulse[-1][0]:
        return 0.0
    for (t0, f0), (t1, f1) in zip(pulse, pulse[1:]):
        if t0 <= t <= t1:
            return f0 + (f1 - f0) * (t - t0) / (t1 - t0) if t1 > t0 else f1
    return 0.0


def _impulse(pulse):
    return sum(0.5 * (f0 + f1) * (t1 - t0) for (t0, f0), (t1, f1) in zip(pulse, pulse[1:]))


class _Spring:
    """The resistance with its plastic history: the backbone in the direction of loading, elastic
    unloading from the furthest point reached, the same resistance in rebound."""

    def __init__(self, member):
        self.m = member
        self.k = member.stiffness
        self.offset = 0.0  # permanent set: R = k (x - offset) while elastic
        self.xmax = 0.0  # furthest positive deflection reached on the backbone
        self.regime = "elastic"

    def _backbone(self, x):
        pts = self.m.points
        if x <= pts[0][0]:
            return self.k * x, "elastic"
        for i, ((x0, r0), (x1, r1)) in enumerate(zip(pts, pts[1:])):
            if x <= x1:
                return r0 + (r1 - r0) * (x - x0) / (x1 - x0), self.m.regimes[i + 1]
        return pts[-1][1], "plastic"

    def trial(self, x):
        """Resistance at x from the committed state, without committing; and its regime."""
        r = self.k * (x - self.offset)
        if x > self.xmax:
            rb, regime = self._backbone(x)
            if r >= rb:
                return rb, regime
        ru = self.m.ultimate
        if r > ru:
            return ru, "plastic"
        if r < -ru:
            return -ru, "plastic"
        return r, "elastic" if self.regime == "elastic" else self.regime

    def commit(self, x):
        r, regime = self.trial(x)
        if x > self.xmax and r < self.k * (x - self.offset):
            self.xmax = x
        if r != self.k * (x - self.offset):
            self.offset = x - r / self.k
        self.regime = regime
        return r


def respond(member, pulse, until=None, dt=None, damping=0.0, constant_factor=None):
    """Integrate the member under `pulse`; returns (times, deflections, resistances).

    The load–mass factor follows the resistance's regime (elastic, elastoplastic, plastic) unless
    `constant_factor` fixes it. `until` defaults to the pulse's end plus three elastic periods."""
    T = member.natural_period("elastic")
    dt = dt or T / 1000.0
    until = until or pulse[-1][0] + 3.0 * T
    spring = _Spring(member)
    km = lambda regime: (constant_factor or load_mass_factor(member.support, member.load, regime)) * member.mass
    c = damping * 2.0 * math.sqrt(member.stiffness * km("elastic"))
    t, x, v = 0.0, 0.0, 0.0
    m = km("elastic")
    a = (_load_at(pulse, 0.0)) / m
    ts, xs, rs = [0.0], [0.0], [0.0]
    while t < until:
        t1 = t + dt
        f1 = _load_at(pulse, t1)
        m = km(spring.regime)
        # Average acceleration: x1 = x + dt v + dt^2/4 (a + a1); iterate a1 to equilibrium.
        a1 = a
        for _ in range(50):
            x1 = x + dt * v + 0.25 * dt * dt * (a + a1)
            v1 = v + 0.5 * dt * (a + a1)
            r1, regime = spring.trial(x1)
            m1 = km(regime)
            a_new = (f1 - r1 - c * v1) / m1
            if abs(a_new - a1) <= 1e-12 * (abs(a_new) + 1e-30):
                a1 = a_new
                break
            a1 = a_new
        x1 = x + dt * v + 0.25 * dt * dt * (a + a1)
        v1 = v + 0.5 * dt * (a + a1)
        r1 = spring.commit(x1)
        t, x, v, a = t1, x1, v1, a1
        ts.append(t)
        xs.append(x)
        rs.append(r1)
    return ts, xs, rs


def peak_ductility(member, pulse, **kw):
    """Largest deflection over the (equivalent) elastic deflection, X_m / X_E."""
    _, xs, _ = respond(member, pulse, **kw)
    return max(xs) / member.equivalent_elastic_deflection


def elastic_triangular_dlf(td_over_T):
    """The largest dynamic load factor x_max / x_static of an undamped elastic SDOF under a
    triangular pulse (Biggs §2.4): x/x_st = 1 - cos wt + sin wt / (w td) - t / td while it acts,
    free vibration after. Maximised over a fine grid of time and refined."""
    w, td = 2.0 * math.pi, td_over_T

    def during(t):
        return 1.0 - math.cos(w * t) + math.sin(w * t) / (w * td) - t / td

    def velocity(t):
        return w * math.sin(w * t) + math.cos(w * t) / td - 1.0 / td

    best = 0.0
    n = 4000
    for i in range(n + 1):
        t = td * i / n
        best = max(best, during(t))
    x_d, v_d = during(td), velocity(td)
    best = max(best, math.hypot(x_d, v_d / w))  # amplitude of the free vibration after td
    return best


def impulsive_ductility(impulse, member):
    """Ductility X_m / X_el of an elastic–perfectly plastic member under an ideal impulse
    (t_d / T -> 0), by energy with one load–mass factor, the elastic one, as Biggs's charts take
    it: I^2 / (2 K_LM M) = R_u (X_m - X_el / 2), or the elastic amplitude when that is less than
    the elastic limit's energy."""
    me = load_mass_factor(member.support, member.load, "elastic") * member.mass
    ru, xe = member.ultimate, member.elastic_limit
    energy = impulse**2 / (2.0 * me)
    elastic_energy = 0.5 * ru * xe
    if energy <= elastic_energy:
        return math.sqrt(energy / elastic_energy)
    return (energy - elastic_energy) / (ru * xe) + 1.0


def step_ductility(ratio):
    """Ductility of an elastic–perfectly plastic member under a constant load suddenly applied,
    R_u / F = ratio: F x_m = R_u (x_m - x_el / 2), x_m / x_el = ratio / (2 (ratio - 1)) for ratios
    below 2 (elastic, at most 2 F / k, above it)."""
    return ratio / (2.0 * (ratio - 1.0)) if ratio < 2.0 else 2.0 / ratio


def main(argv):
    print("Elastic dynamic load factor, triangular pulse (Biggs §2.4)")
    for r in (0.05, 0.1, 0.2, 0.4, 0.6, 1.0, 2.0, 5.0, 10.0):
        print(f"  td/T {r:>5}: DLF {elastic_triangular_dlf(r):.3f}")
    print()
    print("Elastic-perfectly plastic ductility X_m / X_el, triangular pulse, by R_u / F1 (the axes "
          "of Biggs's chart for a triangular load; constant elastic K_LM)")
    ratios = (0.5, 0.8, 1.0, 1.2, 1.5, 2.0)
    print("   td/T " + "".join(f"{r:>8}" for r in ratios))
    for tdT in (0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0):
        row = []
        for r in ratios:
            m = elastic_plastic(1.0, (2 * math.pi) ** 2 * 0.78, r, "simple", "uniform")
            row.append(peak_ductility(m, triangular(1.0, tdT), constant_factor=0.78))
        print(f"  {tdT:>5} " + "".join(f"{d:>8.3f}" for d in row))


if __name__ == "__main__":
    main(sys.argv[1:])
