# The fireball's rise and cloud

What becomes of the fireball once the blast has gone: the hot gas the air model leaves at the end
of a run is handed over to a model of a rising buoyant cloud, which follows its height, size,
temperature and rise speed for minutes after. It is the hand-over in sequence that
[Distributed computing](distributed-computing.md#the-long-term-visions-effects) foresaw: a few
numbers from the air model's final state, and nothing passed back.

**Standing: illustrative.** The cloud is a textbook integral model of a turbulent thermal, with
coefficients from laboratory thermals, started from whatever the gas model leaves; it agrees in
height, within a factor of about 1.6, with an empirical fit to high-explosive clouds (below), but
nothing here has been compared with a measured cloud's growth over time. Use it to see roughly
how high and wide the cloud of a charge goes and how that changes with the charge and the gas
model, not for dispersion or hazard estimates.

```bash
swift run -c release BombCAD run street.bombcad --cloud cloud.json --cloud-results cloud-results.json --usd street.usda
```

The description is JSON; any field left out takes its default, so `{}` will do:

```json
{
  "handOverTemperature": 500,
  "entrainment": 0.25,
  "addedMass": 0.5,
  "emissivity": 0,
  "lapseRate": 0.0065,
  "tropopause": 11000,
  "specificHeat": 1005,
  "duration": 600,
  "frameInterval": 1
}
```

## The model

- **The hand-over** is every cell of air in the domain at least `handOverTemperature` kelvin
  (500 K by default) at the end of the run, once brought to the ambient pressure. Each cell is
  taken to the ambient pressure isentropically, with the run's gamma, which matters only where
  the blast has not quite left it; its temperature is then p / (ρR), which for dissociating air
  is above the true temperature but gives the right density, and so the right buoyancy. The
  cloud starts as a sphere of their mass, of the volume they then fill, at their centre of mass,
  at their mass-weighted temperature and rising at their mean vertical velocity.
- **The cloud** is a sphere of well-mixed gas at the pressure of the air around it, a turbulent
  thermal in the sense of Morton, Taylor and Turner (1956): it draws in the surrounding air across
  its surface at a speed that is a fixed share α, the `entrainment` coefficient, of its rise
  speed. Escudier and Maxworthy (1973) showed how to keep that assumption without the small
  density differences of the original, and that the added mass of the air the cloud pushes aside
  matters at any density; this model follows them. With m its mass, V its volume, b its radius, w
  its rise speed, T its temperature and ρ_air, T_air and p_air the air's at its height:
  - mass: dm/dt = 4π b² α ρ_air |w|
  - impulse: d/dt [(m + k ρ_air V) w] = (ρ_air V − m) g, k the `addedMass`, a half for a sphere
  - heat: m c_p dT/dt = c_p (T_air − T) dm/dt + m (R T / p_air)(dp_air/dz) w − εσ(T⁴ − T_air⁴) 4πb²

  The terms of the last are the air drawn in, cooling by expansion as the pressure falls
  (c_p dT = dp / ρ), and radiation, off by default (`emissivity` 0). The gas is ideal air with a
  constant specific heat throughout, and V = mRT / p_air.
- **The atmosphere** is still and dry: the temperature falls from the run's own ambient air at the
  ground at `lapseRate` (6.5 K/km, the standard atmosphere's) up to the `tropopause` and is
  constant above it, and the pressure is in hydrostatic balance. Air cooling more slowly with
  height than the 9.8 K/km of dry air rising is stable, so a cloud rises until it has mixed itself
  down to the temperature of its surroundings, overshoots and settles back. Lapse rates of
  g / c_p or more, in which nothing would stop it, are refused.
- **Stopped rising** is the first moment the rise speed falls to zero, a common definition of a
  cloud's stabilisation; the model goes on past it to `duration` seconds after the run.
- **The domain and the ground are left behind**: the cloud rises freely from the hand-over, with
  no blocks, structure, ground or domain ceiling, and the ground does not hold it back even while
  it overlaps it at the start.

Integration is by fourth-order Runge–Kutta, with steps short against the time the cloud takes to
rise its own radius, from rest or at its speed, and to draw in its own mass; the whole ten minutes
takes a few milliseconds.

## Checks

The tests check the model against what it should reproduce exactly:

- **The self-similar thermal.** In uniform surroundings the buoyancy F = g m (T − T_air) / T_air
  is conserved, the impulse (1 + k) ρ (4π/3) b³ w grows as F t, and with b = αz the height follows
  z⁴ = 3 F t² / (2π (1 + k) ρ α³). A weakly buoyant thermal started on that path stays on it to a
  part in a thousand over a thousandfold in time, with b = αz and w = z / 2t.
- **A hot start.** A sphere seven times as hot as the air conserves F to a part in ten thousand
  however hot, and later grows as the self-similar law says, b² rising at α² √(3F / (2π (1 + k) ρ
  α³)), to within 1%.
- **The ceiling in stable air.** From a small start, the height at which the cloud stops rising
  doubles for sixteen times the buoyancy and grows by √2 for a quarter of the stability N², the
  (F / N²)^¼ that dimensional analysis requires of a thermal in a stable fluid, to within 1%.
- The standard atmosphere's pressure at the tropopause and at 20 km, a hot sphere in the air model
  handed over with its mass, place, temperature and buoyancy, and a headless run whose number of
  steps and gauges are the same with the cloud as without.

## Measured

The street canyon on the medium grid (0.25 m cells, 100 kg, 0.17 s), defaults otherwise, as for
[Thermal radiation](thermal-radiation.md#measured). The run took about 24 s on the Mac Studio
(M4 Max), with other work running; the cloud adds nothing to see.

| Gas | Handed over | Share of the warm gas's buoyancy | Stopped rising | Centre then | Top | Across |
|---|---|---|---|---|---|---|
| Default (cold air, no afterburning) | 401 kg, 11.4 m across, 685 K | 47% | 365 s | 244 m | 311 m | 133 m |
| Afterburning and hot air | 783 kg, 17.5 m across, 1,263 K | 81% | 365 s | 361 m | 459 m | 197 m |

**The cloud is less sensitive to the gas model than the fireball is.** The thermal radiation's
fireball was three and a half times as wide with afterburning and lasted for the whole run instead of 44 ms;
here the cloud goes about half as high again. What the cloud depends on is the heat left in the
air, and with the default gas much of it is in air only a little warm: handing over everything at
least 320 K takes in 76% of the warm gas's buoyancy and puts the top at 343 m. With afterburning
the cloud rises at up to 6 m/s in its first seconds, has mixed itself to within 4 K of the air by
30 s, and has drawn in some six thousand times its own mass by the time it stops.

**It stops at the same time whatever the charge**, about 3.85 / N after the run, where
N = √((g / T)(g / c_p − Γ)) is the buoyancy frequency, 0.0105 per second in the standard
atmosphere: in a stable fluid the stability alone sets the thermal's time. A larger charge goes
higher in the same time. The added mass slows it: without it (`addedMass` 0) it stops at 298 s,
at the same height. No measured stabilisation time has been compared.

Afterburning and hot air, varying one thing at a time (the top of the cloud when it stops):

| Change | Top |
|---|---|
| As above | 459 m |
| Handed over from 400 K (1,082 kg) or 1,000 K (373 kg) | 466 m, 434 m |
| Entrainment 0.2 or 0.3 | 517 m, 420 m |
| Emissivity 0.3 or 1 | 454 m, 444 m |
| Handed over at 80 ms or 120 ms instead of 170 ms | 435 m, 450 m |

The entrainment coefficient matters most, and is the least certain: laboratory thermals spread at
a quarter of their height or so, with scatter, and a fireball's first seconds, rolling itself into
a ring at many times the air's temperature, are outside that experience. The hand-over hardly
matters once it takes in most of the hot gas, nor does when it is made, since the afterburning gas
gains little more heat after 80 ms. Radiation takes little because the cloud cools by mixing
within a second or two.

**Against high-explosive clouds.** Church (1969) fitted the stabilised height of the clouds of
chemical explosions as H = 92.6 W^0.25 m, W in kilograms of TNT, as quoted by Liolios (2008); the
quotation does not say whether H is the centre or the top. With afterburning:

| Charge | Centre | Top | Across | Church's H |
|---|---|---|---|---|
| 10 kg | 212 m | 269 m | 114 m | 165 m |
| 100 kg | 361 m | 459 m | 197 m | 293 m |
| 1,000 kg | 594 m | 758 m | 328 m | 521 m |

The cloud's centre is 1.1 to 1.3 times Church's height and its top 1.45 to 1.65 times, and both
grow by a factor of 1.65 to 1.7 a decade of charge against the fit's 1.78, as a thermal whose
buoyancy is in proportion to the charge must, (F / N²)^¼, apart from the start's finite size. The
same source gives the cloud's radius as R = 4.7 W^0.375 m, 26 m for 100 kg, a quarter of this
model's; a thermal spreading at a quarter of its height cannot be so narrow at that height, and
without Church's report, which I have not seen, what R measures is left open. The 1,000 kg charge
fills much of the street's domain, so some of its hot gas may have left it before the hand-over.

## Output

- **The summary** printed gives what was handed over, its share of the warm gas's buoyancy, and
  the cloud when it stopped rising and at the end.
- **`--cloud-results`** writes the description, the hand-over, the cloud at times closer together
  early on (a hundredth of a second after the hand-over, then 5% further apart each time), and the
  moment it stopped rising, as JSON: each with the time since the detonation, the height of the
  centre, the radius, the temperature and the air's, the rise speed and the mass.
- **The USD scene** (`--usd`) gains `/Scene/Cloud`, a sphere over the hand-over's centre whose
  position, radius and `temperature` primvar (kelvin) are sampled every `frameInterval` seconds of
  the cloud's rise. Its frames follow the run's on the timeline, at that slower rate, and it is
  hidden until then; `cloudStartTimeCode` and `simulatedSecondsPerCloudFrame` in the layer's
  data say where it starts and how fast it goes. The scene's camera is set for the blast, so a
  cloud hundreds of metres up leaves its view.

## Limitations

- Illustrative, as above: one empirical height to compare with, and nothing on the cloud's
  growth over time.
- One sphere, well mixed: real clouds form a vortex ring with a hot core, carry dust and smoke,
  and spread into a cap; the integral model knows only their averages.
- The entrainment coefficient is from laboratory thermals of small density difference; a
  fireball's first seconds are far from that.
- A still, dry atmosphere: no wind, which bends and dilutes a cloud, no moisture, whose
  condensation heats it and lets it rise further, and no inversion or boundary layer.
- The ground does not hold the cloud back at the start, and the blocks and buildings do not
  disturb it.
- The gas is ideal air of constant specific heat; dissociated air's energy, recombining as it
  cools, and the products' different heat capacity are left out.
- Only the hot gas still in the domain at the end of the run is handed over, and only the
  coarse grid's cells, also where refinement sharpens the blast.
- Headless only; the app does not show it yet.

## Sources

- B. R. Morton, G. I. Taylor and J. S. Turner, "Turbulent gravitational convection from
  maintained and instantaneous sources", *Proc. R. Soc. Lond. A* 234, 1–23, 1956: the
  entrainment assumption and the thermal in stratified surroundings.
- M. P. Escudier and T. Maxworthy, "On the motion of turbulent thermals", *J. Fluid Mech.* 61,
  541–552, 1973: thermals of any density difference, with added mass.
- R. S. Scorer, "Experiments on convection of isolated masses of buoyant fluid", *J. Fluid Mech.*
  2, 583–594, 1957, and J. S. Turner, *Buoyancy Effects in Fluids*, Cambridge University Press,
  1973: laboratory thermals and how fast they spread.
- B. McKim, N. Jeevanjee and D. Lecoanet, "Buoyancy-driven entrainment in dry thermals", 2019
  ([arXiv:1906.07224](https://arxiv.org/abs/1906.07224)): a recent account of the models above.
- H. W. Church, *Cloud Rise from High-Explosives Detonations*, Sandia Laboratories, SC-RR-68-903,
  1969, as quoted in T. E. Liolios, "Broken Arrows: radiological hazards from nuclear warhead
  accidents", 2008 ([arXiv:0902.3824](https://arxiv.org/abs/0902.3824)): the empirical height.
- *U.S. Standard Atmosphere, 1976*, NOAA, NASA and USAF: the lapse rate and the tropopause.
- Long-term scope: [Long-term vision](long-term-vision.md); where it runs:
  [Distributed computing](distributed-computing.md#the-long-term-visions-effects).
