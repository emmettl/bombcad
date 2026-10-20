"""Tests of the open benchmark's scorer, cases and BombCAD's entry:
python3 -I Scripts/open-benchmark/test_score.py"""

import contextlib
import copy
import importlib.util
import io
import json
import math
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location("score", HERE / "score.py")
score = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(score)

CASES = ROOT / "Benchmarks" / "open" / "cases"
SCHEMA = ROOT / "Benchmarks" / "open" / "schema"
BOMBCAD = ROOT / "Benchmarks" / "open" / "results" / "bombcad-0.6.0-dev.json"


def small_case():
    """A two-gauge case for the arithmetic: a value with a relative sd, a range, and a boolean."""
    return {
        "format": "open-blast-benchmark-case", "format_version": 1, "id": "small", "title": "Small",
        "category": "free-field", "summary": "s", "reference_kind": "measurement",
        "sources": [{"id": "src", "authors": ["A"], "year": 2000, "title": "T", "venue": "V", "identifier": "x",
                     "licence": "CC BY 4.0", "redistribution": "values-included"}],
        "redistribution": {"values_included": True, "note": "n"},
        "coordinates": "c", "geometry": {"ground": {"kind": "rigid-plane", "description": "g"}},
        "runs": [{"id": "r", "description": "d",
                  "charges": [{"explosive": "ANFO", "mass_kg": 10.0,
                               "tnt_equivalence": {"factor": 0.82, "basis": "b"}, "tnt_equivalent_mass_kg": 8.2,
                               "shape": "cube", "centre_m": [0, 0, 0.5]}],
                  "gauges": [
                      {"id": "a", "position_m": [5, 0, 0], "mount": "ground-flush",
                       "measured": [{"quantity": "peak_incident_overpressure", "unit": "kPa", "value": 100,
                                     "uncertainty": {"kind": "sd", "relative": 0.1}, "source": "src"},
                                    {"quantity": "arrival_time", "unit": "ms", "range": [4, 9], "source": "src, p. 2"}]},
                      {"id": "b", "position_m": [9, 0, 0], "mount": "on-structure",
                       "measured": [{"quantity": "cracked", "unit": "boolean", "value": False, "source": "src"},
                                    {"quantity": "peak_displacement", "unit": "mm", "withheld": True, "source": "src"}]}]}],
        "scoring": {"rule": "within-factor", "factor": 1.2, "note": "n"},
    }


def results_for(predictions, case_id="small"):
    return {"format": "open-blast-benchmark-results", "format_version": 1,
            "code": {"name": "Test", "version": "1"}, "prepared": "2026-10-20",
            "cases": [{"case": case_id, "configuration": "c", "predictions": predictions}]}


def run_main(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = score.main(argv)
    return status, out.getvalue(), err.getvalue()


class ShippedCases(unittest.TestCase):
    def setUp(self):
        self.paths = sorted(CASES.glob("*.json"))
        self.cases, self.errors = score.read_cases(self.paths)

    def test_ten_cases_all_valid(self):
        self.assertEqual(self.errors, [])
        self.assertEqual(len(self.cases), 10)

    def test_categories_spread(self):
        categories = {case["category"] for case in self.cases}
        for wanted in ("free-field", "reflected", "shielded", "confined", "structural-response", "glazing"):
            self.assertIn(wanted, categories)

    def test_every_source_has_a_citation_and_licence(self):
        for case in self.cases:
            for source in case["sources"]:
                self.assertTrue(source["authors"] and source["year"] and source["title"] and source["venue"])
                self.assertTrue(source["licence"])
                self.assertTrue(any(key in source for key in ("doi", "url", "identifier")), source["id"])

    def test_no_code_option_names_in_cases(self):
        # Solver-neutral: no BombCAD command or option in a case.
        for path in self.paths:
            text = path.read_text()
            for word in ("blastbench", "scenebench", "--", "BombCAD", "SolverConfiguration"):
                self.assertNotIn(word, text, f"{path.name} names {word!r}")

    def test_no_private_or_sealed_sources(self):
        for path in self.paths:
            text = path.read_text().lower()
            for word in ("kinney", "vasudevan", "blind", "/volumes/"):
                self.assertNotIn(word, text, f"{path.name} mentions {word!r}")

    def test_schema_enums_match_the_scorer(self):
        schema = json.loads((SCHEMA / "case.schema.json").read_text())
        defs = schema["$defs"]
        self.assertEqual(set(defs["quantity"]["enum"]), set(score.QUANTITIES))
        self.assertEqual(set(defs["unit"]["enum"]), set(score.QUANTITIES.values()))
        self.assertEqual(set(schema["properties"]["category"]["enum"]), score.CATEGORIES)
        self.assertEqual(set(schema["properties"]["reference_kind"]["enum"]), score.REFERENCE_KINDS)
        self.assertEqual(set(defs["gauge"]["properties"]["mount"]["enum"]), score.MOUNTS)
        self.assertEqual(set(defs["uncertainty"]["properties"]["kind"]["enum"]), score.UNCERTAINTY_KINDS)
        results_schema = json.loads((SCHEMA / "results.schema.json").read_text())
        self.assertEqual(results_schema["properties"]["format"]["const"], "open-blast-benchmark-results")

    def test_check_command(self):
        status, out, _ = run_main(["--check"])
        self.assertEqual(status, 0)
        self.assertIn("10 cases valid", out)


class BombCADEntry(unittest.TestCase):
    def setUp(self):
        self.cases, errors = score.read_cases(sorted(CASES.glob("*.json")))
        self.assertEqual(errors, [])
        self.results = json.loads(BOMBCAD.read_text())

    def test_valid_against_the_cases(self):
        errors, warnings = score.check_results(self.results, {case["id"]: case for case in self.cases})
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_every_case_entered_with_its_commit(self):
        self.assertEqual({entry["case"] for entry in self.results["cases"]}, {case["id"] for case in self.cases})
        self.assertRegex(self.results["code"]["commit"], "^[0-9a-f]{40}$")
        for entry in self.results["cases"]:
            self.assertRegex(entry["recorded_commit"], "^[0-9a-f]{40}$", entry["case"])

    def test_scores(self):
        report = score.score(self.cases, self.results)
        by_case = {c["summary"]["case"]: c["summary"] for c in report["cases"]}
        self.assertEqual(report["overall"]["cases_scored"], 10)
        # Recorded as ratios: the closed room within 6% of the curve at every density.
        self.assertEqual(by_case["ufc-closed-room-gas-pressure"]["score"], 1.0)
        # The vertical ground motion is 20-60 times what was measured.
        self.assertEqual(by_case["xia2022-surface-burst-ground-motion"]["passed"], 0)
        self.assertGreater(by_case["xia2022-surface-burst-ground-motion"]["geometric_mean_ratio"], 20)
        # Arrival times were not recorded on today's defaults: 16 of 24 values entered.
        self.assertEqual(by_case["kb-surface-burst-free-field"]["missing"], 8)
        strict = score.score(self.cases, self.results, strict=True)
        strict_case = {c["summary"]["case"]: c["summary"] for c in strict["cases"]}
        self.assertAlmostEqual(strict_case["kb-surface-burst-free-field"]["score"], 16 / 24)

    def test_text_and_json_reports(self):
        status, out, _ = run_main([str(BOMBCAD)])
        self.assertEqual(status, 0)
        self.assertIn("Summary", out)
        self.assertIn("nian2024-rc-blast-wall", out)
        status, out, _ = run_main([str(BOMBCAD), "--json", "--case", "wu2023-slabs-hung-charges"])
        self.assertEqual(status, 0)
        report = json.loads(out)
        self.assertEqual([c["summary"]["case"] for c in report["cases"]], ["wu2023-slabs-hung-charges"])


class Arithmetic(unittest.TestCase):
    def test_band_and_ratio(self):
        case = small_case()
        self.assertEqual(score.check_case(case), [])
        # 100 kPa +/- 10% widened by 1.2: passes from 90/1.2 = 75 to 110 * 1.2 = 132.
        for predicted, passes in ((75.1, True), (74.9, False), (131.9, True), (132.1, False)):
            report = score.score_case(case, results_for([
                {"run": "r", "gauge": "a", "quantity": "peak_incident_overpressure", "value": predicted}])["cases"][0])
            row = next(r for r in report["rows"] if r["quantity"] == "peak_incident_overpressure")
            self.assertEqual(row["passed"], passes, predicted)
            self.assertAlmostEqual(row["ratio"], predicted / 100)

    def test_ranges_ratios_booleans_and_withheld(self):
        case = small_case()
        entry = results_for([
            {"run": "r", "gauge": "a", "quantity": "arrival_time", "range": [12, 12]},
            {"run": "r", "gauge": "a", "quantity": "peak_incident_overpressure", "ratio": 0.5},
            {"run": "r", "gauge": "b", "quantity": "cracked", "value": False}])["cases"][0]
        report = score.score_case(case, entry)
        rows = {r["quantity"]: r for r in report["rows"]}
        # The measured range's centre is geometric, sqrt(4 x 9) = 6; its band runs to 9 x 1.2 = 10.8.
        self.assertAlmostEqual(rows["arrival_time"]["measured"], 6.0)
        self.assertAlmostEqual(rows["arrival_time"]["ratio"], 2.0)
        self.assertFalse(rows["arrival_time"]["passed"])
        # A ratio stands for ratio x the measured value.
        self.assertAlmostEqual(rows["peak_incident_overpressure"]["predicted"], 50.0)
        self.assertFalse(rows["peak_incident_overpressure"]["passed"])
        self.assertTrue(rows["cracked"]["passed"])
        self.assertEqual(rows["peak_displacement"]["status"], "withheld")
        summary = report["summary"]
        self.assertEqual((summary["scored"], summary["passed"], summary["withheld"], summary["measured"]), (3, 1, 1, 3))
        self.assertAlmostEqual(summary["geometric_mean_ratio"], math.sqrt(2.0 * 0.5))

    def test_strict_counts_missing(self):
        case = small_case()
        entry = results_for([{"run": "r", "gauge": "b", "quantity": "cracked", "value": False}])["cases"][0]
        self.assertEqual(score.score_case(case, entry)["summary"]["score"], 1.0)
        self.assertAlmostEqual(score.score_case(case, entry, strict=True)["summary"]["score"], 1 / 3)


class Validation(unittest.TestCase):
    def test_case_errors(self):
        case = small_case()
        case["runs"][0]["charges"][0]["tnt_equivalent_mass_kg"] = 10.0
        case["runs"][0]["gauges"][0]["measured"][0]["unit"] = "psi"
        case["runs"][0]["gauges"][0]["measured"][1]["source"] = "elsewhere"
        del case["sources"][0]["identifier"]
        errors = "\n".join(score.check_case(case))
        self.assertIn("tnt_equivalent_mass_kg", errors)
        self.assertIn("unit must be 'kPa'", errors)
        self.assertIn("does not start with one of the case's source ids", errors)
        self.assertIn("needs a doi, url or identifier", errors)

    def test_negative_or_zero_values_are_refused(self):
        case = small_case()
        case["runs"][0]["gauges"][0]["measured"][0]["value"] = 0
        self.assertTrue(any("positive" in e for e in score.check_case(case)))

    def test_results_errors(self):
        case = small_case()
        results = results_for([
            {"run": "r", "gauge": "a", "quantity": "peak_incident_overpressure", "value": 1, "unit": "psi"},
            {"run": "r", "gauge": "z", "quantity": "arrival_time", "value": 1},
            {"run": "r", "gauge": "b", "quantity": "cracked", "value": 1},
            {"run": "r", "gauge": "b", "quantity": "peak_displacement", "ratio": 1.0}])
        errors, _ = score.check_results(results, {"small": case})
        text = "\n".join(errors)
        self.assertIn("unit 'psi'", text)
        self.assertIn("no such run, gauge and quantity", text)
        self.assertIn("true or false", text)
        self.assertIn("withheld", text)

    def test_unknown_case_is_a_warning(self):
        errors, warnings = score.check_results(results_for([], case_id="other"), {"small": small_case()})
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 1)

    def test_main_exits_2_on_bad_results(self):
        case = small_case()
        bad = results_for([{"run": "r", "gauge": "nowhere", "quantity": "arrival_time", "value": 1}])
        with tempfile.TemporaryDirectory() as directory:
            case_path = Path(directory) / "small.json"
            case_path.write_text(json.dumps(case))
            results_path = Path(directory) / "results.json"
            results_path.write_text(json.dumps(bad))
            status, _, err = run_main([str(results_path), str(case_path)])
            self.assertEqual(status, 2)
            self.assertIn("no such run", err)
            renamed = copy.deepcopy(case)
            renamed["id"] = "other-name"
            case_path.write_text(json.dumps(renamed))
            status, _, err = run_main(["--check", str(case_path)])
            self.assertEqual(status, 2)
            self.assertIn("should be its id", err)


def load_generator(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Regeneration(unittest.TestCase):
    """The committed JSON is exactly what the generators write: edit the generators, not the files."""

    def test_cases_regenerate_exactly(self):
        with tempfile.TemporaryDirectory() as directory:
            with contextlib.redirect_stdout(io.StringIO()):
                load_generator("make_cases").main(["--out", directory])
            written = {path.name: path.read_bytes() for path in Path(directory).glob("*.json")}
        committed = {path.name: path.read_bytes() for path in CASES.glob("*.json")}
        self.assertEqual(sorted(written), sorted(committed))
        for name in committed:
            self.assertEqual(written[name], committed[name], f"{name} differs from make_cases.py's output")

    def test_bombcad_entry_regenerates_exactly(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "entry.json"
            with contextlib.redirect_stdout(io.StringIO()):
                load_generator("make_bombcad_results").main(["--out", str(out)])
            self.assertEqual(out.read_bytes(), BOMBCAD.read_bytes(),
                             "bombcad-0.6.0-dev.json differs from make_bombcad_results.py's output")


if __name__ == "__main__":
    unittest.main()
