# ADBLAST's blast tests on steel cladding

`tests.json` holds numbers from B. Hoffmeister, N. Schillo, C. Colomer, A. Elghazouli, L. Nardini,
W. Salvatore, D. Lecompte, B. Reymen, J. Vantomme, J. Maljaars, M. Schelland, T. Vrouwenvelder and
R. Obiala, *Advanced design methods for blast loaded steel structures (ADBLAST)*, final report of a
Research Fund for Coal and Steel project, European Commission, EUR 27487 EN, 2015 (reproduction
authorised with the source acknowledged). The report is on StudioData
(`bombcad/profiled-sheeting/adblast/`, with its `SOURCE.md`).

**Single-span claddings** (Table 15, Figure 18): twelve shots by the Royal Military Academy in
Brussels on three TR84/273 trapezoidal sheets, 0.75 or 1.5 mm, over a 2.46 m span between two
square tubes, screwed to them with HILTI S-MP 52Z 6.3×25 self-tapping screws; 0.5–1.5 kg of C4
3.5 m above the middle. The reflected pressure and impulse and the deflection were measured at the
middle: the first dynamic deflection (down, negative) and the plastic deformation left (up,
positive).

**Claddings on a purlin** (Table 17): twelve shots on four TR35 or TR84 sheets over a U 60 × 30 × 6
mid-purlin, bolted or slotted at its ends; with the forces passed to the purlin and its plastic
deformation. Where screws pulled through, the purlin took the impulse.

Also: the sheets' coupon tests at three strain rates (Table 8), and the screws' stiffness and
capacity used in the report's own design example (Annex A 7.2.3).

The [substructure desk stage](substructure/README.md) records the Table 17 audit, rig gaps,
TR35 geometry and the charge-selection protocol fixed before a mechanical comparison.
