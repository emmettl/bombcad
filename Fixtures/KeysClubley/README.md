# Keys and Clubley's masonry panels under long-duration blast

`walls.json` holds the three single flat panels (BWL1A, BWL2C, BWL3B) from R. A. Keys and
S. K. Clubley, "Experimental analysis of debris distribution of masonry panels subjected to long
duration blast loading", *Engineering Structures* 130 (2017) 229–241 (accepted manuscript,
Loughborough repository, figshare 9443321, CC BY-NC-ND 4.0), with construction details from
R. A. Keys's PhD thesis (University of Southampton, 2016). The licence forbids derivatives of the
text, so only numbers are kept here: the loads from the paper's table 1, crack heights and
fragment statistics from its text, and the debris mass by distance read off figures 14, 19 and
20 to about 3 kg per bin (each curve sums to within 2–8 kg of the paper's stated total). The
trials were at MoD Shoeburyness and their data remain the property of the UK MoD.

The paper's legends label the two fragment totals the wrong way round (the large total is the
mass in fragments over 0.1 kg); the fixture names them by what they are.

The PDFs are not in the repository; they are on `/Volumes/StudioData/bombcad/data/`.

## Draft status

This is a draft, folded into the Roadmap status session's Keys comparison. `blastbench keys`
here drives the measured wave in at the tunnel's upstream face (`MasonryDebrisTest.inflow`: the
Friedlander curve fitted to the measured peak, positive phase and impulse; the shock's jump by
Rankine–Hugoniot; a simple wave behind it), written into the two inlet cell layers every eight
steps.

First run, BWL2C, 100 ms only (5 cm air, 25 mm elements, about 1 min on a loaded Studio):
- incident peak 72 kPa against 60 measured, but that gauge sat 1 m upstream of the wall and
  probably caught its reflection; it now sits 0.3 m from the inlet;
- impulse 3458 Pa s by 100 ms against 3952 over the whole positive phase;
- front-face peak 151 kPa (measured reflected 131);
- bed joints open across half the width at 50 ms at the base and about 0.46 and 0.76 m (measured
  0.5 and 1.5 m); 160 elements failed by 50 ms and no more by 100 ms;
- no debris had landed by 100 ms; the 1.5 s run was stopped before it finished.
