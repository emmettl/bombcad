# High-explosive craters from H. F. Cooper's 1976 estimates

`craters.json` holds numbers from H. F. Cooper Jr., *Estimates of Crater Dimensions for
Near-Surface Explosions of Nuclear and High-Explosive Sources*, RDA-TR-2604-001, R&D Associates
for Lawrence Livermore Laboratory, September 1976 (report date October 1976), 53 pp., OSTI
[6696719](https://www.osti.gov/biblio/6696719). The user's copy of the OSTI scan, fetched on
21 October 2026, is on `$BOMBCAD_DATA/sources/cooper-craters-1976/`; it is not in
the repository.

- **Table 1** (p. 22): the cratering efficiency V₀ (ft³ of apparent crater per ton) at zero height
  of burst for wet soil, dry soil, soft rock and hard rock, best estimates and ranges.
- **Figure 7** (p. 16): the best-estimate V₀ of ten media, from wet clay (10,000) to hard rock
  (500).
- **Equation 6** (p. 15): the height-of-burst factor e^(−5.2 H), H = HOB / V^(1/3), for |H| < 0.4.
- **Equations 14 and 15** (pp. 37–39): the apparent radius and depth from the volume.
- **Figures 9–12** (pp. 18–21): 135 points of V/Y against H, by medium. Digitised from the scan at
  150 dpi (`pdftoppm`): the frame and tick marks were found as the long dark rows and columns, each
  marker as a connected blob of dark pixels inside the frame, and its centre mapped through the
  ticks (H, linear) and the frame (V/Y, four decades, logarithmic). Markers that touch were split
  evenly along the stack, so a column of markers at H = 0 counts about as many points as it holds.
  The legends, the axes' ticks and the foot of the H = 0 rule were left out, and so were the two
  points figure 9 marks "(?)". About 0.01–0.02 in H and 10% in V/Y. The markers' own media within
  a figure (alluvium beside playa, say) are not told apart.

Assumed, not stated: the ton is a short ton, 2,000 lb of TNT, and the height of burst is to the
charge's centre, as is usual for these tests.

**Terms.** A US government-sponsored report: "Distribution of this document is unlimited" (the
report documentation page) and no copyright notice. Only the numbers above are transcribed, with
this citation; the scan is not redistributed.

Used by `CooperCraters1976` and `blastmodel craters-cooper` ([cratering](../../docs/cratering.md#against-cooper-1976)).
