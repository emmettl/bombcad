kind: added

**Fire after the blast, building to building over hours, headless: `scenebench fire` and
`blastmodel fire`.** You give it a district's inputs, seeds and a wind.
- **Seeds:** the surface heating's ignitions, buildings near a point, map ids, or ignitions drawn
  at random.
- **What it gives:** the buildings alight and burnt out each hour, over a seeded ensemble, and each
  building's chance of burning, as text, JSON and CSV.

It is the NZ Fire Service's post-earthquake model (GNS Science and Victoria University of
Wellington, Reports 27, 44 and 80), adapted from cells to buildings and from earthquakes to blasts.
It works by radiation from a burning face, sparks carried by the wind, and fire through windows
that the quick estimate's broken glass opens. It reproduces its reports' flux table and critical
separations.

**Standing: illustrative,** and judged only qualitatively, on Beirut 2020. Twenty ignitions in its
concrete and stone take about a hundred buildings and die out within hours, where the same streets
in timber burn by the thousand. See [Fire spread](../../fire-spread.md).
