"""The exact solution of the one-dimensional Riemann problem for an ideal gas.

Two uniform states meet at x = 0 at t = 0. The solution is self-similar in x/t: a left wave
(rarefaction or shock), a contact discontinuity and a right wave. The star-region pressure is
found by Newton iteration on the pressure function, and the solution is sampled at any x/t,
following Toro, Riemann Solvers and Numerical Methods for Fluid Dynamics (3rd edn, Springer,
2009), chapter 4. Sod's shock tube (Sod 1978, J. Comput. Phys. 27, 1-31) is the case
`SOD` below.

Pure Python, SI or any consistent units; vacuum generation is not handled (it raises).

    python3 Scripts/analytic/riemann.py            # the Sod star state and a profile at t = 0.2
"""

import math
from dataclasses import dataclass


@dataclass(frozen=True)
class State:
    rho: float  # density
    u: float  # velocity
    p: float  # pressure


# Sod's shock tube as Toro gives it (test 1, Table 4.1): diaphragm at x = 0.5 in a unit tube.
SOD = (State(1.0, 0.0, 1.0), State(0.125, 0.0, 0.1))
SOD_GAMMA = 1.4


def _sound(s, gamma):
    return math.sqrt(gamma * s.p / s.rho)


def _f(p, s, gamma):
    """Toro's pressure function f_K and its derivative for one side."""
    a = _sound(s, gamma)
    if p > s.p:  # shock
        A = 2.0 / ((gamma + 1.0) * s.rho)
        B = (gamma - 1.0) / (gamma + 1.0) * s.p
        q = math.sqrt(A / (p + B))
        return (p - s.p) * q, q * (1.0 - 0.5 * (p - s.p) / (p + B))
    # rarefaction
    ratio = p / s.p
    e = (gamma - 1.0) / (2.0 * gamma)
    return 2.0 * a / (gamma - 1.0) * (ratio**e - 1.0), ratio ** (-(gamma + 1.0) / (2.0 * gamma)) / (s.rho * a)


@dataclass(frozen=True)
class Solution:
    left: State
    right: State
    gamma: float
    p_star: float
    u_star: float
    rho_star_left: float
    rho_star_right: float

    def wave_speeds(self):
        """Speeds of the waves' edges, left to right, as a dict.

        A shock has one speed (`left_shock` or `right_shock`); a rarefaction a head and a tail."""
        g = self.gamma
        L, R = self.left, self.right
        out = {}
        if self.p_star > L.p:
            out["left_shock"] = L.u - _sound(L, g) * math.sqrt(
                (g + 1) / (2 * g) * self.p_star / L.p + (g - 1) / (2 * g))
        else:
            out["left_head"] = L.u - _sound(L, g)
            out["left_tail"] = self.u_star - _sound(State(self.rho_star_left, 0, self.p_star), g)
        out["contact"] = self.u_star
        if self.p_star > R.p:
            out["right_shock"] = R.u + _sound(R, g) * math.sqrt(
                (g + 1) / (2 * g) * self.p_star / R.p + (g - 1) / (2 * g))
        else:
            out["right_tail"] = self.u_star + _sound(State(self.rho_star_right, 0, self.p_star), g)
            out["right_head"] = R.u + _sound(R, g)
        return out

    def sample(self, s):
        """The state at similarity coordinate s = x/t."""
        g = self.gamma
        L, R = self.left, self.right
        ps, us = self.p_star, self.u_star
        if s <= us:  # left of the contact
            aL = _sound(L, g)
            if ps > L.p:
                SL = L.u - aL * math.sqrt((g + 1) / (2 * g) * ps / L.p + (g - 1) / (2 * g))
                return L if s <= SL else State(self.rho_star_left, us, ps)
            head = L.u - aL
            tail = us - aL * (ps / L.p) ** ((g - 1) / (2 * g))
            if s <= head:
                return L
            if s >= tail:
                return State(self.rho_star_left, us, ps)
            k = 2 / (g + 1) + (g - 1) / ((g + 1) * aL) * (L.u - s)
            return State(L.rho * k ** (2 / (g - 1)), 2 / (g + 1) * (aL + (g - 1) / 2 * L.u + s),
                         L.p * k ** (2 * g / (g - 1)))
        aR = _sound(R, g)
        if ps > R.p:
            SR = R.u + aR * math.sqrt((g + 1) / (2 * g) * ps / R.p + (g - 1) / (2 * g))
            return R if s >= SR else State(self.rho_star_right, us, ps)
        head = R.u + aR
        tail = us + aR * (ps / R.p) ** ((g - 1) / (2 * g))
        if s >= head:
            return R
        if s <= tail:
            return State(self.rho_star_right, us, ps)
        k = 2 / (g + 1) - (g - 1) / ((g + 1) * aR) * (R.u - s)
        return State(R.rho * k ** (2 / (g - 1)), 2 / (g + 1) * (-aR + (g - 1) / 2 * R.u + s),
                     R.p * k ** (2 * g / (g - 1)))

    def profile(self, xs, t, x0=0.0):
        """States at positions xs at time t > 0, the diaphragm at x0."""
        return [self.sample((x - x0) / t) for x in xs]


def solve(left, right, gamma=1.4, tol=1e-12, max_iter=100):
    """The exact Riemann solution for an ideal gas of ratio of specific heats gamma."""
    aL, aR = _sound(left, gamma), _sound(right, gamma)
    du = right.u - left.u
    if 2.0 * (aL + aR) / (gamma - 1.0) <= du:
        raise ValueError("the initial states generate a vacuum")
    # Two-rarefaction guess (Toro 4.46), floored to stay positive.
    z = (gamma - 1.0) / (2.0 * gamma)
    p = ((aL + aR - 0.5 * (gamma - 1.0) * du) / (aL / left.p**z + aR / right.p**z)) ** (1.0 / z)
    p = max(p, 1e-12 * min(left.p, right.p))
    for _ in range(max_iter):
        fL, dL = _f(p, left, gamma)
        fR, dR = _f(p, right, gamma)
        new = max(p - (fL + fR + du) / (dL + dR), 1e-14 * p)
        if abs(new - p) <= tol * 0.5 * (new + p):
            p = new
            break
        p = new
    else:
        raise RuntimeError("the star pressure did not converge")
    fL, _ = _f(p, left, gamma)
    fR, _ = _f(p, right, gamma)
    u = 0.5 * (left.u + right.u) + 0.5 * (fR - fL)

    def star_rho(s):
        r = p / s.p
        if p > s.p:
            k = (gamma - 1.0) / (gamma + 1.0)
            return s.rho * (r + k) / (k * r + 1.0)
        return s.rho * r ** (1.0 / gamma)

    return Solution(left, right, gamma, p, u, star_rho(left), star_rho(right))


def main():
    sol = solve(*SOD, gamma=SOD_GAMMA)
    print(f"Sod (gamma {SOD_GAMMA}): p* {sol.p_star:.5f}  u* {sol.u_star:.5f}  "
          f"rho*L {sol.rho_star_left:.5f}  rho*R {sol.rho_star_right:.5f}")
    for name, speed in sol.wave_speeds().items():
        print(f"  {name:<12} {speed:+.5f}")
    print("\n      x      rho        u        p   (t = 0.2, diaphragm at 0.5)")
    for i in range(11):
        x = i / 10
        st = sol.sample((x - 0.5) / 0.2)
        print(f"  {x:5.2f}  {st.rho:7.4f}  {st.u:7.4f}  {st.p:7.4f}")


if __name__ == "__main__":
    main()
