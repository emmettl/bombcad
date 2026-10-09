#!/usr/bin/env python3
"""Validate retained runs and report sensitivity without asserting convergence."""
import argparse
import gzip
import json
import math
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(gzip.decompress(path.read_bytes()) if path.suffix == ".gz" else path.read_text())


def compare_maps(a, b, excluded=None):
    """Compare fixed physical probes; retain common fluid stencils only."""
    ratio = round(a["cellSizeM"] / b["cellSizeM"])
    require(ratio >= 1 and a["nx"] * ratio == b["nx"] and a["ny"] * ratio == b["ny"], "nested maps")
    sums = {key: [0.0, 0.0] for key in ("peakPa", "positiveImpulsePaS")}
    arrival_errors = []
    mismatches = 0
    count = 0
    for j in range(a["ny"]):
        for i in range(a["nx"]):
            # Exclude source deposition/near-source cells from the far-field comparison.
            x, y = (i + 0.5) * a["cellSizeM"], (j + 0.5) * a["cellSizeM"]
            if math.hypot(x - 8, y - 16) < 3 or x < 1 or y < 1 or x > 39 or y > 31:
                continue
            index = i + j * a["nx"]
            indices = [i * ratio + di + b["nx"] * (j * ratio + dj)
                       for dj in range(ratio) for di in range(ratio)]
            if (excluded is not None and excluded[index]) or a["everSolid"][index] or any(b["everSolid"][n] for n in indices):
                continue
            count += 1
            for key, totals in sums.items():
                reference = sum(b[key][n] for n in indices) / len(indices)
                totals[0] += abs(a[key][index] - reference)
                totals[1] += abs(reference)
            reached = [b["arrivalS"][n] for n in indices]
            if a["arrivalS"][index] is not None and all(t is not None for t in reached):
                arrival_errors.append(abs(a["arrivalS"][index] - sum(reached) / len(reached)))
            elif (a["arrivalS"][index] is None) != all(t is None for t in reached):
                mismatches += 1
    require(count > 0, "no common fluid samples")
    return {
        "commonFluidSamples": count,
        "peakRelativeL1": sums["peakPa"][0] / max(sums["peakPa"][1], 1e-20),
        "impulseRelativeL1": sums["positiveImpulsePaS"][0] / max(sums["positiveImpulsePaS"][1], 1e-20),
        "arrivalCommonReachedSamples": len(arrival_errors),
        "arrivalMeanAbsoluteErrorS": sum(arrival_errors) / len(arrival_errors) if arrival_errors else None,
        "arrivalReachClassificationDifferences": mismatches,
    }


def check(directory):
    report = read(directory / "report.json")
    require(report["schemaVersion"] == 1, "schema")
    runs = {r["id"]: r for r in report["observations"]}
    require(len(runs) == len(report["observations"]), "duplicate run IDs")
    maps = {}
    for name, run in runs.items():
        require(run["stable"] and run["steps"] > 0, f"{name}: failed run")
        expected_time = 0.06 if run["purpose"] == "closed-conservation" else report["durationS"]
        require(abs(run["durationS"] - expected_time) < 1e-7, f"{name}: time cutoff")
        require(abs(run["sourceRadiusM"] - 1) < 1e-6, f"{name}: changed source radius")
        require(run["refinementPatchCapacity"] >= run["maximumRefinedPatches"], f"{name}: refinement capacity")
        require(run["reflectiveFaces"] == (63 if run["purpose"] == "closed-conservation" else 16), f"{name}: boundaries")
        require(run["sourceMassKg"] == (0 if run["purpose"] == "gravity-control" else 2), f"{name}: source")
        for key in ("setupWallS", "runWallS", "commandGPUS", "solverBytes", "massInitialKg", "massFinalKg", "energyInitialJ", "energyFinalJ"):
            require(math.isfinite(run[key]) and run[key] > 0, f"{name}: {key}")
        plane = read(directory / run["mapFile"])
        maps[name] = plane
        count = plane["nx"] * plane["ny"]
        require(plane["nx"] * plane["cellSizeM"] == 40 and plane["ny"] * plane["cellSizeM"] == 32, f"{name}: domain")
        require(plane["heightM"] == 1.5 and plane["thresholdPa"] == 1000, f"{name}: probes")
        require(plane["cellSizeM"] == 0.5 and plane["airCellSizeM"] == run["cellSizeM"], f"{name}: fixed probe spacing")
        require(abs(plane["elapsedS"] - run["durationS"]) < 1e-7, f"{name}: map cutoff")
        for key in ("peakPa", "positiveImpulsePaS", "arrivalS", "everSolid"):
            require(len(plane[key]) == count, f"{name}: {key} length")
        for n in range(count):
            peak, impulse, arrival = (plane[key][n] for key in ("peakPa", "positiveImpulsePaS", "arrivalS"))
            if plane["everSolid"][n]:
                require(peak is None and impulse is None and arrival is None, f"{name}: solid nulls")
            else:
                require(peak is not None and impulse is not None and math.isfinite(peak) and math.isfinite(impulse) and peak >= 0 and impulse >= 0, f"{name}: fluid values")
                require((arrival is None) == (peak < 1000), f"{name}: arrival/peak disagreement")
                require(arrival is None or 0 <= arrival <= run["durationS"] + 1e-7, f"{name}: arrival time")
        owners = [body["id"] for body in run["bodies"]]
        require(len(set(owners)) == len(owners), f"{name}: owners")
        require(len(owners) == {"open": 0, "isolated": 1, "pair": 2, "street": 4}[run["layout"]], f"{name}: missing body")
        for body in run["bodies"]:
            samples = body["samples"]
            require(samples and abs(samples[-1]["timeS"] - run["durationS"]) < 1e-7, f"{name}: body cutoff")
            require(all(b["timeS"] >= a["timeS"] for a, b in zip(samples, samples[1:])), f"{name}: body clock")
            require(all(math.isfinite(s["displacementM"]) and s["displacementM"] >= 0 and 0 <= s["damage"] <= 1 and s["removedElements"] == 0 for s in samples), f"{name}: body response")
        require(len(run["gaugeObservations"]) == 4, f"{name}: gauges")
        for gauge in run["gaugeObservations"]:
            samples = gauge["samples"]
            require(samples and abs(samples[-1][0] - run["durationS"]) < 1e-7, f"{name}: gauge cutoff")
            require(all(b[0] > a[0] for a, b in zip(samples, samples[1:])), f"{name}: gauge clock")
            require(abs(gauge["peakPa"] - max(0, max(s[1] for s in samples))) < 0.1, f"{name}: gauge peak")
    summary = {"schemaVersion": 1, "sourceRevision": report["sourceRevision"], "comparisons": [], "conservation": []}
    if report["completeMatrix"]:
        require(len(runs) == 24, "expected eighteen comparisons, three closed checks, open/gravity controls and profile")
        require(len(report["sourceRevision"]) == 40 and all(c in "0123456789abcdef" for c in report["sourceRevision"]), "source revision")
        for layout in ("isolated", "pair", "street"):
            layout_maps = [maps[f"{layout}-{setting}"] for setting in ("coarse", "medium", "fine", "finest", "adaptive", "half-cfl")]
            excluded = [any(plane["everSolid"][n] for plane in layout_maps) for n in range(len(layout_maps[0]["everSolid"]))]
            for setting in ("coarse", "medium", "fine", "adaptive", "half-cfl"):
                reference = f"{layout}-fine" if setting == "half-cfl" else f"{layout}-finest"
                name = f"{layout}-{setting}"
                require(name in runs and reference in runs, "missing comparison")
                require([b["id"] for b in runs[name]["bodies"]] == [b["id"] for b in runs[reference]["bodies"]], "owner changes")
                summary["comparisons"].append({"run": name, "reference": reference, **compare_maps(maps[name], maps[reference], excluded)})
        summary["comparisonMask"] = "Per layout, exclude every probe whose stencil touched solid in any setting; also exclude source radius 3 m and edge margin 1 m."
        require("open-control" in runs and runs["open-control"]["cellSizeM"] == 0.125, "open-ground reference")
        for name in ("closed-coarse", "closed-medium", "closed-fine"):
            run = runs[name]
            mass = abs(run["massFinalKg"] / run["massInitialKg"] - 1)
            energy = abs(run["energyFinalJ"] / run["energyInitialJ"] - 1)
            source_mass = abs(run["massFinalKg"] - run["massInitialKg"]) / run["sourceMassKg"]
            source_energy = abs(run["energyFinalJ"] - run["energyInitialJ"]) / run["sourceEnergyJ"]
            require(mass < 0.003 and energy < 0.003 and source_mass < 0.003 and source_energy < 0.003,
                    f"{name}: stationary closed conservation > 0.3%")
            summary["conservation"].append({"run": name, "massRelativeResidual": mass, "energyRelativeResidual": energy,
                                            "massErrorPerSourceMass": source_mass, "energyErrorPerSourceEnergy": source_energy})
        profile = runs["profiled-street"]
        require(profile.get("profile") and all(v > 0 for v in profile["profile"].values()), "profile counters")
        require(sum(profile["profile"].values()) <= profile["commandGPUS"] * 1.05, "profile exceeds GPU command intervals")
        for key in ("peakPa", "positiveImpulsePaS", "everSolid", "arrivalS"):
            require(maps["street-finest"][key] == maps["profiled-street"][key], f"profiling changed {key}")
        require(all(s["removedElements"] == 0 for b in runs["gravity-control"]["bodies"] for s in b["samples"]), "gravity control failed")
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()
    result = check(args.directory)
    if args.summary:
        args.summary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"Street report verified; {len(result['comparisons'])} sensitivity comparisons, {len(result['conservation'])} closed checks.")
