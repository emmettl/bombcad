"""Dense image correlation of Peterson's high-speed frames (OpenCV Farneback optical flow from
the first frame), and the major principal strain it implies."""
import glob, os, sys
import numpy as np, cv2
from PIL import Image

ROOT = "/Volumes/StudioData/bombcad/data/Peterson2026/data/HSC Measurements"

def frames(beam):
    d = os.path.join(ROOT, beam)
    sub = [s for s in os.listdir(d) if s.lower().startswith("test")][0]
    fs = sorted(glob.glob(os.path.join(d, sub, "*.tif")))
    # keep the first contiguous run of frame numbers (D_1d_NoS_1 has a later run too)
    nums = [int(os.path.basename(f)[-10:-4]) for f in fs]
    run = [fs[0]]
    for a, b, f in zip(nums, nums[1:], fs[1:]):
        if b - a != 1: break
        run.append(f)
    return run

def load(f):
    return np.array(Image.open(f).convert("L"))

def flow(ref, img):
    return cv2.calcOpticalFlowFarneback(ref, img, None, pyr_scale=0.5, levels=5, winsize=21,
                                        iterations=5, poly_n=7, poly_sigma=1.5, flags=0)

def major_strain(f, sigma=1.5):
    u = cv2.GaussianBlur(f[..., 0], (0, 0), sigma)
    v = cv2.GaussianBlur(f[..., 1], (0, 0), sigma)
    uy, ux = np.gradient(u)
    vy, vx = np.gradient(v)
    exx, eyy, exy = ux, vy, 0.5 * (uy + vx)
    c = 0.5 * (exx + eyy); r = np.sqrt((0.5 * (exx - eyy)) ** 2 + exy ** 2)
    angle = 0.5 * np.degrees(np.arctan2(2 * exy, exx - eyy))  # direction of the major strain
    return c + r, c - r, angle
