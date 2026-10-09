#!/usr/bin/env python3
"""Render retained street-study data with matplotlib (no solver or inferred fields)."""
import argparse
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LogNorm, Normalize
from matplotlib.patches import Rectangle
import numpy as np


def load(path):
    return json.loads(gzip.decompress(path.read_bytes()) if path.suffix == ".gz" else path.read_text())


def render(directory, output):
    output.mkdir(parents=True, exist_ok=True)
    report = load(directory / "report.json")
    summary = load(directory / "sensitivity.json")
    runs = {r["id"]: r for r in report["observations"]}
    layouts = ("open", "isolated", "pair", "street")
    plt.rcParams.update({"font.size": 10, "axes.titlesize": 12, "axes.labelsize": 10})
    fig, axes = plt.subplots(4, 3, figsize=(13, 14), layout="constrained")
    keys = ("peakPa", "positiveImpulsePaS", "arrivalS")
    titles = ("Peak overpressure (kPa)", "Positive impulse (Pa s)", "Arrival at 1 kPa (ms)")
    scales = (1e-3, 1, 1e3)
    norms = (LogNorm(0.1, 1000), LogNorm(0.1, 1000), Normalize(0, report["durationS"] * 1000))
    images = []
    for row, layout in enumerate(layouts):
        run = runs["open-control" if layout == "open" else f"{layout}-finest"]
        data = load(directory / run["mapFile"])
        solids = np.array(data["everSolid"]).reshape(data["ny"], data["nx"])
        for column, key in enumerate(keys):
            ax = axes[row, column]
            values = np.array([np.nan if x is None else x for x in data[key]]).reshape(data["ny"], data["nx"])
            cmap = plt.get_cmap("magma" if column < 2 else "viridis").copy()
            cmap.set_bad("white")
            im = ax.imshow(values * scales[column], extent=(0, 40, 0, 32), origin="lower",
                           cmap=cmap, norm=norms[column], interpolation="nearest")
            mask = np.ma.masked_where(~solids, np.ones_like(solids, dtype=float))
            ax.imshow(mask, extent=(0, 40, 0, 32), origin="lower", cmap="Greys", vmin=0, vmax=2, interpolation="nearest")
            for x, y in [(16, 6), (16, 20), (26, 6), (26, 20)][:len(run["bodies"])]:
                ax.add_patch(Rectangle((x, y), 6, 6, fill=False, color="#4c7c9b", linewidth=0.8))
            ax.plot(8, 16, "*", color="#24b8e8", markersize=10, markeredgecolor="black", markeredgewidth=0.5)
            for n, (x, y) in enumerate([(14, 9), (24, 9), (24, 16), (34, 16)], 1):
                ax.plot(x, y, "o", color="white", markeredgecolor="black", markersize=3)
                ax.annotate(str(n), (x, y), xytext=(3, 3), textcoords="offset points", color="#16779c", fontsize=8)
            if row == 0:
                ax.set_title(titles[column])
                images.append(im)
            ax.set_xlabel("x (m)")
            ax.set_ylabel(f"{layout.capitalize()}\ny (m)" if column == 0 else "y (m)")
            ax.set_xlim(0, 40)
            ax.set_ylim(0, 32)
    for column, im in enumerate(images):
        fig.colorbar(im, ax=axes[:, column], location="bottom", shrink=0.9, pad=0.04)
    fig.suptitle("Street interactions: matched conventional source, changing neighbours\n"
                 "0.125 m air cells · 0.5 m probe spacing · 1.5 m plane · first 120 ms", fontsize=15)
    fig.supxlabel("Grey: a probe stencil touched solid. White arrival cells: threshold unreached. Star: source. Dots: gauges 1–4.\n"
                  "Invented buildings; fixed 1 m source deposition radius; these results are not measured validation.", fontsize=9)
    fig.savefig(output / "exposure.png", dpi=150)
    plt.close(fig)

    fig, axes = plt.subplots(2, 2, figsize=(12, 8), layout="constrained")
    colours = {"open": "#555555", "isolated": "#335f9d", "pair": "#cd6c25", "street": "#2b8260"}
    for index, ax in enumerate(axes.flat):
        for layout in layouts:
            run = runs["open-control" if layout == "open" else f"{layout}-finest"]
            samples = np.array(run["gaugeObservations"][index]["samples"])
            ax.plot(samples[:, 0] * 1000, samples[:, 1] / 1000, label=layout, color=colours[layout], linewidth=1.4, linestyle="--" if layout == "open" else "-")
        gauge = runs["street-finest"]["gaugeObservations"][index]
        ax.set_title(f"{index + 1}. {gauge['name']} — nominal {gauge['positionM']} m")
        ax.set_xlabel("Time (ms)")
        ax.set_ylabel("Overpressure (kPa)")
        ax.grid(alpha=0.2)
        ax.set_xlim(0, 120)
        ax.legend()
    fig.suptitle("Neighbour geometry changes the pressure histories", fontsize=15)
    fig.supxlabel("Containing-cell probes; sampling centres differ from the map probes. Finite 120 ms window.", fontsize=9)
    fig.savefig(output / "histories.png", dpi=150)
    plt.close(fig)

    fig, axes = plt.subplots(1, 3, figsize=(13, 4.5), layout="constrained")
    names = ("coarse", "medium", "fine", "adaptive", "half-cfl")
    for layout in ("isolated", "pair", "street"):
        rows = {r["run"]: r for r in summary["comparisons"]}
        for index, key in enumerate(("peakRelativeL1", "impulseRelativeL1", "arrivalMeanAbsoluteErrorS")):
            values = [rows[f"{layout}-{name}"][key] for name in names]
            scaled = [v * (1000 if index == 2 else 100) for v in values]
            axes[index].plot(range(4), scaled[:4], "o-", label=layout, color=colours[layout])
            axes[index].plot([4], [scaled[4]], "x", color=colours[layout], markersize=8)
    for ax, title, ylabel in zip(axes, ("Peak map sensitivity", "Impulse map sensitivity", "Arrival map sensitivity"),
                                ("Relative L1 difference (%)", "Relative L1 difference (%)", "Mean absolute difference (ms)")):
        ax.set_title(title)
        ax.set_ylabel(ylabel)
        ax.set_xticks(range(5), ("1 m", "0.5 m", "0.25 m", "0.5 m\nrefined ×2", "0.25 m\nhalf CFL"))
        ax.grid(alpha=0.2)
        ax.axvline(3.5, color="#888888", linestyle=":", linewidth=0.8)
        ax.legend()
    fig.suptitle("Resolution sensitivity: reference 0.125 m; half-CFL comparison: reference 0.25 m", fontsize=13)
    fig.supxlabel("Matched physical probes with common fluid stencils; exclude a 1 m edge margin and points within 3 m of source.\n"
                  "Arrival differences use commonly reached points. A smaller difference alone does not establish convergence.", fontsize=9)
    fig.savefig(output / "sensitivity.png", dpi=150)
    plt.close(fig)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    render(args.directory, args.out)
