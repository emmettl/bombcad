#!/usr/bin/env python3
"""The prototype's problems and plans as data, for `ProtectionSearch`'s test to match.

    python3 Scripts/protective/export.py Fixtures/ProtectiveDesign/prototype.json [scenario ...]

For each scenario: its sides, each side's options (glazing, wall, cost; the side as built
first), its site-wide changes (name, cost), the target chance, and every side's chance of passing
its target for every option and every combination of site-wide changes; then the plans the
prototype's exact, greedy and annealing searches find, and its ranked list. The Swift search,
given the same chances, must find the same plans (docs/protective-design.md, "The search").
"""

from __future__ import annotations

import itertools
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import search  # noqa: E402
from scenarios import SCENARIOS  # noqa: E402


def plan_json(problem, plan) -> dict:
    return {
        "site": list(plan.site),
        "cost": plan.cost,
        "meets": plan.meets,
        "choices": [list(plan.choices[s.name]) for s in problem.sides],
    }


def export(name: str) -> dict:
    problem = SCENARIOS[name]()
    ev = search.Evaluator(problem)
    sides = []
    for side in problem.sides:
        sides.append({
            "name": side.name,
            "options": [{"glazing": g, "wall": w, "cost": c} for g, w, c in ev.options(side)],
        })
    n = len(problem.site)
    chances = {}
    for k in range(n + 1):
        for site in itertools.combinations(range(n), k):
            chances[",".join(map(str, site))] = [
                [ev.chance(side, g, w, site)[0] for g, w, _ in ev.options(side)] for side in problem.sides
            ]
    exact = search.exact(problem, ev)
    return {
        "scenario": name,
        "targetChance": problem.target.chance,
        "site": [{"name": c.name, "cost": c.cost} for c in problem.site],
        "sides": sides,
        "chances": chances,
        "best": plan_json(problem, search.best(exact, problem.target)),
        "ranked": [plan_json(problem, p) for p in search.ranked(problem, exact)],
        "greedy": plan_json(problem, search.greedy(problem, ev)),
        "annealed": plan_json(problem, search.anneal(problem, ev)),
        "asBuilt": plan_json(problem, search.as_built(problem, ev)),
    }


def main(argv: list) -> int:
    if not argv:
        print(__doc__)
        return 1
    out = Path(argv[0])
    names = argv[1:] or ["courtyard", "street", "weak-shielding"]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps([export(n) for n in names], indent=None, separators=(",", ":")) + "\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
