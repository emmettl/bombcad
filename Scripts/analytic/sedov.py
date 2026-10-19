"""The Sedov–Taylor point-blast solution for an ideal gas at rest and of uniform density.

An energy E released at a point (j = 3), along a line (j = 2) or on a plane (j = 1) at t = 0
drives a strong shock into gas of density rho0 whose own pressure is neglected. The flow is
self-similar: the shock is at r2 = (E / (alpha rho0))^(1/(j+2)) t^(2/(j+2)), and the profiles
behind it follow from the closed-form parametric solution in Sedov's variable V. The formulas
are those of Kamm, Evaluation of the Sedov-von Neumann-Taylor blast wave solution (Los Alamos
report LA-UR-00-6055, 2000) and Kamm and Timmes, On efficient generation of numerically robust
Sedov solutions (LA-UR-07-2849, 2007), for the standard case (uniform ambient density,
1 < gamma < 2 here). The energy constant alpha is integrated numerically.

Energy is per unit length for j = 2 and per unit area for j = 1. The planar alpha follows
Kamm's tables (0.5385 for gamma 1.4), which integrate over one side of the plane. Pure Python; any consistent units.

    python3 Scripts/analytic/sedov.py            # alpha for gamma 1.4 and a spherical profile
"""

import math

# Area of the unit "sphere" in each geometry: dV = AREA[j] r^(j-1) dr. The planar value is
# Kamm's, one side of the plane.
AREA = {1: 1.0, 2: 2.0 * math.pi, 3: 4.0 * math.pi}


class Sedov:
    def __init__(self, gamma=1.4, j=3):
        if j not in AREA:
            raise ValueError("j must be 1 (planar), 2 (cylindrical) or 3 (spherical)")
        if not 1.0 < gamma < 2.0:
            raise ValueError("this implementation covers 1 < gamma < 2")
        self.gamma, self.j = gamma, j
        g, w = gamma, 0.0
        n = j + 2 - w
        self.a = n * (g + 1) / 4
        self.b = (g + 1) / (g - 1)
        self.c = n * g / 2
        self.d = n * (g + 1) / (n * (g + 1) - 2 * (2 + j * (g - 1)))
        self.e = (2 + j * (g - 1)) / 2
        self.a0 = 2 / n
        self.a2 = -(g - 1) / (2 * (g - 1) + j - g * w)
        self.a1 = n * g / (2 + j * (g - 1)) * (2 * (j * (2 - g) - w) / (g * n * n) - self.a2)
        self.a3 = (j - w) / (2 * (g - 1) + j - g * w)
        self.a4 = n * (j - w) / (j * (2 - g) - w) * self.a1
        self.a5 = (w * (1 + g) - 2 * j) / (j * (2 - g) - w)
        # V runs from V0 at the centre to V2 at the shock.
        self.V0 = 2 / (n * g)
        self.V2 = 4 / (n * (g + 1))
        self.alpha = self._alpha()

    # The similarity functions of V: radius, velocity, density and pressure over their values
    # just behind the shock.
    def _x(self, V):
        x1 = self.a * V
        x2 = self.b * (self.c * V - 1)
        x3 = self.d * (1 - self.e * V)
        x4 = self.b * (1 - self.c * V / self.gamma)
        return x1, x2, x3, x4

    def _lam(self, V):
        x1, x2, x3, _ = self._x(V)
        return x1 ** (-self.a0) * x2 ** (-self.a2) * x3 ** (-self.a1)

    def _fgh(self, V):
        x1, x2, x3, x4 = self._x(V)
        lam = x1 ** (-self.a0) * x2 ** (-self.a2) * x3 ** (-self.a1)
        f = x1 * lam
        gg = x2 ** self.a3 * x3 ** self.a4 * x4 ** self.a5
        h = x1 ** (self.a0 * self.j) * x3 ** (self.a4 - 2 * self.a1) * x4 ** (1 + self.a5)
        return f, gg, h

    def _V_of(self, lam):
        """V for r/r2 = lam in (0, 1], by bisection (lam rises monotonically with V)."""
        if lam >= 1.0:
            return self.V2
        lo, hi = self.V0, self.V2
        for _ in range(80):
            mid = 0.5 * (lo + hi)
            if self._lam(mid) < lam:
                lo = mid
            else:
                hi = mid
        return 0.5 * (lo + hi)

    def shape(self, lam):
        """(u/u2, rho/rho2, p/p2) at r/r2 = lam, zero velocity and density at the centre."""
        if lam <= 0.0:
            return 0.0, 0.0, self._centre_h()
        return self._fgh(self._V_of(lam))

    def _centre_h(self):
        # The pressure ratio tends to a finite limit at the centre: x2 -> 0 and h does not
        # depend on x2.
        x1 = self.a * self.V0
        x3 = self.d * (1 - self.e * self.V0)
        x4 = self.b * (1 - self.c * self.V0 / self.gamma)
        return x1 ** (self.a0 * self.j) * x3 ** (self.a4 - 2 * self.a1) * x4 ** (1 + self.a5)

    def _alpha(self, n=2000):
        """E = alpha rho0 r2^(j+2) / t^2: the energy integral over lam by composite Simpson."""
        g, j = self.gamma, self.j
        k_kin = 0.5 * self.b * (2 / (g + 1)) ** 2
        k_int = 2 / ((g + 1) * (g - 1))
        total = 0.0
        for i in range(n + 1):
            lam = i / n
            if i == 0:
                val = 0.0 if j > 1 else k_int * self._centre_h()
            else:
                f, gg, h = self._fgh(self._V_of(lam))
                val = (k_kin * gg * f * f + k_int * h) * lam ** (j - 1)
            total += val * (1 if i in (0, n) else (4 if i % 2 else 2))
        integral = total / (3 * n)
        return AREA[j] * (2 / (j + 2)) ** 2 * integral

    def shock_radius(self, E, rho0, t):
        return (E / (self.alpha * rho0)) ** (1 / (self.j + 2)) * t ** (2 / (self.j + 2))

    def shock_state(self, E, rho0, t):
        """(r2, shock speed, u2, rho2, p2) at time t."""
        g = self.gamma
        r2 = self.shock_radius(E, rho0, t)
        us = 2 / (self.j + 2) * r2 / t
        return r2, us, 2 / (g + 1) * us, self.b * rho0, 2 / (g + 1) * rho0 * us * us

    def profile(self, r, E, rho0, t):
        """(u, rho, p) at radius r and time t; the undisturbed gas (0, rho0, 0) beyond the shock."""
        r2, _, u2, rho2, p2 = self.shock_state(E, rho0, t)
        if r > r2:
            return 0.0, rho0, 0.0
        f, gg, h = self.shape(r / r2)
        return u2 * f, rho2 * gg, p2 * h

    def time_at_radius(self, r, E, rho0):
        """The time at which the shock reaches radius r."""
        return math.sqrt(self.alpha * rho0 * r ** (self.j + 2) / E)


def main():
    for j in (1, 2, 3):
        print(f"gamma 1.4, j = {j}: alpha = {Sedov(1.4, j).alpha:.5f}")
    s = Sedov(1.4, 3)
    E, rho0, t = 0.851072, 1.0, 1.0
    r2, us, u2, rho2, p2 = s.shock_state(E, rho0, t)
    print(f"\nSpherical, E {E}, rho0 {rho0}, t {t}: r2 {r2:.5f}  shock speed {us:.5f}")
    print("   r/r2      u      rho        p")
    for i in range(0, 11):
        lam = i / 10
        u, rho, p = s.profile(lam * r2, E, rho0, t)
        print(f"  {lam:5.2f} {u:7.4f} {rho:8.4f} {p:8.4f}")


if __name__ == "__main__":
    main()
