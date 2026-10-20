#!/usr/bin/env python3
"""Scores a results file against the open benchmark's cases (docs/open-benchmark.md).

Standard library only; run it isolated:

    python3 -I Scripts/open-benchmark/score.py Benchmarks/open/results/bombcad-0.6.0-dev.json
    python3 -I Scripts/open-benchmark/score.py RESULTS.json [CASE.json ...] [--cases DIR]
                                               [--case ID] [--strict] [--json]
    python3 -I Scripts/open-benchmark/score.py --check [CASE.json ...]

Without case files it reads every case in Benchmarks/open/cases. It prints, for each case the
results cover, every gauge's measured and predicted value and their ratio, whether the prediction
passes the case's rule, the case's score, and a summary across the cases. `--strict` counts a
measured value with no prediction as a failure; `--json` prints the same as JSON; `--check`
validates the cases (and the results, if given) and scores nothing. The exit status is 0 when
everything is valid, 2 when a case or the results file is not.
"""

import argparse
import json
import math
import sys
from pathlib import Path

CASES_DIR = Path(__file__).resolve().parents[2] / "Benchmarks" / "open" / "cases"

# Each quantity and its unit; the schema's enums say the same (test_score checks they agree).
QUANTITIES = {
    "peak_incident_overpressure": "kPa",
    "incident_positive_impulse": "kPa*ms",
    "arrival_time": "ms",
    "peak_reflected_overpressure": "kPa",
    "reflected_positive_impulse": "kPa*ms",
    "quasi_static_gas_pressure": "kPa",
    "peak_displacement": "mm",
    "residual_displacement": "mm",
    "cracked": "boolean",
    "peak_acceleration_vertical": "m/s^2",
    "peak_particle_velocity_vertical": "m/s",
    "peak_particle_speed_horizontal": "m/s",
}
CATEGORIES = {"free-field", "reflected", "shielded", "confined", "structural-response", "glazing", "ground-shock"}
REFERENCE_KINDS = {"measurement", "empirical-fit", "design-curve"}
MOUNTS = {"ground-flush", "face-flush", "column-face", "free-air", "on-structure", "buried", "room-average"}
UNCERTAINTY_KINDS = {"sd", "half-width", "reading"}
RULES = {"within-factor"}


class Invalid(Exception):
    """A case or results file that does not follow the format."""


# --- reading and checking ---------------------------------------------------------------------------


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as error:
        raise Invalid(f"{path}: {error}") from error


def is_number(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def require(obj, keys, where, errors):
    for key in keys:
        if key not in obj:
            errors.append(f"{where}: missing '{key}'")


def check_case(case):
    """The case's errors, as a list of strings (empty when it is valid)."""
    errors = []
    where = case.get("id", "<case without id>") if isinstance(case, dict) else "<case>"
    if not isinstance(case, dict):
        return [f"{where}: not an object"]
    require(case, ["format", "format_version", "id", "title", "category", "summary", "reference_kind", "sources",
                   "redistribution", "coordinates", "geometry", "runs", "scoring"], where, errors)
    if case.get("format") != "open-blast-benchmark-case":
        errors.append(f"{where}: format is not 'open-blast-benchmark-case'")
    if case.get("format_version") != 1:
        errors.append(f"{where}: format_version is not 1")
    if case.get("category") not in CATEGORIES:
        errors.append(f"{where}: unknown category {case.get('category')!r}")
    if case.get("reference_kind") not in REFERENCE_KINDS:
        errors.append(f"{where}: unknown reference_kind {case.get('reference_kind')!r}")
    source_ids = set()
    for k, source in enumerate(case.get("sources", [])):
        sw = f"{where}: source {k}"
        require(source, ["id", "authors", "year", "title", "venue", "licence", "redistribution"], sw, errors)
        if not any(key in source for key in ("doi", "url", "identifier")):
            errors.append(f"{sw}: needs a doi, url or identifier")
        if source.get("redistribution") not in ("values-included", "cited-only"):
            errors.append(f"{sw}: redistribution must be 'values-included' or 'cited-only'")
        source_ids.add(source.get("id"))
    redistribution = case.get("redistribution", {})
    require(redistribution, ["values_included", "note"], f"{where}: redistribution", errors)
    scoring = case.get("scoring", {})
    if scoring.get("rule") not in RULES:
        errors.append(f"{where}: unknown scoring rule {scoring.get('rule')!r}")
    for name, factor in [("factor", scoring.get("factor"))] + list(scoring.get("factor_by_quantity", {}).items()):
        if not is_number(factor) or factor <= 1:
            errors.append(f"{where}: scoring factor {name} must be a number above 1")
    for name in scoring.get("factor_by_quantity", {}):
        if name not in QUANTITIES:
            errors.append(f"{where}: scoring factor for unknown quantity {name!r}")
    run_ids = set()
    for run in case.get("runs", []):
        rw = f"{where}: run {run.get('id')!r}"
        require(run, ["id", "description", "gauges"], rw, errors)
        if run.get("id") in run_ids:
            errors.append(f"{rw}: duplicate run id")
        run_ids.add(run.get("id"))
        if "charges" not in run and "load" not in run:
            errors.append(f"{rw}: needs charges or a load")
        for charge in run.get("charges", []):
            require(charge, ["explosive", "mass_kg", "tnt_equivalence", "tnt_equivalent_mass_kg", "shape", "centre_m"],
                    f"{rw}: charge", errors)
            equivalence = charge.get("tnt_equivalence", {})
            if not is_number(equivalence.get("factor")) or "basis" not in equivalence:
                errors.append(f"{rw}: charge's tnt_equivalence needs a factor and a basis")
            elif is_number(charge.get("mass_kg")) and is_number(charge.get("tnt_equivalent_mass_kg")):
                expected = charge["mass_kg"] * equivalence["factor"]
                if abs(charge["tnt_equivalent_mass_kg"] - expected) > 1e-3 * max(1.0, expected):
                    errors.append(f"{rw}: tnt_equivalent_mass_kg is not mass_kg times the factor")
        gauge_ids = set()
        for gauge in run.get("gauges", []):
            gw = f"{rw}: gauge {gauge.get('id')!r}"
            require(gauge, ["id", "mount", "measured"], gw, errors)
            if gauge.get("id") in gauge_ids:
                errors.append(f"{gw}: duplicate gauge id")
            gauge_ids.add(gauge.get("id"))
            if gauge.get("mount") not in MOUNTS:
                errors.append(f"{gw}: unknown mount {gauge.get('mount')!r}")
            position = gauge.get("position_m")
            if position is None:
                if gauge.get("mount") != "room-average":
                    errors.append(f"{gw}: needs a position_m (only a room-average gauge may have none)")
            elif not (isinstance(position, list) and len(position) == 3 and all(is_number(x) for x in position)):
                errors.append(f"{gw}: position_m must be three numbers")
            quantities = set()
            for entry in gauge.get("measured", []):
                errors += check_measured(entry, f"{gw}", source_ids)
                if entry.get("quantity") in quantities:
                    errors.append(f"{gw}: {entry.get('quantity')} measured twice")
                quantities.add(entry.get("quantity"))
    return errors


def check_measured(entry, where, source_ids):
    errors = []
    quantity = entry.get("quantity")
    mw = f"{where}: {quantity}"
    if quantity not in QUANTITIES:
        return [f"{mw}: unknown quantity"]
    if entry.get("unit") != QUANTITIES[quantity]:
        errors.append(f"{mw}: unit must be {QUANTITIES[quantity]!r}, not {entry.get('unit')!r}")
    if "source" not in entry:
        errors.append(f"{mw}: missing source")
    elif entry["source"].split(",")[0].strip() not in source_ids:
        errors.append(f"{mw}: source {entry['source']!r} does not start with one of the case's source ids")
    given = [key for key in ("value", "range", "withheld") if key in entry]
    if len(given) != 1:
        errors.append(f"{mw}: give exactly one of value, range or withheld")
        return errors
    boolean = QUANTITIES[quantity] == "boolean"
    if "value" in entry:
        value = entry["value"]
        if boolean and not isinstance(value, bool):
            errors.append(f"{mw}: value must be true or false")
        if not boolean and not (is_number(value) and value > 0):
            errors.append(f"{mw}: value must be a positive number (quantities are magnitudes)")
    if "range" in entry:
        low_high = entry["range"]
        if boolean or not (isinstance(low_high, list) and len(low_high) == 2 and all(is_number(x) for x in low_high)
                           and 0 < low_high[0] <= low_high[1]):
            errors.append(f"{mw}: range must be [low, high], positive, low <= high")
    if "withheld" in entry and entry["withheld"] is not True:
        errors.append(f"{mw}: withheld, when given, must be true")
    uncertainty = entry.get("uncertainty")
    if uncertainty is not None:
        if uncertainty.get("kind") not in UNCERTAINTY_KINDS:
            errors.append(f"{mw}: unknown uncertainty kind {uncertainty.get('kind')!r}")
        if ("value" in uncertainty) == ("relative" in uncertainty):
            errors.append(f"{mw}: uncertainty needs exactly one of value or relative")
        for key in ("value", "relative"):
            if key in uncertainty and not (is_number(uncertainty[key]) and uncertainty[key] >= 0):
                errors.append(f"{mw}: uncertainty {key} must be a non-negative number")
    return errors


def measured_items(case):
    """Every measured value of the case, keyed by (run, gauge, quantity)."""
    items = {}
    for run in case["runs"]:
        for gauge in run["gauges"]:
            for entry in gauge["measured"]:
                items[(run["id"], gauge["id"], entry["quantity"])] = entry
    return items


def check_results(results, cases_by_id):
    """The results file's errors and warnings: (errors, warnings)."""
    errors, warnings = [], []
    if results.get("format") != "open-blast-benchmark-results":
        errors.append("results: format is not 'open-blast-benchmark-results'")
    if results.get("format_version") != 1:
        errors.append("results: format_version is not 1")
    require(results, ["code", "prepared", "cases"], "results", errors)
    require(results.get("code", {}), ["name", "version"], "results: code", errors)
    seen = set()
    for entry in results.get("cases", []):
        case_id = entry.get("case")
        cw = f"results: case {case_id!r}"
        require(entry, ["case", "configuration", "predictions"], cw, errors)
        if case_id in seen:
            errors.append(f"{cw}: given twice")
        seen.add(case_id)
        if case_id not in cases_by_id:
            warnings.append(f"{cw}: no such case among those read; skipped")
            continue
        items = measured_items(cases_by_id[case_id])
        keys = set()
        for prediction in entry.get("predictions", []):
            key = (prediction.get("run"), prediction.get("gauge"), prediction.get("quantity"))
            pw = f"{cw}: {'/'.join(str(k) for k in key)}"
            if key not in items:
                errors.append(f"{pw}: the case has no such run, gauge and quantity")
                continue
            if key in keys:
                errors.append(f"{pw}: predicted twice")
            keys.add(key)
            unit = QUANTITIES[key[2]]
            if "unit" in prediction and prediction["unit"] != unit:
                errors.append(f"{pw}: unit {prediction['unit']!r} where the case's is {unit!r}")
            given = [k for k in ("value", "range", "ratio") if k in prediction]
            if len(given) != 1:
                errors.append(f"{pw}: give exactly one of value, range or ratio")
                continue
            if unit == "boolean":
                if given != ["value"] or not isinstance(prediction["value"], bool):
                    errors.append(f"{pw}: a boolean quantity takes a value of true or false")
            elif "value" in prediction and not is_number(prediction["value"]):
                errors.append(f"{pw}: value must be a number")
            elif "range" in prediction and not (isinstance(prediction["range"], list) and len(prediction["range"]) == 2
                                                and all(is_number(x) for x in prediction["range"])
                                                and prediction["range"][0] <= prediction["range"][1]):
                errors.append(f"{pw}: range must be [low, high]")
            elif "ratio" in prediction and not (is_number(prediction["ratio"]) and prediction["ratio"] > 0):
                errors.append(f"{pw}: ratio must be a positive number")
            if "ratio" in prediction and items[key].get("withheld"):
                errors.append(f"{pw}: a ratio needs the case's value, which is withheld")
    return errors, warnings


# --- scoring -----------------------------------------------------------------------------------------


def central(low, high):
    """The middle of a range: geometric where both ends are positive."""
    if low > 0 and high > 0:
        return math.sqrt(low * high)
    return 0.5 * (low + high)


def measured_band(entry):
    """(central value, lowest, highest) of a numeric measured entry, the uncertainty included."""
    if "range" in entry:
        low, high = entry["range"]
        value = central(low, high)
    else:
        value = low = high = entry["value"]
    uncertainty = entry.get("uncertainty")
    if uncertainty:
        spread = uncertainty["value"] if "value" in uncertainty else uncertainty["relative"] * value
        low, high = low - spread, high + spread
    return value, max(low, 0.0), high


def score_item(entry, prediction, factor):
    """One gauge's quantity: measured, predicted, ratio and whether it passes."""
    row = {"quantity": entry["quantity"], "unit": entry["unit"]}
    if entry.get("withheld"):
        row["status"] = "withheld"
        return row
    if prediction is None:
        row["status"] = "missing"
        return row
    if entry["unit"] == "boolean":
        row.update(measured=entry["value"], predicted=prediction["value"], status="scored",
                   passed=prediction["value"] == entry["value"])
        return row
    value, low, high = measured_band(entry)
    if "ratio" in prediction:
        predicted = prediction["ratio"] * value
        predicted_range = None
    elif "range" in prediction:
        predicted_range = prediction["range"]
        predicted = central(*predicted_range)
    else:
        predicted = prediction["value"]
        predicted_range = None
    ratio = predicted / value
    row.update(measured=value, band=[low, high], predicted=predicted, ratio=ratio, status="scored",
               passed=low / factor <= predicted <= high * factor)
    if "range" in entry:
        row["measured_range"] = entry["range"]
    if predicted_range is not None:
        row["predicted_range"] = predicted_range
        row["ratio_range"] = [x / value for x in predicted_range]
    if "ratio" in prediction:
        row["from_ratio"] = True
    return row


def score_case(case, entry, strict=False):
    """The case's rows and summary for one results entry (None: no predictions for it)."""
    predictions = {}
    for prediction in (entry or {}).get("predictions", []):
        predictions[(prediction["run"], prediction["gauge"], prediction["quantity"])] = prediction
    scoring = case["scoring"]
    rows = []
    for (run, gauge, quantity), measured in measured_items(case).items():
        factor = scoring.get("factor_by_quantity", {}).get(quantity, scoring["factor"])
        row = score_item(measured, predictions.get((run, gauge, quantity)), factor)
        row.update(run=run, gauge=gauge, factor=factor)
        rows.append(row)
    scored = [row for row in rows if row["status"] == "scored"]
    missing = [row for row in rows if row["status"] == "missing"]
    withheld = [row for row in rows if row["status"] == "withheld"]
    passed = sum(1 for row in scored if row["passed"])
    logs = [math.log(row["ratio"]) for row in scored if row.get("ratio", 0) > 0]
    denominator = len(scored) + (len(missing) if strict else 0)
    summary = {
        "case": case["id"], "category": case["category"], "reference_kind": case["reference_kind"],
        "measured": len(rows) - len(withheld), "scored": len(scored), "missing": len(missing),
        "withheld": len(withheld), "passed": passed,
        "score": passed / denominator if denominator else None,
        "coverage": len(scored) / (len(rows) - len(withheld)) if len(rows) > len(withheld) else None,
        "geometric_mean_ratio": math.exp(sum(logs) / len(logs)) if logs else None,
        "typical_factor": math.exp(math.sqrt(sum(x * x for x in logs) / len(logs))) if logs else None,
        "rule": scoring["rule"], "factor": scoring["factor"],
    }
    return {"summary": summary, "rows": rows}


def score(cases, results, strict=False):
    by_id = {case["id"]: case for case in cases}
    entries = {entry["case"]: entry for entry in results["cases"] if entry["case"] in by_id}
    scored = [score_case(by_id[case_id], entries[case_id], strict) for case_id in by_id if case_id in entries]
    summaries = [s["summary"] for s in scored if s["summary"]["score"] is not None]
    overall = {
        "code": results["code"],
        "cases_read": len(cases),
        "cases_scored": len(summaries),
        "cases_not_entered": sorted(case_id for case_id in by_id if case_id not in entries),
        "mean_case_score": sum(s["score"] for s in summaries) / len(summaries) if summaries else None,
        "values_scored": sum(s["scored"] for s in summaries),
        "values_passed": sum(s["passed"] for s in summaries),
        "values_missing": sum(s["missing"] for s in summaries),
        "strict": strict,
    }
    return {"cases": scored, "overall": overall}


# --- printing ----------------------------------------------------------------------------------------


def fmt(x):
    if isinstance(x, bool):
        return "yes" if x else "no"
    if x is None:
        return "-"
    if x == 0:
        return "0"
    magnitude = abs(x)
    if magnitude >= 100:
        return f"{x:,.0f}"
    if magnitude >= 1:
        return f"{x:.3g}" if magnitude < 10 else f"{x:.1f}"
    return f"{x:.3g}"


def ratio_text(x):
    return "-" if x is None else f"{x:.2f}"


def text_report(report):
    lines = []
    overall = report["overall"]
    code = overall["code"]
    lines.append(f"{code['name']} {code['version']}" + (f" ({code['commit']})" if code.get("commit") else ""))
    for case in report["cases"]:
        s = case["summary"]
        lines.append("")
        lines.append(f"{s['case']} [{s['category']}, {s['reference_kind']}]: rule {s['rule']}, factor {s['factor']:g}")
        lines.append(f"  {'run':<14} {'gauge':<12} {'quantity':<32} {'measured':>14} {'predicted':>14} {'ratio':>12}  pass")
        for row in case["rows"]:
            quantity = f"{row['quantity']} ({row['unit']})" if row["unit"] != "boolean" else row["quantity"]
            if row["status"] != "scored":
                lines.append(f"  {row['run']:<14} {row['gauge']:<12} {quantity:<32} {row['status']:>14}")
                continue
            measured = (f"{fmt(row['measured_range'][0])}-{fmt(row['measured_range'][1])}" if "measured_range" in row
                        else fmt(row["measured"]))
            predicted = (f"{fmt(row['predicted_range'][0])}-{fmt(row['predicted_range'][1])}" if "predicted_range" in row
                         else fmt(row["predicted"]))
            if "ratio_range" in row:
                ratio = f"{row['ratio_range'][0]:.2f}-{row['ratio_range'][1]:.2f}"
            elif "ratio" in row:
                ratio = f"{row['ratio']:.2f}" + ("*" if row.get("from_ratio") else "")
            else:
                ratio = "-"
            lines.append(f"  {row['run']:<14} {row['gauge']:<12} {quantity:<32} {measured:>14} {predicted:>14} "
                         f"{ratio:>12}  {'yes' if row['passed'] else 'NO'}")
        score_text = "-" if s["score"] is None else f"{s['score']:.2f}"
        lines.append(f"  score {score_text} ({s['passed']} of {s['scored']} pass; coverage {s['scored']} of "
                     f"{s['measured']}" + (f", {s['withheld']} withheld" if s["withheld"] else "") + ")"
                     + (f"; geometric mean ratio {s['geometric_mean_ratio']:.2f}, typical factor "
                        f"{s['typical_factor']:.2f}" if s["geometric_mean_ratio"] else ""))
    lines.append("")
    lines.append("Summary")
    lines.append(f"  {'case':<38} {'category':<20} {'score':>6} {'passed':>8} {'coverage':>9} {'gm ratio':>9} {'factor':>7}")
    for case in report["cases"]:
        s = case["summary"]
        lines.append(f"  {s['case']:<38} {s['category']:<20} "
                     f"{'-' if s['score'] is None else format(s['score'], '.2f'):>6} "
                     f"{str(s['passed']) + '/' + str(s['scored']):>8} {str(s['scored']) + '/' + str(s['measured']):>9} "
                     f"{ratio_text(s['geometric_mean_ratio']):>9} {ratio_text(s['typical_factor']):>7}")
    mean = overall["mean_case_score"]
    lines.append(f"  {overall['cases_scored']} of {overall['cases_read']} cases scored; mean case score "
                 f"{'-' if mean is None else format(mean, '.2f')}; {overall['values_passed']} of "
                 f"{overall['values_scored']} values pass" + (" (missing values count as failures)" if overall["strict"]
                                                                  else f"; {overall['values_missing']} values not predicted"))
    if overall["cases_not_entered"]:
        lines.append(f"  Not entered: {', '.join(overall['cases_not_entered'])}")
    lines.append("  * a ratio the code recorded (predicted over the case's value), not a value")
    return "\n".join(lines)


# --- command line ------------------------------------------------------------------------------------


def read_cases(paths):
    cases, errors = [], []
    for path in paths:
        try:
            case = load_json(path)
        except Invalid as error:
            errors.append(str(error))
            continue
        problems = check_case(case)
        errors += [f"{path.name}: {problem}" for problem in problems]
        if not problems:
            if case["id"] != path.stem:
                errors.append(f"{path.name}: the file's name should be its id, {case['id']}.json")
            cases.append(case)
    ids = [case["id"] for case in cases]
    errors += [f"case id {case_id!r} given twice" for case_id in sorted({i for i in ids if ids.count(i) > 1})]
    return cases, errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("files", nargs="*", type=Path,
                        help="a results file, then case files (with --check, case files only, or a results file too)")
    parser.add_argument("--cases", type=Path, help=f"a directory of case files (default {CASES_DIR})")
    parser.add_argument("--case", action="append", help="score only this case id (repeatable)")
    parser.add_argument("--strict", action="store_true", help="count a measured value with no prediction as a failure")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("--check", action="store_true", help="validate only")
    args = parser.parse_args(argv)

    results_path = None
    case_paths = []
    for path in args.files:
        data = load_json(path) if path.suffix == ".json" else None
        if isinstance(data, dict) and data.get("format") == "open-blast-benchmark-results":
            if results_path is not None:
                parser.error("give one results file")
            results_path = path
        else:
            case_paths.append(path)
    if not case_paths:
        directory = args.cases or CASES_DIR
        case_paths = sorted(directory.glob("*.json"))
    cases, errors = read_cases(case_paths)
    if args.case:
        unknown = set(args.case) - {case["id"] for case in cases}
        errors += [f"no case {case_id!r}" for case_id in sorted(unknown)]
        cases = [case for case in cases if case["id"] in args.case]

    results = None
    warnings = []
    if results_path is not None:
        results = load_json(results_path)
        result_errors, warnings = check_results(results, {case["id"]: case for case in cases})
        errors += result_errors
    elif not args.check:
        parser.error("give a results file (or --check)")

    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 2
    if args.check:
        print(f"{len(cases)} cases valid" + (f"; {results_path.name} valid" if results_path else ""))
        return 0
    report = score(cases, results, strict=args.strict)
    print(json.dumps(report, indent=2) if args.json else text_report(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
