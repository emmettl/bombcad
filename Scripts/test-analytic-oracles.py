"""Tests of the exact Sod and Sedov-Taylor solutions and their comparison script:
python3 Scripts/test-analytic-oracles.py"""

import math
import os
import subprocess
import sys
import unittest

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "analytic"))

import compare  # noqa: E402
import godunov  # noqa: E402
import riemann  # noqa: E402
import sedov  # noqa: E402

State = riemann.State


class RiemannTests(unittest.TestCase):
    # Toro (2009), Tables 4.1 and 4.3: the initial states and the exact star states of his five
    # tests, to the digits he prints. Each row: left, right, p*, u*, rho*L, rho*R.
    TORO = [
        ((1.0, 0.0, 1.0), (0.125, 0.0, 0.1), 0.30313, 0.92745, 0.42632, 0.26557),
        ((1.0, -2.0, 0.4), (1.0, 2.0, 0.4), 0.00189, 0.0, 0.02185, 0.02185),
        ((1.0, 0.0, 1000.0), (1.0, 0.0, 0.01), 460.894, 19.5975, 0.57506, 5.99924),
        ((1.0, 0.0, 0.01), (1.0, 0.0, 100.0), 46.0950, -6.19633, 5.99242, 0.57511),
        ((5.99924, 19.5975, 460.894), (5.99242, -6.19633, 46.0950), 1691.64, 8.68975, 14.2823, 31.0426),
    ]

    def test_toros_five_star_states(self):
        for left, right, p, u, rl, rr in self.TORO:
            s = riemann.solve(State(*left), State(*right))
            self.assertAlmostEqual(s.p_star / p, 1, delta=3e-3 if p < 0.01 else 1e-5, msg=left)
            self.assertAlmostEqual(s.u_star, u, delta=1e-5 * max(1, abs(u)), msg=left)
            self.assertAlmostEqual(s.rho_star_left / rl, 1, delta=5e-4 if rl < 0.1 else 2e-5, msg=left)
            self.assertAlmostEqual(s.rho_star_right / rr, 1, delta=5e-4 if rr < 0.1 else 2e-5, msg=left)

    def test_sods_waves(self):
        speeds = riemann.solve(*riemann.SOD).wave_speeds()
        self.assertAlmostEqual(speeds["left_head"], -math.sqrt(1.4), places=10)
        self.assertAlmostEqual(speeds["left_tail"], -0.07027, places=5)
        self.assertAlmostEqual(speeds["right_shock"], 1.75216, places=5)

    def test_the_shock_conserves_mass_momentum_and_energy(self):
        g = 1.4
        s = riemann.solve(*riemann.SOD, gamma=g)
        S = s.wave_speeds()["right_shock"]
        a, b = s.right, State(s.rho_star_right, s.u_star, s.p_star)

        def fluxes(q):
            E = q.p / (g - 1) + 0.5 * q.rho * q.u**2
            return (q.rho * (q.u - S), q.rho * q.u * (q.u - S) + q.p, E * (q.u - S) + q.p * q.u)

        for fa, fb in zip(fluxes(a), fluxes(b)):
            self.assertAlmostEqual(fa, fb, places=10)

    def test_a_mirrored_problem_gives_the_mirrored_solution(self):
        L, R = State(1.0, 0.3, 2.0), State(0.4, -0.1, 0.5)
        s = riemann.solve(L, R)
        m = riemann.solve(State(R.rho, -R.u, R.p), State(L.rho, -L.u, L.p))
        for xi in (-2.0, -0.7, -0.1, 0.0, 0.2, 0.9, 2.5):
            a, b = s.sample(xi), m.sample(-xi)
            self.assertAlmostEqual(a.rho, b.rho, places=10)
            self.assertAlmostEqual(a.u, -b.u, places=10)
            self.assertAlmostEqual(a.p, b.p, places=10)

    def test_the_rarefaction_is_isentropic_and_continuous(self):
        g = 1.4
        s = riemann.solve(*riemann.SOD, gamma=g)
        w = s.wave_speeds()
        for k in range(11):
            xi = w["left_head"] + k / 10 * (w["left_tail"] - w["left_head"])
            st = s.sample(xi)
            self.assertAlmostEqual(st.p / st.rho**g, 1.0, places=10)
        self.assertAlmostEqual(s.sample(w["left_tail"] + 1e-12).rho, s.rho_star_left, places=6)

    def test_the_swift_tests_hard_coded_sod_density_agrees(self):
        # SolverVerificationTests.sodDensity, ported line for line.
        def swift(x, t):
            gamma = 1.4
            a = math.sqrt(gamma)
            xi = (x - 0.5) / t
            if xi < -a:
                return 1.0
            if xi < -0.07027:
                v = 2 / (gamma + 1) * (a + xi)
                c = a - 0.5 * (gamma - 1) * v
                return (c / a) ** (2 / (gamma - 1))
            if xi < 0.92745:
                return 0.42632
            if xi < 1.75216:
                return 0.26557
            return 0.125

        s = riemann.solve(*riemann.SOD)
        worst = max(abs(swift((i + 0.5) / 400, 0.2) - s.sample(((i + 0.5) / 400 - 0.5) / 0.2).rho)
                    for i in range(400))
        self.assertLess(worst, 1e-5)

    def test_vacuum_is_refused(self):
        with self.assertRaises(ValueError):
            riemann.solve(State(1.0, -10.0, 0.4), State(1.0, 10.0, 0.4))


class SedovTests(unittest.TestCase):
    def test_kamms_energy_constants(self):
        # Kamm (2000), Table 1, gamma = 1.4: planar, cylindrical, spherical. The planar value
        # here converges to 0.538743 under two different quadratures (in r and in V), 0.035%
        # above Kamm's; the cylindrical and spherical agree to the digits printed.
        for j, alpha, tol in ((1, 0.5385, 4e-4), (2, 0.9840, 1e-4), (3, 0.8510, 1e-4)):
            self.assertAlmostEqual(sedov.Sedov(1.4, j).alpha, alpha, delta=tol, msg=f"j = {j}")

    def test_the_similarity_constants_of_textbooks(self):
        # xi0 = alpha^(-1/5): 1.033 for gamma 1.4, 1.152 for 5/3 (Sedov 1959; Taylor 1950).
        self.assertAlmostEqual(sedov.Sedov(1.4, 3).alpha ** -0.2, 1.033, delta=5e-4)
        self.assertAlmostEqual(sedov.Sedov(5 / 3, 3).alpha ** -0.2, 1.152, delta=5e-4)

    def test_the_shock_states_are_the_strong_shock_limits(self):
        for gamma in (1.2, 1.4, 5 / 3):
            s = sedov.Sedov(gamma, 3)
            self.assertGreater(s._centre_h(), 0)
            f, g, h = s.shape(1.0)
            self.assertAlmostEqual(f, 1, places=10)
            self.assertAlmostEqual(g, 1, places=10)
            self.assertAlmostEqual(h, 1, places=10)
            _, _, _, rho2, _ = s.shock_state(1.0, 1.0, 1.0)
            self.assertAlmostEqual(rho2, (gamma + 1) / (gamma - 1), places=10)

    def test_the_swept_mass_is_all_behind_the_shock(self):
        # Mass is not used in finding alpha, so this checks the density profile independently.
        for j in (1, 2, 3):
            for gamma in (1.4, 5 / 3):
                s = sedov.Sedov(gamma, j)
                n = 4000
                total = 0.0
                for i in range(n + 1):
                    lam = i / n
                    w = 1 if i in (0, n) else (4 if i % 2 else 2)
                    total += w * s.shape(lam)[1] * lam ** (j - 1)
                mass = total / (3 * n) * s.b  # over rho0 r2^j, per unit AREA[j]
                self.assertAlmostEqual(mass * j, 1.0, delta=2e-3, msg=f"j = {j}, gamma = {gamma}")

    def test_the_radius_grows_as_t_to_the_two_fifths(self):
        s = sedov.Sedov(1.4, 3)
        r1, r2 = s.shock_radius(1.0, 1.0, 1.0), s.shock_radius(1.0, 1.0, 32.0)
        self.assertAlmostEqual(r2 / r1, 4.0, places=10)
        self.assertAlmostEqual(s.time_at_radius(r2, 1.0, 1.0), 32.0, places=8)

    def test_out_of_range_inputs_are_refused(self):
        with self.assertRaises(ValueError):
            sedov.Sedov(1.4, 4)
        with self.assertRaises(ValueError):
            sedov.Sedov(2.0, 3)


class YardstickTests(unittest.TestCase):
    def test_sods_error_falls_with_the_grid(self):
        sol = riemann.solve(*riemann.SOD)
        errors = []
        for n in (50, 100, 200):
            xs = [(i + 0.5) / n for i in range(n)]
            errors.append(compare.sod_yardstick(xs, sol, 0.2, 0.5, 1.4)["L1 rho"])
        self.assertLess(errors[1], 0.75 * errors[0])
        self.assertLess(errors[2], 0.75 * errors[1])

    def test_the_planar_scheme_conserves_mass_and_energy(self):
        n, dx = 100, 0.01
        rho = [1.0 if i < 50 else 0.125 for i in range(n)]
        p = [1.0 if i < 50 else 0.1 for i in range(n)]
        r, u, pp = godunov.run(rho, [0.0] * n, p, dx, 0.1)  # waves still inside the tube
        self.assertAlmostEqual(sum(r) * dx, sum(rho) * dx, places=12)
        e0 = sum(q / 0.4 for q in p) * dx
        e1 = sum(pp[i] / 0.4 + 0.5 * r[i] * u[i] ** 2 for i in range(n)) * dx
        self.assertAlmostEqual(e1, e0, places=10)


class CompareScriptTests(unittest.TestCase):
    def test_self_test_passes(self):
        out = subprocess.run([sys.executable, os.path.join(here, "analytic", "compare.py"), "--self-test"],
                             capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("self-test passed", out.stdout)

    def test_a_sod_profile_file_is_scored(self):
        import tempfile
        sol = riemann.solve(*riemann.SOD)
        xs, rho = compare.cell_average_sod(sol, 100, 0.2)
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "p.csv")
            with open(path, "w") as f:
                f.write("# a comment line\nx,rho\n")
                for x, r in zip(xs, rho):
                    f.write(f"{x},{r}\n")
            out = subprocess.run(
                [sys.executable, os.path.join(here, "analytic", "compare.py"), "sod", path, "--time", "0.2",
                 "--no-yardstick"], capture_output=True, text=True, check=True)
        self.assertIn("L1 rho", out.stdout)
        self.assertIn("shock (cells)", out.stdout)


if __name__ == "__main__":
    unittest.main()
