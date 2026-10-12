# Keys's brick walls: where their debris landed

`debris.json` holds the longitudinal debris distributions of nine brick walls from R. A. Keys's
PhD thesis, *Experimental & computational structural analysis of masonry panels subject to long
duration blast loading*, University of Southampton, 2016
([eprint 413951](https://eprints.soton.ac.uk/id/eprint/413951/)), some also in R. Keys and
S. K. Clubley, *Engineering Structures* 130 (2017) 229–241, doi:10.1016/j.engstruct.2016.10.054.
The thesis is under the University of Southampton Thesis Licence; its acknowledgements say the
trial data remain the property of the UK Ministry of Defence. These numbers are read off the
thesis's published figures, not taken from the data, and are used only to compare the model.

Each wall is single-leaf solid brick in running bond, one brick (102.5 mm) thick and 2 m high:
an "A panel" 1 m long, or two side by side ("AA", BWL3B), or unmortared (MW1). Every brick was
numbered, and the debris collected and weighed over a 0.5 m grid (1 m bins along the tunnel for
MW1, MW2 and BWL1A). `masses_kg` is the mass in each bin along the radial from `first_bin_m`, in
bins of `bin_m`, with x = 0 at the wall's upstream face.

| Wall | Figure | Load |
|------|--------|------|
| WR1A, WR1B, WR2C | 4.17c, 4.20c, 4.30c | 41 kg TNT on the ground at 10.6, 13 and 15 m (Windrush Arena) |
| WR1C | 4.22c | as WR2C, but rebuilt a week before firing in weaker mortar |
| MW1, MW2, BWL1A | 4.6, 4.12, 4.39 | Air Blast Tunnel, 4.9 m section: about 110 kPa for 200 ms |
| BWL2C, BWL3B | 4.58c, 4.73c | Air Blast Tunnel, 10.2 m section: about 55 kPa for 150 ms |

The histograms were read by `Scripts/keys2016` from the figures' embedded images (425 to 850
pixels wide), each bar's top found over the middle half of its bin; a bin is good to about two
pixels, 0.5 to 1 kg. Checked against the masses the text quotes: BWL1A's peak 47.3 kg at 31 m
(read 48.0), BWL2C's 67.5 kg at 6.5 m (67.0), MW1's total 496.5 kg (487.4) and 226.4 kg between
20 and 29 m (216.0). MW1's tallest bin, 45.5 kg by the text, runs off the figure's 45 kg axis and
reads 39.1 kg. The totals differ from wall to wall (340 to 400 kg for an A panel) as collected.

`panels.json` holds the paper's three flat tunnel panels (BWL1A, BWL2C, BWL3B) as the close-in
breach session drafted them (commit 7296c2f): the measured loads from the paper's table 1
(incident and reflected overpressure, impulse, dynamic pressure, positive phase), the bed joints
seen open at 50 ms, the shares of whole bricks and the largest fragments, from its text, and the
debris mass by distance read off the paper's figures 14, 19 and 20. The paper is CC BY-NC-ND
4.0, so only numbers are kept. Its legends swap the two fragment totals (the large one is the
mass in fragments over 0.1 kg); the file names them by what they are. Its curves and the
thesis's histograms here agree on the mean distance within 0.4 m (BWL1A 26.8 against 27.1 m,
BWL2C 6.8 against 6.4 m, BWL3B 5.9 against 6.0 m); the BWL2C curves sit about one bin apart,
and BWL1A's thesis histogram sums to 400 kg against the paper's 345 kg. The paper notes that
instrumentation columns at about 30 m (BWL1A) and camera lights at about 7 m (BWL2C, BWL3B)
piled debris against them.

`blastbench keys` runs the model against the Windrush walls (see
[Validation](../../docs/validation.md#brick-walls-debris)). `blastbench keys --tunnel` runs the tunnel
walls, the measured wave driven in at the tunnel's inlet (the driver is the breach session's).
