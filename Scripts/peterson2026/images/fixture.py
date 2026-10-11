"""Builds Samples/Peterson2026Images/peterson-images.json from analyse.py's records, with the
cracks the automatic reading cannot follow (the deep beams' steep, short cracks and broken ends;
D-2d-NoS-1's long-span crack) read by hand off the last frames."""
import json, glob, sys

RECORDS = sys.argv[1] if len(sys.argv) > 1 else "/Volumes/StudioData/bombcad/peterson-images/json"
# Read by hand off the last frame, endpoints to about 10 px: inclination from the beam's axis,
# which way it rises, which span, and what it runs between.
BY_HAND = {
    "D_04d_NoS_1": (78, "towards the load", "short", "from under the load to the support, the support's corner broken"),
    "D_04d_NoS_2": (76, "towards the load", "short", "from under the load to near the support"),
    "D_04d_S45_1": (80, "towards the load", "short", "from under the load to the support, the concrete round the support broken out"),
    "D_04d_S90_1": (75, "towards the load", "short", "the end block torn off from under the load to the support, crushed round the support"),
    "D_2d_NoS_1": (37, "towards the load", "long", "from beside the load down into the long span, curving (flexural-shear)"),
}
out = []
for f in sorted(glob.glob(f"{RECORDS}/*.json")):
    r = json.load(open(f))
    name = r["beam"].replace("_", "-")
    if r.get("t0") is None:
        out.append(dict(beam=name, note="the recording ends about 1 ms after the impact; not read"))
        continue
    g = r["geometry"]
    rec = dict(beam=name, scale_mm_per_px=round(g["scale"], 3), recorded_ms_after_impact=round((r["frames"] - 1 - r["t0"]) / 6.0, 1))
    if r["first_crack"]:
        c = max(r["first_crack"]["cracks"], key=lambda c: c["length"])
        rec["first_crack"] = dict(ms=round(r["first_crack"]["ms"], 2), inclination_deg=round(c["inclination"]),
                                  x_mm_from_support=round(c["x_mm"]), length_mm=round(c["length"]))
    if r["first_diagonal"]:
        c = max(r["first_diagonal"]["cracks"], key=lambda c: c["length"])
        rec["first_inclined_crack"] = dict(ms=round(r["first_diagonal"]["ms"], 2), inclination_deg=round(c["inclination"]),
                                           rises="towards the load" if (c["rises_towards"] == "right") == (c["x_mm"] < {"04d": 48, "1d": 120, "2d": 240}[r["beam"].split("_")[1]]) else "away from the load",
                                           x_mm_from_support=round(c["x_mm"]), length_mm=round(c["length"]))
    if r["beam"] in BY_HAND:
        inc, rises, span, what = BY_HAND[r["beam"]]
        rec["main_crack"] = dict(inclination_deg=inc, rises=rises, span=span, read="by hand", note=what)
    elif r["main_crack"]:
        m = r["main_crack"]["main"]
        # of the three stations along the crack (a quarter, half and three quarters along it), the one
        # that opens most: a curved crack can leave a station off it
        mid = max(r["main_crack"]["stations"], key=lambda st: st["series"][-1]["opening"])
        series = [p for p in mid["series"] if abs(p["ms"] * 2 - round(p["ms"] * 2)) < 0.09 and p["ms"] <= 10.01]
        off = mid["series"][-1]["opening"] < 0.1 and mid["series"][-1]["slip"] < 0.3
        rec["main_crack"] = dict(inclination_deg=round(m["inclination"]), span=m["span"], read="automatic",
                                 x_mm_from_support=round(m["x_mm"]), length_mm=round(m["length"]),
                                 appeared_ms=None if m["appeared_ms"] is None else round(m["appeared_ms"], 2),
                                 opening_slip_at=dict(x_mm_from_support=round(mid["x_mm"]), height_mm=round(mid["height_mm"]), along=mid["at"]),
                                 opening_slip=None if off else [dict(ms=round(p["ms"], 1), opening_mm=round(p["opening"], 2), slip_mm=round(p["slip"], 2)) for p in series])
        if off: rec["main_crack"]["note"] = "no station across the crack held open; opening and slip not read"
        if r["beam"].startswith("D_04d") and not off:
            rec["main_crack"]["note"] = "the station sits on the end block, which slides along the crack"

    rec["spalled_at_load_ms"] = None if r["crush_load_ms"] is None else round(r["crush_load_ms"], 2)
    rec["spalled_at_support_ms"] = None if r["crush_support_ms"] is None else round(r["crush_support_ms"], 2)
    out.append(rec)
doc = dict(
    source="V. Peterson, High-speed camera dataset from impact tests on reinforced concrete beams, Mendeley Data, doi:10.17632/kn28g6dbj5.3 (CC BY 4.0); camera set-up from Peterson's KTH thesis (2026)",
    licence="CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/); derived from the frames by Scripts/peterson2026/images",
    camera="Photron APX-RS, 6000 frames/s (0.167 ms), 1024 x 512 px; scale from each beam's 150 mm depth in the frame",
    uncertainty=dict(time_ms=0.25, inclination_deg_automatic=5, inclination_deg_by_hand=8,
                     opening_slip_mm="0.05 below 1 mm; a lower bound beyond about 3 mm, where the speckle across a wide crack no longer correlates"),
    beams=out)
json.dump(doc, open("Samples/Peterson2026Images/peterson-images.json", "w"), indent=1)
print(len(out))
