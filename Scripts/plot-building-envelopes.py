#!/usr/bin/env python3
"""Plot checked envelope exposure, numerical sensitivity and local scaling observations."""
import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import PowerNorm
from matplotlib.patches import Circle
import numpy as np

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location("envelope_check", Path(__file__).with_name("check-building-envelopes.py"))
checker = module_from_spec(spec)
spec.loader.exec_module(checker)


def plot(directory, output):
    summary = checker.check(directory)
    report = checker.read(directory / "report.json")
    if not report["completeMatrix"]:
        raise ValueError("Figures require the complete matrix")
    runs = {r["id"]: r for r in report["observations"]}
    output.mkdir(parents=True, exist_ok=True)
    plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False})
    fig, axes = plt.subplots(2, 2, figsize=(11, 8), constrained_layout=True)
    for column, (field, divisor, label) in enumerate([
        ("peakPa", 1000, "Peak overpressure (kPa)"),
        ("positiveImpulsePaS", 1, "Positive pressure impulse (Pa s)"),
    ]):
        maps = [checker.read(directory / runs[f"street-{mode}-finest"]["mapFile"])
                for mode in ["detailed", "envelope"]]
        limit = max(v for m in maps for i, v in enumerate(m[field])
                    if v is not None and ((i % m["nx"] + 0.5) * 0.5 - 8) ** 2
                    + ((i // m["nx"] + 0.5) * 0.5 - 16) ** 2 >= 9) / divisor
        for row, (mode, m) in enumerate(zip(["Pinned detailed buildings", "Stationary envelopes"], maps)):
            data = np.array([np.nan if v is None else v / divisor for v in m[field]]).reshape(m["ny"], m["nx"])
            palette = plt.get_cmap("magma").copy()
            palette.set_bad("#afb4bb")
            artist = axes[row, column].imshow(data, origin="lower", extent=[0, 40, 0, 32],
                norm=PowerNorm(0.5, vmin=0, vmax=limit), cmap=palette, interpolation="nearest")
            axes[row, column].add_patch(Circle((8, 16), 3, facecolor="white", edgecolor="white"))
            axes[row, column].set_title(f"{mode}\n{label}")
            axes[row, column].set_xlabel("x (m)")
            axes[row, column].set_ylabel("y (m)")
            fig.colorbar(artist, ax=axes[row, column], shrink=0.85)
    fig.suptitle("Shared-flow street exposure · 2 kg TNT equivalent · 120 ms\n0.125 m air; common scales; 3 m source neighbourhood omitted", fontsize=13)
    fig.savefig(output / "exposure.png", dpi=160)
    plt.close(fig)

    fig, axes = plt.subplots(1, 3, figsize=(14, 4.8), constrained_layout=True)
    for mode, color in [("detailed", "#2878b5"), ("envelope", "#de6f22")]:
        sizes = [s["buildings"] for s in summary["scaling"] if mode in s]
        for axis, (field, divisor, ylabel) in zip(axes, [
            ("solverBytes", 1e6, "Solver GPU buffers (MB)"),
            ("runWallS", 1, "Run wall time (s)"),
            ("commandGPUS", 1, "Summed command GPU time (s)"),
        ]):
            values = [s[mode][field] / divisor for s in summary["scaling"] if mode in s]
            axis.plot(sizes, values, "o-", color=color, label="Pinned detailed" if mode == "detailed" else "Envelope")
            sample_field = {"runWallS": "wallSamplesS", "commandGPUS": "gpuSamplesS"}.get(field)
            if sample_field:
                for s in summary["scaling"]:
                    if mode in s:
                        axis.scatter([s["buildings"]] * 3, s[mode][sample_field], color=color, alpha=0.35, s=15)
            axis.set_xscale("log", base=4)
            axis.set_xticks([1, 4, 16, 64], ["1", "4", "16", "64"])
            axis.set_xlabel("Buildings (domain also grows)")
            axis.set_ylabel(ylabel)
            axis.grid(alpha=0.2)
            axis.legend()
    fig.suptitle("Computational scaling · 0.5 m air · 60 ms cutoff\nLines: medians of 3 runs; dots: individual timings; surface recorder disabled", fontsize=13)
    fig.savefig(output / "scaling.png", dpi=160)
    plt.close(fig)

    fig, axes = plt.subplots(1, 2, figsize=(11, 4.8), constrained_layout=True)
    for layout, color in [("isolated", "#2878b5"), ("pair", "#de6f22"), ("street", "#35834b")]:
        for axis, field, label in zip(axes, ["peakRelativeL1", "impulseRelativeL1"],
                                    ["Peak relative L1 difference (%)", "Impulse relative L1 difference (%)"]):
            for mode, marker in [("detailed", "o"), ("envelope", "x")]:
                rows = {r["candidate"].rsplit("-", 1)[1]: r for r in summary["sensitivity"]
                        if r["candidate"].startswith(f"{layout}-{mode}-")}
                values = [rows[s][field] * 100 for s in ["medium", "fine", "adaptive"]]
                axis.plot(range(2), values[:2], marker=marker, color=color,
                    markerfacecolor="none", linestyle="-" if mode == "detailed" else ":",
                    label=f"{layout.title()} · {mode}")
                axis.plot([2], values[2:], marker=marker, color=color, markerfacecolor="none", linestyle="none")
            axis.set_xticks(range(3), ["0.5 m", "0.25 m", "0.5 m ×2"])
            axis.set_ylabel(label)
            axis.grid(alpha=0.2)
    axes[1].legend(fontsize=8)
    for axis in axes:
        axis.axvline(1.5, color="grey", linewidth=0.7, alpha=0.5)
    fig.suptitle("Resolution sensitivity against 0.125 m air\nCommon physical probes; numerical reference differences, not measured errors", fontsize=13)
    fig.savefig(output / "sensitivity.png", dpi=160)
    plt.close(fig)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    plot(args.directory, args.out)
