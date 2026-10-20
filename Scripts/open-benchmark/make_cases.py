"""Writes the open benchmark's cases, Benchmarks/open/cases/*.json, from values transcribed out of
the repository's validation record (docs/open-benchmark.md). Standard library only:

    python3 -I Scripts/open-benchmark/make_cases.py [--out DIR]

DIR defaults to Benchmarks/open/cases; test_score.py checks that the committed files are exactly
what this writes. Edit a case here, not in its JSON, and run it again."""

import argparse
import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "Benchmarks" / "open" / "cases"
TRANSCRIBED = "2026-10-20"


def write(case):
    path = OUT / f"{case['id']}.json"
    path.write_text(json.dumps(case, indent=2, ensure_ascii=False) + "\n")


def tnt(mass, explosive="TNT", factor=1.0, basis="TNT itself", source=None, **rest):
    charge = {"explosive": explosive, "mass_kg": mass,
              "tnt_equivalence": {"factor": factor, "basis": basis},
              "tnt_equivalent_mass_kg": round(mass * factor, 4)}
    if source:
        charge["tnt_equivalence"]["source"] = source
    charge.update(rest)
    return charge


def m(quantity, unit, value=None, source="", rng=None, unc=None, note=None):
    entry = {"quantity": quantity, "unit": unit}
    if rng is not None:
        entry["range"] = rng
    else:
        entry["value"] = value
    if unc:
        entry["uncertainty"] = unc
    entry["source"] = source
    if note:
        entry["note"] = note
    return entry


# --- Kingery-Bulmash ---------------------------------------------------------------------------

W = 100.0
CUBE = W ** (1 / 3)
Z = [0.75, 1, 1.5, 2, 3, 4, 5, 6]
INC_P = [2411, 1354, 551, 284, 116, 65, 43, 32]
INC_I = [890, 1097, 824, 625, 430, 336, 275, 233]
ARR = [1.3, 2.2, 4.6, 7.9, 16.5, 26.9, 38.3, 50.2]
REF_P = [16763, 8152, 2511, 1058, 331, 163, 101, 71]
REF_I = [6102, 4107, 2417, 1689, 1041, 748, 583, 477]

KB_SOURCES = [
    {"id": "kingery-bulmash-1984", "authors": ["C. N. Kingery", "G. Bulmash"], "year": 1984,
     "title": "Airblast parameters from TNT spherical air burst and hemispherical surface burst",
     "venue": "US Army Ballistic Research Laboratory, Technical Report ARBRL-TR-02555",
     "identifier": "ARBRL-TR-02555",
     "licence": "US Government work",
     "redistribution": "values-included",
     "used_for": "The fitted curves themselves",
     "note": "The values in this case are the fit evaluated at each scaled distance, not copied from the report's tables."},
    {"id": "swisdak-1994", "authors": ["M. M. Swisdak"], "year": 1994,
     "title": "Simplified Kingery airblast calculations",
     "venue": "Naval Surface Warfare Center",
     "identifier": "NSWC, 1994",
     "licence": "US Government work",
     "redistribution": "values-included",
     "used_for": "The simplified polynomials evaluated here (within 1% of Kingery and Bulmash on average), and Chart 2's scatter of the tests behind the hemispherical burst",
     "note": "The scatter is Kingery's (BRL Report 1344, 1966) as Swisdak tabulates it: two-thirds of the points of four Canadian TNT shots of 5 to 500 t lie within the stated fraction of the fit."},
]

KB_NOTE = ("Kingery-Bulmash is a fit to many tests, not a single measurement. The uncertainty given is the "
           "scatter of the tests behind the hemispherical-burst fit about it, roughly one standard deviation pooled "
           "over all distances.")


def kb_free_field():
    gauges = []
    for z, p, i, t in zip(Z, INC_P, INC_I, ARR):
        r = round(z * CUBE, 3)
        gauges.append({
            "id": f"Z{z:g}", "position_m": [r, 0, 0], "mount": "ground-flush",
            "description": f"On the ground at {r} m, Z = {z:g} m/kg^(1/3)",
            "measured": [
                m("peak_incident_overpressure", "kPa", p, "swisdak-1994",
                  unc={"kind": "sd", "relative": 0.064, "note": "Kingery 1966 via Swisdak 1994, Chart 2"}),
                m("incident_positive_impulse", "kPa*ms", i, "swisdak-1994",
                  unc={"kind": "sd", "relative": 0.067, "note": "Kingery 1966 via Swisdak 1994, Chart 2"}),
                m("arrival_time", "ms", t, "swisdak-1994",
                  unc={"kind": "sd", "relative": 0.018, "note": "Kingery 1966 via Swisdak 1994, Chart 2"}),
            ]})
    write({
        "format": "open-blast-benchmark-case", "format_version": 1,
        "id": "kb-surface-burst-free-field",
        "title": "Kingery-Bulmash: 100 kg TNT surface burst, incident wave over open ground",
        "category": "free-field",
        "summary": ("A 100 kg hemisphere of TNT on rigid ground. The incident (side-on) peak overpressure, positive "
                    "impulse and arrival time at ground level from 0.75 to 6 m/kg^(1/3), against Kingery and "
                    "Bulmash's fit for a hemispherical surface burst, the design-practice standard behind ConWep and "
                    "UFC 3-340-02."),
        "reference_kind": "empirical-fit",
        "sources": KB_SOURCES,
        "redistribution": {"values_included": True,
                           "note": "The values are a published fit evaluated at these distances (US Government work); nothing is copied from the reports' text or figures."},
        "coordinates": "Origin at the charge's centre on the ground; x along the gauge line, z up; metres.",
        "environment": {"ambient_pressure_kPa": 101.325, "ambient_temperature_C": None,
                        "note": "Sea-level air, to which the fit is normalised."},
        "geometry": {
            "ground": {"kind": "rigid-plane", "z_m": 0, "description": "Flat, rigid, unbounded ground."},
            "note": "Nothing else in the domain. The gauges are far enough apart and the open boundaries should be far enough away (several stand-offs) not to return reflections inside a gauge's positive phase."},
        "runs": [{
            "id": "100kg",
            "description": "One shot; every gauge on one radial line.",
            "charges": [tnt(100.0, shape="hemisphere on the ground", centre_m=[0, 0, 0], height_of_burst_m=0.0)],
            "gauges": gauges}],
        "scoring": {"rule": "within-factor", "factor": 1.2, "factor_by_quantity": {"arrival_time": 1.1},
                    "note": "A prediction passes if it lies within the reference's one-sd band widened by the factor either way: 1.2 for the peak and impulse, 1.1 for the arrival."},
        "notes": [KB_NOTE,
                  "The fit's incident impulse does not fall steadily below about 1 m/kg^(1/3) (890 kPa ms at 0.75 against 1,097 at 1), where it rests on few tests; that gauge is the least sure.",
                  "Peak pressures need fine cells: a captured shock smeared over a few cells reads low."],
        "provenance": {"transcribed_from": ["docs/validation.md (Blast loads against empirical references: Kingery-Bulmash)"],
                       "transcribed": TRANSCRIBED,
                       "note": "Reference values as the record tabulates them: Swisdak's polynomials, checked in this repository against Swisdak's own table and IATG 01.80's worked examples."},
    })


def kb_reflected():
    runs = []
    for z, p, i in zip(Z, REF_P, REF_I):
        r = round(z * CUBE, 3)
        runs.append({
            "id": f"Z{z:g}",
            "description": f"The wall's face at {r} m from the charge (Z = {z:g} m/kg^(1/3)).",
            "charges": [tnt(100.0, shape="hemisphere on the ground", centre_m=[0, 0, 0], height_of_burst_m=0.0)],
            "obstacles": [{"id": "wall", "shape": "box", "min_m": [r, -1000, 0], "max_m": [r + 1, 1000, 1000],
                           "behaviour": "rigid",
                           "description": "A rigid plane wall facing the charge square-on, wide and tall enough that no clearing wave from its edges reaches the gauge in its positive phase."}],
            "gauges": [{"id": "wall-foot", "position_m": [r, 0, 0], "mount": "face-flush", "on": "wall",
                        "description": "In the wall's face at the ground, on the line from the charge",
                        "measured": [
                            m("peak_reflected_overpressure", "kPa", p, "swisdak-1994"),
                            m("reflected_positive_impulse", "kPa*ms", i, "swisdak-1994")]}]})
    write({
        "format": "open-blast-benchmark-case", "format_version": 1,
        "id": "kb-surface-burst-reflected",
        "title": "Kingery-Bulmash: 100 kg TNT surface burst, normally reflected on a rigid wall",
        "category": "reflected",
        "summary": ("The same 100 kg surface burst against a rigid wall placed square-on at each stand-off in turn, from "
                    "0.75 to 6 m/kg^(1/3): the normally reflected peak overpressure and positive impulse at the wall's "
                    "foot, against Kingery and Bulmash's reflected curves."),
        "reference_kind": "empirical-fit",
        "sources": KB_SOURCES,
        "redistribution": {"values_included": True,
                           "note": "The values are a published fit evaluated at these distances (US Government work)."},
        "coordinates": "Origin at the charge's centre on the ground; x towards the wall, z up; metres.",
        "environment": {"ambient_pressure_kPa": 101.325, "ambient_temperature_C": None,
                        "note": "Sea-level air, to which the fit is normalised."},
        "geometry": {"ground": {"kind": "rigid-plane", "z_m": 0, "description": "Flat, rigid ground."},
                     "note": "Each run adds its own wall."},
        "runs": runs,
        "scoring": {"rule": "within-factor", "factor": 1.2,
                    "note": "No measured scatter: Kingery and Bulmash calculated the reflected curves rather than fitting them to reflected measurements (Swisdak's Chart 3), so the band is the factor alone."},
        "notes": [KB_NOTE.replace("The uncertainty given is", "The incident curves' uncertainty is") +
                  " The reflected curves carry none of their own.",
                  "Later reflected tests (Rigby et al. 2014; Farrimond et al. 2024, both PE4 hemispheres at 3 to 12 m/kg^(1/3)) found repeats within about 6-8% of their means and close agreement with the curves, taking PE4 at 1.2-1.24 of TNT.",
                  "Close in, the reflected peak is the hardest quantity to resolve on a grid."],
        "provenance": {"transcribed_from": ["docs/validation.md (Blast loads against empirical references: Kingery-Bulmash)"],
                       "transcribed": TRANSCRIBED},
    })


# --- Alsubaei: ANFO in the open before pipe columns --------------------------------------------

ALSUBAEI_SRC = [{
    "id": "alsubaei-2015", "authors": ["F. C. F. Alsubaei"], "year": 2015,
    "title": "Performance of protective perimeter walls subjected to explosions in reducing the blast resultants on buildings",
    "venue": "Master's thesis, Western University", "url": "https://hdl.handle.net/20.500.14721/35930",
    "licence": "No terms stated by the repository",
    "redistribution": "values-included",
    "used_for": "Tables 4.3-4.5, 4.9-4.11 (chapters 4 and 5) and 6.3-6.10 (chapter 6): peak pressures on the columns with no wall",
    "note": "Only numbers are transcribed (measured facts), from the thesis's tables; no text or figures are copied."}]


def alsubaei():
    heights = [0.75, 2.25, 3.75, 5.25]
    shots = [
        ("ch45", 2.44, 8.2, [35.1, 30.34, 27.72, 37.03]),
        ("ch45", 2.44, 11.85, [28.68, 30.75, 16.82, 26.34]),
        ("ch45", 6.46, 8.2, [69.02, 67.85, 63.85, 69.64]),
        ("ch45", 6.46, 11.85, [49.64, 53.92, 36.48, 46.4]),
        ("ch45", 14.0, 8.2, [148.86, 131.21, 120.04, 124.11]),
        ("ch45", 14.0, 11.85, [82.19, 83.43, 65.92, 89.64]),
        ("ch6", 7.248, 9.2, [76.6, 71.4, 71.0, 73.2]),
        ("ch6", 7.248, 12.85, [53.2, 51.2, 42.8, 58.0]),
        ("ch6", 15.05, 9.2, [140.8, 130.8, 125.4, 130.8]),
        ("ch6", 15.05, 12.85, [82.3, 78.0, 72.6, 89.2]),
    ]
    tables = {("ch45", 8.2): "Tables 4.3-4.5", ("ch45", 11.85): "Tables 4.9-4.11",
              ("ch6", 9.2): "Tables 6.3-6.10", ("ch6", 12.85): "Tables 6.3-6.10"}
    runs = {}
    for chapter, mass, distance, peaks in shots:
        run_id = f"{chapter}-{mass:g}kg"
        run = runs.setdefault(run_id, {
            "id": run_id,
            "description": (f"{mass:g} kg of ANFO, no wall (chapter {'4 and 5' if chapter == 'ch45' else '6'}); "
                            "columns at the distances below"),
            "charges": [tnt(mass, explosive="ANFO", factor=0.82,
                            basis="pressure and impulse alike, as the thesis gives it",
                            source="alsubaei-2015, Table 4.1",
                            shape="cube (ANFO in a non-fragmenting wooden box, bulk density 850 kg/m^3)",
                            centre_m=[0, 0, 0.5], height_of_burst_m=0.5,
                            initiation="at the top of the charge, a 10-20 g PETN booster",
                            note="The thesis gives the height of burst as 0.5 m, taken here as the charge's centre.")],
            "gauges": []})
        for k, (h, p) in enumerate(zip(heights, peaks), start=1):
            run["gauges"].append({
                "id": f"c{distance:g}-P{k}", "position_m": [distance, 0, h], "mount": "column-face",
                "description": f"Gauge P{k}, {h} m up a steel pipe column {distance:g} m from the charge, facing it",
                "measured": [m("peak_reflected_overpressure", "kPa", p, f"alsubaei-2015, {tables[(chapter, distance)]}")]})
    write({
        "format": "open-blast-benchmark-case", "format_version": 1,
        "id": "alsubaei2015-anfo-columns",
        "title": "Alsubaei 2015: ANFO in the open, peaks on pipe columns 8-13 m away",
        "category": "free-field",
        "summary": ("Field shots of 2.4 to 15 kg of ANFO, 0.5 m up over a rigid slab, with no wall: the peak pressure "
                    "recorded by gauges facing the charge on narrow steel pipe columns 8.2 to 12.85 m away, four gauges "
                    "up each from 0.75 to 5.25 m. A real explosive with a stated TNT equivalence, and the gauges' own "
                    "scatter."),
        "reference_kind": "measurement",
        "sources": ALSUBAEI_SRC,
        "redistribution": {"values_included": True,
                           "note": "Measured peaks transcribed from the thesis's tables, cited; the repository states no terms, so nothing else is taken."},
        "coordinates": "Origin on the ground below the charge; x towards the columns, z up; metres.",
        "geometry": {
            "ground": {"kind": "rigid-plane", "z_m": 0,
                       "description": "A reinforced concrete slab in front of the wall's position, a 20 mm steel plate under the charge; the thesis calls it fully reflective."},
            "structure": {"kind": "pipe columns",
                          "description": ("Galvanised steel pipe columns 6 m tall on concrete foundations, standing for a building ('non-responding'). "
                                          "Their diameter, and whether they stand in one line, are not stated. With no wall, nothing else stood between charge and columns.")}},
        "runs": list(runs.values()),
        "scoring": {"rule": "within-factor", "factor": 1.25,
                    "note": "No measurement uncertainty is stated; the factor stands for it and for the narrow columns' reading."},
        "notes": [
            "The gauges sit on narrow pipes, so the reflection clears within about a millisecond: the peaks can be compared, the impulses cannot (they are a quarter to a half of a building face's) and are left out.",
            "The measured peaks fall less with height than a wall's would, as a narrow pipe's do. Some gauges read low or high shot after shot (P3 at 11.85 m low; P4 at 12.85 m high).",
            "At 8.2 m the measurements are themselves low: 6.46 kg at 8.2 m read 64-70 kPa where 7.25 kg at 9.2 m, a larger scaled distance, read 71-77.",
            "The charge masses are of ANFO; the TNT equivalent is 0.82 of each, as the thesis states for pressure and impulse alike.",
            "Chapter 6's shots were fired with the charge 3 m in front of the wall's position, chapters 4 and 5's 2 m: with no wall, only the distances to the columns matter."],
        "provenance": {"transcribed_from": ["Fixtures/Alsubaei2015/walls.json", "docs/validation.md (Perimeter walls under field blasts)"],
                       "transcribed": TRANSCRIBED},
    })


# --- Nian 2024: RC blast wall --------------------------------------------------------------------

NIAN_SRC = [{
    "id": "nian-2024", "authors": ["X. Nian", "Q. Xie", "X. Kong", "Y. Yao", "K. Huang"], "year": 2024,
    "title": "Experimental and numerical study on protective effect of RC blast wall against air shock wave",
    "venue": "Defence Technology 31 (2024) 567-579", "doi": "10.1016/j.dt.2022.11.005",
    "licence": "CC BY-NC-ND 4.0",
    "redistribution": "values-included",
    "used_for": "The wall, the shots, the gauges and the measured peaks (text, Table 1, Table 4, and readings of Fig. 15)",
    "note": "Only measured numbers are transcribed, with citation; no text or figures are reproduced."}]


def nian():
    wall = {"id": "wall", "shape": "box", "min_m": [3.0, -3.0, 0.0], "max_m": [3.4, 3.0, 2.5], "behaviour": "rigid",
            "material": "reinforced concrete (bars and strength not given)",
            "description": ("RC cantilever wall 6.0 m long, 2.5 m high, 0.4 m thick, an inverted T on a buried strip footing; "
                            "no wing walls (sandbags piled at its ends). Undamaged after the 20 kg shot; no deflection measured.")}

    def gauges(front, face, behind, err):
        out = []
        for k, (y, value, src) in enumerate(front, start=1):
            entry = m("peak_incident_overpressure", "kPa", value, src)
            if err and k > 1:
                entry["uncertainty"] = {"kind": "reading", "value": err, "note": "read off Fig. 15"}
            out.append({"id": f"p-{k}", "position_m": [0.0, y, 0.0], "mount": "ground-flush",
                        "description": f"Side-on, in the ground {y:g} m from the charge on a line through it parallel to the wall",
                        "measured": [entry]})
        out.append({"id": "pg-1", "position_m": [3.0, 0.0, 0.22], "mount": "face-flush", "on": "wall",
                    "description": "Reflected, in the wall's front face at its centre, 0.22 m up",
                    "measured": [m("peak_reflected_overpressure", "kPa", face[0], face[1], note=face[2])]})
        for gid, x, measured in behind:
            out.append({"id": gid, "position_m": [x, 0.0, 0.0], "mount": "ground-flush",
                        "description": f"Side-on, in the ground on the wall's axis {x - 3.4:g} m behind its back face",
                        "measured": [measured]})
        return out

    behind_5 = [
        ("ph-1", 5.4, m("peak_incident_overpressure", "kPa", 14.3, "nian-2024, Table 4",
                       note="The authors call the signal abnormal; cut and low-pass filtered at 2 kHz, which lowers a sharp front's peak by an unknown amount.")),
        ("ph-3", 9.4, m("peak_incident_overpressure", "kPa", source="nian-2024, text p. 574 (11.3) and Table 4 (12.2)", rng=[11.3, 12.2],
                       note="Abnormal signal, filtered at 2 kHz; text and table disagree.")),
    ]
    behind_20 = [
        ("ph-2", 7.4, m("peak_incident_overpressure", "kPa", source="nian-2024, Table 4 (52.1) and text p. 574 (54.5)", rng=[52.1, 54.5],
                       note="Abnormal signal, filtered at 2 kHz; text and table disagree.")),
    ]
    runs = [
        {"id": "5kg", "description": "5 kg of TNT on the ground, on the wall's axis, 3 m from its front face",
         "charges": [tnt(5.0, shape="not stated", centre_m=[0, 0, 0], height_of_burst_m=0.0,
                         note="On the ground surface; the shape is not stated.")],
         "gauges": gauges([(3, 310, "nian-2024, text p. 571"), (5, 122, "nian-2024, Fig. 15a"),
                           (7, 63, "nian-2024, Fig. 15a"), (9, 49, "nian-2024, Fig. 15a")],
                          (3240, "nian-2024, text p. 572 and Table 1", "A narrow oscillating spike, about twice ConWep's 1,570 kPa."),
                          behind_5, 5)},
        {"id": "20kg", "description": "20 kg of TNT on the ground, on the wall's axis, 3 m from its front face",
         "charges": [tnt(20.0, shape="not stated", centre_m=[0, 0, 0], height_of_burst_m=0.0,
                         note="On the ground surface; the shape is not stated.")],
         "gauges": gauges([(3, 1620, "nian-2024, text p. 572"), (5, 220, "nian-2024, Fig. 15b"),
                           (7, 170, "nian-2024, text p. 572 and Fig. 15b"), (9, 120, "nian-2024, Fig. 15b")],
                          (7720, "nian-2024, text p. 572 and Table 1", None),
                          behind_20, 20)},
    ]
    # p-3 at 20 kg is from the text, not only the figure: no reading error.
    for g in runs[1]["gauges"]:
        if g["id"] == "p-3":
            g["measured"][0].pop("uncertainty", None)
    for run in runs:
        for g in run["gauges"]:
            for entry in g["measured"]:
                if entry.get("note") is None:
                    entry.pop("note", None)
    write({
        "format": "open-blast-benchmark-case", "format_version": 1,
        "id": "nian2024-rc-blast-wall",
        "title": "Nian et al. 2024: 5 and 20 kg of TNT before a 6 m RC blast wall",
        "category": "shielded",
        "summary": ("A free-standing reinforced concrete wall 6 m long and 2.5 m high, a ground burst of 5 or 20 kg of "
                    "TNT on its axis 3 m in front. Side-on peaks in the ground beside the charge, the reflected peak at "
                    "the wall's foot, and side-on peaks 2 to 6 m behind the wall, where it shields."),
        "reference_kind": "measurement",
        "sources": NIAN_SRC,
        "redistribution": {"values_included": True,
                           "note": "Measured peaks transcribed with citation from an open-access paper (CC BY-NC-ND 4.0); numbers only."},
        "coordinates": "Origin at the charge on the ground; x towards and through the wall along its axis, y along the wall, z up; metres. The wall's front face is at x = 3 m.",
        "geometry": {"ground": {"kind": "not-stated", "z_m": 0,
                                "description": "Natural soil at the site with flush ground gauges; its properties are not given. Taken as flat."},
                     "obstacles": [wall]},
        "runs": runs,
        "scoring": {"rule": "within-factor", "factor": 1.3,
                    "note": "Field gauges with large scatter (at 20 kg the first two read 1.5 and 0.65 of ConWep), so a wider factor; the gauges behind the wall are filtered records."},
        "notes": [
            "There was no shot without the wall: the side-on gauges beside the charge stood in the same shots.",
            "Several gauges behind the wall failed (5 kg: ph-2 invalid; 20 kg: ph-1 and ph-3 invalid). Those that read had abnormal signals, low-pass filtered at 2 kHz by the authors, so their peaks are lower bounds of uncertain size.",
            "The time origin of the plotted records is not stated, so arrival times are not given.",
            "The 20 kg reflected gauge p-1 at 3 m read 1.5 times ConWep's; the 5 kg reflected spike twice ConWep's."],
        "provenance": {"transcribed_from": ["Fixtures/Nian2024/nian2024.json", "docs/validation.md (A blast wall with its length known)"],
                       "transcribed": TRANSCRIBED},
    })


# --- Wang 2022: an aluminised charge's reflected load ---------------------------------------------

WANG_SRC = [{
    "id": "wang-2022", "authors": ["W. Wang", "et al."], "year": 2022,
    "title": "Blast resistance of reinforced concrete slabs based on residual load-bearing capacity",
    "venue": "Materials 15(18), 6449", "doi": "10.3390/ma15186449",
    "licence": "CC BY 4.0", "redistribution": "values-included",
    "used_for": "The charge, the target's placing and the three pressure gauges' peak, arrival and impulse (text, Tables 1-5, Figure 1)"}]


def wang():
    pts = [("P1", 0.0, 0.0, 32.32, 0.36, 3.35, "Facing the charge"),
           ("P2", 0.16, 0.0, 26.47, 0.363, 3.02, "0.16 m across from P1"),
           ("P3", 0.0, 0.3, 23.58, 0.38, 2.93, "0.3 m up from P1")]
    gauges = []
    for gid, dy, dz, p, t, i, what in pts:
        gauges.append({"id": gid, "position_m": [1.2, dy, 0.7 + dz], "mount": "face-flush", "on": "plate",
                       "description": what,
                       "measured": [
                           m("peak_reflected_overpressure", "kPa", round(p * 1000, 1), "wang-2022"),
                           m("arrival_time", "ms", t, "wang-2022"),
                           m("reflected_positive_impulse", "kPa*ms", round(i * 1000, 1), "wang-2022")]})
    write({
        "format": "open-blast-benchmark-case", "format_version": 1,
        "id": "wang2022-aluminised-close-in",
        "title": "Wang et al. 2022: an aluminised 10 kg charge's reflected load at 1.2 m",
        "category": "reflected",
        "summary": ("A bare 10 kg sphere of TNT, RDX and aluminium, which the paper gives as 10 kg of TNT, 0.7 m above the "
                    "ground and 1.2 m from an upright steel plate (0.56 m/kg^(1/3)). The reflected peak, arrival and "
                    "impulse at three gauges in the plate: a close-in load where the stated TNT equivalence is itself "
                    "under test."),
        "reference_kind": "measurement",
        "sources": WANG_SRC,
        "redistribution": {"values_included": True, "note": "Transcribed from an open-access paper (CC BY 4.0), with citation."},
        "coordinates": "Ground at z = 0; the charge's centre at (0, 0, 0.7); x towards the plate, y across it, z up; metres.",
        "geometry": {
            "ground": {"kind": "not-stated", "z_m": 0, "description": "The ground's surface is not described; taken as flat."},
            "obstacles": [{"id": "plate", "shape": "box", "min_m": [1.2, -0.25, 0.1], "max_m": [1.3, 0.25, 1.3], "behaviour": "rigid",
                           "material": "steel",
                           "description": ("A steel plate carrying the gauges, placed as the paper's slabs were (1.2 m long and 0.5 m wide, upright, "
                                           "their centre 0.7 m above the ground; the long side taken vertical, as a gauge 0.3 m up implies). "
                                           "The plate's own size, thickness and frame are not stated.")}]},
        "runs": [{"id": "10kg", "description": "One shot",
                  "charges": [tnt(10.0, explosive="TNT/RDX (4:6 by mass) with aluminium", factor=1.0,
                                  basis="the paper's stated equivalent, 10 kg of TNT; what it was matched to is not stated",
                                  source="wang-2022", shape="bare sphere", centre_m=[0, 0, 0.7], height_of_burst_m=0.7,
                                  initiation="central",
                                  note="mass_kg is the stated TNT equivalent; the charge's own mass is not given separately.")],
                  "gauges": gauges}],
        "scoring": {"rule": "within-factor", "factor": 1.25,
                    "factor_by_quantity": {"arrival_time": 1.15},
                    "note": "No measurement uncertainty stated; one shot."},
        "notes": [
            "The aluminium's contribution beyond its stated TNT equivalent is part of what this case tests: a code that takes the charge as 10 kg of TNT should say so.",
            "The paper's slabs' displacements are not included: their supports are not described well enough to be modelled independently."],
        "provenance": {"transcribed_from": ["Fixtures/TwoFaceSlabs/Wang2022.json", "docs/validation.md (Slabs with steel in both faces)"],
                       "transcribed": TRANSCRIBED},
    })


# --- Yao 2023: pressures on a large slab's top face ------------------------------------------------

YAO_SRC = [{
    "id": "yao-2023", "authors": ["J. Yao", "S. Li", "P. Zhang", "S. Deng", "G. Zhou"], "year": 2023,
    "title": "Dynamic response and damage characteristics of large reinforced concrete slabs under explosion",
    "venue": "Applied Sciences 13, 12552", "doi": "10.3390/app132312552",
    "licence": "CC BY 4.0", "redistribution": "values-included",
    "used_for": "The slab, the tests and the top-face peak pressures read off Figure 6b"}]


def yao():
    tests = [("T1", 0.5, 1.0, 1.70, 0.50), ("T2", 1.0, 1.0, 4.20, 1.25), ("T3", 1.0, 0.8, 8.60, 1.90)]
    runs = []
    for name, mass, h, centre, out in tests:
        runs.append({
            "id": name, "description": f"{mass:g} kg of TNT hung {h:g} m over the slab's centre ({h / mass ** (1 / 3):.2f} m/kg^(1/3))",
            "charges": [tnt(mass, shape="not stated", centre_m=[0, 0, h], height_of_burst_m=None,
                            note="Hung above the slab's top face; the distance is taken to the charge's centre.")],
            "gauges": [
                {"id": "centre", "position_m": [0, 0, 0], "mount": "face-flush", "on": "slab",
                 "description": "Top face, under the charge",
                 "measured": [m("peak_reflected_overpressure", "kPa", round(centre * 1000), "yao-2023, Fig. 6b",
                                unc={"kind": "reading", "value": 100, "note": "read by eye off the figure, about +/-0.1 MPa"})]},
                {"id": "1m-out", "position_m": [1.0, 0, 0], "mount": "face-flush", "on": "slab",
                 "description": "Top face, 1 m from the centre (the direction, in the paper's Figure 3, matters little this far inside the slab)",
                 "measured": [m("peak_reflected_overpressure", "kPa", round(out * 1000), "yao-2023, Fig. 6b",
                                unc={"kind": "reading", "value": 100, "note": "read by eye off the figure, about +/-0.1 MPa"})]}]})
    write({
        "format": "open-blast-benchmark-case", "format_version": 1,
        "id": "yao2023-slab-top-pressure",
        "title": "Yao et al. 2023: close-in pressures on a 4 x 5 m slab's top face",
        "category": "reflected",
        "summary": ("0.5 and 1 kg of TNT hung 0.8 to 1 m over the centre of a 4 x 5 m, 150 mm reinforced concrete slab "
                    "(0.8 to 1.26 m/kg^(1/3)): the peak pressure on its top face under the charge and 1 m out. The "
                    "slab barely moved (under a millimetre), so the load is the test here."),
        "reference_kind": "measurement",
        "sources": YAO_SRC,
        "redistribution": {"values_included": True, "note": "Transcribed and read from an open-access paper (CC BY 4.0), with citation."},
        "coordinates": "Origin at the centre of the slab's top face; x and y in its plane (y along the 5 m side), z up; metres.",
        "geometry": {
            "ground": {"kind": "not-stated", "description": "The slab's height above the ground is not given."},
            "obstacles": [{"id": "slab", "shape": "box", "min_m": [-2.0, -2.5, -0.15], "max_m": [2.0, 2.5, 0.0], "behaviour": "rigid",
                           "material": "reinforced concrete, C35 (cubes 37.2 MPa), two mats of 10 mm bars at 85 mm",
                           "description": "Simply supported on its two long sides on L-shaped concrete supports (150 mm bearing). Treated as rigid for the load: T1-T3 left no visible damage and moved under 1 mm."}]},
        "runs": runs,
        "scoring": {"rule": "within-factor", "factor": 1.25, "note": "The band is the figure's reading error widened by the factor."},
        "notes": [
            "The paper also reports underside displacements and accelerations. They are left out: the reported displacements (0.35-0.86 mm, taken at the wave's arrival) are not comparable with a slab's whole swing, and the displacement record's own meaning is unclear.",
            "A fourth test, 20 kg at 1 m on a second slab, damaged it (a 1.02 x 0.76 m top crater); it has no measured pressure or deflection and is left out."],
        "provenance": {"transcribed_from": ["Fixtures/Yao2023/yao2023.json", "docs/validation.md (Yao's large slabs)"],
                       "transcribed": TRANSCRIBED},
    })


# --- UFC 3-340-02: gas pressure in a closed room -----------------------------------------------------

UFC_SRC = [
    {"id": "ufc-3-340-02", "authors": ["US Department of Defense"], "year": 2008,
     "title": "Structures to Resist the Effects of Accidental Explosions (UFC 3-340-02)",
     "venue": "Unified Facilities Criteria, 5 December 2008", "identifier": "UFC 3-340-02",
     "licence": "US Government work, approved for public release",
     "redistribution": "values-included",
     "used_for": "Figure 2-152, the peak gas pressure in a closed chamber against the charge per volume, read off the chart by hand"},
    {"id": "oswald-2018", "authors": ["C. Oswald"], "year": 2018,
     "title": "An improved method to calculate the gas pressure history from partially confined detonations",
     "venue": "NDIA (for the DoD Explosives Safety Board)", "identifier": "NDIA 2018",
     "licence": "Cited only", "redistribution": "cited-only",
     "used_for": "The scatter: gauge-to-gauge coefficient of variation 5-20% (12% on average) in over 100 confined tests, and a Figure 2-152-based method within 1.7% on average of nearly closed rooms' peaks, standard deviation 11%"},
]


def ufc_room():
    rows = [(0.25, 880), (0.5, 1480), (1.0, 2160), (2.0, 3500), (4.0, 5880)]
    runs = []
    for density, pressure in rows:
        mass = density * 216
        runs.append({
            "id": f"{density:g}kg-m3",
            "description": f"{mass:g} kg of TNT at the room's centre, {density:g} kg/m^3",
            "charges": [tnt(mass, shape="sphere", centre_m=[3, 3, 3], height_of_burst_m=3.0,
                            note="The design curve depends only on the charge per volume; a bare sphere at the centre is this case's choice.")],
            "gauges": [{"id": "room", "position_m": None, "mount": "room-average",
                        "description": "The room's pressure once the shocks have reverberated away, before any heat is lost to the walls in a real chamber",
                        "measured": [m("quasi_static_gas_pressure", "kPa", pressure, "ufc-3-340-02, Figure 2-152",
                                       unc={"kind": "sd", "relative": 0.11, "note": "oswald-2018: a Figure 2-152-based method against nearly closed rooms' measured peaks"})]}]})
    write({
        "format": "open-blast-benchmark-case", "format_version": 1,
        "id": "ufc-closed-room-gas-pressure",
        "title": "UFC 3-340-02: quasi-static gas pressure of TNT in a closed room",
        "category": "confined",
        "summary": ("TNT fired at the centre of a closed, rigid 6 m cube (216 m^3), 0.25 to 4 kg/m^3: the steady gas "
                    "pressure left once the shocks die down, against UFC 3-340-02's design curve (Figure 2-152). At "
                    "light charges most of it comes from the products burning in the room's oxygen."),
        "reference_kind": "design-curve",
        "sources": UFC_SRC,
        "redistribution": {"values_included": True,
                           "note": "Points read off a public US Government design chart; Oswald 2018 is cited for the scatter only."},
        "coordinates": "Origin at one inside corner of the room; z up; metres.",
        "geometry": {"ground": {"kind": "rigid-plane", "z_m": 0, "description": "The room's floor."},
                     "obstacles": [{"id": "room", "shape": "box", "min_m": [0, 0, 0], "max_m": [6, 6, 6], "behaviour": "rigid",
                                    "description": "The inside of a closed room with rigid, adiabatic walls; no vent. The air inside starts at ambient."}],
                     "note": "Only the room's inside matters."},
        "environment": {"ambient_pressure_kPa": 101.325, "ambient_temperature_C": None,
                        "note": "Not stated by the chart; sea-level air assumed."},
        "runs": runs,
        "scoring": {"rule": "within-factor", "factor": 1.15,
                    "note": "The band is Oswald's standard deviation (11%) widened by 1.15."},
        "notes": [
            "The case does not prescribe when to read the pressure: report it once the shock reverberations have decayed (in a 6 m room, tens of milliseconds) and say when, and whether the products burn (afterburning) and lose heat.",
            "UFC 3-340-02 calls Figure 2-152 a curve fitted to tests of partly vented chambers with A/V^(2/3) up to 0.022 and gives no scatter; the tests themselves are not in hand.",
            "Heavy charges (2-4 kg/m^3) have too little oxygen to burn all their products, so the curve flattens."],
        "provenance": {"transcribed_from": ["docs/validation.md (Gas pressure in a closed room)"],
                       "transcribed": TRANSCRIBED,
                       "note": "The curve's points as the record gives them, read off the chart by hand."},
    })


# --- Wu 2023: slabs under hung charges -------------------------------------------------------------

WU_SRC = [{
    "id": "wu-2023", "authors": ["Y. Wu", "et al."], "year": 2023,
    "title": "A research investigation into the impact of reinforcement distribution and blast distance on the blast resilience of reinforced concrete slabs",
    "venue": "Materials 16(11), 4068", "doi": "10.3390/ma16114068",
    "licence": "CC BY 4.0", "redistribution": "values-included",
    "used_for": "The slabs, materials and charges (Tables 1-6, Figure 1) and the measured displacements (Table 10)"}]


def wu():
    shots = [("S5", 1, 0.2, 0.25, 3.99, 0.7), ("D5", 2, 0.2, 0.25, 4.1, 1.97),
             ("S6", 1, 0.4, 0.32, 8.24, 1.99), ("D6", 2, 0.4, 0.32, 10.1, 4.06),
             ("S7", 1, 0.8, 0.40, 13.19, 4.25), ("D7", 2, 0.8, 0.40, 11.98, 4.36),
             ("S8", 1, 1.6, 0.50, 17.99, 5.61), ("D8", 2, 1.6, 0.50, 13.91, 6.95)]
    runs = []
    for name, layers, mass, d, peak, residual in shots:
        steel = ("one layer of 8 mm bars at 100 mm both ways, 20 mm from the underside" if layers == 1 else
                 "two layers of 8 mm bars at 200 mm both ways, 20 mm from each face")
        runs.append({
            "id": name,
            "description": f"Slab {name}: {steel}; {mass:g} kg of TNT hung {d:g} m above the top face's centre",
            "charges": [tnt(mass, shape="stacked 200 g TNT blocks (100 x 50 x 25 mm each)", centre_m=[0, 0, d],
                            height_of_burst_m=None,
                            note="The paper's blast distance; whether to the charge's centre or its lower face is not stated.")],
            "structure": {"reinforcement": steel},
            "gauges": [{"id": "DH5G107", "position_m": [0.3, 0, -0.1], "mount": "on-structure", "on": "slab",
                        "description": "Displacement of the underside 300 mm from its centre (the direction from the centre is not stated)",
                        "measured": [
                            m("peak_displacement", "mm", peak, "wu-2023, Table 10", note="Downward, away from the charge."),
                            m("residual_displacement", "mm", residual, "wu-2023, Table 10",
                              note="D8's residual is 6.95 mm in Table 10 and 6.93 mm in the text." if name == "D8" else None)]}]})
        for entry in runs[-1]["gauges"][0]["measured"]:
            if entry.get("note") is None:
                entry.pop("note", None)
    write({
        "format": "open-blast-benchmark-case", "format_version": 1,
        "id": "wu2023-slabs-hung-charges",
        "title": "Wu et al. 2023: 2 m slabs bent by charges hung above them",
        "category": "structural-response",
        "summary": ("Eight 2 x 2 m, 100 mm reinforced concrete slabs spanning one way, the same steel in one layer near "
                    "the underside or split between both faces, under 0.2 to 1.6 kg of TNT hung 0.25 to 0.5 m above "
                    "(all at 0.43 m/kg^(1/3)). The underside's peak and residual displacement 300 mm from the centre. "
                    "The charge loads the slab through the air: a coupled case."),
        "reference_kind": "measurement",
        "sources": WU_SRC,
        "redistribution": {"values_included": True, "note": "Transcribed from an open-access paper (CC BY 4.0), with citation; nothing digitised from plots."},
        "coordinates": "Origin at the centre of the slab's top face; x along the span (supported edges at x = +/-1 m), z up; metres.",
        "geometry": {
            "ground": {"kind": "not-stated", "description": "The slab stood on a steel frame; its height above the ground is not given."},
            "structure": {
                "kind": "reinforced concrete slab",
                "description": "2.0 x 2.0 x 0.1 m, spanning one way on a steel frame, held down by two bolted clamps a side; the bearing width and the clamps' stiffness are not given.",
                "concrete": "150 mm cubes 45.8, 48.2, 47.4, 46.8, 46.4 and 47.6 MPa (mean 47.0)",
                "steel": "HRB400E: E 200 GPa, yield 455 MPa, tensile 587.5 MPa, elongation 21%",
                "reinforcement_ratio_percent": 0.45}},
        "runs": runs,
        "scoring": {"rule": "within-factor", "factor": 1.5,
                    "note": "One shot a slab, supports not fully described; no measurement uncertainty stated."},
        "notes": [
            "The records swing upward 2-18 mm past where they started over some 60 ms, much more slowly than the slab's own period: something in the rig moved. Only the peak and the residual are given, and the residual carries that doubt.",
            "The undersides of S6, S7 and D6 spalled over about 0.1 m^2, 4 cm deep.",
            "The paper's contact shots (S1-S4, D1-D4), which holed every slab, are not included."],
        "provenance": {"transcribed_from": ["Fixtures/TwoFaceSlabs/Wu2023.json", "docs/validation.md (Slabs with steel in both faces)"],
                       "transcribed": TRANSCRIBED},
    })


# --- Osnes 2019: laminated panes in a shock tube ------------------------------------------------------

OSNES_SRC = [{
    "id": "osnes-2019", "authors": ["K. Osnes", "J. K. Holmen", "O. S. Hopperstad", "T. Børvik"], "year": 2019,
    "title": "Fracture and fragmentation of blast-loaded laminated glass",
    "venue": "International Journal of Impact Engineering 132 (2019) 103334", "identifier": "IJIE 132 (2019) 103334",
    "licence": "CC BY 4.0", "redistribution": "values-included",
    "used_for": "Table 2: each shot's Friedlander fit of the reflected pressure, whether both plies cracked, and the largest deflection"}]


def osnes():
    shots = [("A-01", 167.8, 18.89, 1.18, False, 3.74), ("A-02", 168.7, 18.78, 1.15, False, 3.55),
             ("A-03", 169.7, 19.37, 1.18, False, 3.56), ("A-04", 172.4, 18.87, 1.21, False, 5.79),
             ("B-01", 204.3, 19.60, 1.39, False, 4.25), ("B-02", 205.5, 19.65, 1.29, False, 4.59),
             ("B-03", 206.3, 20.01, 1.35, False, 4.38), ("C-01", 215.2, 20.62, 1.42, False, 4.54),
             ("C-02", 215.6, 20.78, 1.51, True, 69.67), ("D-01", 231.7, 21.40, 1.63, True, 93.80),
             ("D-02", 237.4, 20.23, 1.44, True, 95.41), ("D-03", 237.7, 21.09, 1.48, True, 121.61),
             ("D-04", 238.9, 21.40, 1.52, True, 92.53), ("E-01", 254.2, 23.10, 2.21, True, 99.18),
             ("E-02", 258.9, 24.20, 1.98, True, 111.61)]
    runs = []
    for name, p, td, b, cracked, deflection in shots:
        disp = m("peak_displacement", "mm", deflection, "osnes-2019, Table 2")
        if name in ("D-01", "D-03", "E-02"):
            disp["note"] = "The centre's target was lost after this reading."
        runs.append({
            "id": name, "description": f"Shot {name}",
            "load": {"kind": "friedlander", "applied_to": "the pane's exposed face, uniformly",
                     "peak_kPa": p, "duration_ms": td, "decay_b": b,
                     "description": "p(t) = peak (1 - t/duration) exp(-b t/duration) for 0 <= t <= duration, reflected pressure as the authors fitted it"},
            "gauges": [{"id": "centre", "position_m": [0, 0, 0], "mount": "on-structure", "on": "pane",
                        "description": "The pane's centre",
                        "measured": [m("cracked", "boolean", cracked, "osnes-2019, Table 2", note="Whether both plies cracked."), disp]}]})
    write({
        "format": "open-blast-benchmark-case", "format_version": 1,
        "id": "osnes2019-laminated-panes",
        "title": "Osnes et al. 2019: laminated panes in a shock tube, cracked or held",
        "category": "glazing",
        "summary": ("Fifteen laminated panes (3.8 mm annealed glass, 1.52 mm PVB, 3.8 mm annealed glass) clamped over "
                    "0.3 x 0.3 m in SIMLab's shock tube under fitted Friedlander pulses of 168 to 259 kPa: whether both "
                    "plies cracked, and how far the centre went. Eight held and seven cracked, C-01 holding and C-02 "
                    "cracking on nearly the same load. No air is needed: the load is given."),
        "reference_kind": "measurement",
        "sources": OSNES_SRC,
        "redistribution": {"values_included": True, "note": "Transcribed from an open-access paper (CC BY 4.0), with citation."},
        "coordinates": "Origin at the pane's centre; x and y in its plane, z towards the load; metres.",
        "geometry": {
            "ground": {"kind": "none", "description": "A shock tube; no ground."},
            "structure": {"kind": "laminated glass pane",
                          "description": "0.3 x 0.3 m exposed, clamped between neoprene strips at its edges; 3.8 mm annealed float glass / 1.52 mm PVB / 3.8 mm annealed float glass. The glass's strength was not measured."}},
        "runs": runs,
        "scoring": {"rule": "within-factor", "factor": 1.5,
                    "note": "Cracked or held must match exactly; deflections within a factor of 1.5. The held panes' deflections are a few millimetres, the cracked panes' 70-122 mm."},
        "notes": [
            "New glass in the tests was stronger than ASTM E1300's flaw model allows for weathered glass in service; a code's glass strength decides which panes crack, and should be stated.",
            "None of the cracked panes tore."],
        "provenance": {"transcribed_from": ["Sources/BlastModel/LaminatedShellTest.swift (LaminatedGlassMeasurements.osnes)", "docs/building-envelopes.md (Laminated glass)"],
                       "transcribed": TRANSCRIBED},
    })


# --- Xia 2022: ground motion under 1 t on the ground ----------------------------------------------------

XIA_SRC = [{
    "id": "xia-2022", "authors": ["C. Xia", "L. Chen", "R. Xu", "M. Cao", "D. Chen", "Q. Fang"], "year": 2022,
    "title": "Experimental and numerical studies on ground shock generated by large equivalent surface explosions",
    "venue": "Applied Sciences 12, 7987", "doi": "10.3390/app12167987",
    "licence": "CC BY 4.0", "redistribution": "values-included",
    "used_for": "The test, the peak accelerations printed on Figures 5a and 6a, and the velocities integrated from those figures' digitised histories"}]


def xia():
    def gauge(r, acc, vz, vh):
        return {"id": f"{r}m", "position_m": [r, 0, -0.5], "mount": "buried",
                "description": f"Three-axis accelerometer in a box in a pit 0.5 m deep, {r} m from the charge",
                "measured": [
                    m("peak_acceleration_vertical", "m/s^2", acc, f"xia-2022, Figure {'5a' if r == 21 else '6a'} (printed peak)",
                      note="Downward, the largest vertical excursion."),
                    m("peak_particle_velocity_vertical", "m/s", source=f"xia-2022, Figure {'5a' if r == 21 else '6a'}, integrated", rng=vz,
                      note="Downward peak of the integrated vertical acceleration; the range takes each record's pre-event offset removed and not."),
                    m("peak_particle_speed_horizontal", "m/s", source=f"xia-2022, Figure {'5a' if r == 21 else '6a'}, integrated", rng=vh,
                      note="Peak of sqrt(vx^2 + vy^2) from the two integrated horizontal components; the range as above.")]}

    write({
        "format": "open-blast-benchmark-case", "format_version": 1,
        "id": "xia2022-surface-burst-ground-motion",
        "title": "Xia et al. 2022: ground motion 0.5 m deep under 1 t of TNT on the ground",
        "category": "ground-shock",
        "summary": ("1 t of TNT on the ground in the Gobi desert, on hard alluvial and pluvial sediments: the peak vertical "
                    "acceleration, and the vertical velocity and horizontal speed integrated from the records, 0.5 m deep "
                    "at 21 and 42 m. Near and past the range where the ground's wave outruns the air's."),
        "reference_kind": "measurement",
        "sources": XIA_SRC,
        "redistribution": {"values_included": True,
                           "note": "Printed peaks and values derived from the open-access paper's figures (CC BY 4.0), with citation."},
        "coordinates": "Origin at the charge on the ground surface; x along the gauge line, z up; metres.",
        "geometry": {
            "ground": {"kind": "soil", "z_m": 0,
                       "description": "Sand and gravel on hard fine alluvial and pluvial sediments. Not measured at the site.",
                       "properties": {"seismic_velocity_m_s": 457, "density_kg_m3": 2050,
                                      "note": "Neither is a measurement: the seismic velocity is the authors' fit of UFC 3-340-01's direct-induced relation to the two peak accelerations, the density their numerical model's, from tests on another sand."}}},
        "runs": [{"id": "1t", "description": "One shot",
                  "charges": [tnt(1000.0, shape="not stated (50 kg of cast TNT initiating 950 kg of bulk TNT in nylon bags)",
                                  centre_m=[0, 0, 0], height_of_burst_m=0.0, note="On the ground surface.")],
                  "gauges": [gauge(21, 3.57, [0.0094, 0.012], [0.0542, 0.0575]),
                             gauge(42, 0.36, [0.0008, 0.0012], [0.004, 0.0042])]}],
        "scoring": {"rule": "within-factor", "factor": 2.0,
                    "note": "One shot, two gauges, unmeasured soil: a factor of two."},
        "notes": [
            "The velocity sensor at 21 m clipped at about 0.085 m/s for about 60 ms, more than any integrated component reaches; its component is not stated, and which record is right cannot be told from the paper.",
            "The records' time zero is not stated, so arrival times are not given.",
            "The measured horizontal accelerations were three to eight times the vertical."],
        "provenance": {"transcribed_from": ["Fixtures/XiaChen2022/ground-motion.json", "docs/validation.md (Ground motion under a 1 t surface burst)"],
                       "transcribed": TRANSCRIBED},
    })


def main(argv=None):
    global OUT
    parser = argparse.ArgumentParser(description="Write the open benchmark's case files.")
    parser.add_argument("--out", type=Path, default=OUT, help=f"the directory to write into (default {OUT})")
    OUT = parser.parse_args(argv).out
    OUT.mkdir(parents=True, exist_ok=True)
    for make in (kb_free_field, kb_reflected, alsubaei, nian, wang, yao, ufc_room, wu, osnes, xia):
        make()
    print(f"10 cases written to {OUT}")


if __name__ == "__main__":
    main()
