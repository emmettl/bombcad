"""The search for the least costly set of changes that meets a hazard target, on the toy model.

A problem is a district (`model.Building`s), a threat (charges with weights: one place, several,
or samples of an inference's posterior), a target for each side (the worst glass condition and
wall level allowed, and the largest chance of passing them that is accepted), and the changes
allowed:

- **site-wide**: a stand-off line (`StandOff`), which keeps charges back by moving the threats it
  covers to where it would stop them; a barrier wall (`BarrierWall`), which shields what it stands
  in front of. These change the loads on every side, so each choice of them is a different problem
  for the sides;
- **per side**: its glazing (another glass, a laminate, a film, or filling the windows in) and
  its wall (a retrofit, or a new wall). Given the site-wide changes, each side's choice is its own:
  the cheapest that meets its target.

A side's chance of passing its target is the threats' weighted sum of the chance that the load's
scatter (a lognormal factor on peak and impulse together) reaches the side's limit multiplier
(`model.limit_multiplier`, `model.exceedance`).

Three searches:

- `exact`: every combination of site-wide changes, each side then given its cheapest option that
  meets its target. With site-wide changes few, this is the optimum an integer program over the
  same choices would give, found by enumeration.
- `greedy`: from the district as built, the change that removes the most excess chance per unit
  of cost, again and again until the target is met; then each change undone if the target still
  holds without it.
- `anneal`: simulated annealing over the site-wide changes, each side given its cheapest option,
  for when there are too many site-wide changes to enumerate.

`ranked` gives the plans in order: those meeting the target by cost, then the rest by how far
they miss it.
"""

from __future__ import annotations

import itertools
import math
from dataclasses import dataclass, field

import numpy as np

import model


@dataclass(frozen=True)
class StandOff:
    """A site-wide change that keeps charges back: each threat it covers moves to (x, y)."""
    name: str
    cost: float
    moves: tuple  # ((threat index, x, y), ...)


@dataclass(frozen=True)
class BarrierWall:
    name: str
    cost: float
    barrier: model.Barrier


@dataclass(frozen=True)
class Threat:
    charge: model.Charge
    weight: float = 1.0


@dataclass(frozen=True)
class Target:
    """The worst GSA condition (index into model.CONDITIONS) and wall level (into
    model.WALL_LEVELS) allowed on an occupied side and on an unoccupied one, and the largest
    accepted chance of passing them; `scatter` is the loads' logarithmic standard deviation."""
    glass_occupied: int = 3  # 3b
    glass_unoccupied: int = 4  # 4
    wall_occupied: int = 2  # heavy
    wall_unoccupied: int = 3  # hazardous
    chance: float = 0.1
    scatter: float = 0.25

    def allowed(self, side: model.Side) -> tuple:
        if side.building.occupied:
            return self.glass_occupied, self.wall_occupied
        return self.glass_unoccupied, self.wall_unoccupied


@dataclass
class Problem:
    name: str
    buildings: list
    threats: list
    site: list  # StandOff and BarrierWall changes
    glazings: list  # names in model.GLAZINGS allowed as changes
    walls: list  # names in model.WALLS allowed as changes
    target: Target = field(default_factory=Target)
    shielding: model.Shielding = field(default_factory=model.Shielding)

    def __post_init__(self):
        self.sides = model.sides(self.buildings)


@dataclass
class Plan:
    site: tuple  # indices into the problem's site-wide changes
    choices: dict  # side name -> (glazing, wall)
    chances: dict  # side name -> chance of passing its target
    cost: float
    meets: bool
    limits: dict = field(default_factory=dict)  # side name -> smallest limit multiplier
    outside: int = 0  # sides with a load outside Kingery–Bulmash's fits
    method: str = ""

    def excess(self, target: Target) -> float:
        return sum(max(0.0, p - target.chance) for p in self.chances.values())

    @property
    def expected_failing(self) -> float:
        return sum(self.chances.values())

    @property
    def worst(self) -> float:
        return max(self.chances.values()) if self.chances else 0.0


class Evaluator:
    """Loads and chances, remembered: a side's chance depends only on its options and on which
    site-wide changes are in place."""

    def __init__(self, problem: Problem):
        self.problem = problem
        self._loads = {}
        self._chance = {}

    def threats(self, site: tuple) -> list:
        threats = list(self.problem.threats)
        for i in sorted(site):
            change = self.problem.site[i]
            if isinstance(change, StandOff):
                for k, x, y in change.moves:
                    t = threats[k]
                    threats[k] = Threat(model.Charge(t.charge.mass, x, y), t.weight)
        return threats

    def barriers(self, site: tuple) -> tuple:
        return tuple(self.problem.site[i].barrier for i in sorted(site)
                     if isinstance(self.problem.site[i], BarrierWall))

    def loads(self, side: model.Side, site: tuple) -> list:
        threats = self.threats(site)
        barriers = self.barriers(site)
        out = []
        for t in threats:
            key = (side.name, t.charge, barriers)
            if key not in self._loads:
                self._loads[key] = model.side_load(side, t.charge, self.problem.buildings, barriers,
                                                   self.problem.shielding)
            out.append((self._loads[key], t.weight))
        return out

    def chance(self, side: model.Side, glazing: str, wall: str, site: tuple) -> tuple:
        """(chance of passing the target, smallest limit multiplier over the threats)."""
        key = (side.name, glazing, wall, self._site_key(site))
        if key not in self._chance:
            target = self.problem.target
            allowed_glass, allowed_wall = target.allowed(side)
            loads = self.loads(side, site)
            total = sum(w for _, w in loads)
            p = 0.0
            smallest = math.inf
            for load, w in loads:
                m = model.limit_multiplier(side, glazing, wall, load, allowed_glass, allowed_wall)
                smallest = min(smallest, m)
                p += w / total * model.exceedance(m, target.scatter)
            self._chance[key] = (p, smallest)
        return self._chance[key]

    def _site_key(self, site: tuple) -> tuple:
        # Only the changes that move a threat or stand a barrier matter; all do here.
        return tuple(sorted(site))

    def options(self, side: model.Side) -> list:
        """(glazing, wall, cost) for every option of a side, the side as built first."""
        b = side.building
        glazings = [b.glazing] + [g for g in self.problem.glazings if g != b.glazing]
        walls = [b.wall] + [w for w in self.problem.walls if w != b.wall]
        out = []
        for g in glazings:
            if side.panes == 0 and g != b.glazing:
                continue
            for w in walls:
                cost = 0.0
                if g != b.glazing:
                    cost += model.GLAZINGS[g].cost * side.glazed_area
                if w != b.wall:
                    cost += model.WALLS[w].cost * (side.area - side.glazed_area)
                out.append((g, w, cost))
        return out

    def plan(self, site: tuple, method: str = "exact") -> Plan:
        """Each side given its cheapest option meeting the target, or, where none does, the one
        with the least chance of failing."""
        target = self.problem.target
        choices, chances, limits = {}, {}, {}
        cost = sum(self.problem.site[i].cost for i in site)
        meets = True
        outside = 0
        for side in self.problem.sides:
            best = None
            fallback = None
            for g, w, c in self.options(side):
                p, m = self.chance(side, g, w, site)
                if p <= target.chance and (best is None or c < best[2]):
                    best = (g, w, c, p, m)
                if fallback is None or p < fallback[3] or (p == fallback[3] and c < fallback[2]):
                    fallback = (g, w, c, p, m)
            if best is None:
                best = fallback
                meets = False
            g, w, c, p, m = best
            choices[side.name] = (g, w)
            chances[side.name] = p
            limits[side.name] = m
            cost += c
            outside += any(not load.in_range and load.peak > 0 for load, _ in self.loads(side, site))
        return Plan(tuple(sorted(site)), choices, chances, cost, meets, limits, outside, method)

    def evaluate(self, site: tuple, choices: dict, method: str) -> Plan:
        """A plan with the given site-wide changes and side choices, costed and judged."""
        target = self.problem.target
        cost = sum(self.problem.site[i].cost for i in site)
        chances, limits = {}, {}
        for side in self.problem.sides:
            g, w = choices[side.name]
            costs = {(og, ow): oc for og, ow, oc in self.options(side)}
            cost += costs[(g, w)]
            chances[side.name], limits[side.name] = self.chance(side, g, w, site)
        meets = all(p <= target.chance for p in chances.values())
        return Plan(tuple(sorted(site)), dict(choices), chances, cost, meets, limits, 0, method)


def as_built(problem: Problem, evaluator: Evaluator | None = None) -> Plan:
    ev = evaluator or Evaluator(problem)
    choices = {s.name: (s.building.glazing, s.building.wall) for s in problem.sides}
    return ev.evaluate((), choices, "as built")


def exact(problem: Problem, evaluator: Evaluator | None = None) -> list:
    """The best plan for every combination of site-wide changes."""
    ev = evaluator or Evaluator(problem)
    n = len(problem.site)
    if n > 12:
        raise ValueError(f"{n} site-wide changes are too many to enumerate; use anneal")
    plans = []
    for k in range(n + 1):
        for site in itertools.combinations(range(n), k):
            plans.append(ev.plan(site, "exact"))
    return plans


def best(plans: list, target: Target) -> Plan:
    meeting = [p for p in plans if p.meets]
    if meeting:
        return min(meeting, key=lambda p: (p.cost, p.expected_failing))
    return min(plans, key=lambda p: (p.excess(target), p.cost))


def greedy(problem: Problem, evaluator: Evaluator | None = None) -> Plan:
    """Change by change, the most excess chance removed per unit of cost, then pruned."""
    ev = evaluator or Evaluator(problem)
    target = problem.target
    site = ()
    choices = {s.name: (s.building.glazing, s.building.wall) for s in problem.sides}
    plan = ev.evaluate(site, choices, "greedy")
    history = []
    while not plan.meets:
        base = plan.excess(target)
        best_move, best_score = None, 0.0
        for i, change in enumerate(problem.site):
            if i in site:
                continue
            trial = ev.evaluate(site + (i,), choices, "greedy")
            gain = base - trial.excess(target)
            if gain > 1e-12 and gain / max(change.cost, 1e-9) > best_score:
                best_move, best_score = ("site", i), gain / max(change.cost, 1e-9)
        for side in problem.sides:
            g0, w0 = choices[side.name]
            p0 = ev.chance(side, g0, w0, site)[0]
            if p0 <= target.chance:
                continue
            costs = {(g, w): c for g, w, c in ev.options(side)}
            for (g, w), c in costs.items():
                extra = c - costs[(g0, w0)]
                if extra <= 0:
                    continue
                p = ev.chance(side, g, w, site)[0]
                gain = max(0.0, p0 - target.chance) - max(0.0, p - target.chance)
                if gain > 1e-12 and gain / extra > best_score:
                    best_move, best_score = ("side", side.name, (g, w)), gain / extra
        if best_move is None:
            break
        history.append((best_move, site, dict(choices)))
        if best_move[0] == "site":
            site = tuple(sorted(site + (best_move[1],)))
        else:
            choices[best_move[1]] = best_move[2]
        plan = ev.evaluate(site, choices, "greedy")
    if not plan.meets:
        return plan
    # Undo what is no longer needed, latest first.
    built = {s.name: (s.building.glazing, s.building.wall) for s in problem.sides}
    for move, _, _ in reversed(history):
        if move[0] == "site":
            trial_site, trial_choices = tuple(i for i in site if i != move[1]), choices
        else:
            trial_site = site
            trial_choices = dict(choices)
            trial_choices[move[1]] = built[move[1]]
        trial = ev.evaluate(trial_site, trial_choices, "greedy")
        if trial.meets and trial.cost < plan.cost:
            site, choices, plan = trial_site, trial_choices, trial
    return plan


def anneal(problem: Problem, evaluator: Evaluator | None = None, steps: int = 300,
           seed: int = 1) -> Plan:
    """Simulated annealing over the site-wide changes, each side given its cheapest option; a plan
    that misses the target is charged its excess chance at a large price."""
    ev = evaluator or Evaluator(problem)
    target = problem.target
    rng = np.random.default_rng(seed)
    n = len(problem.site)
    scale = max([c.cost for c in problem.site] + [1.0])
    penalty = 100.0 * scale * len(problem.sides)

    def energy(p: Plan) -> float:
        return p.cost + penalty * p.excess(target)

    state = ()
    plan = ev.plan(state, "anneal")
    found = plan
    if n == 0:
        return plan
    temperature = scale
    for step in range(steps):
        i = int(rng.integers(n))
        trial_state = tuple(sorted(set(state) ^ {i}))
        trial = ev.plan(trial_state, "anneal")
        delta = energy(trial) - energy(plan)
        if delta <= 0 or rng.random() < math.exp(-delta / max(temperature, 1e-9)):
            state, plan = trial_state, trial
            if energy(plan) < energy(found):
                found = plan
        temperature = scale * (1.0 - (step + 1) / steps) + 1e-6
    return found


def ranked(problem: Problem, plans: list, count: int = 6) -> list:
    """Plans in order: meeting the target by cost, then the rest by excess chance; one plan for
    each combination of site-wide changes."""
    target = problem.target
    seen = set()
    out = []
    order = sorted(plans, key=lambda p: (not p.meets, p.cost if p.meets else p.excess(target),
                                         p.expected_failing))
    for p in order:
        key = (p.site, tuple(sorted(p.choices.items())))
        if key in seen:
            continue
        seen.add(key)
        out.append(p)
        if len(out) == count:
            break
    return out


def standing(problem: Problem, plan: Plan) -> str:
    """What the plan's numbers rest on, in a line."""
    target = problem.target
    narrow = sum(1 for p in plan.chances.values() if target.chance / 3 <= p <= target.chance)
    parts = ["illustrative (toy model, assumed shielding)"]
    if narrow:
        parts.append(f"{narrow} side{'s pass' if narrow != 1 else ' passes'} narrowly: confirm with a run")
    if plan.outside:
        parts.append(f"{plan.outside} outside Kingery–Bulmash's fits")
    return "; ".join(parts)


def describe(problem: Problem, plan: Plan) -> str:
    """The plan's changes, in a few words."""
    parts = [problem.site[i].name for i in plan.site]
    counts = {}
    for side in problem.sides:
        g, w = plan.choices[side.name]
        if g != side.building.glazing:
            counts[g] = counts.get(g, 0) + 1
        if w != side.building.wall:
            counts[w] = counts.get(w, 0) + 1
    parts += [f"{name} on {n} side{'s' if n != 1 else ''}" for name, n in sorted(counts.items())]
    return "; ".join(parts) if parts else "nothing"
