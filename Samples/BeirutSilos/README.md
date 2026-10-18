# Beirut's grain silos as a block

Two layouts for the comparison in [docs/beirut-2020.md](../../docs/beirut-2020.md#the-grain-silos-shadow-denny-et-al-2025)
with Denny et al. 2025 (*Shock Waves*, "The influence of obstacle geometric fidelity on blast wave
propagation", CC BY): 0.5 kt of TNT on rigid ground, and, in `block.json`, their rectangular silos at
full scale, 152.25 × 30.5 × 55.3 m with the front face 80 m from the charge and 40 m to its ocean
side. The gauges are theirs (Table 2, ×250) at 1 m, x from the charge through the silos, y along
them towards the city, and a line behind them at Z = 4, 5, 6 and 8 (79.37 m each, W = 500 t). Every
open face is 4 m/kg^(1/3) from the charge and the gauges.

```bash
BombCAD run block.json --resolution 2 --duration 2 --csv block.csv
BombCAD run free.json --resolution 2 --duration 2 --csv free.csv
```

Each gauge's peak and impulse in `block.csv` over those in `free.csv` is its shielding ratio.
