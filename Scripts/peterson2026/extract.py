"""Peaks and timing from Peterson's DAQ records (V. Peterson, Mendeley Data, doi:10.17632/kn28g6dbj5.3,
CC BY 4.0), for the bombcad comparison.

Per beam: the impact found where the striker's deceleration, smoothed over 0.5 ms, first passes 1,000 m/s^2; each channel's offset
taken off as its mean over the 50 ms before; the impact force as the striker's 70 kg times its
deceleration (Peterson's eq. 4.2), smoothed by a centred moving average of `window` ms (0.42 ms by default, as bombcad's readout), as his low-pass
filter (cut-off not given) removes the striker's own ringing; the support reactions likewise.
"""

import glob
import json
import os
import sys

import numpy as np

from readmat import load

ROOT = "/Volumes/StudioData/bombcad/data/Peterson2026/data/DAQ System Measurements"
MASS = 70.0
RATE = 19200.0


def smooth(signal, window_ms):
    n = max(1, int(round(window_ms * 1e-3 * RATE)))
    if n == 1:
        return signal
    kernel = np.ones(n) / n
    return np.convolve(signal, kernel, mode="same")


def beam(path, window_ms):
    data = load(path)
    t = np.atleast_1d(data["Channel_1_Data"])
    close, far = np.atleast_1d(data["Channel_2_Data"]), np.atleast_1d(data["Channel_3_Data"])
    striker, beam_acc = np.atleast_1d(data["Channel_4_Data"]), np.atleast_1d(data["Channel_5_Data"])
    # The striker decelerates as it strikes; take whichever sign its spike has.
    sign = 1.0 if np.max(striker) >= -np.min(striker) else -1.0
    # The impact: where the striker's deceleration, smoothed over 0.5 ms, first passes 1,000 m/s^2
    # (14 kN on the 70 kg striker); a 50 g threshold on the raw signal tripped on noise.
    smoothed = smooth(sign * striker, 0.5)
    hit = int(np.argmax(smoothed > 1000.0))
    if smoothed[hit] <= 1000.0:
        return {"empty": True}
    if np.max(np.abs(close)) < 1.0 and np.max(np.abs(far)) < 1.0:
        empty_cells = True
    else:
        empty_cells = False
    before = slice(max(0, hit - int(0.05 * RATE)), max(1, hit - int(0.002 * RATE)))
    out = {}
    for name, signal in (("impact", sign * striker * MASS / 1000), ("close", close), ("far", far)):
        signal = signal - np.mean(signal[before])
        window = signal[hit - int(0.005 * RATE) : hit + int(0.05 * RATE)]
        filtered = smooth(window, window_ms)
        local = np.argmax(np.abs(filtered))
        out[name] = {
            "peak_kN": float(filtered[local]),
            "at_ms": float((local - int(0.005 * RATE)) / RATE * 1000),
        }
        if name == "impact":
            span = filtered[int(0.005 * RATE) : int(0.005 * RATE) + int(0.010 * RATE)]
            out[name]["impulse_10ms_Ns"] = float(np.sum(np.clip(span, 0, None)) * 1000 / RATE)
    out["record_s"] = float(t[-1])
    out["load_cells_empty"] = empty_cells
    return out


if __name__ == "__main__":
    window = float(sys.argv[1]) if len(sys.argv) > 1 else 0.42
    results = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "*", "*.MAT"))):
        name = os.path.basename(os.path.dirname(path)).replace("_", "-")
        results[name] = beam(path, window)
    print(json.dumps({"window_ms": window, "beams": results}, indent=1))
