"""Writes BombCAD's open-benchmark entry, Benchmarks/open/results/bombcad-0.6.0-dev.json, from
values quoted out of the validation record (no new runs; docs/open-benchmark.md). Standard library
only:

    python3 -I Scripts/open-benchmark/make_bombcad_results.py [--out FILE]

FILE defaults to the committed entry; test_score.py checks that it is exactly what this writes."""

import argparse
import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "Benchmarks" / "open" / "results" / "bombcad-0.6.0-dev.json"
Z = ["0.75", "1", "1.5", "2", "3", "4", "5", "6"]


def p(run, gauge, quantity, **kw):
    entry = {"run": run, "gauge": gauge, "quantity": quantity}
    entry.update(kw)
    return entry


cases = []

inc_peak = [1.15, 1.16, 1.13, 1.01, 1.03, 0.83, 0.86, 0.87]
inc_imp = [1.27, 0.96, 0.95, 0.98, 1.05, 1.06, 1.06, 1.06]
cases.append({
    "case": "kb-surface-burst-free-field",
    "configuration": ("blastbench validate: 100 kg surface burst on uniform 0.25 m cells, the recommended air "
                      "(afterburning, hot air, far-field open faces) started from the one-dimensional solution "
                      "mapped onto the grid (the default since 18 October 2026)."),
    "recorded_in": "docs/validation.md#the-mapped-start-18-october",
    "recorded_commit": "7242c4494859196f81fca9826db8af4da0c11710",
    "notes": ["Recorded as percentages of the reference, so given here as ratios.",
              "The record gives this configuration's arrival times only as 'within 10% of the reference on every grid', not gauge by gauge, so they are not entered.",
              "Within the mapped radius (12.8 m on this grid) the peaks are the one-dimensional start's; beyond it the grid carries the wave."],
    "predictions": [p("100kg", f"Z{z}", "peak_incident_overpressure", ratio=a) for z, a in zip(Z, inc_peak)]
                   + [p("100kg", f"Z{z}", "incident_positive_impulse", ratio=a) for z, a in zip(Z, inc_imp)],
})

ref_peak = [0.32, 0.40, 0.55, 0.64, 0.77, 0.83, 0.87, 0.88]
ref_imp = [0.85, 0.95, 1.07, 1.11, 1.18, 1.18, 1.17, 1.15]
cases.append({
    "case": "kb-surface-burst-reflected",
    "configuration": ("blastbench validate: the domain's far face made reflecting, the 100 kg charge at each stand-off in "
                      "turn, uniform 0.25 m cells, the recommended air with the mapped start (default since 18 October 2026)."),
    "recorded_in": "docs/validation.md#the-mapped-start-18-october",
    "recorded_commit": "7242c4494859196f81fca9826db8af4da0c11710",
    "notes": ["Recorded as percentages of the reference, so given here as ratios.",
              "Reflected peaks need finer cells than these: on 0.125 m cells the record gives 57-97%."],
    "predictions": [p(f"Z{z}", "wall-foot", "peak_reflected_overpressure", ratio=a) for z, a in zip(Z, ref_peak)]
                   + [p(f"Z{z}", "wall-foot", "reflected_positive_impulse", ratio=a) for z, a in zip(Z, ref_imp)],
})

alsubaei = [
    ("ch45-2.44kg", 8.2, [54, 51, 46, 41]), ("ch45-6.46kg", 8.2, [103, 96, 86, 75]),
    ("ch45-14kg", 8.2, [187, 173, 151, 129]), ("ch6-7.248kg", 9.2, [89, 85, 77, 69]),
    ("ch6-15.05kg", 9.2, [153, 143, 129, 114]), ("ch45-2.44kg", 11.85, [29, 29, 28, 26]),
    ("ch45-6.46kg", 11.85, [52, 51, 48, 45]), ("ch45-14kg", 11.85, [85, 83, 78, 73]),
    ("ch6-7.248kg", 12.85, [48, 47, 46, 43]), ("ch6-15.05kg", 12.85, [77, 75, 71, 67]),
]
cases.append({
    "case": "alsubaei2015-anfo-columns",
    "configuration": ("blastbench perimeter --study air: 50 mm air cells, no wall, the ANFO taken as 0.82 of its mass of TNT; "
                      "the gauges in the open where the columns' faces would be, their peak reflected square-on by the "
                      "Rankine-Hugoniot relations. Recorded 11 October 2026, before afterburning, hot air and far-field "
                      "faces became the defaults."),
    "recorded_in": "docs/validation.md#perimeter-walls-under-field-blasts",
    "recorded_commit": "5d87ee5fc17b61939efd1aa61cd6c9c58e5c2eae",
    "notes": ["On the defaults of 15 October the record puts these reflected peaks 3-5% higher, and the mapped start of 18 October within 2% of that; the gauge-by-gauge values were not recorded again.",
              "With rigid 0.2 m square columns in the air instead of open gauges, the record gives peaks 15-20% lower."],
    "predictions": [p(run, f"c{d:g}-P{k}", "peak_reflected_overpressure", value=v)
                    for run, d, values in alsubaei for k, v in enumerate(values, start=1)],
})

cases.append({
    "case": "nian2024-rc-blast-wall",
    "configuration": ("blastbench nian: the wall rigid, 50 mm air cells, the recommended air with the mapped start "
                      "(19 October 2026)."),
    "recorded_in": "docs/validation.md#a-blast-wall-with-its-length-known",
    "recorded_commit": "84574cda1bd3cf0ddfe78ca88ac563c98cc4d72f",
    "notes": ["The model also gives the gauges that failed in the tests (5 kg ph-2: 28.3 kPa; 20 kg ph-1 and ph-3: 58.1 and 64.7 kPa); they have no measured value and are not entered.",
              "The reflected peak at the wall's foot was still rising with the mesh on 50 mm cells."],
    "predictions": [
        p("5kg", "p-1", "peak_incident_overpressure", value=326), p("5kg", "p-2", "peak_incident_overpressure", value=109),
        p("5kg", "p-3", "peak_incident_overpressure", value=57), p("5kg", "p-4", "peak_incident_overpressure", value=37),
        p("5kg", "pg-1", "peak_reflected_overpressure", value=1218),
        p("5kg", "ph-1", "peak_incident_overpressure", value=27.5), p("5kg", "ph-3", "peak_incident_overpressure", value=26.4),
        p("20kg", "p-1", "peak_incident_overpressure", value=1056), p("20kg", "p-2", "peak_incident_overpressure", value=313),
        p("20kg", "p-3", "peak_incident_overpressure", value=147), p("20kg", "p-4", "peak_incident_overpressure", value=87),
        p("20kg", "pg-1", "peak_reflected_overpressure", value=5024),
        p("20kg", "ph-2", "peak_incident_overpressure", value=66.8)],
})

cases.append({
    "case": "wang2022-aluminised-close-in",
    "configuration": ("blastbench twoface --wang A --roomy --dx 0.05 --refine 2: the charge as 10 kg of TNT, 50 mm air "
                      "refined by 2, every open face 4 m/kg^(1/3) from the charge and the slab, the recommended air with "
                      "the mapped start (18 October 2026). The gauges are on the model's slab face where the paper's plate "
                      "carried them."),
    "recorded_in": "docs/validation.md#slabs-with-steel-in-both-faces",
    "recorded_commit": "90c9391ab472d8a59648b71d7a02d86b175271e7",
    "notes": ["Arrival times were recorded only on earlier defaults (0.42, 0.42 and 0.44 ms) and are not entered."],
    "predictions": [
        p("10kg", "P1", "peak_reflected_overpressure", value=15100), p("10kg", "P2", "peak_reflected_overpressure", value=14300),
        p("10kg", "P3", "peak_reflected_overpressure", value=13600),
        p("10kg", "P1", "reflected_positive_impulse", value=2690), p("10kg", "P2", "reflected_positive_impulse", value=2510),
        p("10kg", "P3", "reflected_positive_impulse", value=2260)],
})

cases.append({
    "case": "yao2023-slab-top-pressure",
    "configuration": ("blastbench twoface --yao T1,T2,T3: the recommended air on 25 mm cells refined by 2, the slab "
                      "deformable and settled under its own weight; recorded 17 October 2026 on the balloon start, "
                      "before the mapped start became the default."),
    "recorded_in": "docs/validation.md#yaos-large-slabs",
    "recorded_commit": "4bbe98d7988c080b37ad087752d3bb8bd16d5b13",
    "predictions": [
        p("T1", "centre", "peak_reflected_overpressure", value=1880), p("T1", "1m-out", "peak_reflected_overpressure", value=620),
        p("T2", "centre", "peak_reflected_overpressure", value=3940), p("T2", "1m-out", "peak_reflected_overpressure", value=1220),
        p("T3", "centre", "peak_reflected_overpressure", value=6970), p("T3", "1m-out", "peak_reflected_overpressure", value=1200)],
})

ufc = [1.05, 1.02, 0.98, 0.94, 0.98]
cases.append({
    "case": "ufc-closed-room-gas-pressure",
    "configuration": ("blastbench gas --radiate: a closed 6 m cube, the charge at its centre, afterburning, hot air and "
                      "the gas losing what it radiates (the default since 19 October 2026); the pressure read at 80 ms."),
    "recorded_in": "docs/validation.md#gas-pressure-in-a-closed-room",
    "recorded_commit": "87a60b68d11539d75f3acba7468b5b1ba28c41a5",
    "notes": ["Recorded as percentages of the curve, so given here as ratios.",
              "Without afterburning the same room gives 48-114% of the curve, the light charges half."],
    "predictions": [p(f"{d}kg-m3", "room", "quasi_static_gas_pressure", ratio=a)
                    for d, a in zip(["0.25", "0.5", "1", "2", "4"], ufc)],
})

cases.append({
    "case": "wu2023-slabs-hung-charges",
    "configuration": ("blastbench twoface --wu S8,D8 --roomy: solid elements of 12.5 mm (8 through the thickness), each "
                      "mat smeared at its depth, the air in 25 mm cells refined by 2, every open face 4 m/kg^(1/3) from the "
                      "charge and slab, the recommended air with the mapped start (18 October 2026). Assumed: the cube "
                      "strength's 0.8 for the cylinder's; 100 mm bearing, held down along the clamps' line and lengthwise "
                      "at one edge."),
    "recorded_in": "docs/validation.md#slabs-with-steel-in-both-faces",
    "recorded_commit": "5b5126f1afc7a06eef420a02062ff551bd153d64",
    "notes": ["Only S8 and D8 were run on today's defaults; the six smaller charges were recorded on earlier defaults (peaks 39-68% of measured) and are not entered.",
              "The record gives both slabs' residual as 8.0-8.2 mm across three roundings, entered as a range for each."],
    "predictions": [
        p("S8", "DH5G107", "peak_displacement", value=16.2), p("S8", "DH5G107", "residual_displacement", range=[8.0, 8.2]),
        p("D8", "DH5G107", "peak_displacement", value=16.6), p("D8", "DH5G107", "residual_displacement", range=[8.0, 8.2])],
})

cases.append({
    "case": "osnes2019-laminated-panes",
    "configuration": ("The envelope's one-way laminated glass model (EnvelopePanel.laminatedGlass, LaminatedGlassTests), "
                      "simply supported over 0.3 m, the glass at ASTM E1300's median strength for the pane (42.9 MPa held "
                      "60 s), each shot's Friedlander pulse applied directly."),
    "recorded_in": "docs/building-envelopes.md#laminated-glass",
    "recorded_commit": "dc1c8d388705065b37907c00d04750eaa784866a",
    "notes": ["At E1300's median every pane cracks, the eight that held as well: 7 of 15 as measured. The record gives the deflections only as ranges over shots, so they are not entered.",
              "With the glass given 69 MPa, 1.6 times E1300's median (the tests' new glass was stronger), 14 of 15 sort as measured; the shell model (blastbench laminated) sorts 10 of 15 at the median. Neither is entered: this entry is the app's default."],
    "predictions": [p(shot, "centre", "cracked", value=True)
                    for shot in ["A-01", "A-02", "A-03", "A-04", "B-01", "B-02", "B-03", "C-01", "C-02", "D-01", "D-02",
                                 "D-03", "D-04", "E-01", "E-02"]],
})

cases.append({
    "case": "xia2022-surface-burst-ground-motion",
    "configuration": ("blastbench groundmotion: a quarter of the burst on the recommended air on 0.25 m cells (balloon "
                      "start), its ground loading streamed to the manuals' estimate and to layered soil columns of the "
                      "authors' fitted soil unloading at one to three times its loading speed; the range is over those "
                      "models (17 October 2026)."),
    "recorded_in": "docs/validation.md#ground-motion-under-a-1-t-surface-burst",
    "recorded_commit": "73251fe040e1a4e6c1b6d19557a2c32c802c900a",
    "notes": ["The models are one-dimensional and vertical: they give no horizontal motion, which dominated the measurement, and their accelerations are set by the cells, not predictions, so neither is entered.",
              "An elastic half-space and a yielding one were also compared (docs/ground-shock-outrunning.md); not entered."],
    "predictions": [
        p("1t", "21m", "peak_particle_velocity_vertical", range=[0.221, 0.239]),
        p("1t", "42m", "peak_particle_velocity_vertical", range=[0.057, 0.059])],
})

RESULTS = {
    "format": "open-blast-benchmark-results",
    "format_version": 1,
    "code": {"name": "BombCAD", "version": "0.6.0-dev", "commit": "6115dbcb513a840efaa4a4ca3fef30401f360d67",
             "url": "https://github.com/emmettl/bombcad"},
    "prepared": "2026-10-20",
    "notes": [
        "Quoted from BombCAD's validation record at the commit above; no new simulations were run. Each case gives the commit that recorded its numbers and the configuration they came from, which differs from case to case where a comparison was not rerun on the latest defaults.",
        "BombCAD's own development used several of these comparisons (the defaults were chosen with the record in view), so they are a calibration set as much as a validation set.",
        "Version 0.6.0-dev is main after 0.5.1, before 0.6.0's release."],
    "cases": cases,
}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Write BombCAD's open-benchmark entry.")
    parser.add_argument("--out", type=Path, default=OUT, help=f"the file to write (default {OUT})")
    out = parser.parse_args(argv).out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(RESULTS, indent=2, ensure_ascii=False) + "\n")
    print(f"written to {out}")


if __name__ == "__main__":
    main()
