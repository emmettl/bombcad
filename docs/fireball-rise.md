# The fireball's rise and cloud

What becomes of the fireball once the blast has gone: the hot gas the air model leaves at the end
of a run is handed over to a model of a rising buoyant cloud, which follows its height, size,
temperature, rise speed, drift in the wind, the water it condenses and freezes, and the rain and
snow that fall from it, and, once it stops rising, how it spreads at its level and grows and
dilutes as it drifts downwind, for minutes to hours after, in a standard atmosphere or a measured
sounding, in still or turbulent air. It is the hand-over in sequence that
[Distributed computing](distributed-computing.md#the-long-term-visions-effects) foresaw: a few
numbers from the air model's final state, and nothing passed back.

**Standing: illustrative.** The cloud is a textbook integral model of a turbulent thermal, with
coefficients from laboratory thermals, started from whatever the gas model leaves; its cloud's top
agrees with the tops Church measured over 22 detonations of 54 to 1,270 kg of TNT, from half a
minute to two minutes after each, to 4% on average and 21% shot by shot, as closely as his own
fit, but falls behind them later, as the real clouds go on growing (below). Once it stops rising,
it spreads as a gravity current and grows as a Pasquill–Gifford puff; no open measurements of a
high-explosive cloud's width have been found to check that against, and its top after it stops
falls further behind Church's than the rising thermal's did. Use it to see roughly how high and
wide the cloud of a charge goes, roughly where the wind takes it and how much it has spread and
thinned by then, and how that changes with the charge, the gas model and the weather, not for
dispersion or hazard estimates.

```bash
swift run -c release BombCAD run street.bombcad --cloud cloud.json --cloud-results cloud-results.json --usd street.usda
```

`--sounding` reads a measured atmosphere in place of the standard one (see [A measured
sounding](#a-measured-sounding)), and `BombCAD cloud` follows the cloud of a run already made
again, from the hand-over its results kept, in another atmosphere or with another description,
in a fraction of a second and without the blast:

```bash
swift run -c release BombCAD cloud cloud-results.json --cloud afternoon.json --sounding Samples/Soundings/las-vegas-2024-06-16-00z.csv
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
  "rainRate": 0.001,
  "rainThreshold": 0.0005,
  "frictionVelocity": 0,
  "convectiveVelocity": 0,
  "boundaryLayerHeight": 1000,
  "turbulentEntrainment": 0.655,
  "northDirection": 90,
  "spread": true,
  "frontFroude": 1.19,
  "stabilityClass": null,
  "leastTransportSpeed": 1,
  "duration": 600,
  "frameInterval": 1
}
```

## In the app

Turn on **Fireball's rise and cloud** in the Run tab's Rise and cloud section, and set the wind
10 m up and where it blows towards, the relative humidity and how long the cloud is followed; the
rest of the description keeps its defaults, and a project's `cloud.json` may bring a measured
sounding, which then sets the air. The description is saved with the project, takes effect from
the next run, and is undone and redone with the layout's edits (⌘Z). Once a run reaches its end,
the hot gas left in the air is handed over and the cloud followed, away from the main thread, in
a few milliseconds; a run paused before its end has no cloud.

The view then draws where the cloud went: the track of its centre in white, its outline (the
sphere's silhouette from the eye) at round intervals until it stopped rising, at most eight, the
cloud where it stopped in orange, with a ring at its height and a line down to the ground, its
ring at its height in teal at round intervals as it spread after, at most eight, with its outline
from the side at the end and a line down from there, and the track of its centre across the
ground in dark grey, which shows how far it drifted. Under Display, **Cloud's path** hides it.
The section gives what was handed over, when the cloud stopped rising (or that it had not by the
end), its centre and top then, how wide it was and how far downwind, how wide and deep it had
spread by the end and how many times the gas it held when it stopped it then held, and charts
its height against time, or against its distance downwind when the wind carries it: its centre
as a line, the band from its bottom to its top, and where it stopped; and below, its width and
depth, with where it stopped. **Frame the Cloud** turns the view to the whole path, from the side
and a little above the ground; the view's controls zoom out to 600 m, so when the wind has
carried the cloud farther than that it frames the cloud where it stopped, and the charts show
the whole path. **Frame the Scene** turns it back.

![The street canyon's cloud, 100 kg with afterburning and hot air, in still air for ten minutes: the white track rising from the street, the outlines a minute apart growing as it rises, the cloud where it stopped rising, 357 m up after six minutes, in orange, and its rings in teal half a minute apart as it settles to 313 m and spreads to 378 m across](street-cloud.png)

`blastbench snapshot --cloud cloud.json --frame-cloud` hands over at the snapshot's time and draws
the path as the view does (the figure, with `--preset street --air thermal --afterburn --time 0.17
--no-wave`).

**Keep Run** keeps the cloud with the run, as `--cloud-results` writes it: the description, the
hand-over, the samples and where it stopped. Compare gives a line for each run that followed it,
and **Use this run's inputs** brings the description back. A sweep's cases on this Mac follow it
too before they are kept. It does not act on the air, so it is no part of the run's input
fingerprint.

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
  through that air, in still air its rise speed. Escudier and Maxworthy (1973) showed how to keep
  that assumption without the small density differences of the original, and that the added
  mass of the air the cloud pushes aside matters at any density; this model follows them. With m its mass, V its volume, b its radius, w
  its rise speed, u its velocity across the ground, T its temperature and ρ_air, T_air, p_air and
  U the air's temperature, pressure and wind at its height:
  - mass: dm/dt = 4π b² α ρ_air |(u − U, w)|
  - upward impulse: d/dt [(m + k ρ_air V) w] = (ρ_air V − m) g, k the `addedMass`, a half for a
    sphere
  - horizontal impulse: d/dt [m u + k ρ_air V (u − U)] = U dm/dt
  - water: m dq/dt = (q_air − q) dm/dt − P (1 − q), q its water and q_air the air's vapour, each
    a kilogram, and P the water falling out
  - heat: m dh/dt = (h_air − h) dm/dt + V (dp_air/dz) w − εσ(T⁴ − T_air⁴) 4πb² − P (h_P − h),
    with h = c_p T + L_v q_v − L_f q_i its frozen moist enthalpy, q_v its vapour, q_i its ice, L_v
    and L_f water's latent heats of vaporisation and fusion, and h_P that of the water falling

  The terms of the last are the air drawn in, cooling by expansion as the pressure falls
  (dh = dp / ρ), radiation, off by default (`emissivity` 0), and the water falling out. At each
  step the cloud's water is all vapour if that leaves it unsaturated, and otherwise as much vapour
  as saturates it, with T found from h; condensing, evaporating, freezing and melting move heat
  between c_p T, L_v q_v and L_f q_i, so latent heat needs no term of its own.

  The gas is ideal air with a constant specific heat throughout, its density that of dry air at
  its density temperature T (1 + q_v / ε − q), ε = 0.622, so that vapour lightens it and
  condensed water weighs it down, as in Morton's (1957) and Squires and Turner's (1962) moist
  plumes: V = mRT(1 + q_v / ε − q) / p_air, and likewise for the air.

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
- **Turbulent air.** The boundary layer's own turbulence draws air into the cloud as well as the
  cloud's motion does, as in the plume rise model of ADMS (CERC's Atmospheric Dispersion Modelling
  System), where the speed at which air is drawn in across the surface is the sum of the two:
  α |(u − U, w)| + α₃ min((εb)^⅓, σ_w (1 + t / 2T_L)^−½), with α₃ = 0.655
  (`turbulentEntrainment`), ε the turbulence's rate of dissipation, σ_w its root mean square
  vertical velocity, T_L its Lagrangian time scale and t the time since the detonation. Eddies
  smaller than the cloud mix into it at the inertial range's (εb)^⅓, the speed of eddies of its
  size; the larger ones' share falls with time, as they come to carry the cloud about rather
  than mix into it. ε, σ_w and T_L are ADMS's profiles of the boundary layer (after Hunt, Holroyd
  and Carruthers, 1988) from its friction velocity u* (`frictionVelocity`), convective velocity w*
  (`convectiveVelocity`) and depth h (`boundaryLayerHeight`, 1,000 m):
  - σ_w² = (1.3 u* (1 − 0.8 z/h))² + 0.4 w*² (2.1 (z/h)^⅓ (1 − 0.8 z/h))²
  - ε = (u* (1 − 0.8 z/h))³ / Λ + 0.4 w*³ / h, Λ = (2.5/z + 4/h)⁻¹ without convection and
    (0.6/z + 2/h)⁻¹ with it, so that ε is the surface layer's u*³ / κz near the ground
  - T_L = Λ / 1.3σ_w without convection, and (|h/L| + 1/1.3) / (|h/L| + 1) Λ / σ_w with it,
    |h/L| = κ w*³ / u*³

  The air above h is still, and below 1 m the profiles are those at 1 m. There is no turbulence
  by default. The air the turbulence draws in brings the wind's momentum across the ground, as
  the rest does, and none upwards. Over open country u* is a twelfth to a fifteenth of the wind
  10 m up (κ U / ln(10 m / z₀), z₀ = 0.03 to 0.1 m), so 0.35 to 0.45 m/s for a 5 m/s wind; on a sunny afternoon w*
  is 1 to 3 m/s and h 1 to 3 km. The turbulence is not tied to the wind: a turbulent day needs
  both given.
- **A measured sounding** (`--sounding`, or `sounding` in the description, as its levels) takes
  the place of the standard atmosphere, the wind and the humidity: a radiosonde's pressure,
  height, temperature, dew point and wind, read from the comma-separated values the University of
  Wyoming's upper-air archive gives (`type=TEXT:CSV`). The scene's ground is the sounding's first
  level; between levels the temperature, the logarithm of the pressure and the wind's eastward
  and northward parts are linear in height, and the air's vapour pressure is the saturation
  vapour pressure over water at the dew point. Above the last level the air is isothermal and dry,
  and the wind is the last level's. North is `northDirection` degrees anticlockwise from the
  scene's x axis, 90, along y, by default. The blast is still worked out in the run's own
  ambient air, and the hand-over keeps its temperature as a ratio to the air's, so its buoyancy,
  in the sounding's air at the ground. A sounding brings its own wind and humidity, so
  `windSpeed` and `relativeHumidity` must be left at 0 with it; `lapseRate` and `tropopause` are
  not used. Two soundings over Las Vegas on a June day, a few kilobytes each, are in
  [Samples/Soundings](../Samples/Soundings/README.md) with their source and licence.
- **Stopped rising** is the first moment the rise speed falls to zero, a common definition of a
  cloud's stabilisation; the model goes on past it to `duration` seconds after the run, spreading
  the cloud as below, or, with `spread` false, following the thermal on as it overshoots and
  settles back.
- **Once it stops** (`spread`, on by default), the cloud is no longer a rising sphere but an
  ellipsoid of horizontal semi-axis a and vertical semi-axis c, drifting with the wind at its
  centre, which grows in three ways:
  - *It settles back* to its level of neutral buoyancy, where its gas, brought there without
    mixing (dh = dp / ρ), is as dense as the air, over half a buoyancy period π / N of the air
    between, z = z_n + (z_s − z_n)(1 + cos(πt / t_s)) / 2: the thermal stops at the top of an
    overshoot, and would otherwise oscillate about that level, as the rising model does.
  - *It spreads as a gravity current* where the air is stable, N² > 0: a well-mixed cloud in
    stratified air is lighter than the air at its top and heavier than that at its bottom, and
    collapses into a layer that spreads at its level, an intrusion. A box model of a constant
    volume V, the cloud's when it stopped, with the front condition u = Fr N h / 2 of Ungarish
    (2006), h = V / πa² its mean thickness and Fr = 1.19 (`frontFroude`), gives
    da/dt = Fr N V / 2πa², so its radius a_g³ = b³ + (3 Fr / 2π) N V t from the radius b where
    it stopped, and its half-depth c_g = b³ / a_g², the volume kept; the long-time t^⅓ of Ungarish and Zemach's (2007) inertial
    regime for a constant-volume intrusion, the regime Ib of Pouget et al. (2016). N is the air's
    over the cloud's depth around its centre, from its density temperature.
  - *It grows as a passive puff* in the air's turbulence, by the spreads of an instantaneous puff
    that Slade (1968) estimated for each of Pasquill's stability classes, as CCPS (1999) gives
    them: σ_y = δ x^β across the wind (and along it) and σ_z vertically, with x the distance
    travelled, A to F from 0.18 x^0.92 to 0.02 x^0.89 across and 0.60 x^0.75 to 0.05 x^0.61 up,
    for 100 m to 4 km. Each grows from the distance at which a puff of its class would have
    reached its present spread, so that its growth depends on its size, and goes on smoothly when
    the class changes with height. The class (`stabilityClass`) is taken, unless given, from the
    air's lapse rate over the cloud's depth by the US NRC's temperature-difference criteria
    (Safety Guide 23, 1972): A where it cools by more than 1.9 K a hundred metres, then B to 1.7,
    C to 1.5, D to 0.5, E to warming by 1.5 K, F beyond, so that the standard atmosphere is D and
    Church's nights E. The curves are against distance, so in air calmer than 1 m/s
    (`leastTransportSpeed`) the puff is taken to travel at that speed.

  The gravity current's and the turbulence's spreads add as variances, as independent spreading
  does, with the ellipsoid's semi-axes √5 σ, as a uniform sphere's radius is √5 times its σ:
  a² = a_g² + 5σ_y², c² = c_g² + 5σ_z². As it grows the cloud draws in the air it grows into,
  ρ_air dV, with that air's heat and vapour, so its water goes on condensing, freezing and
  raining out as the rising cloud's does, by the same rain rate. The rising thermal's ADMS
  turbulence (above) is not used once it stops: the class sets the growth.
- **The domain and the ground are left behind**: the cloud rises freely from the hand-over, with
  no blocks, structure, ground or domain ceiling, and the ground does not hold it back even while
  it overlaps it at the start.
- **Ice.** The condensed water is liquid above the freezing point and ice below 250.16 K, the
  liquid share the square of the way between, as in ECMWF's IFS, which has supercooled water
  down to about −23 °C as real clouds do. Saturation is over that mixture, its vapour pressure
  blended between Bolton's (1980) fit over water and Tetens' form over ice with the IFS's
  constants. The air's relative humidity is over water, as weather observations give it.
- **Rain and snow.** Condensed water beyond `rainThreshold` (0.5 g/kg) falls out of the cloud at
  `rainRate` (a thousandth of the excess a second), Kessler's (1969) conversion of cloud water
  into rain, here taken to fall out at once: P = m × rainRate × (q_c − rainThreshold), q_c the
  condensed water. It takes its mass, its momentum and its enthalpy with it, liquid and ice in
  the shares of the cloud's condensed water, and the ice is counted as snow. It falls straight out:
  it does not evaporate below the cloud or wash out what is in it.

Integration is by fourth-order Runge–Kutta, with steps short against the time the cloud takes to
move its own radius through the air, from rest or at its speed, and to draw in its own mass; ten
minutes takes a few milliseconds, two hours of a cloud filling the troposphere a few tenths of a
second. The spread goes in steps of at most a second, shorter while it settles, each exact for the
gravity current and the puff's growth at the step's stability and class.

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
- **Ice and rain.** The vapour pressure over ice at the triple point and at −20 °C, the liquid
  share at 0 °C, −13.5 °C and below −23 °C, and gas split into vapour, liquid and ice at
  saturation. Warm, wet gas mixing into cold, humid air condenses, freezes in part and
  precipitates, with every drop of water accounted for, in the cloud or fallen out, to a part in a
  million. In saturated air a cloud freezes only above the freezing level, snows, and stops where
  the saturated adiabatic lapse rate has passed the air's.
- **Turbulence.** ADMS's profiles reduce to the surface layer's ε = u*³ / κz near the ground, to
  1%, and to the mixed layer's 0.4 w*³ / h; a small cloud is entered at α₃ (εb)^⅓ and a large one
  at α₃ σ_w (1 + t / 2T_L)^−½. A puff at the air's temperature, at rest in steady turbulence of
  one ε, grows as b^⅔ = b₀^⅔ + ⅔ α₃ ε^⅓ t to a part in a million, Richardson's (1926) law of
  the growth of a cloud of particles, b² ∝ ε t³ once large. A cloud in turbulent air draws in
  more air and stops lower, the lower the stronger the turbulence, and without turbulence the
  model is unchanged to the last digit.
- **A sounding.** The Las Vegas soundings are read with the archive's values at the ground, their
  relative humidity from the dew point within a point of the archive's 13%, and their measured
  pressures in hydrostatic balance with their measured temperatures to 0.3% all the way up; the
  wind blows from where they say. A sounding made of the standard atmosphere every 100 m gives
  the standard atmosphere's cloud to 0.5% in height and 1% in time. The afternoon's cloud goes
  higher than the dawn's, and `BombCAD cloud` follows a headless run's hand-over again in a
  sounding.
- **Church's clouds.** Two minutes after his 22 shots, from the hand-overs of open-ground runs
  with afterburning and in each shot's stability, the cloud's top is 1.04 times his measured top
  on average, scattered no more than his fit (a geometric standard deviation under 1.24); without
  afterburning, under three-quarters.
- **The spread.** The stability classes from the lapse rate, and Slade's σ = δ x^β grown in a
  hundred steps as in one, to a part in a billion. A neutrally buoyant puff without a gravity
  current grows as a² = b² + 5σ_y² and c² = b² + 5σ_z² for its class and the distance the wind
  has carried it, drifts at the wind's speed and holds the air's density times its volume, all to
  a part in a billion. In the standard atmosphere, a cloud at the air's temperature spreads as
  a³ = b³ + (3 Fr / 2π) N V t to 0.2% over ten minutes, keeping its volume to 5%, and does not
  spread in air at the dry adiabatic lapse rate. A cloud stopped 0.2 K colder than the air
  settles to where the air's potential temperature is its own, to half a metre, sinking only and
  in half a buoyancy period to 15 s. Wet gas spreading and raining in humid air keeps every drop,
  in it, fallen out or drawn in with the air, to a part in a billion. The result spreads the cloud
  from where it stopped, its radius within 2% a second later and never shrinking, flattening first
  and then thickened by the turbulence; with `spread` false the thermal goes on as before.
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
at about the same height. In the more stable night air of Church's shots it stops 2¼ to 4 minutes
after the detonation, where he saw high-explosive clouds stop by 2 to 3 (below).

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

| Relative humidity | Stopped rising | Centre then | Top | Condensed water |
|---|---|---|---|---|
| None | 365 s | 355 m | 453 m | none |
| 50% | 378 s | 363 m | 462 m | none |
| 80% | 387 s | 367 m | 468 m | none |
| 95% | 392 s | 369 m | 471 m | none |
| 100% | not by 1,200 s | 1,423 m at 1,200 s, rising at 1.7 m/s | 1,797 m | from 106 s, 0.66 g/kg at 1,200 s; 3.6 t of rain from 954 s |

Up to 95% nothing condenses, and the humidity lifts the cloud only a little: it carries the damper
air from lower down, whose vapour makes it lighter than the drier air around it at its height.
The products' water is too little to matter: diluted a hundredfold within half a minute, it
never brings the cloud near saturation. In saturated air the cloud reaches saturation itself at about 230 m,
110 s after the blast, and then each metre it rises condenses more water, whose latent heat keeps
it 0.2 to 0.5 K warmer than the air around it. It cools as saturated air does, at about 5 K/km,
more slowly than the air's 6.5 K/km, so the higher it goes the more buoyant it is: it is a
growing cumulus cloud, still rising at 1.4 km after 20 minutes and gathering speed. Beyond
0.5 g/kg its water starts to rain out, 16 minutes after the blast and 1 km up.

Followed for two hours, it goes on rising to the freezing level, 2.5 km up after 29 minutes,
where its water starts to freeze and to fall as snow, and rises fastest since its first seconds,
at 2.9 m/s, at about 4.3 km. It stops 50 minutes after the blast with its centre 5.4 km up and
its top at 6.9 km, 3 km across: there the air is at −20 °C and holds so little water that
saturated air rising cools at more than the air's 6.5 K/km, and condensing no longer keeps the
cloud warmer than its surroundings. By the end of the two hours some 10,600 t of water has fallen
out of it, nine-tenths of it as snow, against the charge's 20 kg; without rain it stops a little
lower, at 5.2 km, weighed down by the water it keeps. With the default gas it stops at the same
height, 54 minutes after the blast: in saturated air the charge only starts the cloud, and the
heat that carries it to its ceiling is the air's own water condensing, so its height is the
atmosphere's, not the explosion's. Real air is rarely saturated from the ground up at a steady
lapse rate, and how far such a cloud goes depends on the layers above, which this atmosphere does
not describe.

**In turbulent air**, from the same hand-overs (`BombCAD cloud`), in the standard atmosphere and
without wind unless it says so, the cloud's centre and top when it stops rising:

| Air | 10 kg | 100 kg | 1,000 kg |
|---|---|---|---|
| Still | 209 m, 266 m | 355 m, 453 m | 586 m, 749 m |
| u* 0.2 m/s | 143 m, 226 m | 285 m, 408 m | 522 m, 705 m |
| u* 0.4 m/s | 104 m, 208 m | 229 m, 375 m | 462 m, 666 m |
| u* 0.4 m/s and a 5 m/s wind | 101 m, 208 m | 228 m, 377 m | 463 m, 670 m |
| u* 0.3 m/s, w* 2 m/s, h 1.5 km | 97 m, 261 m | 204 m, 413 m | 395 m, 676 m |

The turbulence draws more air into the cloud, which is then wider and, being weaker, stops lower:
by a third at 10 kg with u* 0.2 m/s, by a tenth at 1,000 kg, the smaller cloud rising more
slowly, so that the turbulence's share of the air it draws in is larger; the centre's height
then grows faster with the charge than in still air. It stops at the same time, 365 s, the
stability alone still setting it. The convective case is the standard atmosphere's stable
6.5 K/km with a mixed layer's turbulence, which a real afternoon does not have; the afternoon
sounding below has both.

**Once it stops rising**, the street's hand-over with afterburning (`blastbench snapshot --cloud
… --cloud-results`, without the products' water), in the standard atmosphere, followed for an
hour; at each time how far downwind its centre is, how wide and deep it is, and how many times the
gas it held when it stopped it holds:

| Wind 10 m up | Stopped rising | 10 min | 30 min | 60 min |
|---|---|---|---|---|
| None | 365 s, 357 m up, 197 m across | 384 × 61 m, 1.2 | 707 × 115 m, 7.5 | 970 × 192 m, 24 |
| 2 m/s | 365 s, 357 m, 200 m | 1.9 km, 408 × 91 m, 1.9 | 6.1 km, 959 × 261 m, 30 | 11.7 km, 1,607 × 440 m, 144 |
| 5 m/s | 365 s, 352 m, 208 m | 4.8 km, 503 × 151 m, 4.3 | 15.2 km, 1,724 × 494 m, 165 | 29.2 km, 3,269 × 836 m, 1,000 |
| 10 m/s | 365 s, 334 m, 225 m | 9.6 km, 715 × 235 m, 11 | 30.3 km, 3,062 × 800 m, 665 | 58.2 km, 6,002 × 1,354 m, 4,320 |
| 5 m/s, not spreading | | 241 m sphere, 1.6 | 314 m, 3.5 | 370 m, 5.7 |

**At the hand-over to the spread**, the rising thermal has already drawn in some six thousand
times the gas handed over, 4,700 t of air, and is about 200 m across; the spread then takes it
past a kilometre across within half an hour in a 5 m/s wind and dilutes it a thousandfold more
within the hour, some six million times the gas handed over, when the charge's 100 kg of products
would be about 20 µg in each cubic metre of its 4.7 km³, against 25 mg in the cloud when it
stopped. In the first ten minutes the gravity current does most of it: the cloud settles about 50 m
to its level of neutral buoyancy in the five minutes of half the standard atmosphere's buoyancy
period, flattens to under a third of its depth and nearly doubles its width, its top falling from
455 to about 340 m. After that the puff's growth takes over, as fast as the wind carries it, so
that the wind, which hardly changes how high the cloud goes, sets how big and how thin it gets as
well as how far it goes; by an hour the puff reaches the ground (the bottom of its band in the
chart) in a 5 m/s wind or more. The distance is the wind's at the cloud's height, 8.2 m/s for
5 m/s 10 m up, and is the same within 1% without the spread.

**How certain**: the stability class matters most. At 5 m/s after an hour, a class either side of
the standard atmosphere's D gives 2.3 km (E) to 5.3 km (C) across, 0.34 to 2.1 km deep and 195 to
6,640 times the gas it held when it stopped; Pasquill's classes are a coarse description of the
turbulence, and a lapse rate alone often misjudges them by a class, so take a factor of about 1.6
on the width and 5 on the dilution. The front's Froude number, from 0.6 to 2.4, changes the width
by −11% to +16% at ten minutes and under 3% after an hour. In still air the speed taken for the puff's
travel matters as much as the class: 0.5 or 2 m/s in place of 1 gives 890 or 1,214 m across and
12 or 60 times the gas after an hour. A cloud in still air for an hour is itself an idealisation;
real air is rarely so still for so long.

In the Las Vegas soundings it spreads as the air there says: at dawn, in the stable layer, class E,
2.9 km across, 0.4 km deep and 37 km downwind after an hour; in the afternoon, stopped a kilometre
up after 20 minutes, class D, 3.2 km across and 29 km downwind. In
saturated air the cloud stopping 5.4 km up after 50 minutes spreads to 14 km across within the
next 70 minutes in still air, a gravity current of fourteen cubic kilometres in stable air, an anvil;
some 8,600 t of water fall out of it by two hours, against 10,600 t when the thermal goes on
rising and sinking about its level.

## Against Church's measured clouds

Church (1969) measured the tops of the clouds of 23 surface detonations of 118 to 2,800 lb (54 to
1,270 kg) of TNT on dry lake beds in Nevada in 1963, by night and by day, from half a minute to
five minutes after each, with the air's stability and wind
([Samples/Church1969](../Samples/Church1969/README.md)). His fit, H = 76 W^¼ m with W in pounds
(92.6 W^¼ with W in kilograms, as Liolios (2008) quotes it), is of the top **two minutes after the
detonation**, by when, he found, "the buoyant motion of the puffs as a whole had ceased"; the
top went on growing after that only as turbulence spread the cloud. Its geometric standard
deviation over his 22 shots is 1.23, and he gives his heights as good to 15 or 20%. He compared
them with Morton, Taylor and Turner's thermals in salt water too, whose coefficient, 71, is close
to his 76.

Each shot is followed here (`Scripts/compare-church-cloud.py`) from the hand-over of an
open-ground run of its charge, in dry air on the lake bed 1,636 m above sea level, at 300 K in
the afternoon and 288 K at night, cooling with height at the lapse rate that gives the shot's
stability S = 1 − γ/Γ up to 600 m and at 6.5 K/km above, in its mean wind at every height (2 m/s
where none is given); Church's appendix plots the temperature profiles, which are not
transcribed. The model's top against his, the geometric mean of the ratio and, in brackets, its
geometric standard deviation, leaving out the shot P3, as he did:

| After the detonation | ½ min | 1 min | 2 min | 3 min | 4 min | 5 min |
|---|---|---|---|---|---|---|
| Shots measured | 21 | 22 | 22 | 20 | 9 | 13 |
| Afterburning, still air | 1.06 (1.21) | 1.05 (1.18) | 1.04 (1.21) | 0.94 (1.27) | 0.84 (1.52) | 0.69 (1.36) |
| The same, the thermal going on once it stops | 1.06 (1.21) | 1.05 (1.18) | 1.04 (1.21) | 0.98 (1.25) | 0.90 (1.49) | 0.79 (1.32) |
| The same, spreading in class A | | | | 0.96 (1.27) | 0.87 (1.51) | 0.82 (1.38) |
| Afterburning, a guess at the turbulence | 1.01 (1.22) | 0.99 (1.19) | 0.97 (1.24) | 0.88 (1.27) | 0.74 (1.51) | 0.65 (1.33) |
| Default gas, the 15 shots of 140, 560 and 1,600 lb | 0.72 (1.23) | 0.70 (1.19) | 0.68 (1.23) | 0.62 (1.26) | 0.61 (1.59) | 0.46 (1.31) |

**For the first two minutes the model is as close as Church's own fit, and accounts for the
air's stability.** Two minutes after, its tops are 4% above his on average, scattered by a factor
of 1.21, against his fit's 1.24 on the same shots, within what he gives for his measurements. His
fit leaves the stability out, and its errors follow it (a correlation of 0.47 with S); the
model's barely do (0.20). In the stable night air of most of his shots, S from 0.9 to 2.5, the
model's clouds stop rising 2¼ to 4 minutes after the detonation, where he saw them stop by 2 to
3. The worst are Clean Slate 2, 1.28 times his (532 m against 415 m), and P7, 0.80 (450 m against
565 m). P3, fired at dawn into an inversion about three times as stable as any other (S 7.07),
which Church left out, the model puts at 168 m against 76 m, 2.2 times too high, his fit at 3.4
times; a stability averaged over the lowest 600 m does not describe a shallow, strong inversion.

**Later the measured tops go on growing and the model's do not**: by five minutes it is nearly a
third low. Once the model's cloud stops, it settles back to its level and, in the stable night air
of most shots, flattens into a layer, so that its top falls; Church's mostly went on rising, by up
to 1.5 m/s from two to five minutes on the stable nights (shot 8 from 450 to 680 m, P7 from 565
to 832 m, though shot 9 and Clean Slate 2 hardly grew), and shot 1, on a windy afternoon, reached 978 m at four minutes against the model's 487 m.
Following the thermal on instead, as it overshoots and settles back, leaves it a fifth low at
five minutes; neither spreading nor rising fits what he saw. Passive growth cannot lift the top
that fast: even the most unstable class, A, against the shots' E, only brings five minutes to
0.82, and with no gravity current to 0.88. A guess at the lake bed's turbulence does not mend
this either (u* a twenty-third of the mean wind, over ground about a millimetre rough, in a 2 km
convective layer with w* 2 m/s in the afternoon and a 200 m layer at night): it widens the cloud
but lowers it more, 0.97 at two minutes and 0.65 at five. What lifts the measured tops is more
likely the air's own layers, a strong inversion near the ground and much weaker stability above
it, which one lapse rate to 600 m averages away, and a cloud that is not well mixed, whose hotter
core or largest eddies go on rising after its mean has stopped; neither is in this model. Church
gives tops only, so how wide his clouds spread is not compared.

**The hand-over needs afterburning.** Without it, only about two-fifths of the warm gas's
buoyancy is at least 500 K, and the tops are a third too low. With it, the hand-over carries about
250 N of buoyancy a kilogram of TNT, whatever the charge, the heat of some 7.5 MJ/kg left in the
air, between TNT's heat of detonation, about 4.6 MJ/kg, and its heat of burning completely,
about 15.

**In the standard atmosphere**, the street's hand-overs' tops two minutes after are 182, 308
and 516 m for 10, 100 and 1,000 kg, against Church's 165, 293 and 521 m: 1.10, 1.05 and 0.99
times. Before his report was read, this page compared his height with the top when the cloud
stops rising, six minutes after the detonation in the standard atmosphere, much less stable
(S 0.34) than most of his nights, and found the model 1.4 to 1.6 times too high; that compared
different things. The turbulence stays off by default: at two minutes the guess at it moves the
model from 1.04 to 0.97 times Church's tops, both within his data's scatter, and it does not
bring back their later growth. Liolios also quotes Church for the cloud's radius,
R = 4.7 W^0.375 m; the report gives only tops, so where that comes from is left open.

## A measured sounding

Over Las Vegas on 15 June 2024 ([Samples/Soundings](../Samples/Soundings/README.md)), at 04:09
local time (the 12 UTC sounding) and at 16:07 (the 00 UTC sounding of the 16th), followed for
30 minutes from the same hand-overs with afterburning, without turbulence:

| Charge | Standard atmosphere: stopped, centre, top | Dawn: stopped, centre, top | Afternoon: stopped, centre, top |
|---|---|---|---|
| 10 kg | 365 s, 209 m, 266 m | 235 s, 143 m, 205 m | 1,482 s, 1,043 m, 1,436 m |
| 100 kg | 365 s, 355 m, 453 m | 234 s, 271 m, 359 m | 1,173 s, 1,053 m, 1,429 m |
| 1,000 kg | 360 s, 586 m, 749 m | 250 s, 474 m, 620 m | 759 s, 1,122 m, 1,493 m |

**At dawn** the air at the ground is at 31 °C after a hot night and cools by only about 3 K/km up
to 1.5 km, half the standard atmosphere's lapse rate and so much more stable: the cloud stops
sooner, about as 3.85 / N with N = 0.0149 per second there says (259 s), and lower, a fifth lower at 1,000 kg
and a third at 10 kg. A wind from the south-south-west, 10 m/s some 250 m up, carries it 2 to 2.5 km
to the north-east by then, and 17 to 18 km in half an hour.

**In the afternoon** the ground is at 40 °C, the lowest 250 m cools faster than dry air rising
would, and above it, up to about 2.8 km, a mixed layer has a potential temperature constant to
half a kelvin. The cloud rises through it until it has mixed its buoyancy down to the layer's
small differences, about a kilometre up whatever the charge, a hundredfold in charge making a
tenth of difference in height; it takes 13 to 25 minutes to get there and drifts 7 to 13 km. As in
saturated air, the height is the atmosphere's, not the explosion's: here a hundred kilograms goes
nearly four times as high in the afternoon as at dawn, and three times as high as in the standard
atmosphere.

With turbulence, u* 0.2 m/s in a dawn layer 300 m deep and u* 0.3 m/s and w* 2.5 m/s in an
afternoon layer 3 km deep, the dawn's clouds stop at 116, 233 and 449 m with their tops at 202,
329 and 594 m, and the afternoon's spread to nearly 3 km across, their centres 0.86 to 1.08 km
up and their tops 2.2 to 2.5 km, the 100 kg cloud still rising slowly at 30 minutes. The
neutral form of the profiles stands in for the night's stable layer, whose turbulence is weaker
and which ADMS describes otherwise.

## Output

- **The summary** printed gives what was handed over, its share of the warm gas's buoyancy, the
  cloud when it stopped rising and at the end, how far downwind, when and where it condensed and
  how much of its water was ice, and how much rain and snow fell.
- **`--cloud-results`** writes the description, the hand-over, the cloud at times closer together
  early on (a hundredth of a second after the hand-over, then 5% further apart each time), and the
  moment it stopped rising, as JSON: each with the time since the detonation, the height of the
  centre, the radius, the temperature and the air's, the rise speed, the mass, and the centre's
  place and velocity across the ground, its water and the liquid and frozen parts of it, and the
  water fallen out of it so far, in all and as snow; once it spreads, also its half-depth
  (`thickness`), its radius then being its horizontal semi-axis, and its stability class. The
  summary gives its spread at the end, and the samples are 5% apart in time, so tens of seconds
  apart by the time it stops.
- **The USD scene** (`--usd`) gains `/Scene/Cloud`, a sphere starting at the hand-over's centre
  whose position, radius, `temperature` primvar (kelvin) and `liquidWater` and `ice` primvars
  (grams a kilogram, for showing it as a visible cloud) are sampled every `frameInterval`
  seconds of the cloud's rise, scaled vertically (`xformOp:scale`) to its depth once it spreads. Its frames follow the run's on the timeline, at that slower rate, and it is
  hidden until then; `cloudStartTimeCode` and `simulatedSecondsPerCloudFrame` in the layer's
  data say where it starts and how fast it goes. The scene's camera is set for the blast, so a
  cloud hundreds of metres up leaves its view.

## Limitations

- Illustrative, as above: compared with one set of measured clouds, Church's, from charges of
  54 to 1,270 kg on dry ground in Nevada, in air whose temperature profiles are taken as one
  lapse rate to 600 m; their tops after the first two or three minutes, which go on growing as
  turbulence spreads them, the model does not follow.
- One sphere, well mixed: real clouds form a vortex ring with a hot core, carry dust and smoke,
  and spread into a cap; the integral model knows only their averages.
- The spread once it stops is three textbook pieces put side by side, not a model fitted or
  checked against a spreading explosion cloud: no open measurements of one's width have been
  found, and Church's tops after it stops, which go on growing, it does not follow. Its gravity
  current is a box model in the inertial regime throughout, without the drag that slows real
  intrusions to t^2/9 (Pouget et al., 2016), the mixing at its head, or the earth's rotation; it
  acts on the volume the cloud had when it stopped, however much the turbulence has mixed it
  since, and on the air's stability around the cloud, through which the thin layer it becomes
  spreads in reality only at its own level. Settling back over half a buoyancy period is a
  description of the thermal's damped overshoot, not worked out.
- The puff's growth is Slade's (1968) estimates for instantaneous puffs, for 100 m to 4 km of
  travel near the ground, used here kilometres up and out to tens of kilometres; one stability
  class at a time from the lapse rate alone, without the wind and the sunshine that Pasquill's
  classes are also set by; one spread along and across the wind, without the wind's shear
  drawing the cloud out along it or a sounding's turning wind twisting it; no limit at the
  mixing height or the tropopause, and no reflection from the ground, so a puff that reaches the
  ground goes on counting the volume below it. In still air the travel is taken at 1 m/s.
- The entrainment coefficient is from laboratory thermals of small density difference; a
  fireball's first seconds are far from that.
- The standard atmosphere has one lapse rate and one relative humidity up to the tropopause: no
  inversion, no boundary layer capped by drier air, no cloud base. Saturated air from the ground
  up lets a condensing cloud rise for kilometres, which real air, drier aloft, seldom does. A
  measured sounding has all of these, but only as one profile at one place and time, taken by a
  balloon that drifts tens of kilometres as it rises, while the cloud may take half an hour to
  stop; the air between soundings, and the sounding's ground not being the scene's, are not
  described.
- In a sounding the blast is still worked out in the run's own ambient air, and the hand-over is
  carried to the sounding's air at the ground by keeping its temperature's ratio to the air's.
  A sounding's lowest few metres, where the ground's heating or cooling is strongest, are only
  as fine as its levels.
- The water's microphysics in one line each: ice by temperature alone, with no freezing of
  supercooled drops by nuclei or by contact with ice; one rate for rain and snow, falling out at
  once, none evaporating below the cloud and none washing out its dust and smoke; the water's
  own heat capacity left out, and its condensate at the gas's temperature. The products' water
  is TNT's and assumed to be all in the gas handed over.
- The wind is steady; a sounding's turns with height, but the cloud, one sphere, is not sheared
  by it. Beyond carrying the cloud, the wind acts only through the extra air drawn in while the
  cloud lags it, and through the turbulence, which must be given as well.
- The turbulence is ADMS's entrainment for plumes, its α₃ chosen there to match its own model of
  how a plume's instantaneous width grows, applied here unchanged to a thermal; nothing has
  tested it against a turbulent thermal. Its profiles are ADMS's neutral and convective ones with
  the length scale's terms for shear, stratification and the capping inversion left out; there is
  no stable boundary layer, whose weaker turbulence the neutral form overstates, and the air
  above the boundary layer is still. Eddies larger than the cloud carry it about, which an
  integral model of its mean cannot show: in a convective afternoon, updraughts and downdraughts
  of a few metres a second move a cloud that rises at less than that. Bent-over
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
- In the app, only the wind's speed and direction, the humidity and the duration can be set; the
  rest of the description, a sounding and the turbulence come from a project's `cloud.json`. The
  view's controls zoom out to 600 m, nearer than a cloud carried kilometres downwind.

## Future work

- The growth of Church's tops after two minutes, which neither the rising thermal nor the spread
  follows: Church's appendix's temperature and wind profiles, transcribed, would replace the one
  lapse rate here and show whether the air above the night's inversion lets the cloud go on
  rising; a cloud that is not well mixed, its hot core rising on, is the other candidate.
- Measured widths of spreading explosion clouds, to check the spread against: Roller Coaster's
  and the large high-explosive tests' cloud photographs, if any are open.
- The spread's gravity current with drag and the puff's growth with wind shear, a mixing height
  and the ground's reflection, and the class from the wind and sunshine as well as the lapse rate,
  or from the turbulence's own σ_v and σ_w as ADMS gives them.
- Thompson, Snyder and Weil's (2000) tank experiments on thermals from open detonations give
  their growth in stratified water and through inversions, which P3's inversion needs; the paper
  is not openly available, and has not been compared.
- Stable boundary layers in the turbulence, ADMS's third form, and the length scale's other
  terms; or turbulence read from a sounding's own gradients, the bulk Richardson number giving
  the boundary layer's depth.
- The large eddies' meandering, as a spread of the cloud's place about its mean, which dispersion
  models add to the integral model's path.
- A sounding near in time and place chosen for a scene, and soundings in other formats, such as
  NOAA's Integrated Global Radiosonde Archive.

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
- E. Kessler, *On the Distribution and Continuity of Water Substance in Atmospheric
  Circulations*, Meteorological Monographs 10 (32), American Meteorological Society, 1969: cloud
  water converted to rain beyond a threshold.
- ECMWF, *IFS Documentation, Part IV: Physical Processes*: the share of condensate liquid
  between 0 °C and −23 °C, and the saturation vapour pressure over ice.
- R. S. Scorer, "Experiments on convection of isolated masses of buoyant fluid", *J. Fluid Mech.*
  2, 583–594, 1957, and J. S. Turner, *Buoyancy Effects in Fluids*, Cambridge University Press,
  1973: laboratory thermals and how fast they spread.
- B. McKim, N. Jeevanjee and D. Lecoanet, "Buoyancy-driven entrainment in dry thermals", 2019
  ([arXiv:1906.07224](https://arxiv.org/abs/1906.07224)): a recent account of the models above.
- H. W. Church, *Cloud Rise from High-Explosives Detonations*, Sandia Laboratories, SC-RR-68-903,
  1969 ([OSTI 4798257](https://www.osti.gov/biblio/4798257)): the measured cloud tops, their
  times, stabilities and winds, and the fit; quoted in kilograms in T. E. Liolios, "Broken Arrows:
  radiological hazards from nuclear warhead accidents", 2008
  ([arXiv:0902.3824](https://arxiv.org/abs/0902.3824)).
- *U.S. Standard Atmosphere, 1976*, NOAA, NASA and USAF: the lapse rate and the tropopause.
- S. P. Arya, *Introduction to Micrometeorology*, 2nd ed., Academic Press, 2001: the wind's
  power law near the ground.
- Cambridge Environmental Research Consultants, *ADMS Plume Rise Model Specification*,
  P11/02R/25, 2025 (A. G. Robins, University of Surrey, D. D. Apsley, National Power, and CERC):
  the entrainment speed of ambient turbulence, α₃ min((εb)^⅓, σ_w (1 + t / 2T_L)^−½), and
  α₃ = 0.655, after G. Ooms (1972), G. Ooms and A. P. Mahieu (1981) and D. J. Thomson (1990).
- Cambridge Environmental Research Consultants, *ADMS Boundary Layer Structure Specification*,
  P09/01Z/25, 2025: σ_w, ε and T_L in the boundary layer, after J. C. R. Hunt, R. J. Holroyd and
  D. J. Carruthers (1988).
- L. F. Richardson, "Atmospheric diffusion shown on a distance-neighbour graph", *Proc. R. Soc.
  Lond. A* 110, 709–737, 1926: the growth of a cloud of particles in turbulence, b² ∝ ε t³.
- R. S. Thompson, W. H. Snyder and J. C. Weil, "Laboratory simulation of the rise of buoyant
  thermals created by open detonation", *J. Fluid Mech.* 417, 127–156, 2000: thermals in
  stratified water and through inversions, not yet compared.
- University of Wyoming, Department of Atmospheric Science, upper-air soundings
  ([weather.uwyo.edu/upperair/sounding.shtml](https://weather.uwyo.edu/upperair/sounding.shtml)):
  the Las Vegas soundings, the US National Weather Service's observations.
- D. P. Hoult, J. A. Fay and L. J. Forney, "A theory of plume rise compared with field
  observations", *J. Air Pollut. Control Assoc.* 19, 585–590, 1969: entrainment in a crosswind.
- D. H. Slade (ed.), *Meteorology and Atomic Energy 1968*, US Atomic Energy Commission,
  TID-24190, 1968: the spreads of instantaneous puffs by stability class, as tabulated (σ = δ x^β,
  A to F) in Center for Chemical Process Safety, *Guidelines for Consequence Analysis of
  Chemical Releases*, AIChE, 1999, and quoted in GasDispersion.jl's documentation
  ([aefarrell.github.io/GasDispersion.jl](https://aefarrell.github.io/GasDispersion.jl/dev/puff/)).
- F. Pasquill, "The estimation of the dispersion of windborne material", *Meteorol. Mag.* 90,
  33–49, 1961: the stability classes; US Atomic Energy Commission, *Onsite Meteorological
  Programs*, Safety Guide 23, 1972 (now NRC Regulatory Guide 1.23): the classes from the
  temperature's change with height.
- M. Ungarish, "On gravity currents in a linearly stratified ambient: a generalization of
  Benjamin's steady-state propagation results", *J. Fluid Mech.* 548, 49–68, 2006: the front's
  Froude number, 1.19; M. Ungarish and T. Zemach, "On axisymmetric intrusive gravity currents in
  a stratified ambient – shallow-water theory and numerical results", *Eur. J. Mech. B/Fluids*
  26, 220–235, 2007: the constant-volume intrusion's t^⅓.
- S. Pouget, M. Bursik, C. G. Johnson, A. J. Hogg, J. C. Phillips and R. S. J. Sparks,
  "Interpretation of umbrella cloud growth and morphology: implications for flow regimes of
  short-lived and long-lived eruptions", *Bull. Volcanol.* 78, 1, 2016: the regimes of an
  intrusion's spread, inertial t^⅓ and drag-dominated t^2/9 for a constant volume, and the front
  condition u = Fr N h / 2.
- B. Tull, J. Shaw and A. Davies (AWE), "Dispersion model validation illustrating the importance
  of the source term in hazard assessments from explosive releases", HARMO 15, Madrid, 2013, and K. T.
  Foster, R. P. Freis and J. S. Nasstrom, *Incorporation of an explosive cloud rise code into
  ARAC's ADPIC transport and diffusion model*, LLNL UCRL-ID-103443, 1990: dispersion models
  of explosive clouds checked against Roller Coaster's deposition and Church's tops, read for
  measured cloud widths, which they do not give.
- Long-term scope: [Long-term vision](long-term-vision.md); where it runs:
  [Distributed computing](distributed-computing.md#the-long-term-visions-effects).
