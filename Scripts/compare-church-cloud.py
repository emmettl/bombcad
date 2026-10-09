#!/usr/bin/env python3
"""Compares the fireball's cloud with Church's (1969) measured cloud tops.

Follows each of the 23 shots in Samples/Church1969/church-1969.json from the air model's
hand-over for its charge (an open-ground run, afterburning unless --gas default), through dry
air on a Nevada lake bed at the shot's measured stability up to 600 m and its mean wind, with
`BombCAD cloud`, and prints the model's cloud top against Church's at 1/2 to 5 minutes, and the
geometric mean and spread of their ratio at each time (shot P3, which Church left out, apart).

    swift build -c release --product BombCAD
    python3 Scripts/compare-church-cloud.py .build/release/BombCAD [--gas default] [--turbulent]

See docs/fireball-rise.md#against-churchs-measured-clouds.
"""

import argparse
import json
import math
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
G, R, CP = 9.80665, 287.05, 1005.0
ADIABAT = G / CP  # K/m, the model's dry adiabatic lapse rate
GROUND = 1636.0  # m above sea level, Cactus Flat
GROUND_PRESSURE = 83_200.0  # Pa, the standard atmosphere's at that height


def sounding(stability, wind, afternoon, path):
    """Dry air whose lapse rate up to 600 m gives Church's stability S = 1 - lapse / adiabatic,
    the standard atmosphere's 6.5 K/km above it, isothermal from 12 km, one wind throughout."""
    ground = 300.0 if afternoon else 288.0
    lapse = ADIABAT * (1 - stability)

    def temperature(z):
        if z <= 600:
            return ground - lapse * z
        return ground - lapse * 600 - 0.0065 * (min(z, 12_000) - 600)

    heights = list(range(0, 2000, 50)) + list(range(2000, 16_001, 250))
    pressure, last, rows = GROUND_PRESSURE, 0.0, []
    for z in heights:
        steps = max(1, int((z - last) / 10))
        for k in range(steps):
            middle = last + (k + 0.5) * (z - last) / steps
            pressure *= math.exp(-G * (z - last) / steps / (R * temperature(middle)))
        t = temperature(z) - 273.15
        rows.append(f"-,0,0,{pressure / 100:.2f},{GROUND + z:.0f},{t:.2f},{t - 40:.2f},0,0,0,0,270,{wind:.1f}")
        last = z
    header = (
        "time,longitude,latitude,pressure_hPa,geopotential height_m,temperature_C,"
        "dew point temperature_C,ice point temperature_C,relative humidity_%,humidity wrt ice_%,"
        "mixing ratio_g/kg,wind direction_degree,wind speed_m/s"
    )
    with open(path, "w") as file:
        file.write(header + "\n" + "\n".join(rows) + "\n")


def top_at(samples, time):
    for a, b in zip(samples, samples[1:]):
        if a["time"] <= time <= b["time"]:
            share = (time - a["time"]) / (b["time"] - a["time"])
            low, high = a["height"] + a["radius"], b["height"] + b["radius"]
            return low + share * (high - low)
    return None


def observed(shot):
    """The mean of the camera's and the theodolite's tops where both saw it."""
    columns = [c for c in (shot["camera"], shot["theodolite"]) if c]
    values = []
    for row in zip(*columns):
        seen = [v for v in row if v is not None]
        values.append(sum(seen) / len(seen) if seen else None)
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("bombcad")
    parser.add_argument("--gas", choices=["afterburning", "default"], default="afterburning")
    parser.add_argument("--turbulent", action="store_true", help="add a guess at the lake bed's turbulence")
    arguments = parser.parse_args()
    data = json.load(open(os.path.join(ROOT, "Samples/Church1969/church-1969.json")))
    hand_overs = data["handOvers"][arguments.gas]
    ratios = [[] for _ in data["times"]]
    print(f"{'Shot':14} {'lb':>5} {'S':>5}  " + "  ".join(f"{t // 60 if t >= 60 else '½':>9} min" for t in data["times"]))
    with tempfile.TemporaryDirectory() as folder:
        for shot in data["shots"]:
            hand_over = hand_overs.get(str(shot["yieldPounds"]))
            if hand_over is None:
                continue
            hour = int(shot["localTime"][:2])
            afternoon = 12 <= hour < 20
            wind = shot["meanWind"] or 2
            spec = {"duration": 330}
            if arguments.turbulent:
                # Not measured: u* from the mean wind over a smooth lake bed (z0 about 1 mm), a 2 km
                # convective layer with w* 2 m/s in the afternoon, a 200 m layer at night.
                spec["frictionVelocity"] = wind / 23
                spec.update(
                    {"convectiveVelocity": 2, "boundaryLayerHeight": 2000}
                    if shot["stability"] < 0
                    else {"boundaryLayerHeight": 200}
                )
            paths = {name: os.path.join(folder, name) for name in ("in.json", "spec.json", "air.csv", "out.json")}
            json.dump({"spec": {}, "handOver": hand_over, "samples": []}, open(paths["in.json"], "w"))
            json.dump(spec, open(paths["spec.json"], "w"))
            sounding(shot["stability"], wind, afternoon, paths["air.csv"])
            if os.path.exists(paths["out.json"]):
                os.remove(paths["out.json"])
            subprocess.run(
                [arguments.bombcad, "cloud", paths["in.json"], "--cloud", paths["spec.json"], "--sounding",
                 paths["air.csv"], "--cloud-results", paths["out.json"]],
                check=True, stdout=subprocess.DEVNULL)
            samples = json.load(open(paths["out.json"]))["samples"]
            times = list(data["times"])
            if shot["name"] in data["lateTimes"]:
                times[3] = data["lateTimes"][shot["name"]]
            cells = []
            for index, (seen, time) in enumerate(zip(observed(shot), times)):
                model = top_at(samples, time)
                if seen is None or model is None:
                    cells.append(" " * 13)
                    continue
                cells.append(f"{model:5.0f} / {seen:<5.0f}")
                if shot["name"] != "P3":
                    ratios[index].append(math.log(model / seen))
            print(f"{shot['name']:14} {shot['yieldPounds']:5} {shot['stability']:5.2f}  " + " ".join(cells))
    print("Model / observed, without P3:")
    for time, values in zip(data["times"], ratios):
        mean = sum(values) / len(values)
        spread = math.sqrt(sum((v - mean) ** 2 for v in values) / (len(values) - 1))
        print(f"  {time:3} s: geometric mean {math.exp(mean):.2f}, geometric standard deviation {math.exp(spread):.2f}, {len(values)} shots")


if __name__ == "__main__":
    main()
