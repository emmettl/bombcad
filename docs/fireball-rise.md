# The fireball's rise and cloud

What becomes of the fireball once the blast has gone: the hot gas the air model leaves at the end
of a run is handed over to a model of a rising buoyant cloud, which follows its height, size,
temperature, rise speed, drift in the wind and the water it condenses for minutes after. It is the hand-over in sequence that
[Distributed computing](distributed-computing.md#the-long-term-visions-effects) foresaw: a few
numbers from the air model's final state, and nothing passed back.

**Standing: illustrative.** The cloud is a textbook integral model of a turbulent thermal, with
coefficients from laboratory thermals, started from whatever the gas model leaves; it agrees in
height, within a factor of about 1.6, with an empirical fit to high-explosive clouds (below), but
nothing here has been compared with a measured cloud's growth over time. Use it to see roughly
how high and wide the cloud of a charge goes, roughly where the wind takes it, and how that
changes with the charge and the gas model, not for dispersion or hazard estimates.

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
  "windSpeed": 0,
  "windDirection": 0,
  "windHeight": 10,
  "windExponent": 0.142857,
  "windCeiling": 1000,
  "relativeHumidity": 0,
  "productWater": 0.2,
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
  at their mass-weighted temperature and moving at their mean velocity. The charge's products
  are taken to be in it, with `productWater` kilograms of water a kilogram of charge: TNT,
  C₇H₅N₃O₆, has five hydrogen atoms a molecule, which end as two and a half molecules of water,
  a fifth of its mass, whether it afterburns or not. The rest of the gas is air with the
  humidity of the air at the ground.
- **The cloud** is a sphere of well-mixed gas at the pressure of the air around it, a turbulent
  thermal in the sense of Morton, Taylor and Turner (1956): it draws in the surrounding air across
  its surface at a speed that is a fixed share α, the `entrainment` coefficient, of its speed
  through that air, in still air its rise speed. Escudier and Maxworthy (1973) showed how to keep that assumption without the small
  density differences of the original, and that the added mass of the air the cloud pushes aside
  matters at any density; this model follows them. With m its mass, V its volume, b its radius, w
  its rise speed, u its velocity across the ground, T its temperature and ρ_air, T_air, p_air and
  U the air's temperature, pressure and wind at its height:
  - mass: dm/dt = 4π b² α ρ_air |(u − U, w)|
  - upward impulse: d/dt [(m + k ρ_air V) w] = (ρ_air V − m) g, k the `addedMass`, a half for a
    sphere
  - horizontal impulse: d/dt [m u + k ρ_air V (u − U)] = U dm/dt
  - water: m dq/dt = (q_air − q) dm/dt, q its water and q_air the air's vapour, each a kilogram
  - heat: m dh/dt = (h_air − h) dm/dt + V (dp_air/dz) w − εσ(T⁴ − T_air⁴) 4πb², with
    h = c_p T + L q_v its moist enthalpy, q_v its vapour and L water's latent heat

  The terms of the last are the air drawn in, cooling by expansion as the pressure falls
  (dh = dp / ρ), and radiation, off by default (`emissivity` 0). At each step the cloud's water is
  all vapour if that leaves it unsaturated, and otherwise as much vapour as saturates it, the
  rest liquid, with T found from h; condensing and evaporating move heat between c_p T and L q_v,
  so latent heat needs no term of its own. The saturation humidity is Bolton's (1980) fit to the
  vapour pressure over water. The gas is ideal air with a constant specific heat throughout, its
  density that of dry air at its density temperature T (1 + q_v / ε − q), ε = 0.622, so that
  vapour lightens it and liquid weighs it down, as in Morton's (1957) and Squires and Turner's
  (1962) moist plumes; V = mRT(1 + q_v / ε − q) / p_air, and likewise for the air. Liquid water
  stays in the cloud: none falls out as rain.

  The horizontal impulse is the cloud's momentum and its added mass's relative to the wind: the
  air drawn in brings the wind's momentum with it, and the air pushed aside acts only on the
  cloud's motion through it. In a uniform wind this keeps (m + k ρ_air V)(u − U) constant, so a
  cloud moving with the wind rises exactly as in still air, and one starting at rest takes up
  the wind as it grows. In a wind growing with height the cloud lags the wind around it and, moving
  through the air, draws more of it in; a single coefficient for drawing in air whichever way the
  cloud moves through it is this model's own choice, the simplest that is the same in every
  direction.
- **The atmosphere**: the temperature falls from the run's own ambient air at the
  ground at `lapseRate` (6.5 K/km, the standard atmosphere's) up to the `tropopause` and is
  constant above it, and the pressure is in hydrostatic balance. Air cooling more slowly with
  height than the 9.8 K/km of dry air rising is stable, so a cloud rises until it has mixed itself
  down to the temperature of its surroundings, overshoots and settles back. Lapse rates of
  g / c_p or more, in which nothing would stop a dry cloud, are refused. The air's
  `relativeHumidity` is the same at every height up to the tropopause and the air is dry above;
  none by default. Saturated air at 6.5 K/km is unstable for a cloud that condenses as it rises,
  which then cools at the moist adiabatic lapse rate of about 5 K/km near the ground, and need not
  stop. The air's pressure is reckoned for dry air, a difference of well under 1% in humid air.
- **The wind** is steady and from one direction, `windSpeed` at `windHeight` (10 m, where winds
  are usually measured) blowing towards `windDirection`, in degrees anticlockwise from the scene's
  x axis towards its y axis. It grows with height as (z / windHeight)^`windExponent`, the power law
  usually used for the wind near the ground, with a seventh for open country in neutral air, up to
  `windCeiling` (1,000 m), and is steady above it. There is none by default. The blast itself is
  worked out in still air, so the cloud starts still across the ground, unless its gas was moving,
  and is taken up by the wind from the hand-over.
- **Stopped rising** is the first moment the rise speed falls to zero, a common definition of a
  cloud's stabilisation; the model goes on past it to `duration` seconds after the run.
- **The domain and the ground are left behind**: the cloud rises freely from the hand-over, with
  no blocks, structure, ground or domain ceiling, and the ground does not hold it back even while
  it overlaps it at the start.

Integration is by fourth-order Runge–Kutta, with steps short against the time the cloud takes to
move its own radius through the air, from rest or at its speed, and to draw in its own mass; the
whole ten minutes takes a few milliseconds.

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
- **Wind.** In a uniform wind, a cloud already moving with it rises exactly as in still air, to
  a part in a billion, and drifts at the wind's speed; one starting at rest takes up the wind as
  u = U (1 − M₀ / M), M = m + k ρ_air V, to a part in a million, rising less than in still air
  for the air it draws in. In a wind growing with height it ends up moving within 2% of the wind
  around it and stops lower than in still air.
- **Moisture.** Bolton's saturation vapour pressure at 0 °C and 30 °C, and gas split into vapour
  and liquid at saturation. In uniform humid air the cloud's excess water, m (q − q_air), and
  moist enthalpy, m (h − h_air), are conserved to a part in a hundred thousand while warm, wet
  gas mixing into air near saturation condenses and evaporates again, a mixing cloud. Air rising
  without mixing cools at g / c_p to 0.2% and, saturated, at the saturated adiabatic lapse rate,
  g (1 + L r / RT) / (c_p + L² r ε / RT²), to 2%. In humid air the cloud stops a little higher
  than in dry air, and in saturated air it condenses and goes on rising.
- The standard atmosphere's pressure at the tropopause and at 20 km, a hot sphere in the air model
  handed over with its mass, place, temperature and buoyancy, and a headless run whose number of
  steps and gauges are the same with the cloud as without.

## Measured

The street canyon on the medium grid (0.25 m cells, 100 kg, 0.17 s), defaults otherwise (dry
air, still, with the products' water), as for [Thermal radiation](thermal-radiation.md#measured).
The run took about 24 s on the Mac Studio (M4 Max), with other work running; the cloud adds
nothing to see.

| Gas | Handed over | Share of the warm gas's buoyancy | Stopped rising | Centre then | Top | Across |
|---|---|---|---|---|---|---|
| Default (cold air, no afterburning) | 401 kg, 11.4 m across, 685 K | 47% | 364 s | 238 m | 304 m | 132 m |
| Afterburning and hot air | 783 kg, 17.5 m across, 1,263 K | 81% | 365 s | 355 m | 453 m | 196 m |

**The cloud is less sensitive to the gas model than the fireball is.** The thermal radiation's
fireball was three and a half times as wide with afterburning and lasted for the whole run
instead of 44 ms; here the cloud goes about half as high again. What the cloud depends on is the
heat left in the air, and with the default gas much of it is in air only a little warm: handing
over everything at least 320 K takes in 76% of the warm gas's buoyancy and puts the top at
334 m. With afterburning the cloud rises at up to 5.4 m/s in its first seconds, has mixed itself
to within 4 K of the air by 30 s, and has drawn in some six thousand times its own mass by the
time it stops. Its gas is moving at 6.4 m/s across the ground at the hand-over, faster than it
rises, carried along the street by the blast; the cloud keeps little of that, ending 16 m from
where it started.

**It stops at the same time whatever the charge**, about 3.85 / N after the run, where
N = √((g / T)(g / c_p − Γ)) is the buoyancy frequency, 0.0105 per second in the standard
atmosphere: in a stable fluid the stability alone sets the thermal's time. A larger charge goes
higher in the same time. The added mass slows it: without it (`addedMass` 0) it stops at 298 s,
at about the same height. No measured stabilisation time has been compared.

Afterburning and hot air, varying one thing at a time (the top of the cloud when it stops):

| Change | Top |
|---|---|
| As above | 453 m |
| Handed over from 400 K (1,082 kg) or 1,000 K (373 kg) | 461 m, 426 m |
| Entrainment 0.2 or 0.3 | 510 m, 414 m |
| Emissivity 0.3 or 1 | 450 m, 444 m |
| Handed over at 80 ms or 120 ms instead of 170 ms | 432 m, 443 m |
| Without the products' water | 455 m |

The entrainment coefficient matters most, and is the least certain: laboratory thermals spread at
a quarter of their height or so, with scatter, and a fireball's first seconds, rolling itself into
a ring at many times the air's temperature, are outside that experience. The hand-over hardly
matters once it takes in most of the hot gas, nor does when it is made, since the afterburning gas
gains little more heat after 80 ms. Radiation takes little because the cloud cools by mixing
within a second or two. The products' water, 20 kg, makes the gas of a given density a little
cooler, since vapour is lighter than air, and so leaves it a little less heat.

**In wind**, with afterburning, the wind blowing along the street's x axis and growing as the
seventh power of height:

| Wind 10 m up | Stopped rising | Centre then | Top | Across | Downwind then | Downwind at 600 s |
|---|---|---|---|---|---|---|
| None | 365 s | 355 m | 453 m | 196 m | | |
| 2 m/s | 365 s | 355 m | 455 m | 199 m | 1.1 km | 1.9 km |
| 5 m/s | 365 s | 350 m | 454 m | 207 m | 2.8 km | 4.7 km |
| 10 m/s | 365 s | 333 m | 445 m | 224 m | 5.5 km | 9.3 km |
| 5 m/s, the same at every height | 365 s | 356 m | 454 m | 196 m | 1.8 km | 3.0 km |

The wind carries the cloud far but hardly changes how high it goes. It takes up nine-tenths of the
wind in its first 0.3 s, so heavily does it draw in air early on, and then lags the wind around it
by 3 to 8% as it rises into faster air; that lag makes it draw in a little more air, wider and
lower at 10 m/s. A wind growing with height carries it half as far again as a wind of its 10 m
speed at every height. With the default gas and 5 m/s it stops at 233 m, 2.6 km downwind.

**In humid air**, with afterburning, the relative humidity the same up to the tropopause, followed
for 20 minutes:

| Relative humidity | Stopped rising | Centre then | Top | Liquid water |
|---|---|---|---|---|
| None | 365 s | 355 m | 453 m | none |
| 50% | 378 s | 363 m | 462 m | none |
| 80% | 387 s | 367 m | 468 m | none |
| 95% | 392 s | 369 m | 471 m | none |
| 100% | not by 1,200 s | 1,423 m at 1,200 s, rising at 1.7 m/s | 1,796 m | from 106 s, 0.67 g/kg at 1,200 s |

Up to 95% nothing condenses, and the humidity lifts the cloud only a little: it carries the damper
air from lower down, whose vapour makes it lighter than the drier air around it at its height. The
products' water is too little to matter: diluted a hundredfold within half a minute, it never brings the
cloud near saturation. In saturated air the cloud reaches saturation itself at about 230 m,
110 s after the blast, and then each metre it rises condenses more water, whose latent heat keeps
it 0.2 to 0.5 K warmer than the air around it. It cools as saturated air does, at about 5 K/km,
more slowly than the air's 6.5 K/km, so the higher it goes the more buoyant it is: it is a
growing cumulus cloud, still rising at 1.4 km after 20 minutes and gathering speed. With the
default gas the same happens from 96 s, reaching 1,009 m by 20 minutes. Real air is rarely
saturated from the ground up at a steady lapse rate, and how far such a cloud goes depends on the
layers above, which this atmosphere does not describe.

**Against high-explosive clouds.** Church (1969) fitted the stabilised height of the clouds of
chemical explosions as H = 92.6 W^0.25 m, W in kilograms of TNT, as quoted by Liolios (2008); the
quotation does not say whether H is the centre or the top. With afterburning, in dry, still air:

| Charge | Centre | Top | Across | Church's H |
|---|---|---|---|---|
| 10 kg | 209 m | 266 m | 114 m | 165 m |
| 100 kg | 355 m | 453 m | 196 m | 293 m |
| 1,000 kg | 586 m | 749 m | 326 m | 521 m |

The cloud's centre is 1.1 to 1.3 times Church's height and its top 1.4 to 1.6 times, and both
grow by a factor of 1.65 to 1.7 a decade of charge against the fit's 1.78, as a thermal whose
buoyancy is in proportion to the charge must, (F / N²)^¼, apart from the start's finite size. The
same source gives the cloud's radius as R = 4.7 W^0.375 m, 26 m for 100 kg, a quarter of this
model's; a thermal spreading at a quarter of its height cannot be so narrow at that height, and
without Church's report, which I have not seen, what R measures is left open. The 1,000 kg charge
fills much of the street's domain, so some of its hot gas may have left it before the hand-over.

## Output

- **The summary** printed gives what was handed over, its share of the warm gas's buoyancy, the
  cloud when it stopped rising and at the end, how far downwind, and when and where it condensed.
- **`--cloud-results`** writes the description, the hand-over, the cloud at times closer together
  early on (a hundredth of a second after the hand-over, then 5% further apart each time), and the
  moment it stopped rising, as JSON: each with the time since the detonation, the height of the
  centre, the radius, the temperature and the air's, the rise speed, the mass, and the centre's
  place and velocity across the ground, its water and the liquid part of it.
- **The USD scene** (`--usd`) gains `/Scene/Cloud`, a sphere starting at the hand-over's centre
  whose position, radius, `temperature` primvar (kelvin) and `liquidWater` primvar (grams a
  kilogram, for showing it as a visible cloud) are sampled every `frameInterval` seconds of the
  cloud's rise. Its frames follow the run's on the timeline, at that slower rate, and it is
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
- One lapse rate and one relative humidity up to the tropopause: no inversion, no boundary layer
  capped by drier air, no cloud base. Saturated air from the ground up is unstable at this lapse
  rate and lets a condensing cloud rise without limit, which real air, drier aloft, seldom does.
- Water only as vapour and liquid: no ice, which matters above the freezing level, a couple of
  kilometres up in mild weather; no rain falling out; liquid and vapour at the same temperature as
  the gas, and the water's own heat capacity left out. The products' water is TNT's and assumed
  to be all in the gas handed over.
- The wind is steady, from one direction and without turbulence. Its gusts and eddies would
  spread and dilute the cloud, and its turning with height would shear it; the only effect of
  the wind here beyond carrying the cloud is the extra air drawn in while it lags. Bent-over
  plumes, the steady counterpart, are found to draw in air across the wind much faster than
  along their own motion (Hoult, Fay and Forney, 1969); whether a thermal does too, this model
  does not say.
- The blast is worked out in still air, and the wind starts only at the hand-over.
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
- B. R. Morton, "Buoyant plumes in a moist atmosphere", *J. Fluid Mech.* 2, 127–144, 1957, and
  P. Squires and J. S. Turner, "An entraining jet model for cumulo-nimbus updraughts", *Tellus*
  14, 422–434, 1962: entraining plumes in humid air, condensing.
- D. Bolton, "The computation of equivalent potential temperature", *Mon. Weather Rev.* 108,
  1046–1053, 1980: the saturation vapour pressure over water.
- R. S. Scorer, "Experiments on convection of isolated masses of buoyant fluid", *J. Fluid Mech.*
  2, 583–594, 1957, and J. S. Turner, *Buoyancy Effects in Fluids*, Cambridge University Press,
  1973: laboratory thermals and how fast they spread.
- B. McKim, N. Jeevanjee and D. Lecoanet, "Buoyancy-driven entrainment in dry thermals", 2019
  ([arXiv:1906.07224](https://arxiv.org/abs/1906.07224)): a recent account of the models above.
- H. W. Church, *Cloud Rise from High-Explosives Detonations*, Sandia Laboratories, SC-RR-68-903,
  1969, as quoted in T. E. Liolios, "Broken Arrows: radiological hazards from nuclear warhead
  accidents", 2008 ([arXiv:0902.3824](https://arxiv.org/abs/0902.3824)): the empirical height.
- *U.S. Standard Atmosphere, 1976*, NOAA, NASA and USAF: the lapse rate and the tropopause.
- S. P. Arya, *Introduction to Micrometeorology*, 2nd ed., Academic Press, 2001: the wind's
  power law near the ground.
- D. P. Hoult, J. A. Fay and L. J. Forney, "A theory of plume rise compared with field
  observations", *J. Air Pollut. Control Assoc.* 19, 585–590, 1969: entrainment in a crosswind.
- Long-term scope: [Long-term vision](long-term-vision.md); where it runs:
  [Distributed computing](distributed-computing.md#the-long-term-visions-effects).
