# Hayman 2014: one-way reinforced masonry walls under blast

M. Hayman, *Response of one-way reinforced masonry flexural walls under blast loading*, MASc thesis,
McMaster University, 2014 (MacSphere 11375/16312). The thesis carries only a copyright notice, so
only numbers and short paraphrases derived from it are kept here; the PDF stays off the repository
(on StudioData, `bombcad/data/Hayman2014/`).

`hayman2014.json` holds, each with its page or table:

- the six third-scale walls (1 × 1 m, 63.3 mm, fully grouted, one layer of vertical bars at mid
  thickness, D4 or D7 in every cell), their materials (prisms, grout, mortar, steel yields);
- the rig: one-way, simply supported top and bottom on rods, sides free, in a steel bunker with wing
  walls and a parapet;
- each wall's single shot (6, 12 or 30 kg TNT-equivalent of Pentex-D at 5 m, a surface burst), its
  reflected peak and impulse from Friedlander fits to the gauges (Tables 2.2 and 3.3, which disagree
  in places), and the Kingery–Bulmash values;
- the measured mid-height displacement, support rotation, damage and damage state, the times and
  residuals read by eye from the figures;
- the thesis's own SDOF and resistance-function predictions, for context.

Read 17 October 2026 by a subagent from the PDF's text and Figs 2.1, 2.5, 2.7 and 2.8. Its
inconsistencies are kept as notes in the JSON (ρv 0.62 or 0.68%, bar spacing, WMH6's peak 14.57 or
15.6 mm, WMH12's damage state, WMH6's impulse identical to WML6's). Neither the walls' density nor
the positive phases' durations are given. See docs/building-envelopes.md#one-way-walls.
