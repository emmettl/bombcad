"""A textbook one-dimensional finite-volume solver, as a yardstick for the exact solutions.

Second-order MUSCL-Hancock with minmod-limited primitive slopes and the HLLC Riemann solver
(Toro, Riemann Solvers and Numerical Methods for Fluid Dynamics, 3rd edn, 2009, chapters 10
and 14), for an ideal gas in planar, cylindrical or spherical geometry. The curved geometries
use the finite-volume form with face areas r^(j-1) and the pressure source on the momentum.

It is not an oracle: it shows what an ordinary second-order scheme scores on the same grid, so a
BombCAD error can be read against a known-good scheme's error, not only against zero.
Pure Python; a few seconds for a few hundred cells.
"""

import math


def _flux(rho, u, p, g):
    E = p / (g - 1) + 0.5 * rho * u * u
    return rho * u, rho * u * u + p, u * (E + p), E


def _hllc(L, R, g):
    rL, uL, pL = L
    rR, uR, pR = R
    aL, aR = math.sqrt(g * pL / rL), math.sqrt(g * pR / rR)
    SL = min(uL - aL, uR - aR)
    SR = max(uL + aL, uR + aR)
    FL0, FL1, FL2, EL = _flux(rL, uL, pL, g)
    FR0, FR1, FR2, ER = _flux(rR, uR, pR, g)
    if SL >= 0:
        return FL0, FL1, FL2
    if SR <= 0:
        return FR0, FR1, FR2
    Ss = (pR - pL + rL * uL * (SL - uL) - rR * uR * (SR - uR)) / (rL * (SL - uL) - rR * (SR - uR))
    if Ss >= 0:
        r, u, p, E, S, F0, F1, F2 = rL, uL, pL, EL, SL, FL0, FL1, FL2
    else:
        r, u, p, E, S, F0, F1, F2 = rR, uR, pR, ER, SR, FR0, FR1, FR2
    k = r * (S - u) / (S - Ss)
    U0, U1 = k, k * Ss
    U2 = k * (E / r + (Ss - u) * (Ss + p / (r * (S - u))))
    return F0 + S * (U0 - r), F1 + S * (U1 - r * u), F2 + S * (U2 - E)


def _minmod(a, b):
    if a * b <= 0:
        return 0.0
    return a if abs(a) < abs(b) else b


def run(rho, u, p, dx, t_end, gamma=1.4, j=1, r0=0.0, cfl=0.4, p_floor=1e-12, reflect_left=None):
    """Advance cell values rho, u, p (lists, cell i centred at r0 + (i + 0.5) dx) to t_end.

    j = 1, 2 or 3 for planar, cylindrical or spherical; the left face is a reflecting wall when
    reflect_left (default: when j > 1) and the right face transmissive. Returns (rho, u, p)."""
    g = gamma
    n = len(rho)
    if reflect_left is None:
        reflect_left = j > 1
    faces = [r0 + i * dx for i in range(n + 1)]
    area = [f ** (j - 1) if j > 1 else 1.0 for f in faces]
    vol = [((faces[i + 1] ** j - faces[i] ** j) / j) if j > 1 else dx for i in range(n)]
    U = [[rho[i], rho[i] * u[i], p[i] / (g - 1) + 0.5 * rho[i] * u[i] ** 2] for i in range(n)]
    t = 0.0
    while t < t_end * (1 - 1e-12):
        W = []
        for q in U:
            r = q[0]
            v = q[1] / r
            W.append((r, v, max((g - 1) * (q[2] - 0.5 * r * v * v), p_floor)))
        smax = max(abs(w[1]) + math.sqrt(g * w[2] / w[0]) for w in W)
        dt = min(cfl * dx / smax, t_end - t)
        # Ghost cells: a mirror on the left when reflecting, copies otherwise.
        left = (W[0][0], -W[0][1], W[0][2]) if reflect_left else W[0]
        Wg = [left] + W + [W[-1]]
        # Limited slopes and the half-step evolution of the face values (MUSCL-Hancock).
        lo, hi = [None] * n, [None] * n
        for i in range(n):
            a, b, c = Wg[i], Wg[i + 1], Wg[i + 2]
            d = [_minmod(b[k] - a[k], c[k] - b[k]) for k in range(3)]
            r, v, pp = b
            # Primitive form of the planar Euler equations over dt/2.
            dr = -0.5 * dt / dx * (v * d[0] + r * d[1])
            dv = -0.5 * dt / dx * (v * d[1] + d[2] / r)
            dp = -0.5 * dt / dx * (g * pp * d[1] + v * d[2])
            lo[i] = (max(r - 0.5 * d[0] + dr, 1e-12), v - 0.5 * d[1] + dv, max(pp - 0.5 * d[2] + dp, p_floor))
            hi[i] = (max(r + 0.5 * d[0] + dr, 1e-12), v + 0.5 * d[1] + dv, max(pp + 0.5 * d[2] + dp, p_floor))
        F = []
        for f in range(n + 1):
            if f == 0:
                L = (lo[0][0], -lo[0][1], lo[0][2]) if reflect_left else lo[0]
                R = lo[0]
            elif f == n:
                L, R = hi[n - 1], hi[n - 1]
            else:
                L, R = hi[f - 1], lo[f]
            F.append(_hllc(L, R, g))
        for i in range(n):
            k = dt / vol[i]
            Fa, Fb = F[i], F[i + 1]
            Aa, Ab = area[i], area[i + 1]
            U[i][0] -= k * (Ab * Fb[0] - Aa * Fa[0])
            U[i][1] -= k * (Ab * Fb[1] - Aa * Fa[1])
            U[i][2] -= k * (Ab * Fb[2] - Aa * Fa[2])
            if j > 1:
                # The pressure on the cell's curved sides: (j - 1) p r^(j-2) dr over the volume.
                U[i][1] += dt * W[i][2] * (Ab - Aa) / vol[i]
        t += dt
    out_r, out_u, out_p = [], [], []
    for q in U:
        r = q[0]
        v = q[1] / r
        out_r.append(r)
        out_u.append(v)
        out_p.append(max((g - 1) * (q[2] - 0.5 * r * v * v), p_floor))
    return out_r, out_u, out_p
