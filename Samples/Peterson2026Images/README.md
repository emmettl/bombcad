# Peterson et al. (2026): cracks and spalling read from the high-speed images

`peterson-images.json` holds, for each impact-tested beam with frames, what its high-speed images
show: when the first crack and the first inclined crack formed, and where, at what angle; the main
crack's inclination (read automatically, or by hand where noted) and, where a station across it
held, its opening and slip every 0.5 ms to 10 ms; and when the concrete visibly spalled or burst
at the load or the support. It is compared with the model in
[validation](../../docs/validation.md#read-from-the-high-speed-images).

**Source.** V. Peterson, *High-speed camera dataset from impact tests on reinforced concrete
beams*, Mendeley Data, doi:10.17632/kn28g6dbj5.3, licensed
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); camera set-up from Peterson's KTH thesis
(2026, DiVA diva2:2029364). The tests are reported in V. Peterson, J. Magnusson, M. Hallgren and
A. Ansell, *International Journal of Impact Engineering* 208, 105539 (2026). This file is derived
from the frames and shared under the same licence; the frames are not copied here.

**How.** `Scripts/peterson2026/images`: `analyse.py` (with `dic.py`) computes the displacement
field from the frame before impact by OpenCV's Farnebäck optical flow, finds cracks as regions of
major principal strain of 3% or more and 15 mm or longer, takes their angle by principal axes and
tracks points 6 mm either side of the main crack; `fixture.py` writes this file, with the cracks
read by hand from the last frames for the deep beams and D-2d-NoS-1. Python 3.9 with numpy, scipy,
scikit-image, OpenCV and Pillow. Times are from the frame in which the top of the beam under the
load first moves.

**Uncertainty.** Times ±0.25 ms; inclinations about ±5° read automatically, ±8° by hand; openings
and slips ±0.05 mm below 1 mm, and a lower bound beyond about 3 mm, where the speckle across a wide
crack no longer correlates. Spalling is visible damage only: crushing short of it is not
resolved at 0.53 mm a pixel. D-2d-S90-1 has no frames in the dataset; D-2d-NoS-2's end about 1 ms
after the impact.
