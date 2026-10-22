#!/usr/bin/env python3
"""The calibration's emulators and posterior (docs/calibration.md): a Gaussian process for each
comparison over the parameters its case reads, fitted to the runs of the design (a case run in
several files, the last file's), and a
Kennedy–O'Hagan posterior with a discrepancy for each regime.

    python3 Scripts/calibration/calibrate.py runs.jsonl [more.jsonl …] [--json out.json] [--steps 4000]
        [--seed 1] [--bias-sd 0.3] [--with-threshold]

The runs are those `Scripts/calibration/runs.py` gathers: one JSON line a run, its case, the
parameters' values and its outputs (a parameter a run does not give is at today's value); the
measured.json beside each file gives what the cases themselves are compared with
(Kingery–Bulmash's impulses, the panes' break times and their repeats' scatter, E1300's load
resistances). Only numpy is needed.

E1300's thresholds are left out of the likelihood unless `--with-threshold` is given: they are
E1300's own flaw model (Beason and Morgan's), not tests, so against BombCAD's copy of it they
measure only the stressed share that makes one reproduce the other, which is reported apart
(the review of 20 October, docs/calibration.md).
"""
import json
import math
import sys

import numpy as np

# The parameters as `Scripts/calibration/design.py` spreads them: key, range, today's value, name.
PARAMETERS = [
    ("afterburnTime", 0.003, 0.03, 0.01, "afterburning time (s/kg^1/3)"),
    ("ft", 0.6, 1.6, 1.0, "concrete tensile strength (factor)"),
    ("gf", 0.5, 2.0, 1.0, "concrete fracture energy (factor)"),
    ("glassK", 0.01, 3.0, 1.0, "glass flaw constant x stressed share (factor)"),
]

# Each comparison: case, output, measured value, regime, the measurement's scatter (log; the
# repeats' where there are some, else assumed) and the model's spread from its own uncertain
# inputs (log; docs/validation.md, "The model's spread from uncertain inputs", where recorded).
# Its regime names the parameters its case reads (`ACTIVE`, by the regime or its first word): the
# air's cases read only the afterburning time, the concrete's the tensile strength and fracture
# energy, the glass's the flaw factor, and Wu's slab under its charge the afterburning time and
# the concrete's both. Each emulator is over those axes alone, so that the others cannot leak
# into it through the runs' noise.
ACTIVE = {"air": [0], "concrete": [1, 2], "glass": [3], "concrete, close-in blast": [0, 1, 2]}


def active(regime):
    return ACTIVE.get(regime, ACTIVE[regime.split(",")[0]])
# Kingery-Bulmash's incident impulse against the 1966 tests: two-thirds within ±6.7% (Swisdak 1994;
# docs/data-survey.md, 3g). Its reflected curves were calculated, not measured: 10%, assumed.
KB_INCIDENT_SCATTER = 0.067
KB_REFLECTED_SCATTER = 0.10
# One curve's errors at its three distances are not independent: correlated, as the review asks.
KB_CORRELATION = 0.7
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
        ("peterson-d-2d-s90", "impact", 238.5, "concrete, impact", 0.18, 0.14),
        ("contest-slab", "peak", 109.0, "concrete, blast", 0.032, 0.12),
        # Wu's S8 under 1.6 kg at 0.5 m, one test; the gauges on Chiquito's slab, their repeats'
        # scatter (docs/validation.md, "The model's spread from uncertain inputs").
        ("wu-s8", "peak", 18.0, "concrete, close-in blast", ASSUMED, 0.04),
        ("wu-s8", "residual", 5.6, "concrete, close-in blast", ASSUMED, 0.21),
        ("chiquito-s1", "near", 2.5, "air, close-in gauges", 0.05, 0.07),
        ("chiquito-s1", "far", 0.5, "air, close-in gauges", 0.12, 0.06),
    ]
    for aspect in ["1-1", "1-1.3", "1-1.7", "1-2"]:
        rows.append(("glass-monk", "t" + aspect, None, "glass, break time", None, 0.0))
    for pane in ["A", "D", "T", "CC"]:
        rows.append(("glass-e1300", "lr" + pane, None, "glass, threshold", ASSUMED, 0.0))
    return rows


def outputs_of(case):
    """The case's comparisons: (regime, output)."""
    return [(regime, output) for c, output, _, regime, _, _ in comparisons() if c == case]


def unit(values):
    """The parameters' values on the unit cube, uniform in their logarithms."""
    return np.array([(math.log(values.get(key, today)) - math.log(low)) / (math.log(high) - math.log(low))
                     for key, low, high, today, _ in PARAMETERS])


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
        """The trend's mean and variance at `x` (every parameter's axis), the runs' own scatter added."""
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

P = len(PARAMETERS)
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
        return P + (len(self.regimes) if self.discrepancy else 0)

    def log_posterior(self, theta):
        u = theta[:P]
        if np.any(u < 0) or np.any(u > 1):
            return -np.inf
        total = 0.0
        if self.discrepancy:
            logs = theta[P:]
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
            # Kingery–Bulmash's distances: the curve's own error correlated between them.
            curve = np.array([self.items[i].get("curveScatter", 0.0) for i in members])
            cov += KB_CORRELATION * (np.outer(curve, curve) - np.diag(curve ** 2))
            if self.discrepancy:
                cov += np.diag(np.full(len(members), spreads[n] ** 2)) + BIAS_SD ** 2
            sign, logdet = np.linalg.slogdet(cov)
            total += -0.5 * (d @ np.linalg.solve(cov, d) + logdet)
        return total

    def sample(self, steps, walkers=40, seed=1):
        generator = np.random.default_rng(seed)
        dims = self.dimensions
        start = np.empty((walkers, dims))
        start[:, :P] = generator.uniform(0.05, 0.95, (walkers, P))
        if self.discrepancy:
            start[:, P:] = np.log(generator.uniform(0.02, 0.2, (walkers, dims - P)))
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
        # Split R-hat for each parameter, each walker's kept half split in two (near 1: mixed).
        kept = np.array(chain)  # steps × walkers × dims
        n = kept.shape[0] // 2
        halves = np.concatenate([kept[:n], kept[n:2 * n]], axis=1)
        within = np.mean(np.var(halves, axis=0, ddof=1), axis=0)
        between = n * np.var(np.mean(halves, axis=0), axis=0, ddof=1)
        self.rhat = np.sqrt(((n - 1) / n * within + between / n) / np.maximum(within, 1e-300))
        return np.concatenate(chain)


def percentiles(values):
    return {p: float(np.percentile(values, p)) for p in (5, 16, 50, 84, 95)}


# MARK: - Which data would narrow the bands

def linearised(items, regimes, u, spreads):
    """The posterior's precision on the parameters (unit cube, log) at `u`, linearised: each
    regime's sensitivities through its covariance, its shared discrepancy marginalised."""
    precision = np.zeros((P, P))
    gradients = []
    for item in items:
        e = item["emulator"]
        g = np.empty(P)
        for d in range(P):
            step = np.zeros(P)
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
    import os
    files = []
    for argument in arguments:
        if argument.startswith("--"):
            break
        files.append(argument)
    # A case run in more than one file takes the last file's runs only: a later step's design.
    runs = []
    for name in reversed(files):
        mine = [json.loads(line) for line in open(name) if line.strip()]
        known = {r["sample"]["caseID"] for r in runs}
        runs += [r for r in mine if r["sample"]["caseID"] not in known]
    measured = {}
    for name in files:
        path = os.path.join(os.path.dirname(os.path.abspath(name)), "measured.json")
        if os.path.exists(path):
            for case, outputs in json.load(open(path)).items():
                measured.setdefault(case, {}).update(outputs)

    items = []
    thresholds = []
    with_threshold = "--with-threshold" in arguments
    print("Emulators (log output over its parameters' unit intervals): runs, leave-one-out error (log), "
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
        emulator = Emulator(x, y, active=active(regime))
        loo, sd = emulator.leave_one_out()
        known = measured.get(case, {}).get(output, [])
        target = value if value is not None else (known[0] if known else None)
        if target is None:
            print("  %s %s: no measurement, left out" % (case, output))
            continue
        # The glass's break times carry the repeats' scatter as `measuredVariation` in the case,
        # floored at the series' pooled scatter: two repeats give it one degree of freedom.
        if scatter is None:
            series = [measured.get(case, {}).get(o, []) for _, o in outputs_of(case)]
            pooled = [v[1] for v in series if len(v) > 1]
            own = known[1] if len(known) > 1 else ASSUMED
            scatter = max(own, math.sqrt(sum(x * x for x in pooled) / len(pooled))) if pooled else own
        sigma = math.sqrt(scatter ** 2 + spread ** 2)
        if regime == "glass, threshold" and not with_threshold:
            thresholds.append((case, output, emulator, target))
            print("  %-18s %-9s %2d runs, LOO rms %.3f; a model against a model: left out of the likelihood"
                  % (case, output, len(points), float(np.sqrt(np.mean(loo ** 2)))))
            continue
        items.append(dict(case=case, output=output, regime=regime, emulator=emulator,
                          curveScatter=scatter if case.startswith("kb-") else 0.0,
                          logMeasured=math.log(target), sigma=sigma, measured=target,
                          today=math.exp(emulator.predict(unit({k: v for k, _, _, v, _ in PARAMETERS}))[0][0])))
        print("  %-18s %-9s %2d runs, LOO rms %.3f (sd %.3f), length %s, scatter %.3f; today %.4g against %.4g" % (
            case, output, len(points), float(np.sqrt(np.mean(loo ** 2))), float(np.mean(sd)),
            " ".join("%.2g" % l for l in emulator.lengths), emulator.nugget, items[-1]["today"], target))

    # E1300's thresholds, apart: the stressed share (flaw factor) at which BombCAD's flaw model
    # gives each pane's load resistance.
    shares = []
    grid = np.linspace(0, 1, 401)
    glass_axis = [p[0] for p in PARAMETERS].index("glassK")
    for case, output, emulator, target in thresholds:
        u = np.tile(unit({}), (len(grid), 1))
        u[:, glass_axis] = grid
        gap = np.abs(emulator.predict(u)[0] - math.log(target))
        share = from_unit(u[int(np.argmin(gap))])[glass_axis]
        shares.append(share)
        print("  E1300 %s: reproduced at a flaw factor of %.3g" % (output, share))
    if shares:
        print("  E1300's thresholds, as BombCAD's flaw model reproduces them: a stressed share of %.3g-%.3g "
              "(median %.3g)" % (min(shares), max(shares), float(np.median(shares))))

    results = {"thresholdShares": shares}
    for label, discrepancy in [("no discrepancy", False), ("Kennedy-O'Hagan", True)]:
        posterior = Posterior(items, discrepancy)
        chain = posterior.sample(steps, seed=seed)
        print("\n%s: %d samples, acceptance %.2f, split R-hat %s" % (
            label, len(chain), posterior.acceptance, " ".join("%.3f" % r for r in posterior.rhat[:P])))
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
                s = percentiles(np.exp(chain[:, P + n]))
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
                    d = np.array([items[i]["emulator"].predict(theta[:P])[0][0] - items[i]["logMeasured"]
                                  for i in members])
                    v = np.array([items[i]["sigma"] ** 2 + math.exp(theta[P + n]) ** 2 for i in members])
                    v = v + np.array([items[i]["emulator"].predict(theta[:P])[1][0] for i in members])
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
    u = np.array(koh["chainMedian"][:P])
    spreads = {r: koh["spreads"][r][50] for r in koh["regimes"]}
    prior = np.eye(P) * 12  # uniform on the unit interval: variance 1/12
    base, gradients = linearised(items, koh["regimes"], u, spreads)
    base_sd = np.sqrt(np.diag(np.linalg.inv(prior + base)))
    print("\nSensitivities (d log output / d unit parameter) at the medians, and what would narrow "
          "each parameter (linearised; sd in the unit cube, now %s):" % " ".join("%.3f" % s for s in base_sd))
    for item, g in zip(items, gradients):
        print("  %-18s %-9s %s" % (item["case"], item["output"], " ".join("%+.3f" % v for v in g)))
    candidates = []
    for regime in koh["regimes"]:
        members = [i for i, item in enumerate(items) if item["regime"] == regime]
        # A regime's shared discrepancy known (a reference that pins it): exactly, or to within
        # ±5, 10 or 20% (the review: a pin is never exact, and the gain falls fast with it).
        j = np.array([gradients[i] for i in members])
        cov = np.diag([items[i]["sigma"] ** 2 + spreads[regime] ** 2 for i in members])
        for pin in (0.0, 0.05, 0.10, 0.20):
            other = base - j.T @ np.linalg.solve(cov + BIAS_SD ** 2, j) + j.T @ np.linalg.solve(cov + pin ** 2, j)
            candidates.append(("%s: its shared discrepancy pinned%s" % (
                regime, " exactly" if pin == 0 else " to ±%.0f%%" % (100 * pin)), other))
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
