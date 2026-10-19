"""BombCAD's blast gauges against the independent references, by scaled distance.

    python3 Scripts/reference/compare.py PATH... [--mass KG] [--burst surface|free]
                                         [--oracle blast1d.json] [--json OUT]
    python3 Scripts/reference/compare.py --self-test

Each PATH is one of the outputs `blastbench` and `scenebench` write, recognised by its contents:

- a folder of `blastbench validate --histories DIR` CSVs (`validate-[tag-]dx<cell>-Z=<z>.csv`,
  `time_ms,overpressure_pa`), from which peak, positive impulse and arrival (half the peak) are
  worked out here; `--mass` gives the charge (validate's default, 100 kg) and `--tag` picks one
  tag where a folder holds several;
- `blastbench groundmotion --out DIR` JSON (`runs[].air`, a surface burst, `mass_kg` in the file);
- `scenebench street` or `scenebench envelopes` `report.json`: its runs on the open layout, the
  charge and gauges taken from the `<layout>-layout.json` beside it (a burst 1 m up, compared as a
  surface burst at the slant range; the impulse there is the whole window's positive part);
- `scenebench envelope-openings --out` JSON (incident peaks at 28 m, in psi);
- `scenebench district-compare` `comparison.json` (its `line` peaks and `arrivals`);
- the gauges format this folder defines for anything else: `{"mass_kg": W, "burst": "surface" |
  "free", "gauges": [{"z" or "range_m", "peak_pa", "impulse_pa_s", "arrival_s"}...]}` (any of the
  three values may be missing or null), which `blast1d.py --json` also writes.

For each gauge it prints the ratio of BombCAD's peak overpressure, positive impulse and arrival to
Kingery–Bulmash's (hemispherical surface burst, or free air as a surface burst of W / 1.8), and,
with `--oracle`, to the one-dimensional solution's at the same scaled distance (log-log
interpolated; free air, so for a surface burst it is read at Z / 2^(1/3), BombCAD's own doubling of
a charge on rigid ground). Kingery–Bulmash is used from 0.0674 to 40 m/kg^(1/3); outside, "-".
"""

import argparse
import csv
import glob
import gzip
import json
import math
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import kingery_bulmash as kb  # noqa: E402

TABLES = os.path.join(HERE, "tables")
PSI = 6894.757
P0 = 101325.0


class Gauge:
    def __init__(self, source, name, z, peak=None, impulse=None, arrival=None, note=""):
        self.source, self.name, self.z = source, name, z
        self.peak, self.impulse, self.arrival, self.note = peak, impulse, arrival, note


def _load(path):
    with (gzip.open if path.endswith(".gz") else open)(path, "rt") as f:
        return json.load(f)


def _num(x):
    return None if x is None or (isinstance(x, float) and math.isnan(x)) else float(x)


# ---- Readers ---------------------------------------------------------------------------------

def history_measures(t, p):
    """Peak overpressure, positive impulse and arrival of one history (s, Pa): the arrival where it
    first reaches half the peak (as blastbench validate takes it), the impulse over the positive
    phase about the peak, between its zero crossings (linearly interpolated)."""
    t, p = np.asarray(t, float), np.asarray(p, float)
    if len(p) == 0 or p.max() <= 0:
        return None, None, None
    k = int(p.argmax())
    peak = float(p[k])
    arrival = float(t[int(np.nonzero(p >= 0.5 * peak)[0][0])])
    start = k
    while start > 0 and p[start - 1] > 0:
        start -= 1
    end = k
    while end < len(p) - 1 and p[end + 1] > 0:
        end += 1
    impulse = float(np.sum(0.5 * (p[start + 1:end + 1] + p[start:end]) * np.diff(t[start:end + 1])))
    # The partial intervals into and out of the positive phase, to where it crosses zero.
    for i, j in ((start - 1, start), (end + 1, end)):
        if 0 <= i < len(p):
            frac = p[j] / (p[j] - p[i])
            impulse += 0.5 * p[j] * frac * abs(t[j] - t[i])
    return peak, impulse, arrival


def read_validate_histories(folder, mass, tag=None):
    pattern = re.compile(r"validate-(?:(?P<tag>.+)-)?dx(?P<dx>[0-9.]+)-Z=(?P<z>[0-9.]+)\.csv$")
    gauges = []
    for path in sorted(glob.glob(os.path.join(folder, "validate-*.csv"))):
        m = pattern.search(os.path.basename(path))
        if not m or (tag is not None and m.group("tag") != tag):
            continue
        with open(path) as f:
            rows = list(csv.reader(f))[1:]
        t = [float(r[0]) * 1e-3 for r in rows if r]
        p = [float(r[1]) for r in rows if r]
        peak, impulse, arrival = history_measures(t, p)
        w3 = mass ** (1 / 3)
        gauges.append(Gauge(f"validate dx {m.group('dx')} m" + (f" {m.group('tag')}" if m.group("tag") else ""),
                            f"Z = {m.group('z')}", float(m.group("z")), peak,
                            None if impulse is None else impulse, arrival))
    return gauges, "surface", mass


def read_groundmotion(doc, path):
    mass = float(doc["mass_kg"])
    w3 = mass ** (1 / 3)
    gauges = []
    for run in doc.get("runs", []):
        for name, g in (run.get("air") or {}).items():
            m = re.match(r"gauge ([0-9.]+) m", name)
            if not m or not isinstance(g, dict):
                continue
            gauges.append(Gauge(f"groundmotion dx {run.get('dx')} m", name, float(m.group(1)) / w3,
                                _num(g.get("peak_pa")), _num(g.get("impulse_pa_s")), _num(g.get("arrival_s"))))
    return gauges, "surface", mass


def read_street_report(doc, path):
    folder = os.path.dirname(path)
    gauges, mass = [], None
    for run in doc.get("observations", []):
        if run.get("layout") != "open":
            continue
        layout_path = os.path.join(folder, f"{run['layout']}-layout.json")
        if not os.path.exists(layout_path):
            print(f"note: {layout_path} not found; skipping {run.get('id')}", file=sys.stderr)
            continue
        layout = _load(layout_path)
        charge = np.array(layout["charge"]["position"], float)
        mass = float(layout["charge"]["mass"])
        w3 = mass ** (1 / 3)
        for g in run.get("gaugeObservations", []):
            r = float(np.linalg.norm(np.array(g["positionM"], float) - charge))
            gauges.append(Gauge(f"{run['id']} dx {run.get('cellSizeM')} m", g["name"], r / w3,
                                _num(g.get("peakPa")), _num(g.get("positiveImpulsePaS")), _num(g.get("arrivalS")),
                                note="burst 1 m up; impulse over the whole window; arrival at 1 kPa"))
    return gauges, "surface", mass


def read_envelope_openings(doc, path):
    gauges = []
    for case in doc:
        mass = float(case["chargeKg"])
        r = math.hypot(28.0, 0.5)  # charge (6, 14, 1), gauge (34, 14, 1.5): EnvelopeOpeningsBenchmark
        gauges.append(Gauge(f"envelope-openings {case.get('targetPsi')} psi", "front wall, no building",
                            r / mass ** (1 / 3), case["incidentPsi"] * PSI, note=f"{mass:g} kg"))
    return gauges, "surface", None


def read_district(doc, path):
    mass = float(doc["massKg"])
    w3 = mass ** (1 / 3)
    gauges = [Gauge("district line", f"line {p['distanceM']:g} m", p["distanceM"] / w3, _num(p.get("peakPa")))
              for p in doc.get("line", [])]
    gauges += [Gauge("district arrivals", a["name"], a["distanceM"] / w3, _num(a.get("peakPa")), None,
                     _num(a.get("simulatedS")), note="arrival 500 Pa above the first sample")
               for a in doc.get("arrivals", [])]
    return gauges, "surface", mass


def read_gauges_format(doc, path):
    mass = float(doc["mass_kg"])
    w3 = mass ** (1 / 3)
    gauges = []
    for i, g in enumerate(doc["gauges"]):
        z = float(g["z"]) if g.get("z") is not None else float(g["range_m"]) / w3
        # Values may be given scaled (per kg^(1/3)) when "scaled" is true, as blast1d.py writes.
        s = w3 if doc.get("scaled") else 1.0
        gauges.append(Gauge(doc.get("source", os.path.basename(path)), g.get("name", f"Z = {z:g}"), z,
                            _num(g.get("peak_pa", g.get("peak_overpressure"))),
                            None if g.get("impulse_pa_s", g.get("impulse")) is None else float(g.get("impulse_pa_s", g.get("impulse"))) * s,
                            None if g.get("arrival_s", g.get("arrival_time")) is None else float(g.get("arrival_s", g.get("arrival_time"))) * s))
    return gauges, doc.get("burst", "surface"), mass


def read(path, mass=None, tag=None):
    """Gauges from one output, its burst type and charge mass."""
    if os.path.isdir(path):
        return read_validate_histories(path, mass or 100.0, tag)
    doc = _load(path)
    if isinstance(doc, list) and doc and "incidentPsi" in doc[0]:
        return read_envelope_openings(doc, path)
    if isinstance(doc, dict):
        if "runs" in doc and "mass_kg" in doc:
            return read_groundmotion(doc, path)
        if "observations" in doc:
            return read_street_report(doc, path)
        if "line" in doc and "massKg" in doc:
            return read_district(doc, path)
        if "gauges" in doc and "mass_kg" in doc:
            return read_gauges_format(doc, path)
        if "gauges" in doc and "charge" in doc and "mass" in doc:  # blast1d.py --json
            d = dict(mass_kg=doc["mass"], burst="free", scaled=True, source=f"blast1d {doc['charge']}",
                     gauges=doc["gauges"])
            return read_gauges_format(d, path)
    raise ValueError(f"{path}: not an output this script knows")


# ---- References ------------------------------------------------------------------------------

class Oracle:
    """The one-dimensional solution's free-air gauges (blast1d.py --json), interpolated in log-log
    by scaled distance."""

    def __init__(self, path):
        doc = _load(path)
        g = sorted(doc["gauges"], key=lambda g: g["z"])
        self.z = np.array([x["z"] for x in g])
        self.values = {k: np.array([x[k] for x in g]) for k in ("peak_overpressure", "impulse", "arrival_time")}
        self.label = f"1-D {doc['charge']}"

    def at(self, z, burst):
        if burst == "surface":
            z = z / 2.0 ** (1 / 3)  # a charge on rigid ground as one of twice the mass in free air
            factor = 2.0 ** (1 / 3)
        else:
            factor = 1.0
        if not self.z[0] <= z <= self.z[-1]:
            return None
        out = {}
        for k, v in self.values.items():
            val = float(np.exp(np.interp(np.log(z), np.log(self.z), np.log(np.maximum(v, 1e-30)))))
            out[k] = val * factor if k != "peak_overpressure" else val
        return out


def reference(z, burst):
    p = kb.parameters(z, burst)
    return p["incident_pressure"], p["incident_impulse"], p["arrival_time"]


def ratios(gauges, burst, mass, oracle=None):
    rows = []
    for g in gauges:
        w3 = (mass ** (1 / 3)) if mass else None
        ps, i_s, ta = reference(g.z, burst)
        row = dict(source=g.source, name=g.name, z=g.z, note=g.note,
                   peak=g.peak, impulse=g.impulse, arrival=g.arrival,
                   peak_kb=None if math.isnan(ps) else ps,
                   peak_ratio=None, impulse_ratio=None, arrival_ratio=None,
                   peak_1d=None, impulse_1d=None, arrival_1d=None)
        if g.peak is not None and not math.isnan(ps):
            row["peak_ratio"] = g.peak / ps
        if w3 and g.impulse is not None and not math.isnan(i_s):
            row["impulse_ratio"] = g.impulse / (i_s * w3)
        if w3 and g.arrival is not None and not math.isnan(ta):
            row["arrival_ratio"] = g.arrival / (ta * w3)
        if oracle:
            o = oracle.at(g.z, burst)
            if o:
                if g.peak is not None:
                    row["peak_1d"] = g.peak / o["peak_overpressure"]
                if w3 and g.impulse is not None:
                    row["impulse_1d"] = g.impulse / (o["impulse"] * w3)
                if w3 and g.arrival is not None:
                    row["arrival_1d"] = g.arrival / (o["arrival_time"] * w3)
        rows.append(row)
    return rows


def _f(x, fmt="{:.3f}"):
    return "-" if x is None else fmt.format(x)


def print_rows(rows, burst, mass, oracle=None):
    kind = "hemispherical surface burst" if burst == "surface" else "free-air burst (surface burst of W/1.8)"
    print(f"Against Kingery-Bulmash, {kind}" + (f", {mass:g} kg" if mass else "") +
          (f"; and {oracle.label}" if oracle else ""))
    head = f"{'source':<28} {'gauge':<18} {'Z':>6} {'peak kPa':>9} {'peak/KB':>8} {'imp/KB':>7} {'arr/KB':>7}"
    if oracle:
        head += f" {'peak/1D':>8} {'imp/1D':>7} {'arr/1D':>7}"
    print(head)
    for r in sorted(rows, key=lambda r: (r["source"], r["z"])):
        line = (f"{r['source'][:28]:<28} {r['name'][:18]:<18} {r['z']:>6.3g} {_f(r['peak'] and r['peak'] / 1e3, '{:.4g}'):>9} "
                f"{_f(r['peak_ratio']):>8} {_f(r['impulse_ratio']):>7} {_f(r['arrival_ratio']):>7}")
        if oracle:
            line += f" {_f(r['peak_1d']):>8} {_f(r['impulse_1d']):>7} {_f(r['arrival_1d']):>7}"
        print(line)
    notes = sorted({r["note"] for r in rows if r["note"]})
    for n in notes:
        print(f"  note: {n}")


# ---- Self-test -------------------------------------------------------------------------------

def self_test():
    """Checks on the bundled tables alone; returns the number of failures."""
    failures = 0

    def check(ok, what):
        nonlocal failures
        print(("ok    " if ok else "FAIL  ") + what)
        failures += 0 if ok else 1

    iatg = _load(os.path.join(TABLES, "iatg-01.80-table5.json"))
    for row in iatg["rows"]:
        a = kb.at(row["range_m"], row["mass_kg"])
        for key, unit, ref in (("incident_pressure", 1e5, "incident_bar"), ("reflected_pressure", 1e5, "reflected_bar"),
                               ("incident_impulse", 100.0, "incident_impulse_bar_ms"),
                               ("reflected_impulse", 100.0, "reflected_impulse_bar_ms"),
                               ("arrival_time", 1e-3, "arrival_ms")):
            r = a[key] / (row[ref] * unit)
            check(abs(r - 1) < 0.01, f"Kingery-Bulmash {key} at {row['mass_kg']:g} kg, 50 m: {r:.4f} of IATG 01.80")

    oracle_path = os.path.join(TABLES, "blast1d-tnt.json")
    oracle = Oracle(oracle_path)
    doc = _load(oracle_path)
    for g in doc["gauges"]:
        if 2.0 <= g["z"] <= 6.0:
            k = kb.free_air(g["z"])
            check(0.85 < g["peak_overpressure"] / k["incident_pressure"] < 1.10,
                  f"bundled 1-D TNT peak at Z {g['z']:g}: {g['peak_overpressure'] / k['incident_pressure']:.3f} of KB free air")
            check(abs(g["arrival_time"] / k["arrival_time"] - 1) < 0.03,
                  f"bundled 1-D TNT arrival at Z {g['z']:g}: {g['arrival_time'] / k['arrival_time']:.3f} of KB free air")

    # Each reader on a made-up output holding Kingery-Bulmash's own values: every ratio 1.
    import tempfile
    mass = 100.0
    w3 = mass ** (1 / 3)
    zs = [1.0, 2.0, 4.0]
    with tempfile.TemporaryDirectory() as tmp:
        for z in zs:
            p = kb.hemispherical(z)
            ta, peak, td = p["arrival_time"] * w3, p["incident_pressure"], p["positive_duration"] * w3
            # A triangular pulse with K-B's peak and impulse, sampled finely.
            dur = 2 * p["incident_impulse"] * w3 / peak
            t = np.linspace(0, ta + 3 * dur, 30001)
            pr = np.where((t >= ta) & (t <= ta + dur), peak * (1 - (t - ta) / dur), 0.0)
            with open(os.path.join(tmp, f"validate-dx0.25-Z={z:g}.csv"), "w") as f:
                f.write("time_ms,overpressure_pa\n" + "\n".join(f"{a * 1e3},{b}" for a, b in zip(t, pr)))
        gm = {"mass_kg": mass, "runs": [{"dx": 0.5, "air": {f"gauge {z * w3:.6f} m": {
            "peak_pa": kb.hemispherical(z)["incident_pressure"],
            "impulse_pa_s": kb.hemispherical(z)["incident_impulse"] * w3,
            "arrival_s": kb.hemispherical(z)["arrival_time"] * w3} for z in zs}}]}
        with open(os.path.join(tmp, "gm.json"), "w") as f:
            json.dump(gm, f)
        for path in (tmp, os.path.join(tmp, "gm.json")):
            gauges, burst, m = read(path, mass)
            rows = ratios(gauges, burst, m, oracle)
            worst = max(abs(r[k] - 1) for r in rows for k in ("peak_ratio", "impulse_ratio", "arrival_ratio"))
            check(len(rows) == 3 and worst < 0.01,
                  f"reader {'validate histories' if os.path.isdir(path) else 'groundmotion'}: {len(rows)} gauges, "
                  f"ratios within {worst:.4f} of 1")
    print(f"{failures} failed")
    return failures


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--mass", type=float, help="charge, kg, for validate histories (default 100)")
    ap.add_argument("--tag", help="validate histories' tag")
    ap.add_argument("--burst", choices=["surface", "free"], help="override the burst type")
    ap.add_argument("--oracle", help="a blast1d.py --json solution (default the bundled TNT one)",
                    nargs="?", const=os.path.join(TABLES, "blast1d-tnt.json"))
    ap.add_argument("--json", help="write the ratios here")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args(argv)
    if a.self_test:
        return 1 if self_test() else 0
    if not a.paths:
        ap.error("give one or more outputs, or --self-test")
    oracle = Oracle(a.oracle) if a.oracle else None
    out = []
    for path in a.paths:
        gauges, burst, mass = read(path, a.mass, a.tag)
        burst = a.burst or burst
        if mass is None:
            mass = a.mass
        rows = ratios(gauges, burst, mass, oracle)
        print(f"== {path}")
        print_rows(rows, burst, mass, oracle)
        print()
        out += rows
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
