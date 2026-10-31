kind: changed

**Fire after the blast colours each building by its chance of catching from a neighbour.** The
chance is taken over the draws in which the building was not itself a starting fire, so random
starting fires no longer colour the buildings they happen to land on. A building that is a starting
fire in every draw, such as one picked by hand, is grey under its outline; with fires picked by
hand every other building is coloured exactly as before. The legend, its caption and the selected
building's panel say what is measured, and the panel gives the draws it was a starting fire in.
The earlier map stays by name, under **Caught ▸ At all, seeds with it (earlier map)**, and
headless as `--map-chance caught`. `scenebench fire` and `blastmodel fire` now write each
building's starting-fire draws and neighbour chance, and print the map's bands. On Beirut with 20
fires at random within 1.5 km the change is small: 320 of the 2,880 buildings there are grey at 12
hours against 75, because most of the rest do have a few percent chance from their neighbours'
fires. Illustrative, as before. See
[Fire spread](../../fire-spread.md#the-chance-of-catching-from-a-neighbour-31-october-2026).
