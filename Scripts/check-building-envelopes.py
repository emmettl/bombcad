#!/usr/bin/env python3
"""Check stationary envelope comparisons and retain numerical differences, not validation claims."""
import argparse
import json
import math
import statistics
from pathlib import Path

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location("street_check", Path(__file__).with_name("check-street-interaction.py"))
street = module_from_spec(spec)
spec.loader.exec_module(street)
read, require = street.read, street.require


def relative(candidate, reference):
    return sum(abs(a - b) for a, b in zip(candidate, reference)) / max(sum(map(abs, reference)), 1e-20)


def key(face):
    return tuple(face["positionM"] + face["normal"])


def check(directory, diagnostic=False):
    report = read(directory / "report.json")
    require(report["schemaVersion"] == 1, "report schema")
    if not diagnostic:
        require(report.get("referenceElementKind") == "solid", "strict comparison requires matched solid-element reference geometry")
    runs = {r["id"]: r for r in report["observations"]}
    require(len(runs) == len(report["observations"]), "duplicate runs")
    expected = set()
    settings = ["medium", "fine", "finest", "adaptive"] if report["completeMatrix"] else ["medium"]
    for layout in ["isolated", "pair", "street"]:
        for mode in ["detailed", "envelope"]:
            expected.update(f"{layout}-{mode}-{setting}" for setting in settings)
    if report["completeMatrix"]:
        for mode in ["detailed", "envelope"]:
            expected.update(f"opened-{mode}-{setting}" for setting in ["medium", "fine"])
            expected.update([f"closed-{mode}", f"street-{mode}-half-cfl", f"profiled-{mode}", f"ordinary-{mode}"])
        for count in [1, 4, 16, 64]:
            for mode in (["envelope"] if count == 64 else ["detailed", "envelope"]):
                expected.update(f"scaling-{count}-{mode}-{i}" for i in range(3))
    require(set(runs) == expected, "incomplete or unexpected matrix")
    maps, surfaces, loads = {}, {}, {}
    for name, run in runs.items():
        require(run["stable"] and run["steps"] > 0, f"{name}: unstable/incomplete")
        duration = 0.06 if run["purpose"] in ["scaling", "conservation"] else 0.12 if report["completeMatrix"] else 0.012
        require(abs(run["durationS"] - duration) < 1e-7, f"{name}: cutoff")
        require(run["sourceMassKg"] == 2 and abs(run["sourceRadiusM"] - 1) < 1e-6, f"{name}: source")
        require(run["reflectiveFaces"] == (63 if run["purpose"] == "conservation" else 16), f"{name}: boundaries")
        require(run["maximumRefinedPatches"] <= run["refinementPatchCapacity"], f"{name}: refinement allocation")
        for field in ["setupWallS", "runWallS", "commandGPUS", "solverBytes", "massInitialKg", "energyInitialJ"]:
            require(math.isfinite(run[field]) and run[field] > 0, f"{name}: {field}")
        histories = read(directory / run["historiesFile"])
        require([dict(g, samples=[]) for g in histories["gaugeObservations"]] == run["gaugeObservations"], f"{name}: gauge metadata")
        require([dict(b, samples=[]) for b in histories["bodies"]] == run["bodies"], f"{name}: body metadata")
        for body in histories["bodies"]:
            require(body["samples"] and all(s["displacementM"] == 0 and s["removedElements"] == 0 for s in body["samples"]), f"{name}: reference moved/failed")
        require(not run["bodies"] if "envelope" in name else bool(run["bodies"]), f"{name}: representation")
        for gauge in histories["gaugeObservations"]:
            samples = gauge["samples"]
            require(samples and all(math.isfinite(v) for sample in samples for v in sample), f"{name}: gauge values")
            require(all(a[0] < b[0] for a, b in zip(samples, samples[1:])), f"{name}: gauge clock")
            require(abs(samples[-1][0] - duration) < 1e-7, f"{name}: gauge cutoff")
        plane = maps[name] = read(directory / run["mapFile"])
        require(plane["heightM"] == 1.5 and plane["cellSizeM"] == 0.5 and plane["thresholdPa"] == 1000, f"{name}: probe geometry")
        require(abs(plane["elapsedS"] - duration) < 1e-7, f"{name}: map cutoff")
        n = plane["nx"] * plane["ny"]
        require(all(len(plane[k]) == n for k in ["peakPa", "positiveImpulsePaS", "arrivalS", "everSolid"]), f"{name}: map dimensions")
        for i in range(n):
            values = [plane[k][i] for k in ["peakPa", "positiveImpulsePaS", "arrivalS"]]
            require(all(v is None for v in values) if plane["everSolid"][i] else all(v is not None and math.isfinite(v) and v >= 0 for v in values[:2]), f"{name}: map values/nulls")
            if values[2] is not None:
                require(0 <= values[2] <= duration + 1e-7 and values[0] >= 1000, f"{name}: arrival")
        observed = run["purpose"] not in ["scaling", "recorder-control"]
        require(bool(run.get("envelopeFile")) == observed and bool(run.get("loadsFile")) == observed, f"{name}: observer presence")
        if observed:
            surfaces[name] = read(directory / run["envelopeFile"])
            loads[name] = read(directory / run["loadsFile"])
            owners = [b["id"] for b in surfaces[name]]
            require(len(set(owners)) == len(owners) and owners == [b["id"] for b in loads[name]], f"{name}: owners")
            if "detailed" in name:
                require(owners == [b["id"] for b in run["bodies"]], f"{name}: reference owners")
            for building, history in zip(surfaces[name], loads[name]):
                require(building["surfaces"] and abs(building["elapsedS"] - duration) < 1e-7, f"{name}: surface cutoff")
                require(len({key(f) for f in building["surfaces"]}) == len(building["surfaces"]), f"{name}: duplicate faces")
                force, impulse = [0.0] * 3, [0.0] * 3
                for face in building["surfaces"]:
                    require(not face["invalid"] and abs(face["areaM2"] - run["cellSizeM"] ** 2) < 1e-8, f"{name}: invalid face")
                    require(sum(v * v for v in face["normal"]) == 1, f"{name}: normal")
                    require(all(math.isfinite(v) for field in ["positionM", "normal"] for v in face[field]), f"{name}: face geometry")
                    require(all(math.isfinite(face[k]) for k in ["overpressurePa", "peakPositivePa", "positiveImpulsePaS", "signedImpulsePaS"]), f"{name}: pressure")
                    require(face["peakPositivePa"] >= 0 and face["positiveImpulsePaS"] >= 0, f"{name}: positive exposure")
                    for axis in range(3):
                        force[axis] -= face["normal"][axis] * face["overpressurePa"] * face["areaM2"]
                        impulse[axis] -= face["normal"][axis] * face["signedImpulsePaS"] * face["areaM2"]
                samples = history["samples"]
                require(samples and all(a["timeS"] < b["timeS"] for a, b in zip(samples, samples[1:])), f"{name}: load clock")
                require(abs(samples[-1]["timeS"] - duration) < 1e-7, f"{name}: load cutoff")
                require(all(math.isfinite(v) for s in samples for k in ["forceN", "signedImpulseNS"] for v in s[k]), f"{name}: loads")
                require(max(abs(a - b) for a, b in zip(force, samples[-1]["forceN"])) < max(0.01, max(map(abs, force)) * 1e-6), f"{name}: force sum")
                require(max(abs(a - b) for a, b in zip(impulse, samples[-1]["signedImpulseNS"])) < max(1e-5, max(map(abs, impulse)) * 1e-6), f"{name}: impulse sum")

    comparisons = []
    for layout in ["isolated", "pair", "street", "opened"]:
        available = [s for s in settings if f"{layout}-detailed-{s}" in runs]
        mask = [any(maps[f"{layout}-{mode}-{s}"]["everSolid"][i] for s in available for mode in ["detailed", "envelope"])
                for i in range(maps[f"{layout}-detailed-{available[0]}"]["nx"] * maps[f"{layout}-detailed-{available[0]}"]["ny"])] if available else []
        for setting in available:
            reference, candidate = f"{layout}-detailed-{setting}", f"{layout}-envelope-{setting}"
            a, b = maps[candidate], maps[reference]
            metrics = street.compare_maps(a, b, excluded=mask)
            metrics["solidProbeClassificationDifferences"] = sum(x != y for x, y in zip(a["everSolid"], b["everSolid"]))
            matched, unmatched, peak_a, peak_b, impulse_a, impulse_b, signed_a, signed_b = 0, 0, [], [], [], [], [], []
            area_a, area_b, vector_difference, vector_reference = [], [], 0.0, 0.0
            require([o["id"] for o in surfaces[candidate]] == [o["id"] for o in surfaces[reference]], "changed owner IDs")
            for ca, rb in zip(surfaces[candidate], surfaces[reference]):
                area_a.append(sum(f["areaM2"] * f["positiveImpulsePaS"] for f in ca["surfaces"]))
                area_b.append(sum(f["areaM2"] * f["positiveImpulsePaS"] for f in rb["surfaces"]))
                vector_a = [-sum(f["areaM2"] * f["normal"][k] * f["signedImpulsePaS"] for f in ca["surfaces"]) for k in range(3)]
                vector_b = [-sum(f["areaM2"] * f["normal"][k] * f["signedImpulsePaS"] for f in rb["surfaces"]) for k in range(3)]
                vector_difference += math.dist(vector_a, vector_b)
                vector_reference += math.dist(vector_b, [0, 0, 0])
                c, r = {key(f): f for f in ca["surfaces"]}, {key(f): f for f in rb["surfaces"]}
                common = c.keys() & r.keys()
                matched += len(common)
                unmatched += len(c.keys() ^ r.keys())
                for p in common:
                    peak_a.append(c[p]["peakPositivePa"]); peak_b.append(r[p]["peakPositivePa"])
                    impulse_a.append(c[p]["positiveImpulsePaS"]); impulse_b.append(r[p]["positiveImpulsePaS"])
                    signed_a.append(c[p]["signedImpulsePaS"]); signed_b.append(r[p]["signedImpulsePaS"])
            require(matched > 0, "no matched faces")
            metrics.update(commonFaces=matched, unmatchedFaces=unmatched,
                fullSurfacePositiveLoadRelativeL1=relative(area_a, area_b),
                fullSurfaceVectorImpulseRelativeDifference=vector_difference / max(vector_reference, 1e-20),
                surfacePeakRelativeL1=relative(peak_a, peak_b), surfacePositiveImpulseRelativeL1=relative(impulse_a, impulse_b),
                surfaceSignedImpulseRelativeL1=relative(signed_a, signed_b))
            # Acceptance gates for the representation comparison, not physical accuracy.
            if not diagnostic:
                require(metrics["solidProbeClassificationDifferences"] == 0 and unmatched == 0, f"{candidate}: geometry mismatch")
                require(metrics["peakRelativeL1"] < 0.10 and metrics["impulseRelativeL1"] < 0.05
                    and metrics["surfacePeakRelativeL1"] < 0.10 and metrics["surfacePositiveImpulseRelativeL1"] < 0.05
                    and metrics["fullSurfacePositiveLoadRelativeL1"] < 0.05 and metrics["fullSurfaceVectorImpulseRelativeDifference"] < 0.10,
                    f"{candidate}: representation differences exceed limits")
            comparisons.append(dict(candidate=candidate, reference=reference, **metrics))

    sensitivity, conservation, profiles, scaling = [], [], {}, []
    if report["completeMatrix"]:
        for mode in ["detailed", "envelope"]:
            for layout in ["isolated", "pair", "street"]:
                excluded = [any(maps[f"{layout}-{m}-{s}"]["everSolid"][i] for m in ["detailed", "envelope"] for s in settings)
                            for i in range(maps[f"{layout}-{mode}-finest"]["nx"] * maps[f"{layout}-{mode}-finest"]["ny"])]
                for setting in ["medium", "fine", "adaptive"]:
                    candidate, reference = f"{layout}-{mode}-{setting}", f"{layout}-{mode}-finest"
                    sensitivity.append(dict(candidate=candidate, reference=reference, **street.compare_maps(maps[candidate], maps[reference], excluded)))
            candidate, reference = f"street-{mode}-half-cfl", f"street-{mode}-fine"
            sensitivity.append(dict(candidate=candidate, reference=reference, **street.compare_maps(maps[candidate], maps[reference])))
            require(maps[f"ordinary-{mode}"] == maps[reference] == maps[f"profiled-{mode}"], f"{mode}: observer/profile changed maps")
            closed = runs[f"closed-{mode}"]
            errors = {"massSourceRelative": abs(closed["massFinalKg"] - closed["massInitialKg"]) / closed["sourceMassKg"],
                      "energySourceRelative": abs(closed["energyFinalJ"] - closed["energyInitialJ"]) / closed["sourceEnergyJ"]}
            require(max(errors.values()) < 0.003, f"{mode}: source-normalised conservation")
            conservation.append(dict(mode=mode, **errors))
            profiles[mode] = runs[f"profiled-{mode}"]["profile"]
            require(profiles[mode] and all(math.isfinite(v) and v >= 0 for v in profiles[mode].values()), f"{mode}: stage profile")
        for count in [1, 4, 16, 64]:
            result = dict(buildings=count)
            for mode in (["envelope"] if count == 64 else ["detailed", "envelope"]):
                samples = [runs[f"scaling-{count}-{mode}-{i}"] for i in range(3)]
                result[mode] = {k: statistics.median(r[k] for r in samples) for k in ["solverBytes", "setupWallS", "runWallS", "commandGPUS"]}
                result[mode]["wallSamplesS"] = [r["runWallS"] for r in samples]
                result[mode]["gpuSamplesS"] = [r["commandGPUS"] for r in samples]
                require(all(r["steps"] == samples[0]["steps"] for r in samples), "scaling steps changed across repeats")
            if "detailed" in result:
                result["wallSpeedup"] = result["detailed"]["runWallS"] / result["envelope"]["runWallS"]
                result["gpuSpeedup"] = result["detailed"]["commandGPUS"] / result["envelope"]["commandGPUS"]
                require(result["envelope"]["solverBytes"] < result["detailed"]["solverBytes"], "envelope did not remove mechanics memory")
                require(maps[f"scaling-{count}-envelope-0"] == maps[f"scaling-{count}-detailed-0"], "scaling changed exposure")
            scaling.append(result)
    return dict(schemaVersion=1, sourceRevision=report["sourceRevision"], acceptanceChecked=not diagnostic, comparisons=comparisons,
                sensitivity=sensitivity, conservation=conservation, stageProfiles=profiles, scaling=scaling)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--diagnostic", action="store_true", help="Report reference mismatches without applying representation acceptance gates")
    args = parser.parse_args()
    summary = check(args.directory, diagnostic=args.diagnostic)
    if args.summary:
        args.summary.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(f"{'Diagnosed' if args.diagnostic else 'Checked'} {len(summary['comparisons'])} representation comparisons, {len(summary['sensitivity'])} sensitivity comparisons and {len(summary['scaling'])} scaling sizes")
