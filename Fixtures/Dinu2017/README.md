# A steel column's web under 1.815 kg close in (the bunker tests, FRAMEBLAST)

`columns.json` holds what the test paper gives of the bunker tests on two HEB260 beam–column
specimens (INSEMEX Petroșani), and what FRAMEBLAST's report gives of the full-scale
building's shots (2018), for `blastbench dinu` (`DinuColumnTest`; emmettl/bombcad-work#77;
[validation](../../docs/validation.md#a-column-web-breached-close-in)).

The sources (none is in the repository; copies are under `$BOMBCAD_DATA/sources/`):

| Source | What it gives | Terms |
|--------|---------------|-------|
| Dinu, Marginean, Dubina, Kovacs and Ghicioi, Procedia Engineering 210 (2017) 377–385, doi:10.1016/j.proeng.2017.11.091 (obtained 30 October 2026) | The tests: the specimens' drawings, the measured steel (Table 1), the charges m1–m5, their shape, height and stand-offs, the web's dish after m4, the breaches after m5, gauge S6's peak, permanent strain and strain rate, the pressures at 3.5 m | CC BY-NC-ND 4.0 |
| FRAMEBLAST technical report, stage II (2018), UPT, via the Internet Archive's copy of 26 June 2023 | The full-scale building's ten shots, outcomes in words and photographs | None stated |

Before the paper, the setup came from FRAMEBLAST's stage I report (2017), Ahmed's SUSCOS thesis
(CTU Prague, 2018) and Dinu et al., ASCCS 2018 (doi:10.4995/ASCCS2018.2018.7186). Where those
differ from the paper, the paper's numbers are kept: the beams are IPE220 on 16 mm end plates
with M16 bolts (not IPE270, 20 mm, M24), and the breach after m5 is almost 500 and 600 mm (not
about 0.3 m: the ASCCS paper's "almost twice the flange width" fits the full HEB260 flange's
260 mm, not the cut 160 mm).

Readings off the paper's figures (strains in Fig. 4, the breach in the photographs) are to about
±10%. Not obtained: the SDSS 2016 paper (only its abstract page is archived), the SGEM 2020 paper
on the full-scale building (paid), and Marginean's 2017 thesis (the archived copy is cut off at
1 MB).
