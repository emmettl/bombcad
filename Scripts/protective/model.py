"""A toy district's façades under a surface burst, and how their glazing and walls respond.

The forward model of the protective-design prototype (docs/protective-design.md). It is a toy: a
plan of rectangular buildings, each side one façade with one kind of pane and one kind of wall,
the charge on the ground. Nothing here is BombCAD's own model; it is built from the independent
references in Scripts/reference/ so that the search in `search.py` has something cheap and
plausible to search over.

- **Loads.** Kingery–Bulmash's hemispherical surface burst (`kingery_bulmash.py`) at the façade's
  representative pane, 1.5 m up. Facing the charge, the peak is raised from the incident toward
  Kingery–Bulmash's normally reflected peak by the reflected-pressure coefficient's dependence on
  the angle of incidence (`oblique.coefficient`, two-shock theory), and the impulse in the same
  proportion; facing away, or side on, the incident values. Each building crossed on the straight
  line from the charge to the façade, and each barrier wall, multiplies the peak and the impulse by
  a fixed factor (`Shielding`): an assumption, not a fit.
- **Glazing.** A pane simply supported on four edges, as a single degree of freedom on
  small-deflection plate theory (Timoshenko's coefficients), loaded by a triangular pulse. Its
  elastic response has Biggs's closed form, checked in the tests against `sdof.respond`. It cracks
  when the plate's largest stress reaches the glass's short-duration strength. Monolithic glass
  then flies at the speed it had plus what the rest of the impulse gives it. Laminated glass and
  filmed glass become a membrane (after Hooper's cracked-laminate model as BombCAD uses it), a
  linear spring with the same closed form; it is held, tears or pulls out of its frame. The tests
  check both closed forms against `sdof.respond`. Where a
  thrown pane lands gives its GSA performance condition, as BombCAD's `GlazingHazard` grades it.
- **Walls.** A one-way strip a storey tall, simply supported, as `sdof.beam`, judged by its support
  rotation against the response limits PDC-TR 06-08 gives for flexure (as reproduced, unverified,
  in the survey): superficial to ductility 1, moderate to 2°, heavy to 5°, hazardous to 10°.

Every response is a function of the load's peak and impulse together. The search needs, for each
façade, change and threat, the factor `m` on both at which the façade first passes its allowed
level (`limit_multiplier`); with the loads' scatter as a lognormal factor, the chance of passing
it is then one line (`exceedance`).
"""

from __future__ import annotations

import math
import sys
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "reference"))
import kingery_bulmash as kb  # noqa: E402
import oblique  # noqa: E402
import sdof  # noqa: E402

G = 9.81
AMBIENT_PA = 101_325.0
CHARGE_HEIGHT_M = 0.5
PANE_HEIGHT_M = 1.5  # the representative pane's middle, on the ground floor
SILL_M = 0.9
WITNESS_DISTANCE_M = 3.0
WITNESS_HEIGHT_M = 0.6

GLASS_E = 70e9
GLASS_NU = 0.22
GLASS_RHO = 2500.0

# GSA-TS01's performance conditions, safest first.
CONDITIONS = ["1", "2", "3a", "3b", "4", "5"]
# PDC-TR 06-08's component damage levels.
WALL_LEVELS = ["superficial", "moderate", "heavy", "hazardous", "blowout"]


# Geometry

@dataclass(frozen=True)
class Building:
    name: str
    x0: float
    y0: float
    x1: float
    y1: float
    storeys: int = 3
    occupied: bool = True
    wall: str = "brick"
    glazing: str = "annealed 6"
    pane: tuple = (1.2, 1.5)  # width, height, m
    glazed_share: float = 0.3

    @property
    def height(self) -> float:
        return 3.0 * self.storeys

    def contains(self, x: float, y: float) -> bool:
        return self.x0 < x < self.x1 and self.y0 < y < self.y1


@dataclass(frozen=True)
class Side:
    building: Building
    face: str  # "N", "S", "E" or "W"

    @property
    def name(self) -> str:
        return f"{self.building.name}/{self.face}"

    @property
    def normal(self) -> tuple:
        return {"N": (0.0, 1.0), "S": (0.0, -1.0), "E": (1.0, 0.0), "W": (-1.0, 0.0)}[self.face]

    @property
    def centre(self) -> tuple:
        b = self.building
        return {"N": (0.5 * (b.x0 + b.x1), b.y1), "S": (0.5 * (b.x0 + b.x1), b.y0),
                "E": (b.x1, 0.5 * (b.y0 + b.y1)), "W": (b.x0, 0.5 * (b.y0 + b.y1))}[self.face]

    @property
    def length(self) -> float:
        b = self.building
        return b.x1 - b.x0 if self.face in "NS" else b.y1 - b.y0

    @property
    def area(self) -> float:
        return self.length * self.building.height

    @property
    def glazed_area(self) -> float:
        a, h = self.building.pane
        return self.panes * a * h

    @property
    def panes(self) -> int:
        a, h = self.building.pane
        return int(round(self.building.glazed_share * self.area / (a * h)))


def sides(buildings) -> list:
    return [Side(b, f) for b in buildings for f in "NSEW"]


@dataclass(frozen=True)
class Charge:
    """A surface burst: TNT mass (kg) and place (m)."""
    mass: float
    x: float
    y: float


@dataclass(frozen=True)
class Barrier:
    """A wall in plan from (x0, y0) to (x1, y1), tall enough to stand in the line of sight."""
    x0: float
    y0: float
    x1: float
    y1: float


@dataclass(frozen=True)
class Shielding:
    """Factors on the peak and the impulse for each building, and each barrier, crossed on the
    line from the charge. Assumed, not fitted: BombCAD's surrogate fits a far weaker term to its own
    district runs (its peak falls by a factor (1 + n)^-0.022 for n buildings crossed), and which is
    nearer the truth is one of the design's open questions."""
    building_peak: float = 0.7
    building_impulse: float = 0.85
    barrier_peak: float = 0.6
    barrier_impulse: float = 0.8


def _segments_cross(p, q, a, b) -> bool:
    def orient(u, v, w):
        return (v[0] - u[0]) * (w[1] - u[1]) - (v[1] - u[1]) * (w[0] - u[0])
    d1, d2 = orient(a, b, p), orient(a, b, q)
    d3, d4 = orient(p, q, a), orient(p, q, b)
    return d1 * d2 < 0 and d3 * d4 < 0


def _crosses_box(p, q, b: Building) -> bool:
    corners = [(b.x0, b.y0), (b.x1, b.y0), (b.x1, b.y1), (b.x0, b.y1)]
    if b.contains(*p) or b.contains(*q):
        return True
    return any(_segments_cross(p, q, corners[i], corners[(i + 1) % 4]) for i in range(4))


@dataclass(frozen=True)
class Load:
    peak: float  # Pa
    impulse: float  # Pa s
    distance: float  # m
    facing: float  # cosine of the angle of incidence (negative facing away)
    crossed: int  # buildings crossed
    barriers: int  # barriers crossed
    in_range: bool  # within Kingery–Bulmash's fits

    @property
    def duration(self) -> float:
        return 2.0 * self.impulse / self.peak if self.peak > 0 else 0.0


def side_load(side: Side, charge: Charge, buildings, barriers=(), shielding=Shielding()) -> Load:
    cx, cy = side.centre
    nx, ny = side.normal
    target = (cx + 0.05 * nx, cy + 0.05 * ny)  # just outside its own building
    dx, dy = charge.x - target[0], charge.y - target[1]
    plan = math.hypot(dx, dy)
    distance = math.hypot(plan, PANE_HEIGHT_M - CHARGE_HEIGHT_M)
    facing = (nx * dx + ny * dy) / plan if plan > 0 else 1.0
    crossed = sum(1 for b in buildings if b is not side.building and
                  _crosses_box((charge.x, charge.y), target, b))
    walls = sum(1 for w in barriers if _segments_cross((charge.x, charge.y), target,
                                                        (w.x0, w.y0), (w.x1, w.y1)))
    z = distance / charge.mass ** (1.0 / 3.0)
    in_range = 0.0674 <= z <= 40.0
    if z > 40.0:
        return Load(0.0, 0.0, distance, facing, crossed, walls, False)
    point = kb.at(np.array([max(distance, 0.0674 * charge.mass ** (1 / 3))]), charge.mass)
    ps = float(point["incident_pressure"][0])
    pr0 = float(point["reflected_pressure"][0])
    i_s = float(point["incident_impulse"][0])
    i_r0 = float(point["reflected_impulse"][0])
    if facing > 0:
        alpha = math.acos(min(facing, 1.0))
        ratio = ps / AMBIENT_PA
        share = (oblique.coefficient(ratio, alpha) - 1.0) / (oblique.coefficient(ratio, 0.0) - 1.0)
        share = min(max(share, 0.0), 1.0)
        peak = ps + share * (pr0 - ps)
        impulse = i_s + share * (i_r0 - i_s)
    else:
        peak, impulse = ps, i_s
    peak *= shielding.building_peak ** crossed * shielding.barrier_peak ** walls
    impulse *= shielding.building_impulse ** crossed * shielding.barrier_impulse ** walls
    return Load(peak, impulse, distance, facing, crossed, walls, in_range)


# Glazing

@dataclass(frozen=True)
class Glazing:
    """A glazing as built or as a change. `strength` is the short-duration breaking stress (Pa) of
    the glass, `glass_mm` its thickness for stiffness and stress. A laminate or a film is a
    membrane once the glass cracks: `tension` (N/m) its plateau tension, `tear_strain` its average
    strain at tearing, `anchor` (N/m) what its frame holds before it pulls out (infinite: held).
    `cost` is per square metre of glazing, in the scenario's cost units; `infill` replaces the
    window with wall."""
    name: str
    glass_mm: float
    strength: float
    tension: float = 0.0
    tear_strain: float = 0.0
    anchor: float = math.inf
    cost: float = 0.0
    infill: bool = False


# E1300's 60 s strength of weathered annealed glass, 42.9 MPa as BombCAD takes it, carried to a
# 10 ms load by static fatigue (exponent 16): 42.9 (60 / 0.01)^(1/16) = 74 MPa. E1300's glass type
# factors for short loads give heat-strengthened glass twice that and toughened four times.
ANNEALED_STRENGTH = 42.9e6 * (60 / 0.01) ** (1 / 16)

GLAZINGS = {
    "annealed 6": Glazing("annealed 6", 6.0, ANNEALED_STRENGTH, cost=0.0),
    "film, daylight": Glazing("film, daylight", 6.0, ANNEALED_STRENGTH, tension=20e3,
                              tear_strain=1.0, anchor=3e3, cost=1.0),
    "film, anchored": Glazing("film, anchored", 6.0, ANNEALED_STRENGTH, tension=20e3,
                              tear_strain=1.0, anchor=30e3, cost=2.5),
    "laminated 6.8": Glazing("laminated 6.8", 6.0, ANNEALED_STRENGTH, tension=12e3,
                             tear_strain=0.2, anchor=22e3, cost=5.0),
    "laminated 13.5": Glazing("laminated 13.5", 12.0, ANNEALED_STRENGTH, tension=24e3,
                              tear_strain=1.5, anchor=math.inf, cost=9.0),
    "toughened 10": Glazing("toughened 10", 10.0, 4.0 * ANNEALED_STRENGTH, cost=4.0),
    "infill": Glazing("infill", 0.0, 0.0, cost=6.0, infill=True),
}

# Timoshenko's simply supported plate under a uniform load, by aspect b/a: centre deflection
# w = alpha q a^4 / D and largest stress sigma = beta q a^2 / t^2 (Theory of Plates and Shells,
# 2nd ed., 1959, Table 8, with nu 0.3; small deflections).
_ASPECT = [1.0, 1.2, 1.4, 1.6, 1.8, 2.0, 3.0, 4.0, 5.0, 1e9]
_ALPHA = [0.00406, 0.00564, 0.00705, 0.00830, 0.00931, 0.01013, 0.01223, 0.01282, 0.01297, 0.01302]
_BETA = [0.2874, 0.3762, 0.4530, 0.5172, 0.5688, 0.6102, 0.7134, 0.7410, 0.7476, 0.7500]


def plate_coefficients(width: float, height: float) -> tuple:
    a, b = min(width, height), max(width, height)
    r = b / a
    return float(np.interp(r, _ASPECT, _ALPHA)), float(np.interp(r, _ASPECT, _BETA))


@dataclass(frozen=True)
class Pane:
    """A pane's equivalent single degree of freedom: total mass (kg), stiffness (N/m of its middle's
    deflection under the total load), and the stress at its middle per metre of deflection."""
    width: float
    height: float
    glass: Glazing
    mass: float
    stiffness: float
    stress_per_m: float

    @property
    def area(self) -> float:
        return self.width * self.height

    @property
    def omega(self) -> float:
        factor = sdof.load_mass_factor("simple", "uniform", "elastic")
        return math.sqrt(self.stiffness / (factor * self.mass))


def pane(width: float, height: float, glass: Glazing) -> Pane:
    t = glass.glass_mm / 1000.0
    a = min(width, height)
    alpha, beta = plate_coefficients(width, height)
    d = GLASS_E * t**3 / (12.0 * (1.0 - GLASS_NU**2))
    stiffness = width * height * d / (alpha * a**4)  # total load per deflection
    stress_per_m = beta * a**2 / t**2 * stiffness / (width * height)
    return Pane(width, height, glass, GLASS_RHO * t * width * height, stiffness, stress_per_m)


def elastic_triangular(omega: float, duration: float, static: float, times):
    """Biggs's undamped elastic response to a load falling linearly from its peak to nothing at
    `duration`: deflection and velocity at `times`, `static` the peak load's static deflection."""
    t = np.asarray(times, dtype=float)
    td = duration
    w = omega
    during = t <= td
    x = np.empty_like(t)
    v = np.empty_like(t)
    tt = t[during]
    x[during] = static * (1 - np.cos(w * tt) + np.sin(w * tt) / (w * td) - tt / td)
    v[during] = static * (w * np.sin(w * tt) + np.cos(w * tt) / td - 1 / td)
    xd = static * (1 - math.cos(w * td) + math.sin(w * td) / (w * td) - 1)
    vd = static * (w * math.sin(w * td) + math.cos(w * td) / td - 1 / td)
    ta = t[~during] - td
    x[~during] = xd * np.cos(w * ta) + vd / w * np.sin(w * ta)
    v[~during] = -xd * w * np.sin(w * ta) + vd * np.cos(w * ta)
    return x, v


def _landing(speed: float, height: float) -> int:
    """GSA's condition (an index into CONDITIONS) of glass thrown level at `speed` from `height`
    above the floor: on the floor within 1 m (3a) or 3 m (3b), or striking a witness panel 3 m in
    at most 0.6 m up (4) or higher (5)."""
    if speed <= 0:
        return 2
    fall = math.sqrt(2.0 * height / G)
    reach = speed * fall
    if reach <= 1.0:
        return 2
    if reach <= WITNESS_DISTANCE_M:
        return 3
    at_witness = height - 0.5 * G * (WITNESS_DISTANCE_M / speed) ** 2
    return 4 if at_witness <= WITNESS_HEIGHT_M else 5


def glazing_condition(p: Pane, peak: float, impulse: float) -> int:
    """The pane's GSA condition (an index into CONDITIONS) under a triangular pulse."""
    glass = p.glass
    if glass.infill or peak <= 0:
        return 0
    duration = 2.0 * impulse / peak
    static = peak * p.area / p.stiffness
    period = 2 * math.pi / p.omega
    times = np.linspace(0.0, duration + 0.75 * period, 1500)
    x, v = elastic_triangular(p.omega, duration, static, times)
    crack = glass.strength / p.stress_per_m
    hit = np.nonzero(x >= crack)[0]
    if len(hit) == 0:
        return 0
    k = hit[0]
    tc, vc = float(times[k]), float(v[k])
    rest = 0.0 if tc >= duration else 0.5 * peak * (duration - tc) ** 2 / duration  # impulse left
    centre = SILL_M + 0.5 * p.height
    if glass.tension <= 0:
        # Monolithic glass flies at its speed plus what the rest of the impulse gives it.
        speed = vc + rest * p.area / p.mass
        return _landing(speed, centre)
    return _membrane(p, peak, duration, tc, vc, centre)


def membrane_system(p: Pane) -> tuple:
    """The cracked pane as a membrane: (total stiffness N/m, short span m). Its resistance is
    p = k T x / a^2 per unit area, k Poisson's factor for a uniformly tensioned rectangle (13.6
    square, 8 for a long strip), T the interlayer's or film's plateau tension; linear in x."""
    a, b = min(p.width, p.height), max(p.width, p.height)
    shape = 8.0 + 5.6 / (b / a) ** 2
    return shape * p.glass.tension / a**2 * p.area, a


def _membrane(p: Pane, peak: float, duration: float, tc: float, vc: float, centre: float) -> int:
    """After cracking, the membrane is a linear spring, so its response is Biggs's closed form for
    the load still to come plus free vibration from the speed at cracking, from rest at the
    crack's deflection taken as zero. It is held (GSA 2), or tears or pulls out and is thrown."""
    glass = p.glass
    stiffness, a = membrane_system(p)
    factor = sdof.load_mass_factor("simple", "uniform", "elastic")
    omega = math.sqrt(stiffness / (factor * p.mass))
    period = 2 * math.pi / omega
    left = max(duration - tc, 0.0)
    force = peak * p.area * (1.0 - tc / duration) if left > 0 else 0.0
    times = np.linspace(0.0, left + 0.75 * period, 2000)
    if left > 0:
        x, v = elastic_triangular(omega, left, force / stiffness, times)
    else:
        x, v = np.zeros_like(times), np.zeros_like(times)
    x = x + max(vc, 0.0) / omega * np.sin(omega * times)
    v = v + max(vc, 0.0) * np.cos(omega * times)
    strain = (8.0 / 3.0) * (x / a) ** 2
    gone = list(np.nonzero(strain >= glass.tear_strain)[0][:1])
    if glass.tension > glass.anchor:
        gone += list(np.nonzero(x >= 0.067 * a)[0][:1])
    if not gone:
        return 1
    return _landing(float(v[min(gone)]), centre)


# Walls

@dataclass(frozen=True)
class Wall:
    """A wall a metre wide spanning a storey: mass per area (kg/m^2), flexural rigidity (N m^2 per
    m), plastic moment (N m per m); `cost` per square metre as a change."""
    name: str
    mass: float
    ei: float
    mp: float
    cost: float = 0.0


WALLS = {
    # 0.215 m unreinforced brick: f_t t^2 / 6 at 0.4 MPa, E 5 GPa; no arching.
    "brick": Wall("brick", 1900 * 0.215, 5e9 * 0.215**3 / 12, 0.4e6 * 0.215**2 / 6),
    # The brick with a catcher or a sprayed or bonded retrofit, taken as three times as strong.
    "brick, retrofitted": Wall("brick, retrofitted", 1900 * 0.215 + 20, 5e9 * 0.215**3 / 12,
                               3 * 0.4e6 * 0.215**2 / 6, cost=1.5),
    # 0.2 m reinforced concrete, 0.3% in one mat at 0.16 m, 500 MPa bars at 1.17 dynamic; half
    # the gross section's stiffness.
    "concrete": Wall("concrete", 2400 * 0.2, 0.5 * 30e9 * 0.2**3 / 12,
                     0.003 * 0.16 * 1.17 * 500e6 * 0.9 * 0.16, cost=4.0),
}
STOREY_M = 3.0


@lru_cache(maxsize=None)
def _wall_member(wall: Wall):
    return sdof.beam(STOREY_M, wall.mass, wall.ei, "simple", "uniform", wall.mp)


def wall_level(wall: Wall, peak: float, impulse: float) -> int:
    """The wall's damage level (an index into WALL_LEVELS) by its support rotation."""
    if peak <= 0:
        return 0
    member = _wall_member(wall)
    duration = 2.0 * impulse / peak
    period = member.natural_period()
    pulse = sdof.triangular(peak * STOREY_M, duration)
    _, xs, _ = sdof.respond(member, pulse, until=duration + 0.75 * period, dt=period / 300)
    x = max(abs(min(xs)), max(xs))
    if x <= member.elastic_limit:
        return 0
    degrees = math.degrees(math.atan(2.0 * x / STOREY_M))
    for level, limit in ((1, 2.0), (2, 5.0), (3, 10.0)):
        if degrees <= limit:
            return level
    return 4


# Limits and chances

def _round(value: float, step: float = 0.01) -> float:
    return round(math.log(value) / step) * step if value > 0 else -math.inf


@lru_cache(maxsize=None)
def _glazing_limit(glazing: str, width: float, height: float, allowed: int, lp: float, li: float):
    if GLAZINGS[glazing].infill:
        return 50.0
    p = pane(width, height, GLAZINGS[glazing])
    return _bisect(lambda m: glazing_condition(p, m * math.exp(lp), m * math.exp(li)) > allowed)


@lru_cache(maxsize=None)
def _wall_limit(wall: str, allowed: int, lp: float, li: float):
    w = WALLS[wall]
    return _bisect(lambda m: wall_level(w, m * math.exp(lp), m * math.exp(li)) > allowed)


def _bisect(fails, low=0.02, high=50.0, steps=11) -> float:
    """The factor on the load at which `fails` first holds, in log steps; `high` if never and
    `low` if already."""
    if not fails(high):
        return high
    if fails(low):
        return low
    lo, hi = math.log(low), math.log(high)
    for _ in range(steps):
        mid = 0.5 * (lo + hi)
        if fails(math.exp(mid)):
            hi = mid
        else:
            lo = mid
    return math.exp(hi)


def limit_multiplier(side: Side, glazing: str, wall: str, load: Load, allowed_glass: int,
                     allowed_wall: int) -> float:
    """The factor on this load's peak and impulse at which the side first passes its allowed glass
    condition or wall level, with `glazing` and `wall` in place. Loads are rounded to 1% in their
    logarithms so that the many façades share their responses."""
    if load.peak <= 0:
        return 50.0
    lp, li = _round(load.peak), _round(load.impulse)
    width, height = side.building.pane
    g = 50.0 if side.panes == 0 else _glazing_limit(glazing, width, height, allowed_glass, lp, li)
    w = _wall_limit(wall, allowed_wall, lp, li)
    return min(g, w)


def exceedance(multiplier: float, scatter: float) -> float:
    """The chance that a lognormal factor of median 1 and logarithmic standard deviation `scatter`
    on the load reaches `multiplier`."""
    if scatter <= 0:
        return 1.0 if multiplier <= 1.0 else 0.0
    return 0.5 * math.erfc(math.log(multiplier) / (scatter * math.sqrt(2.0)))
