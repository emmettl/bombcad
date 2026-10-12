# UFC 3-340-02's blast charts

Charts from UFC 3-340-02, *Structures to Resist the Effects of Accidental Explosions*, US
Department of Defense, 5 December 2008, digitised by `Scripts/digitise-sources`. The user's copy
is on `/Volumes/StudioData/bombcad/data/UFC-3-340-02/`; only these derived numbers are kept here,
with citation. Units are the manual's own (psi, ms, ft, lb); W is the TNT charge weight in lb.

| File | Figures (PDF pages) | What | How read | Error |
|------|---------------------|------|----------|-------|
| `oblique-reflection.json` | 2-9, 2-10 (161, 162) | Peak reflected pressure (psi) and scaled reflected impulse (psi ms/lb^(1/3)) on a surface against the angle of incidence, 0–85°, for ten scaled normal distances H_c/W^(1/3) of 0.3 to 14.3 ft/lb^(1/3) | Vector: each coloured curve's drawing commands mapped through the chart frame; sampled every 5° | Calibration within 0.14% of the gridlines; the curves as drawn |
| `vented-gas-impulse.json` | 2-153 to 2-163 (304–314) | Scaled gas impulse i_g/W^(1/3) (psi ms/lb^(1/3)) against scaled vent area A/V_f^(2/3), 0.02–5, for W/V_f of 0.002, 0.015, 0.15 and 1.0 lb/ft³, reflected impulses of 20, 100 and 600, and frangible covers W_F/W^(1/3) of 0 to 100 | Vector, each axis fitted to its printed tick labels (pdftotext's positions), each curve named by the number printed at its end | Labels fitted within 0.0003 decades (0.07%) |
| `negative-phase.json` | 2-8, 2-16 (160, 167) | The negative phase of a spherical free-air burst and a hemispherical surface burst against Z = R/W^(1/3) (ft/lb^(1/3)): incident and reflected underpressure (psi), their scaled impulses (psi ms/lb^(1/3)), duration (ms/lb^(1/3)) and wavelength (ft/lb^(1/3)) | Scanned: each line traced column by column at 220 dpi along anchor points read by eye (which only decide which line is meant where lines cross), median-filtered over five columns, sampled every 0.05 in log Z | About ±2 px on 4–5 px lines: ±1–1.5% in value; frames checked against the tick labels |

Notes. Figures 2-154 and 2-155 print one curve's label as ".03" where the others' sequence has
0.3; it is kept as printed, marked "probably 0.3". Figure 2-16's underpressure close in reads
15.0 psi, against the vacuum's 14.7: the reading error. Figures 2-9 and 2-10 are plots for a
charge at a height H_c above the surface: the manual uses them for the Mach front on the ground
before a structure, but they serve any surface at a known normal distance.
