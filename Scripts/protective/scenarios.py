"""Three made-up sites for the protective-design prototype.

Costs are in made-up cost units (CU): their ratios follow the order the survey's sources give
(film cheaper than laminated glass, a new glazing system dearer still, stand-off cheapest where
there is room for it), not any price list. Charges are TNT equivalents on the ground.

- `courtyard`: six buildings round a courtyard, a car park against its south row, one charge in
  the car park. Site-wide changes: closing the car park, which keeps the charge out on the road
  beyond a stand-off line, or a barrier wall along the south row.
- `street`: two rows of four buildings either side of a street, a charge anywhere along it (five
  places, equally likely). Site-wide changes: closing the street's west, middle or east third to
  vehicles, each moving its charges to the closed stretch's end.
- `uncertain`: the courtyard, the charge's mass and place as twelve samples of an inference's
  posterior (median 100 kg, a factor of about 1.5 either way; within about 8 m of the car park).
- `weak-shielding`: the courtyard with shielding about as weak as BombCAD's own surrogate finds in
  its district runs (a building crossed takes 2% off the peak and nothing off the impulse; a
  barrier 10% and 5%), against the assumed 30% and 15% (40% and 20% for a barrier) of the others.
"""

from __future__ import annotations

import numpy as np

import model
from search import BarrierWall, Problem, StandOff, Target, Threat

GLAZINGS = ["film, daylight", "film, anchored", "laminated 6.8", "laminated 13.5", "toughened 10",
            "infill"]
WALLS = ["brick, retrofitted", "concrete"]


def _courtyard_buildings():
    return [
        model.Building("S1", 0, 0, 24, 12),
        model.Building("S2", 30, 0, 54, 12),
        model.Building("E", 60, 0, 72, 40, storeys=2),
        model.Building("N1", 0, 46, 24, 58),
        model.Building("N2", 30, 46, 54, 58),
        model.Building("Store", -18, 0, -6, 40, storeys=1, occupied=False, glazed_share=0.1),
    ]


def _courtyard_site():
    return [
        StandOff("close the car park", 80.0, ((0, 27.0, -45.0),)),
        BarrierWall("barrier wall along the south row", 150.0, model.Barrier(-2.0, -6.0, 58.0, -6.0)),
    ]


def courtyard() -> Problem:
    return Problem("courtyard", _courtyard_buildings(),
                   [Threat(model.Charge(100.0, 27.0, -14.0))], _courtyard_site(), GLAZINGS, WALLS,
                   Target())


def street() -> Problem:
    buildings = []
    for i, x in enumerate(range(0, 100, 25)):
        buildings.append(model.Building(f"N{i + 1}", x, 20, x + 20, 32, storeys=4))
        buildings.append(model.Building(f"S{i + 1}", x, -16, x + 20, -4, storeys=2,
                                        occupied=i != 3))
    threats = [Threat(model.Charge(100.0, x, 8.0)) for x in (10.0, 35.0, 50.0, 65.0, 90.0)]
    site = [
        StandOff("close the street's west third", 60.0, ((0, -45.0, 8.0), (1, -45.0, 8.0))),
        StandOff("close the street's middle", 60.0, ((2, 50.0, 70.0),)),
        StandOff("close the street's east third", 60.0, ((3, 145.0, 8.0), (4, 145.0, 8.0))),
    ]
    return Problem("street", buildings, threats, site, GLAZINGS, WALLS, Target())


def uncertain(samples: int = 12, seed: int = 7) -> Problem:
    rng = np.random.default_rng(seed)
    masses = 100.0 * np.exp(0.4 * rng.standard_normal(samples))
    places = np.array([27.0, -14.0]) + 4.0 * rng.standard_normal((samples, 2))
    threats = [Threat(model.Charge(float(m), float(x), float(y))) for m, (x, y) in zip(masses, places)]
    site = [
        StandOff("close the car park", 80.0, tuple((k, 27.0, -45.0) for k in range(samples))),
        BarrierWall("barrier wall along the south row", 150.0, model.Barrier(-2.0, -6.0, 58.0, -6.0)),
    ]
    return Problem("uncertain", _courtyard_buildings(), threats, site, GLAZINGS, WALLS, Target())


def weak_shielding() -> Problem:
    problem = courtyard()
    problem.name = "weak-shielding"
    problem.shielding = model.Shielding(building_peak=0.98, building_impulse=1.0,
                                        barrier_peak=0.9, barrier_impulse=0.95)
    return problem


SCENARIOS = {"courtyard": courtyard, "street": street, "uncertain": uncertain,
             "weak-shielding": weak_shielding}
