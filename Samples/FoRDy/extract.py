"""Derives the files here from FoRDy (DesignSafe PRJ-3836); see README.md.

    python3 extract.py /path/to/PRJ-3836
"""
import os
import sys

EVENTS = [
    "SSG04-1-DSW-3", "SSG04-1-DSW-4", "SSG04-1-DSW-5",
    "SSG04-1-SHW-3", "SSG04-1-SHW-4",
    "SSG03-1-DSW-3", "SSG03-1-DSW-4", "SSG03-1-DSW-5",
]
COLUMNS = [
    ("rotation_rad", "theta_fy"),
    ("normalized_moment", "M_fy/(0.5 P_st L)"),
    ("normalized_shear", "V_fx/P_st"),
    ("normalized_sliding", "u_frx/L"),
    ("normalized_settlement", "s_ft/L"),
]


def table(path, header_line):
    lines = open(path).read().splitlines()
    rate = float(lines[1].split("\t")[1])
    names = [h.strip() for h in lines[header_line].split("\t")]
    rows = []
    for line in lines[header_line + 2:]:
        cells = [c for c in line.split("\t") if c.strip()]
        if cells:
            rows.append([float(c) for c in cells])
    return rate, {name: [r[i] for r in rows] for i, name in enumerate(names) if name}


def main(root):
    here = os.path.dirname(os.path.abspath(__file__))
    for event in EVENTS:
        rate, critical = table(f"{root}/2_Data Files/Critical Plots Data Files/{event}-CriticalData.txt", 3)
        _, motion = table(
            f"{root}/2_Data Files/Baseline Corrected Motions Data Files/{event}-BaselineCorMotions.txt", 7)
        # SSG04 was sampled at 204.8 Hz: every second sample is kept.
        stride = 2 if rate > 150 else 1
        count = min(len(critical["t"]), len(motion["t"]))
        with open(os.path.join(here, f"{event}.csv"), "w") as out:
            out.write("time_s,base_acceleration_g," + ",".join(c for c, _ in COLUMNS) + "\n")
            for i in range(0, count, stride):
                values = [critical["t"][i], motion["a_sbx"][i]] + [critical[k][i] for _, k in COLUMNS]
                out.write(",".join(f"{v:.5g}" for v in values) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
