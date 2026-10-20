#!/usr/bin/env python3
"""The calibration's emulators and posterior (docs/calibration.md): a Gaussian process for each
comparison over the three parameters, fitted to the runs of the design, and a Kennedy–O'Hagan
posterior with a discrepancy for each regime.

    python3 Scripts/calibration/calibrate.py runs.jsonl [--json out.json] [--steps 4000] [--seed 1]
        [--bias-sd 0.3]

The runs are those `Scripts/calibration/runs.py` gathers: one JSON line a run, its case, the
parameters' values and its outputs; measured.json beside them gives what the cases themselves
are compared with (Kingery–Bulmash's impulses, the panes' break times and their repeats'
scatter, E1300's load resistances). Only numpy is needed.
"""
import json
import math
import sys

import numpy as np

# The parameters as `Scripts/calibration/design.py` spreads them: key, range, today's value, name.
PARAMETERS = [
    ("afterburnTime", 0.003, 0.03, 0.01, "afterburning time (s/kg^1/3)"),
    ("ft", 0.6, 1.6, 1.0, "concrete tensile strength (factor)"),
    ("glassK", 0.01, 3.0, 1.0, "glass flaw constant x stressed share (factor)"),
]

# Each comparison: case, output, measured value, regime, the measurement's scatter (log; the
# repeats' where there are some, else assumed) and the model's spread from its own uncertain
# inputs (log; docs/validation.md, "The model's spread from uncertain inputs", where recorded).
# Its regime names the one parameter its case reads (`ACTIVE`): the air's cases read only the
# afterburning time, the concrete's only the tensile strength, the glass's only the flaw factor, so
# each emulator is over that one axis and the others cannot leak into it through noise.
ACTIVE = {"air": 0, "concrete": 1, "glass": 2}
# Kingery-Bulmash's incident impulse against the 1966 tests: two-thirds within ±6.7% (Swisdak 1994;
# docs/data-survey.md, 3g). Its reflected curves were calculated, not measured: 10%, assumed.
KB_INCIDENT_SCATTER = 0.067
KB_REFLECTED_SCATTER = 0.10
ASSUMED = 0.10     # one test, no repeat


def comparisons():
    rows = []
    for z in [1, 2, 4]:
        rows.append(("kb-open", "i%d" % z, None, "air, incident", KB_INCIDENT_SCATTER, 0.02))
        rows.append(("kb-reflected", "r%d" % z, None, "air, reflected", KB_REFLECTED_SCATTER, 0.02))
    rows += [
        ("janney", "moment", 41.5, "concrete, static", ASSUMED, 0.05),
        ("oa1", "peak", 332.0, "concrete, static", ASSUMED, 0.06),
        ("saatci", "peak", 37.9, "concrete, impact", ASSUMED, 0.06),
        ("saatci", "residual", 18.5, "concrete, impact", ASSUMED, 0.25),
        ("peterson-d-1d-nos", "impact", 289.0, "concrete, impact", 0.04, 0.15),
        ("peterson-d-2d-s90", "impact", 238.0, "concrete, impact", 0.18, 0.14),
        ("contest-slab", "peak", 109.0, "concrete, blast", 0.032, 0.12),
    ]
    for aspect in ["1-1", "1-1.3", "1-1.7", "1-2"]:
        rows.append(("glass-monk", "t" + aspect, None, "glass, break time", None, 0.0))
    for pane in ["A", "D", "T", "CC"]:
        rows.append(("glass-e1300", "lr" + pane, None, "glass, threshold", ASSUMED, 0.0))
    return rows


def unit(values):
    """The parameters' values on the unit cube, uniform in their logarithms."""
    return np.array([(math.log(values[key]) - math.log(low)) / (math.log(high) - math.log(low))
                     for key, low, high, _, _ in PARAMETERS])


def from_unit(u):
    return [math.exp(math.log(low) + x * (math.log(high) - math.log(low)))
            for x, (_, low, high, _, _) in zip(u, PARAMETERS)]


# MARK: - Gaussian processes

def nelder_mead(f, x0, step=0.5, iterations=600):
    n = len(x0)
    simplex = [np.array(x0, float)] + [np.array(x0, float) + step * np.eye(n)[i] for i in range(n)]
    values = [f(x) for x in simplex]
    for _ in range(iterations):
        order = np.argsort(values)
        simplex = [simplex[i] for i in order]
        values = [values[i] for i in order]
        centre = np.mean(simplex[:-1], axis=0)
        worst = simplex[-1]
        reflected = centre + (centre - worst)
        fr = f(reflected)
        if fr < values[0]:
            expanded = centre + 2 * (centre - worst)
            fe = f(expanded)
            simplex[-1], values[-1] = (expanded, fe) if fe < fr else (reflected, fr)
        elif fr < values[-2]:
            simplex[-1], values[-1] = reflected, fr
        else:
            contracted = centre + 0.5 * (worst - centre)
            fc = f(contracted)
            if fc < values[-1]:
                simplex[-1], values[-1] = contracted, fc
            else:
                simplex = [simplex[0] + 0.5 * (x - simplex[0]) for x in simplex]
                values = [f(x) for x in simplex]
        if np.std(values) < 1e-9:
            break
    return simplex[int(np.argmin(values))]


class Emulator:
    """A Gaussian process on y over x in the unit cube (its `active` axes): a linear mean fitted
    by least squares, a squared-exponential kernel with a length for each axis, its scale and a
    nugget found by the marginal likelihood (with weak priors keeping the lengths between a tenth
    and ten). The nugget is the runs' own scatter about a smooth trend (a member failing one way
    or another from one run to the next), which `predict` adds to the trend's uncertainty as the
    model's scatter."""

    def __init__(self, x, y, active=None):
        x = np.asarray(x, float)
        self.active = list(range(x.shape[1])) if active is None else list(active)
        self.x = x[:, self.active]
        dims = len(self.active)
        self.y = np.asarray(y, float)
        self.basis = lambda x: np.hstack([np.ones((len(x), 1)), x])
        h = self.basis(self.x)
        self.beta = np.linalg.lstsq(h, self.y, rcond=None)[0]
        self.r = self.y - h @ self.beta
        scale = max(np.std(self.r), 1e-6)

        def negative(theta):
            lengths, sf, nugget = np.exp(theta[:dims]), math.exp(theta[dims]), math.exp(theta[dims + 1])
            k = self.kernel(self.x, self.x, lengths, sf) + (nugget ** 2 + 1e-10) * np.eye(len(self.x))
            try:
                chol = np.linalg.cholesky(k)
            except np.linalg.LinAlgError:
                return 1e10
            alpha = np.linalg.solve(chol.T, np.linalg.solve(chol, self.r))
            fit = 0.5 * self.r @ alpha + np.sum(np.log(np.diag(chol)))
            prior = 0.5 * np.sum((theta[:dims] / 1.2) ** 2) + 0.5 * ((theta[dims + 1] - math.log(0.1 * scale)) / 3) ** 2
            return fit + prior
        start = [0.0] * dims + [math.log(scale), math.log(0.1 * scale)]
        theta = nelder_mead(negative, start)
        self.lengths, self.sf = np.exp(theta[:dims]), math.exp(theta[dims])
        self.nugget = math.exp(theta[dims + 1])
        k = self.kernel(self.x, self.x, self.lengths, self.sf) + (self.nugget ** 2 + 1e-10) * np.eye(len(self.x))
        self.kinv = np.linalg.inv(k)
        self.alpha = self.kinv @ self.r

    @staticmethod
    def kernel(a, b, lengths, sf):
        d = (a[:, None, :] - b[None, :, :]) / lengths
        return sf ** 2 * np.exp(-0.5 * np.sum(d * d, axis=2))

    def predict(self, x):
        """The trend's mean and variance at `x` (all three axes), the runs' own scatter added."""
        x = np.atleast_2d(x)[:, self.active]
        ks = self.kernel(x, self.x, self.lengths, self.sf)
        mean = self.basis(x) @ self.beta + ks @ self.alpha
        variance = np.maximum(self.sf ** 2 - np.sum((ks @ self.kinv) * ks, axis=1), 0) + self.nugget ** 2
        return mean, variance

    def leave_one_out(self):
        """Each run's error when the others predict it (closed form), and its predicted sd."""
        diagonal = np.diag(self.kinv)
        return self.alpha / diagonal, 1 / np.sqrt(diagonal)


# MARK: - The posterior

BIAS_SD = 0.3     # a regime's shared discrepancy, prior
SPREAD_SD = 0.15  # a regime's discrepancy from one comparison to the next: half-normal, its scale


class Posterior:
    def __init__(self, items, discrepancy=True):
        self.items = items
        self.discrepancy = discrepancy
        self.regimes = sorted(set(item["regime"] for item in items))
        self.members = {r: [i for i, item in enumerate(items) if item["regime"] == r] for r in self.regimes}

    @property
    def dimensions(self):
        return 3 + (len(self.regimes) if self.discrepancy else 0)

    def log_posterior(self, theta):
        u = theta[:3]
        if np.any(u < 0) or np.any(u > 1):
            return -np.inf
        total = 0.0
        if self.discrepancy:
            logs = theta[3:]
            if np.any(logs < math.log(1e-3)) or np.any(logs > math.log(2)):
                return -np.inf
            spreads = np.exp(logs)
            # Half-normal on each spread, sampled in its log.
            total += np.sum(-0.5 * (spreads / SPREAD_SD) ** 2 + logs)
        for n, regime in enumerate(self.regimes):
            members = self.members[regime]
            d = np.empty(len(members))
            variance = np.empty(len(members))
            for k, i in enumerate(members):
                item = self.items[i]
                mean, v = item["emulator"].predict(u)
                d[k] = mean[0] - item["logMeasured"]
                variance[k] = v[0] + item["sigma"] ** 2
            cov = np.diag(variance)
            if self.discrepancy:
                cov += np.diag(np.full(len(members), spreads[n] ** 2)) + BIAS_SD ** 2
            sign, logdet = np.linalg.slogdet(cov)
            total += -0.5 * (d @ np.linalg.solve(cov, d) + logdet)
        return total

    def sample(self, steps, walkers=40, seed=1):
        generator = np.random.default_rng(seed)
        dims = self.dimensions
        start = np.empty((walkers, dims))
        start[:, :3] = generator.uniform(0.05, 0.95, (walkers, 3))
        if self.discrepancy:
            start[:, 3:] = np.log(generator.uniform(0.02, 0.2, (walkers, dims - 3)))
        values = np.array([self.log_posterior(w) for w in start])
        chain = []
        accepted = 0
        half = walkers // 2
        for step in range(steps):
            for first in (0, 1):
                active = np.arange(first * half, (first + 1) * half)
                others = np.arange((1 - first) * half, (2 - first) * half)
                for i in active:
                    j = generator.choice(others)
                    z = ((2 - 1) * generator.random() + 1) ** 2 / 2  # g(z) ∝ 1/√z on [1/2, 2]
                    proposal = start[j] + z * (start[i] - start[j])
                    value = self.log_posterior(proposal)
                    if math.log(generator.random()) < (dims - 1) * math.log(z) + value - values[i]:
                        start[i], values[i] = proposal, value
                        accepted += 1
            if step >= steps // 2:
                chain.append(start.copy())
        self.acceptance = accepted / (steps * walkers)
        return np.concatenate(chain)


def percentiles(values):
    return {p: float(np.percentile(values, p)) for p in (5, 16, 50, 84, 95)}


# MARK: - Which data would narrow the bands

def linearised(items, regimes, u, spreads):
    """The posterior's precision on the three parameters (unit cube, log) at `u`, linearised:
    each regime's sensitivities through its covariance, its shared discrepancy marginalised."""
    precision = np.zeros((3, 3))
    gradients = []
    for item in items:
        e = item["emulator"]
        g = np.empty(3)
        for d in range(3):
            step = np.zeros(3)
            step[d] = 0.02
            g[d] = (e.predict(np.clip(u + step, 0, 1))[0][0] - e.predict(np.clip(u - step, 0, 1))[0][0]) / (
                np.clip(u + step, 0, 1)[d] - np.clip(u - step, 0, 1)[d])
        gradients.append(g)
    for regime in regimes:
        members = [i for i, item in enumerate(items) if item["regime"] == regime]
        j = np.array([gradients[i] for i in members])
        cov = np.diag([items[i]["sigma"] ** 2 + spreads[regime] ** 2 for i in members]) + BIAS_SD ** 2
        precision += j.T @ np.linalg.solve(cov, j)
    return precision, gradients


def main(arguments):
    if not arguments:
        print(__doc__, file=sys.stderr)
        return 2

    def option(name, default):
        return arguments[arguments.index(name) + 1] if name in arguments else default
    steps = int(option("--steps", "4000"))
    global BIAS_SD
    BIAS_SD = float(option("--bias-sd", str(BIAS_SD)))
    seed = int(option("--seed", "1"))
    runs = [json.loads(line) for line in open(arguments[0]) if line.strip()]
    import os
    path = os.path.join(os.path.dirname(os.path.abspath(arguments[0])), "measured.json")
    measured = json.load(open(path)) if os.path.exists(path) else {}

    items = []
    print("Emulators (log output over its parameter's unit interval): runs, leave-one-out error (log), "
          "its predicted sd, length, the runs' own scatter (log)")
    for case, output, value, regime, scatter, spread in comparisons():
        points = [(unit(r["sample"]["values"]), r["outcome"]["outputs"].get(output)) for r in runs
                  if r["sample"]["caseID"] == case]
        points = [(x, y) for x, y in points if y is not None and y > 0 and math.isfinite(y)]
        if len(points) < 5:
            print("  %s %s: %d runs, left out" % (case, output, len(points)))
            continue
        x = np.array([p[0] for p in points])
        y = np.log([p[1] for p in points])
        emulator = Emulator(x, y, active=[ACTIVE[regime.split(",")[0]]])
        loo, sd = emulator.leave_one_out()
        known = measured.get(case, {}).get(output, [])
        target = value if value is not None else (known[0] if known else None)
        if target is None:
            print("  %s %s: no measurement, left out" % (case, output))
            continue
        # The glass's break times carry the repeats' scatter as `measuredVariation` in the case.
        if scatter is None:
            scatter = known[1] if len(known) > 1 else ASSUMED
        sigma = math.sqrt(scatter ** 2 + spread ** 2)
        items.append(dict(case=case, output=output, regime=regime, emulator=emulator,
                          logMeasured=math.log(target), sigma=sigma, measured=target,
                          today=math.exp(emulator.predict(unit({k: v for k, _, _, v, _ in PARAMETERS}))[0][0])))
        print("  %-18s %-9s %2d runs, LOO rms %.3f (sd %.3f), length %s, scatter %.3f; today %.4g against %.4g" % (
            case, output, len(points), float(np.sqrt(np.mean(loo ** 2))), float(np.mean(sd)),
            " ".join("%.2g" % l for l in emulator.lengths), emulator.nugget, items[-1]["today"], target))

    results = {}
    for label, discrepancy in [("no discrepancy", False), ("Kennedy-O'Hagan", True)]:
        posterior = Posterior(items, discrepancy)
        chain = posterior.sample(steps, seed=seed)
        print("\n%s: %d samples, acceptance %.2f" % (label, len(chain), posterior.acceptance))
        entry = {"parameters": {}, "spreads": {}, "biases": {}}
        for d, (key, low, high, today, name) in enumerate(PARAMETERS):
            values = np.exp(np.log(low) + chain[:, d] * (np.log(high) - np.log(low)))
            p = percentiles(values)
            # The posterior's width in the log against the prior's (uniform in the log: sd = range/√12).
            width = float(np.std(chain[:, d]) / (1 / math.sqrt(12)))
            entry["parameters"][key] = dict(p, today=today, widthOverPrior=width)
            print("  %-46s median %.4g (90%%: %.4g-%.4g; 68%%: %.4g-%.4g), today %.4g; width %.2f of the prior's"
                  % (name, p[50], p[5], p[95], p[16], p[84], today, width))
        if discrepancy:
            for n, regime in enumerate(posterior.regimes):
                s = percentiles(np.exp(chain[:, 3 + n]))
                entry["spreads"][regime] = s
            # Each regime's shared discrepancy given each sample: drawn from its conditional
            # distribution (normal, given the sample's parameters and spread).
            draws = np.random.default_rng(seed)
            thin = chain[:: max(1, len(chain) // 2000)]
            for regime in posterior.regimes:
                members = posterior.members[regime]
                biases = []
                n = posterior.regimes.index(regime)
                for theta in thin:
                    d = np.array([items[i]["emulator"].predict(theta[:3])[0][0] - items[i]["logMeasured"]
                                  for i in members])
                    v = np.array([items[i]["sigma"] ** 2 + math.exp(theta[3 + n]) ** 2 for i in members])
                    v = v + np.array([items[i]["emulator"].predict(theta[:3])[1][0] for i in members])
                    precision = 1 / BIAS_SD ** 2 + np.sum(1 / v)
                    biases.append(np.sum(d / v) / precision + draws.normal() / math.sqrt(precision))
                b = percentiles(np.exp(biases))
                entry["biases"][regime] = b
                print("  %-22s model/measured %.3f (90%%: %.3f-%.3f), spread between its comparisons %.3f (90%%: %.3f-%.3f)"
                      % (regime, b[50], b[5], b[95], entry["spreads"][regime][50], entry["spreads"][regime][5],
                         entry["spreads"][regime][95]))
            entry["chainMedian"] = [float(np.median(chain[:, d])) for d in range(chain.shape[1])]
            entry["regimes"] = posterior.regimes
        results[label] = entry

    # What would narrow the parameters most, linearised at the Kennedy-O'Hagan medians.
    koh = results["Kennedy-O'Hagan"]
    u = np.array(koh["chainMedian"][:3])
    spreads = {r: koh["spreads"][r][50] for r in koh["regimes"]}
    prior = np.eye(3) * 12  # uniform on the unit interval: variance 1/12
    base, gradients = linearised(items, koh["regimes"], u, spreads)
    base_sd = np.sqrt(np.diag(np.linalg.inv(prior + base)))
    print("\nSensitivities (d log output / d unit parameter) at the medians, and what would narrow "
          "each parameter (linearised; sd in the unit cube, now %s):" % " ".join("%.3f" % s for s in base_sd))
    for item, g in zip(items, gradients):
        print("  %-18s %-9s %s" % (item["case"], item["output"], " ".join("%+.3f" % v for v in g)))
    candidates = []
    for regime in koh["regimes"]:
        members = [i for i, item in enumerate(items) if item["regime"] == regime]
        # A regime's shared discrepancy known (a reference that pins it): the bias term gone.
        j = np.array([gradients[i] for i in members])
        cov = np.diag([items[i]["sigma"] ** 2 + spreads[regime] ** 2 for i in members])
        other = base - j.T @ np.linalg.solve(cov + BIAS_SD ** 2, j) + j.T @ np.linalg.solve(cov, j)
        candidates.append(("%s: its shared discrepancy pinned" % regime, other))
        # Twice the comparisons, like the ones it has (each new one as its regime's average).
        mean = np.mean(j, axis=0)
        sigma = np.mean([items[i]["sigma"] for i in members])
        k = len(members)
        jj = np.vstack([j, np.tile(mean, (k, 1))])
        cc = np.diag(np.concatenate([np.diag(cov), np.full(k, sigma ** 2 + spreads[regime] ** 2)])) + BIAS_SD ** 2
        other = base - j.T @ np.linalg.solve(cov + BIAS_SD ** 2, j) + jj.T @ np.linalg.solve(cc, jj)
        candidates.append(("%s: as many again comparisons" % regime, other))
        # Repeats halving each measurement's scatter.
        cov2 = np.diag([(items[i]["sigma"] ** 2) / 4 + spreads[regime] ** 2 for i in members]) + BIAS_SD ** 2
        other = base - j.T @ np.linalg.solve(cov + BIAS_SD ** 2, j) + j.T @ np.linalg.solve(cov2, j)
        candidates.append(("%s: repeats halving its scatter" % regime, other))
    rows = []
    for label, precision in candidates:
        sd = np.sqrt(np.diag(np.linalg.inv(prior + precision)))
        rows.append((label, sd))
    for d, (key, _, _, _, name) in enumerate(PARAMETERS):
        ranked = sorted(rows, key=lambda r: r[1][d])[:4]
        print("  %s: %s" % (name, "; ".join("%s %.0f%%" % (label, 100 * (1 - sd[d] / base_sd[d]))
                                              for label, sd in ranked)))
    results["narrowing"] = [{"what": label, "sd": [float(v) for v in sd]} for label, sd in rows]
    results["baseSD"] = [float(v) for v in base_sd]
    results["comparisons"] = [
        dict(case=i["case"], output=i["output"], regime=i["regime"], measured=i["measured"], today=i["today"],
             sigma=i["sigma"]) for i in items]
    if "--json" in arguments:
        with open(option("--json", ""), "w") as f:
            json.dump(results, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
