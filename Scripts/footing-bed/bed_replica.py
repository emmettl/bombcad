#!/usr/bin/env python3
"""A quasi-static replica of the footing bed's cyclic sand (`footingStep` in Footing.metal, the
bed of `FootingBed`), for trying laws on it in seconds rather than GPU runs in minutes: a rigid
footing turned through a rotation history, its height solved each step so that the bed carries
the weight, each point following the GPU's law. Driven by SSG02_03's measured rotation (the slow
FoRCy test, `FootingRockingTest`) on its 40 MPa bed it gives the GPU's moments within about 4%
and its settlement within 5% from packet c (19 October 2026); it leaves out the footing's mass,
sliding and the wall's own deformation.

    python3 Scripts/footing-bed/bed_replica.py [--bed 40|80] [--heave 0.7 | --heave-raw 0.8]
        [--memory 0] [--spread 1.4,0.5 [--conserve]]

`bed-40mpa.csv` and `bed-80mpa.csv` are `FootingBed(width: 2.8, length: 0.65, soil:)` on sand of
40 and 80 MPa (Poisson's ratio 0.3, 1,657 kg/m³): each point's place, area and stiffness on first
loading. `--spread lam,beta` tries one law the GPU lacks, the toe's crushing spreading inwards:
each point's crushing in a step lowers the points within `lam` m of it along the footing by
`beta` of it, triangle-weighted (`--conserve`: taken from the point itself, keeping volume).
It raised the energy and the settlement together (docs/validation.md, "A footing shaken on dry
sand").
"""
import argparse
import csv
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


class Bed:
    """The bed under one footing, its points' state as the GPU keeps it."""

    def __init__(self, path, capacity=814e3, elastic_share=0.12, memory=0.0, heave=0.7, weight=285e3,
                 spread=None, conserve=False, heave_raw=None):
        rows = list(csv.DictReader(open(path)))
        self.x = np.array([float(r["x"]) for r in rows])
        self.y = np.array([float(r["y"]) for r in rows])
        area = np.array([float(r["area"]) for r in rows])
        # The GPU's stiffness is the unloading one, the bed's over the elastic share.
        self.k = np.array([float(r["k"]) for r in rows]) / elastic_share
        self.es = elastic_share
        self.cap = capacity * area
        self.memory = memory
        safety = capacity / (weight / area.sum())
        # Gajan's heave by 1 - 1/FS, as `FootingSystem` sets it, unless given raw.
        self.heave = heave * max(1 - 1 / safety, 0) if heave_raw is None else heave_raw
        self.weight = weight
        n = len(self.x)
        self.sz = np.zeros(n)  # the point's surface, m, negative down
        self.sw = np.zeros(n)  # the most force it has borne; < 0 once lifted off
        self.land = np.zeros(n)  # its surface where it last landed
        self.clear = np.zeros(n, dtype=bool)  # lifted clear since
        self.spread = spread
        if spread:
            lam, beta = spread
            d = np.abs(self.x[:, None] - self.x[None, :])
            same = np.abs(self.y[:, None] - self.y[None, :]) < 1e-6
            w = np.where(same & (d > 1e-9) & (d < lam), 1 - d / lam, 0.0)
            sums = w.sum(axis=1, keepdims=True)
            self.share = np.where(sums > 0, w / np.maximum(sums, 1e-30), 0.0) * beta
            self.kept = 1 - self.share.sum(axis=1) if conserve else np.ones(n)

    def step(self, w, theta, commit):
        """The bed's vertical force and moment with the base centre at `w` (up), turned by `theta`
        (lifting +x); keeps the state if `commit`."""
        disp = w + theta * self.x
        sz, sw, land, clear = self.sz.copy(), self.sw.copy(), self.land.copy(), self.clear.copy()
        k = self.k
        opening = disp - sz
        contact = opening < 0
        push = np.where(contact, -k * opening, 0.0)
        relanded = contact & clear
        land = np.where(relanded, sz, land)
        clear = np.where(relanded, False, clear)
        borne = np.where(sw < 0, -sw * self.memory, sw)
        loading = contact & (push > borne)
        force = borne + self.es * (push - borne)
        before = sz.copy()
        sz = np.where(loading, disp + force / k, sz)
        push = np.where(loading, force, push)
        sw = np.where(contact, np.where(push > borne, push, borne), sw)
        over = contact & (push > self.cap)
        sz = np.where(over, disp + self.cap / k, sz)
        push = np.where(over, self.cap, push)
        sw = np.where(over, self.cap, sw)
        lifted = ~contact
        sw = np.where(lifted & (sw > 0), -sw, sw)
        goes = lifted & ~clear & (sw < 0) & (opening > -sw / k)
        sz = np.where(goes, sz + self.heave * np.maximum(land - sz, 0), sz)
        sw = np.where(goes & (self.heave > 0), -0.0, sw)
        clear = np.where(goes, True, clear)
        if commit and self.spread:
            crushed = np.minimum(sz - before, 0)
            sz = sz - (1 - self.kept) * crushed + self.share.T @ crushed
        normal = np.where(contact, push, 0.0)
        if commit:
            self.sz, self.sw, self.land, self.clear = sz, sw, land, clear
        return normal.sum(), (normal * self.x).sum()

    def solve(self, theta, guess):
        """The base centre's height at which the bed carries the weight at `theta`; keeps it."""
        lo, hi = guess - 0.05, guess + 0.05
        for _ in range(60):
            mid = 0.5 * (lo + hi)
            if self.step(mid, theta, False)[0] > self.weight:
                lo = mid
            else:
                hi = mid
        w = 0.5 * (lo + hi)
        return w, self.step(w, theta, True)[1]


def rocking(bed, rotations, substeps=4):
    """Turns `bed` through `rotations`; (theta, moment, height) a sample."""
    out = []
    w = 0.0
    previous = 0.0
    for theta in rotations:
        for s in range(1, substeps + 1):
            w, m = bed.solve(previous + (theta - previous) * s / substeps, w)
        previous = theta
        out.append((theta, m, w))
    return np.array(out)


def packets(bed, path=os.path.join(ROOT, "Samples", "FoRCy", "ssg02_03.csv"), names="abcde"):
    """SSG02_03's packets on `bed`: per packet, the model's and the test's peak moments (2M/PL),
    settlement (/L) at its end and energy a cycle (10⁻³ P L / 2)."""
    rows = list(csv.DictReader(open(path)))
    L, P = 2.8, 285e3
    kept = [r for r in rows if r["packet"] in names]
    res = rocking(bed, np.array([float(r["rotation_rad"]) for r in kept]))
    out = []
    for name in names:
        idx = [i for i, r in enumerate(kept) if r["packet"] == name]
        th = res[idx, 0]
        m = -res[idx, 1] * 2 / (L * P)
        loop = abs(np.sum(0.5 * (m[1:] + m[:-1]) * np.diff(th))) / 3 * 1e3
        measured = [float(kept[i]["normalized_moment"]) for i in idx]
        out.append(dict(
            packet=name, moment=(m.max(), -m.min()), measured_moment=(max(measured), -min(measured)),
            settlement=-res[idx[-1], 2] / L, measured_settlement=float(kept[idx[-1]]["normalized_settlement"]),
            energy=loop))
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--bed", default="80", choices=["40", "80"])
    parser.add_argument("--heave", type=float, default=0.7)
    parser.add_argument("--heave-raw", type=float)
    parser.add_argument("--memory", type=float, default=0.0)
    parser.add_argument("--spread")
    parser.add_argument("--conserve", action="store_true")
    a = parser.parse_args()
    spread = tuple(float(v) for v in a.spread.split(",")) if a.spread else None
    bed = Bed(os.path.join(HERE, f"bed-{a.bed}mpa.csv"), heave=a.heave, heave_raw=a.heave_raw, memory=a.memory,
              spread=spread, conserve=a.conserve)
    print("packet  moment +/- (measured)          settlement / L (measured)  energy a cycle, 1e-3 PL/2")
    for p in packets(bed):
        print(f"  {p['packet']}     {p['moment'][0]:.3f}/{p['moment'][1]:.3f} ({p['measured_moment'][0]:.3f}/"
              f"{p['measured_moment'][1]:.3f})   {p['settlement']:.4f} ({p['measured_settlement']:.4f})"
              f"          {p['energy']:.2f}")


if __name__ == "__main__":
    main()
