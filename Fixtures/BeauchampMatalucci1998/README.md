# Sandia's windows at EMRTC (Beauchamp and Matalucci, 1998)

`windows.json` holds numbers from E. K. Beauchamp and R. V. Matalucci, *Dynamics of Window Glass
Fracture in Explosions*, SAND98-0598, Sandia National Laboratories, May 1998, 62 pp., OSTI
[658184](https://www.osti.gov/biblio/658184), doi:10.2172/658184. The user's copy of the OSTI scan,
fetched on 21 October 2026, is on
`/Volumes/StudioData/bombcad/sources/beauchamp-glass-fracture-1998/`; it is not in the repository.

Three shots at the Energetic Materials Research and Testing Center, Socorro, each against four
panes in one window of a reinforced concrete building, and a later test filmed for speed:

- **The window** (section 3.0): four panes with a 16 × 22 in open area each, in soft putty over
  foam in an angle-iron frame, in a 36 × 48 in opening of a 12 in wall. The charge was on the line
  normal to the window through its centre.
- **The shots** (table 2): 0.22 lb of C4 at 12 ft, and 25 and 13 lb of ANFO at 20 ft. Their nominal
  peak and impulse are from handbook data. Only shot 1's pressure was measured: 4 psi, on two gauges
  at the front of the window.
- **The panes** (table 1, sections 4–6): annealed and tempered glass, most of it weakened on purpose.
  The flaws were Vickers indents of 1–30 kg, a flame- or laser-annealed spot, or none (as received).
  Each pane is listed with whether it broke, and the stresses the fractures gave (tables 3 and 4).
  Only one pane held, shot 1's 1/2 in annealed sheet.
- **The speeds** (figure 20's legend): the central clusters of two 1/8 in and two 1/4 in annealed
  panes, filmed under shot 3's conditions in a non-Sandia test. The zero-crossing times are read
  off the figure and are approximate.
- **The fragments** (sections 5.2.3, 8.1): the annealed edge band's shard sizes, the tempered
  sheets' clusters of dice, and the share caught in the backstop.

**What it is not:** a threshold series. Every pane but one broke, most had flaws put in, and the
loads were not measured beyond shot 1's gauges. The report's own reading is that the indents
blunted in the 3–5 days before the shots, so the flaws did not set where the sheets broke at
12.7 psi: they broke from their corners.

**Terms.** A Sandia report for the US Department of Energy, "Unlimited Release" and "Distribution
of this document is unlimited" on its cover, with no copyright notice. Only the numbers above are
transcribed, with this citation; the scan is not redistributed.

Used by `SandiaWindows1998` and `blastmodel glass-sandia`
([validation](../../docs/validation.md#sandias-windows)).
