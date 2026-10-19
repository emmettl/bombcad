#!/usr/bin/env python3
"""Plans of protective changes for the prototype's made-up sites, as a table.

    python3 Scripts/protective/plan.py [courtyard|street|uncertain ...] [--json FILE]

For each scenario it prints the district as built, then the ranked plans of the exact search
(every combination of site-wide changes, each side given its cheapest option meeting the target),
and the plans the greedy search and simulated annealing find, with each plan's cost, the expected
number of sides that miss their target, the worst side's chance, and its standing. See
docs/protective-design.md; the model is `model.py`, the searches `search.py`, the sites
`scenarios.py`.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import model  # noqa: E402
import search  # noqa: E402
from scenarios import SCENARIOS  # noqa: E402


def run(name: str) -> dict:
    problem = SCENARIOS[name]()
    ev = search.Evaluator(problem)
    start = time.time()
    built = search.as_built(problem, ev)
    plans = search.exact(problem, ev)
    top = search.ranked(problem, plans)
    greedy = search.greedy(problem, ev)
    annealed = search.anneal(problem, ev)
    seconds = time.time() - start
    t = problem.target
    rows = [("as built", built)] + [(str(i + 1), p) for i, p in enumerate(top)] + [
        ("greedy", greedy), ("annealing", annealed)]
    print(f"\n{name}: {len(problem.buildings)} buildings, {len(problem.sides)} sides, "
          f"{len(problem.threats)} charge place{'s' if len(problem.threats) != 1 else ''}; target: "
          f"glass {model.CONDITIONS[t.glass_occupied]} or better and walls "
          f"{model.WALL_LEVELS[t.wall_occupied]} or better on occupied sides, each passed with a "
          f"chance under {t.chance:.0%} (load scatter {t.scatter})")
    print(f"| Plan | Cost, CU | Meets target | Sides missing it (expected) | Worst side | Changes | Standing |")
    print(f"|---|---:|---|---:|---:|---|---|")
    out = []
    for label, p in rows:
        print(f"| {label} | {p.cost:,.0f} | {'yes' if p.meets else 'no'} | "
              f"{p.expected_failing:.2f} | {p.worst:.0%} | {search.describe(problem, p)} | "
              f"{search.standing(problem, p)} |")
        out.append({"plan": label, "cost": round(p.cost, 1), "meets": p.meets,
                    "expectedFailing": round(p.expected_failing, 3), "worst": round(p.worst, 4),
                    "changes": search.describe(problem, p), "standing": search.standing(problem, p),
                    "site": [problem.site[i].name for i in p.site],
                    "sides": {k: list(v) for k, v in p.choices.items()}})
    print(f"({seconds:.0f} s)")
    return {"scenario": name, "seconds": round(seconds, 1), "plans": out}


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(description="Plans of protective changes for made-up sites.")
    ap.add_argument("scenarios", nargs="*", default=list(SCENARIOS))
    ap.add_argument("--json", type=Path)
    args = ap.parse_args(argv)
    results = [run(name) for name in args.scenarios]
    if args.json:
        args.json.write_text(json.dumps(results, indent=1, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
