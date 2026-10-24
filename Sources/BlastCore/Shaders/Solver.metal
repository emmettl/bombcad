// Compressible Euler solver for air blast on a uniform Cartesian grid.
//
// Scheme: dimensionally split MUSCL-Hancock (second order in smooth regions) with a
// minmod-family limiter and an HLLC (or HLL) approximate Riemann solver. Solid cells
// and reflective domain faces are handled with mirrored ghost states, so stationary
// obstacles are exactly conservative. A moving solid mirrors the gas about its own
// velocity, which makes it act as a piston. Layouts here must match `SolverTypes.swift`.
//
// Still air is skipped. The grid is divided into tiles of 8 x 8 x 8 cells, and a tile is swept
// only once a cell within reach of it has left the uniform state the air was filled with. A
// cell's update reads two cells either side along each sweep, so in one step (three sweeps) a
// change spreads at most two cells along each axis: a tile woken when a changed cell comes
// within two cells of it is always woken before the change can reach it. Tiles never go back
// to sleep, so a skipped tile holds exactly the uniform state in both state buffers, and the
// result is the same as sweeping everything.

#include <metal_stdlib>
using namespace metal;

struct Cell {
    float rho;
    float mx;
    float my;
    float mz;
    float energy;
};

struct SolverUniforms {
    uint nx;
    uint ny;
    uint nz;
    uint axis;
    float dx;
    float gamma;
    float cfl;
    float ambientPressure;
    float densityFloor;
    float pressureFloor;
    float limiterTheta;
    uint riemannSolver;  // 0 = HLLC, 1 = HLL
    uint boundaryFlags;  // bit (2 * axis + side) set => reflective, clear => outflow
    uint finalSweep;
    uint gaugeCount;
    float forcedStep;  // > 0: use this time step instead of the CFL limit (the air is asleep)
    // Block of cells in which solids may move; `wallVelocity` holds their velocity there.
    uint regionX;
    uint regionY;
    uint regionZ;
    uint regionNx;
    uint regionNy;
    uint regionNz;
    float maxStep;  // > 0: never step further than this (what the structure's substeps cover)
    // Tiles of still air: the grid's size in tiles (0 when every cell is swept), and the uniform
    // state the air was filled with.
    uint tileNx;
    uint tileNy;
    uint tileNz;
    float stillRho;
    float stillMx;
    float stillMy;
    float stillMz;
    float stillEnergy;
    // Afterburning (0 when off): the energy released per kilogram of detonation products that
    // burns, the oxygen it takes per kilogram, and the oxygen density of still air.
    float afterburnEnergy;
    float oxygenPerFuel;
    float stillOxygen;
    float afterburnRate;  // 1 / the time over which mixed products burn
    uint airModel;        // 0: ideal gas with `gamma`; 1: thermally perfect air
    // Refinement (see Refine.metal; ratio 0 when the air is not refined): the grid's size in
    // tiles, the fine substep under way and how far through the coarse step it starts, the
    // pressure jump between neighbouring cells that asks for refinement, and the pool's size.
    uint refineRatio;
    uint refineTileNx;
    uint refineTileNy;
    uint refineTileNz;
    uint refineSubstep;
    float refineAlpha;
    float refineThreshold;
    uint refineMaxPatches;
    // The number of experimental rigid boxes in the air, whose definitions are passed beside.
    uint experimentalBox;
    uint couplingMapCount;
    // Refinement in several levels (see Refine.metal). For a level refining another: the side
    // of its parent's patches (0 when the parent is the coarse grid, as for the first level), its
    // parent's grid of blocks, and its parent's cells along a coarse cell's edge (1 for the first
    // level); and, for any grid with a finer level beneath it, that level's grid of blocks (0
    // when there is none).
    uint parentSide;
    uint parentTileNx;
    uint parentTileNy;
    uint parentScale;
    uint childTileNx;
    uint childTileNy;
    uint childTileNz;
    // Gravity along -z (0 when off; see `stencilFluxesGravity`): its acceleration, and the
    // hydrostatic atmosphere it holds at rest, cooling with height at `gravityLapse` K/m (0 for
    // isothermal) from `gravityT0` K and `gravityP0` Pa at the ground.
    float gravity;
    float gravityLapse;
    float gravityT0;
    float gravityP0;
    // 1 when the species carry a deflagration's unburnt mixture (x) instead of afterburning's fuel
    // and oxygen: they are carried as afterburning's are, and burnt by Deflagration.metal.
    uint deflagration;
    // Sub-grid mixing (see `mixingFace`): Smagorinsky's coefficient, and the turbulent Prandtl
    // and Schmidt numbers.
    float mixingCoefficient;
    float mixingPrandtl;
    // Afterburning's extinction limit (see `afterburntHere`): the ignition temperature, and the
    // limit flame temperature a mixture must reach by burning.
    float ignitionTemperature;
    float limitFlameTemperature;
    // Sub-grid mixing's model (see `eddyViscosity`): 0 Smagorinsky's, 1 the sigma model.
    uint mixingModel;
    // How close, in cells of the grid a level refines, a sharp jump must come to a block for it to
    // be refined (see `flagAround`).
    uint refineMargin;
    // Refined levels' own steps (see `refineLevelSteps`; 0 when every level takes r substeps of
    // the grid above): the level these uniforms are for (1 or 2), and the sweeps in a step.
    uint ownSteps;
    uint refineLevel;
    uint sweepAxes;
    uint gaugeWalls;  // 1: a gauge beside a wall reads the pressure at the wall (`gaugesReadWallPressure`)
    // Mixing-limited afterburning (see `afterburnRateHere`): C / C_k, the burning rate's factor on
    // the eddy viscosity over the cell's area.
    float burnMixingRate;
};

// Whether the air carries species, for afterburning or a deflagration.
static inline bool carriesSpecies(constant SolverUniforms &u) {
    return u.afterburnEnergy > 0.0f || u.deflagration != 0u;
}

// Each experimental box has `boxVectors` definition vectors: quaternion, half-size, local
// centre-of-mass offset, velocity, spin, centre, and its bounds' low and high corners.
constant uint boxVectors = 8;
static inline bool experimentalBoxContains(float3 point, float dx, const device float4 *definition) {
    float4 q = definition[0]; q.xyz = -q.xyz;
    float3 v = point-definition[5].xyz;
    float3 local = v+2.0f*cross(q.xyz,cross(q.xyz,v)+q.w*v)+definition[2].xyz;
    return all(abs(local) <= definition[1].xyz + dx*1e-5f);
}
static inline float3 experimentalBoxVelocity(float3 point, const device float4 *definition) {
    return definition[3].xyz+cross(definition[4].xyz,point-definition[5].xyz);
}
// The first of the boxes that holds the point, or -1. Its bounds pass over boxes far from it.
static inline int experimentalBoxOwner(float3 point, float dx, constant SolverUniforms &u,
                                       const device float4 *definitions) {
    for (uint b = 0; b < u.experimentalBox; ++b) {
        const device float4 *definition = definitions + boxVectors * b;
        if (any(point < definition[6].xyz - dx) || any(point > definition[7].xyz + dx)) continue;
        if (experimentalBoxContains(point, dx, definition)) return int(b);
    }
    return -1;
}

constant int tileSize = 8;
// The air is refined in patches of this many cells along each edge (see Refine.metal).
constant int patchSize = 4;
// How far a change spreads in one step, along each axis.
constant int tileReach = 2;
enum TileFlag { tileStill = 0, tileActive = 1, tileWoken = 2 };

struct StepControl {
    float dt;
    float batchTime;
    float timeLimit;
    uint stepIndex;
    uint activeSteps;
    float maxOverpressure;  // largest |overpressure| anywhere after the previous step
    uint activeTiles;       // tiles swept in the last step
    uint tileSweeps;        // tiles swept, summed over the batch's steps
    uint stopped;           // 1 once a step has stopped short of the time limit, 2 once one reached it
    float lastStep;         // the last step that advanced, before any clipping to the time limit
    // With refined levels' own steps: each level's substeps in a step of the grid above, their
    // length, and the substeps taken, summed over the batch (the second level's per coarse step).
    uint levelSubsteps0;
    uint levelSubsteps1;
    float levelStep0;
    float levelStep1;
    uint levelSubstepSum0;
    uint levelSubstepSum1;
    // The run's clock, in ticks of 2^-40 s since the restart, low and high words (see `runClock`).
    uint clockLow;
    uint clockHigh;
};

// The run's clock in ticks of 2^-40 s: each step adds its dt in whole ticks, so that the time at a
// step is the same however the run's steps are cut into batches (a batch's float sum of its steps
// from its start rounded with each cut). The host carries it from batch to batch. A dt of 2^-17 s
// (7.6 us) or more converts exactly, its float holding no bit finer than a tick; a shorter one, as
// fine cells near a charge take (5-50 mm cells, steps of 1-10 us), is cut down to a whole tick, so
// the clock falls behind the steps' sum by under a tick (0.9 ps) a step: under 10 ns over 10 ms of
// 1 us steps, a thousandth of a step, and still the same however batched (emmettl/bombcad-work#76).
static inline ulong runClock(const device StepControl &control) {
    return ulong(control.clockLow) | (ulong(control.clockHigh) << 32);
}

static inline float runClockSeconds(const device StepControl &control) {
    return float(runClock(control)) * 9.094947017729282e-13f;  // 2^-40
}

// The gas's equation of state. An ideal gas has p = (gamma - 1) times the internal energy per
// volume. Thermally perfect air is an ideal gas whose molecules also store energy in vibration
// once hot: N2 and O2 as harmonic oscillators of characteristic temperatures 3390 K and 2270 K,
// in proportion 0.79 to 0.21 by moles, on top of translation and rotation (5/2 R). So its
// internal energy per kilogram is e(T) = 5/2 R T + e_vib(T), its pressure is rho R T, and its
// ratio of specific heats falls from 1.4 at room temperature towards 1.29 near 3000 K.
// Dissociation, which sets in above about 2500 K, is included only in dissociating air
// (below). Below about 500 K they agree to better than 0.1%; the shock-tube and point-blast
// tests, in units where T is tiny, are unchanged.
enum AirModel { airIdeal = 0, airThermallyPerfect = 1, airDissociating = 2 };
// The gas model, when a kernel is compiled for one: the other models' code is then left out of
// it, which spares the kernels that run on every cell the registers it would hold. Kernels
// compiled without it read the model from their uniforms.
constant uint airModelConstant [[function_constant(2)]];
static inline uint airModelOf(uint model) {
    return is_function_constant_defined(airModelConstant) ? airModelConstant : model;
}
constant float airGasConstant = 287.05f;
// Gravity in the air, when a kernel is compiled for it (see `stencilFluxesGravity`): without it,
// its code is left out of the kernels, which then run exactly as they did before it.
constant bool airGravityConstant [[function_constant(5)]];
constant bool airGravity = is_function_constant_defined(airGravityConstant) && airGravityConstant;
// Sub-grid mixing, when a kernel is compiled for it (see `mixingFace`), likewise.
constant bool airMixingConstant [[function_constant(6)]];
constant bool airMixing = is_function_constant_defined(airMixingConstant) && airMixingConstant;
// Afterburning's extinction limit, when a kernel is compiled for it (see `afterburntHere`).
constant bool burnLimitConstant [[function_constant(7)]];
constant bool burnLimit = is_function_constant_defined(burnLimitConstant) && burnLimitConstant;
// Mixing-limited afterburning, when a kernel is compiled for it (see `afterburnRateHere`); it reads
// sub-grid mixing's eddy viscosity, so it takes effect only with that compiled in too.
constant bool burnMixingConstant [[function_constant(16)]];
constant bool burnMixing = is_function_constant_defined(burnMixingConstant) && burnMixingConstant && airMixing;

// Cut cells for the terrain's ground surface, as an option (see TerrainCutCells.swift): the cells
// the surface crosses keep the share of their volume above it (alpha) and of each face open to the
// air (the apertures). Their conservative update is each face's flux times its aperture and the
// wall's pressure on the wall's area along the sweep, over the fluid volume; but divided by a
// small alpha it would need a small time step, and in a split scheme air flowing along the wall
// would swing by the Courant number each sweep (the aperture of one face against the other's),
// only to swing back in the next. So, as in flux redistribution (Chern and Colella; Colella,
// Graves, Keen and Modiano 2006), a sweep gives a cut cell the update of a whole cell and keeps
// the difference from the conservative one (`cutDefects`); summed over a step's sweeps it is
// exactly nothing for air moving along the wall, and after the step it is redistributed
// (`redistributeCutDefects`): the cell keeps its share alpha, the rest goes to the first cell above
// it at least half full. The total is conserved.
constant bool cutCellsConstant [[function_constant(13)]];
constant bool cutCells = is_function_constant_defined(cutCellsConstant) && cutCellsConstant;
// Structures' outlines as cut cells (StructureCutCells.swift): per cell its record or -1, each
// record's air share and low faces' apertures, its wall, and its differences, as the terrain's.
constant bool structureCutConstant [[function_constant(15)]];
constant bool structureCut = is_function_constant_defined(structureCutConstant) && structureCutConstant;

// Congestion below the grid (`CongestionArray`, docs/congestion-model.md): cells holding obstacles
// too small to resolve are porous. Each keeps the share β_v of its volume open to the air, and a
// face the smaller of its two cells' shares (so that the update never outruns the step's Courant
// number); the update is each face's flux times its open share over the open volume, with the
// pressure on the obstacles' faces, p (β_high - β_low), so that still air stays still. Their drag
// is applied after the step (`congestionDrag`). Without congestion its code is left out.
constant bool porousAirConstant [[function_constant(14)]];
constant bool porousAir = is_function_constant_defined(porousAirConstant) && porousAirConstant;

// A column's cut cells: where its records start, its first cell of air (cells below are solid),
// its first whole cell (cells from it up are whole), and its first cell at least half full (the
// one its smaller cells give the rest of their difference to). Columns run to nx and ny
// inclusive, so that the domain's high faces have apertures.
static inline uint4 cutColumnOf(int3 cell, const device uint4 *columns, constant SolverUniforms &u) {
    return columns[uint(cell.x) + (u.nx + 1u) * uint(cell.y)];
}

// A cell's fluid share and the apertures of its low faces (x, y, z): zero below its column's cut
// cells, one above them.
static inline float4 cutRecordOf(int3 cell, const device uint4 *columns, const device float4 *records,
                                 constant SolverUniforms &u) {
    uint4 column = cutColumnOf(cell, columns, u);
    int k = cell.z;
    if (k < int(column.y)) return float4(0.0f);
    if (k >= int(column.z)) return float4(1.0f);
    return records[column.x + uint(k) - column.y];
}

// Dissociating air: thermally perfect air whose N2 and O2 also split into atoms once hot, in
// equilibrium, as Lighthill's ideal dissociating gas. For each, a mass fraction alpha of the
// molecules has dissociated where alpha^2 / (1 - alpha) = (rho_d / rho_s) exp(-theta_d / T), rho_s
// being the species' own density; its atoms carry 3/2 R T each and the bond's energy R theta_d
// per mass of molecules, and its pressure rises by (1 + alpha). N2 then O2: mass fractions,
// gas constants, dissociation temperatures and characteristic densities (Vincenti and Kruger),
// and vibrational temperatures.
constant float dissociatingShare[2] = {0.767f, 0.233f};
constant float dissociatingGasConstant[2] = {296.8f, 259.8f};
constant float dissociationTemperature[2] = {113000.0f, 59500.0f};
constant float dissociationDensity[2] = {1.3e5f, 1.5e5f};
constant float dissociatingVibration[2] = {3390.0f, 2270.0f};

// Dissociating air at a density and temperature: internal energy per kilogram and its
// derivative in temperature with the composition in equilibrium; the mixture's gas constant as
// it stands, p / (rho T), and its derivative; and the heat capacity at fixed composition.
struct DissociatingAir {
    float energy;
    float energySlope;
    float gasConstant;
    float gasConstantSlope;
    float frozenHeat;
};

static inline DissociatingAir dissociatingAir(float rho, float t) {
    // No floor of a kelvin or so: tests run in units where the gas is at a few millikelvin.
    t = max(t, 1e-12f);
    DissociatingAir air = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    for (int n = 0; n < 2; ++n) {
        float y = dissociatingShare[n];
        float r = dissociatingGasConstant[n];
        float theta = dissociationTemperature[n];
        float exponent = theta / t;
        float k = exponent > 80.0f ? 0.0f : dissociationDensity[n] / max(y * rho, 1e-12f) * exp(-exponent);
        float alpha = k > 0.0f ? 2.0f / (1.0f + sqrt(1.0f + 4.0f / k)) : 0.0f;
        // alpha^2 = k (1 - alpha), so d alpha / dk = (1 - alpha) / (2 alpha + k); dk/dT = k theta / T^2.
        float slope = k > 0.0f ? (1.0f - alpha) / (2.0f * alpha + k) * k * exponent / t : 0.0f;
        float x = min(dissociatingVibration[n] / t, 80.0f);
        float ex = exp(x);
        float below = 1.0f / (ex - 1.0f);
        float molecules = r * (2.5f * t + dissociatingVibration[n] * below);
        float atoms = r * (3.0f * t + theta);
        float frozen = (1.0f - alpha) * r * (2.5f + x * x * ex * below * below) + alpha * 3.0f * r;
        air.energy += y * ((1.0f - alpha) * molecules + alpha * atoms);
        air.energySlope += y * (frozen + slope * (atoms - molecules));
        air.gasConstant += y * r * (1.0f + alpha);
        air.gasConstantSlope += y * r * slope;
        air.frozenHeat += y * frozen;
    }
    return air;
}

// Temperature of dissociating air of density `rho` and internal energy `e` per kilogram, by
// Newton's method from `start`, the temperature of air that does not dissociate, which lies
// above it: dissociation only takes up energy.
static inline float dissociatingTemperature(float rho, float e, float start) {
    float t = max(start, 1e-12f);
    for (int n = 0; n < 6; ++n) {
        DissociatingAir air = dissociatingAir(rho, t);
        t = max(t - (air.energy - e) / max(air.energySlope, 1e-12f), 0.5f * t);
    }
    return t;
}

// Temperature of dissociating air of density `rho` at pressure `p`, from above likewise: the
// temperature at which undissociated air would have that pressure.
static inline float dissociatingTemperatureAt(float rho, float p) {
    rho = max(rho, 1e-12f);
    float t = max(p / (rho * dissociatingAir(rho, 1.0f).gasConstant), 1e-12f);
    for (int n = 0; n < 6; ++n) {
        DissociatingAir air = dissociatingAir(rho, t);
        float gap = rho * air.gasConstant * t - p;
        t = max(t - gap / (rho * (air.gasConstant + t * air.gasConstantSlope)), 0.5f * t);
    }
    return t;
}

// Vibrational energy per kilogram (x) and its heat capacity (y) at `temperature`.
static inline float2 vibration(float temperature) {
    float t = max(temperature, 1.0f);
    const float theta[2] = {3390.0f, 2270.0f};
    const float share[2] = {0.79f, 0.21f};
    float2 sum = float2(0.0f);
    for (int n = 0; n < 2; ++n) {
        float x = min(theta[n] / t, 80.0f);
        float ex = exp(x);
        float below = 1.0f / (ex - 1.0f);
        sum += share[n] * float2(theta[n] * below, x * x * ex * below * below);
    }
    return airGasConstant * sum;
}

// Temperature (x) of thermally perfect air of internal energy `e` per kilogram, and its
// vibrational heat capacity (y) at the first guess: a rational function of the temperature
// without vibration, y = e / (5/2 R), within 10^-4 of the root from 1 K to 60,000 K (and exact as
// y falls to nothing), then one step of Newton's method, which brings it within 2 x 10^-10. The
// heat capacity at the guess gives the ratio of specific heats within 2 x 10^-6. (Until October
// 2026 two steps from y itself, and the heat capacity evaluated again at the root: three
// evaluations of the vibration's exponentials where one does, which hot air spent a tenth of a
// cell's update on.)
static inline float2 airTemperatureAndHeat(float e) {
    float y = max(e, 0.0f) / (2.5f * airGasConstant);
    float z = y * (1.0f / 3000.0f);
    float p = 1.0f + z * (3.3791424f + z * (20.550920f + z * (137.42716f + z * 249.79498f)));
    float q = 1.0f + z * (3.3600479f + z * (21.645931f + z * (118.98650f + z * 349.70334f)));
    float t = y * p / q;
    float2 v = vibration(t);
    t -= (2.5f * airGasConstant * t + v.x - e) / (2.5f * airGasConstant + v.y);
    return float2(max(t, 0.0f), v.y);
}

// Temperature of thermally perfect air of internal energy `e` per kilogram.
static inline float airTemperature(float e) { return airTemperatureAndHeat(e).x; }

// Pressure from density and internal energy per volume.
static inline float gasPressure(float rho, float internalEnergy, uint model, float gamma) {
    model = airModelOf(model);
    if (model == airIdeal) {
        return (gamma - 1.0f) * internalEnergy;
    }
    float e = internalEnergy / rho;
    float t = airTemperature(e);
    if (model == airDissociating) {
        t = dissociatingTemperature(rho, e, t);
        return rho * dissociatingAir(rho, t).gasConstant * t;
    }
    return rho * airGasConstant * t;
}

// Pressure (x) and ratio of specific heats (y), from density and internal energy per volume.
// For dissociating air the ratio is the frozen one, at the composition as it stands: sound
// travels too fast for the gas to dissociate or recombine as it passes.
static inline float2 gasState(float rho, float internalEnergy, uint model, float gamma) {
    model = airModelOf(model);
    if (model == airIdeal) {
        return float2((gamma - 1.0f) * internalEnergy, gamma);
    }
    float e = internalEnergy / rho;
    float2 th = airTemperatureAndHeat(e);
    if (model == airDissociating) {
        float t = dissociatingTemperature(rho, e, th.x);
        DissociatingAir air = dissociatingAir(rho, t);
        return float2(rho * air.gasConstant * t, 1.0f + air.gasConstant / air.frozenHeat);
    }
    return float2(rho * airGasConstant * th.x, 1.0f + airGasConstant / (2.5f * airGasConstant + th.y));
}

// Internal energy per volume from density and pressure.
static inline float gasEnergy(float rho, float pressure, uint model, float gamma) {
    model = airModelOf(model);
    if (model == airIdeal) {
        return pressure / (gamma - 1.0f);
    }
    if (model == airDissociating) {
        return rho * dissociatingAir(rho, dissociatingTemperatureAt(rho, pressure)).energy;
    }
    float t = pressure / (rho * airGasConstant);
    return rho * (2.5f * airGasConstant * t + vibration(t).x);
}

// Ratio of specific heats at the state (frozen), which sets the speed of sound: c^2 = g p / rho.
static inline float gasGamma(float rho, float pressure, uint model, float gamma) {
    model = airModelOf(model);
    if (model == airIdeal) {
        return gamma;
    }
    if (model == airDissociating) {
        DissociatingAir air = dissociatingAir(rho, dissociatingTemperatureAt(rho, pressure));
        return 1.0f + air.gasConstant / air.frozenHeat;
    }
    float t = pressure / (rho * airGasConstant);
    return 1.0f + airGasConstant / (2.5f * airGasConstant + vibration(t).y);
}

// Primitive state in the sweep frame: v.x is the velocity along the sweep axis; g is the ratio
// of specific heats at the state.
struct Prim {
    float rho;
    float3 v;
    float p;
    float g;
};

struct Flux {
    float mass;
    float3 momentum;
    float energy;
};

struct FacePair {
    Prim lo;
    Prim hi;
};

enum CellKind { kindFluid = 0, kindWall = 1, kindOpen = 2 };

static inline float3 toSweep(float3 v, uint axis) {
    return axis == 0 ? v : (axis == 1 ? v.yzx : v.zxy);
}

static inline float3 fromSweep(float3 s, uint axis) {
    return axis == 0 ? s : (axis == 1 ? s.zxy : s.yzx);
}

static inline Prim primOfCell(Cell c, constant SolverUniforms &u) {
    Prim w;
    w.rho = max(c.rho, u.densityFloor);
    float3 velocity = float3(c.mx, c.my, c.mz) / w.rho;
    w.v = toSweep(velocity, u.axis);
    float2 gas = gasState(w.rho, c.energy - 0.5f * w.rho * dot(velocity, velocity), u.airModel, u.gamma);
    w.p = max(gas.x, u.pressureFloor);
    w.g = gas.y;
    return w;
}

static inline Prim loadPrim(const device Cell *state, int index, constant SolverUniforms &u) {
    return primOfCell(state[index], u);
}

// Reflection in a wall moving at `wallSpeed` along the sweep axis.
static inline Prim mirrored(Prim w, float wallSpeed) {
    w.v.x = 2.0f * wallSpeed - w.v.x;
    return w;
}

// Whether the open faces stand still ambient air beyond them (`OpenFaces.farField`).
static inline bool farFieldFaces(constant SolverUniforms &u) { return (u.boundaryFlags & (1u << 6)) != 0; }

// The ghost beyond an open face for the far field, from the state `w` inside it; `side` is +1 on
// the high face of the sweep and -1 on the low. Across the face's normal the waves are taken as
// acoustic: the one leaving, p + ρc u, comes from inside, and the one entering is still air's,
// so a wave passing out is let through, and gas at ambient pressure, however hot, stays at rest
// (Riemann invariants would not keep it so, the two sides' ratios of specific heats differing).
// Leaving supersonically the ghost is the inside state, and drawn in supersonically still air;
// otherwise the density follows the isentrope of the side the flow comes from, and the speeds
// along the face come from that side.
static inline Prim farFieldGhost(Prim w, float side, constant SolverUniforms &u) {
    float un = side * w.v.x;
    float c = sqrt(w.g * w.p / w.rho);
    if (un >= c) { return w; }
    Prim a;
    a.rho = u.stillRho;
    float3 still = float3(u.stillMx, u.stillMy, u.stillMz) / u.stillRho;
    a.v = toSweep(still, u.axis);
    float2 gas = gasState(a.rho, u.stillEnergy - 0.5f * a.rho * dot(still, still), u.airModel, u.gamma);
    a.p = gas.x;
    a.g = gas.y;
    // Drawn in supersonically, still air itself.
    if (un <= -c) { return a; }
    float impedance = w.rho * c;
    float leaving = w.p + impedance * un;
    float entering = a.p - impedance * side * a.v.x;
    // The acoustic waves are a linearisation: where the two sides differ several times over (air
    // drawn back hard into a contact charge's rarefaction would give a negative pressure) the
    // ghost's pressure is held within a factor of two of theirs, which keeps its density, and
    // hot air's temperature worked out from it, finite.
    float p = clamp(0.5f * (leaving + entering), 0.5f * min(w.p, a.p), 2.0f * max(w.p, a.p));
    float speed = (leaving - entering) / (2.0f * impedance);
    Prim b = speed > 0.0f ? w : a;
    b.rho *= powr(p / b.p, 1.0f / b.g);
    b.p = p;
    b.v.x = side * speed;
    return b;
}

// Reflection in a still wall whose unit normal is `normal`.
static inline Prim mirroredAbout(Prim w, float3 normal) {
    w.v -= 2.0f * dot(w.v, normal) * normal;
    return w;
}

// The wall normal of a cut cell, in the sweep's frame (out of the air into the ground).
static inline float3 cutNormalOf(int3 cell, const device uint4 *columns, const device float4 *walls, uint axis,
                                 constant SolverUniforms &u) {
    uint4 column = cutColumnOf(cell, columns, u);
    return toSweep(walls[column.x + uint(cell.z) - column.y].xyz, axis);
}

// Whether `cell` is one of its column's cut cells, and so has a wall and a normal of its own. A
// whole cell beside the terrain's solid cells (above ground lying on a cell's face, or beside a
// cliff) meets them across its face, as a staircase does.
static inline bool cutCellHere(int3 cell, const device uint4 *columns, constant SolverUniforms &u) {
    uint4 column = cutColumnOf(cell, columns, u);
    return cell.z >= int(column.y) && cell.z < int(column.z);
}

// Whether `cell` is inside the domain and solid by the terrain, below its column's cut cells.
static inline bool terrainSolid(int3 cell, const device uint4 *columns, constant SolverUniforms &u) {
    return all(cell >= 0) && cell.x < int(u.nx) && cell.y < int(u.ny) && cell.z < int(u.nz)
        && cell.z < int(cutColumnOf(cell, columns, u).y);
}

// A compact coarse-boundary page is 4^3 cells. Wall storage starts with a tile count,
// an overflow flag and one world-tile -> pool-slot entry (UINT_MAX when absent).
constant int couplingSide = 4;
constant uint couplingCells = 64u;
static inline int sparseCouplingSlot(int3 cell, int3 dims, const device uint *map) {
    if (any(cell < 0) || any(cell >= dims)) { return -1; }
    int3 tiles = (dims + couplingSide - 1) / couplingSide;
    int3 tile = cell / couplingSide;
    uint slot = map[2 + tile.x + tiles.x * (tile.y + tiles.y * tile.z)];
    if (slot == 0xffffffffu) { return -1; }
    int3 local = cell % couplingSide;
    return int(slot * couplingCells) + local.x + couplingSide * (local.y + couplingSide * local.z);
}
static inline int checkedCouplingSlot(int3 cell, int3 dims, device atomic_uint *map) {
    int slot = sparseCouplingSlot(cell, dims, (const device uint *)map);
    if (slot < 0 && all(cell >= 0) && all(cell < dims)) {
        atomic_store_explicit(map + 1, 1u, memory_order_relaxed);
    }
    return slot;
}
static inline float3 movingWallVelocity(const device float *velocity, int3 cell, constant SolverUniforms &u) {
    int3 local = cell - int3(u.regionX, u.regionY, u.regionZ);
    int3 dims = int3(u.regionNx, u.regionNy, u.regionNz);
    if (any(local < 0) || any(local >= dims)) { return float3(0); }
    int at = local.x + dims.x * (local.y + dims.y * local.z);
    uint header = 0;
    if (u.couplingMapCount != 0u) {
        at = sparseCouplingSlot(cell, int3(u.nx, u.ny, u.nz), (const device uint *)velocity);
        if (at < 0) { return float3(0); }
        header = u.couplingMapCount + 2u;
    }
    uint offset = header + 3u * uint(at);
    return float3(velocity[offset], velocity[offset + 1], velocity[offset + 2]);
}

// Speed along the sweep axis of the solid `offset` cells from `cell`; zero outside the region
// where solids move.
static inline float wallSpeed(const device float *wallVelocity, int3 cell, int offset,
                              constant SolverUniforms &u) {
    cell[u.axis] += offset;
    return movingWallVelocity(wallVelocity, cell, u)[u.axis];
}

static inline int classify(const device uchar *mask, int index, int offset, int stride, int i, int n,
                           bool lowWall, bool highWall) {
    int j = i + offset;
    if (j < 0) {
        return lowWall ? kindWall : kindOpen;
    }
    if (j >= n) {
        return highWall ? kindWall : kindOpen;
    }
    return mask[index + offset * stride] != 0 ? kindWall : kindFluid;
}

// Whether a structure's outline closes the low face of the cell at `index` along `axis` (its
// record's aperture there is nought; a cell without a record has every face open).
static inline bool structureClosedBelow(const device int *structureCutIndex, const device float4 *structureCutRecords,
                                        int index, uint axis) {
    int record = structureCutIndex[index];
    return record >= 0 && structureCutRecords[record][1 + axis] == 0.0f;
}

static inline float limitedSlope(float a, float b, float theta) {
    if ((a > 0.0f && b > 0.0f) || (a < 0.0f && b < 0.0f)) {
        float magnitude = min(theta * fabs(a), min(0.5f * fabs(a + b), theta * fabs(b)));
        return a > 0.0f ? magnitude : -magnitude;
    }
    return 0.0f;
}

static inline Prim slope(Prim lo, Prim mid, Prim hi, float theta) {
    Prim d;
    d.rho = limitedSlope(mid.rho - lo.rho, hi.rho - mid.rho, theta);
    d.v.x = limitedSlope(mid.v.x - lo.v.x, hi.v.x - mid.v.x, theta);
    d.v.y = limitedSlope(mid.v.y - lo.v.y, hi.v.y - mid.v.y, theta);
    d.v.z = limitedSlope(mid.v.z - lo.v.z, hi.v.z - mid.v.z, theta);
    d.p = limitedSlope(mid.p - lo.p, hi.p - mid.p, theta);
    return d;
}

// Hancock half-step predictor in primitive variables, then extrapolation to both faces.
static inline FacePair reconstruct(Prim w, Prim d, float halfLambda, constant SolverUniforms &u) {
    Prim h;
    h.rho = w.rho - halfLambda * (w.v.x * d.rho + w.rho * d.v.x);
    h.v.x = w.v.x - halfLambda * (w.v.x * d.v.x + d.p / w.rho);
    h.v.y = w.v.y - halfLambda * (w.v.x * d.v.y);
    h.v.z = w.v.z - halfLambda * (w.v.x * d.v.z);
    h.p = w.p - halfLambda * (w.v.x * d.p + w.g * w.p * d.v.x);
    h.g = w.g;

    FacePair faces;
    faces.lo.rho = h.rho - 0.5f * d.rho;
    faces.lo.v = h.v - 0.5f * d.v;
    faces.lo.p = h.p - 0.5f * d.p;
    faces.lo.g = w.g;
    faces.hi.rho = h.rho + 0.5f * d.rho;
    faces.hi.v = h.v + 0.5f * d.v;
    faces.hi.p = h.p + 0.5f * d.p;
    faces.hi.g = w.g;

    // Fall back to first order where the reconstruction would lose positivity.
    bool valid = min(faces.lo.rho, faces.hi.rho) > u.densityFloor
        && min(faces.lo.p, faces.hi.p) > u.pressureFloor;
    if (!valid) {
        faces.lo = w;
        faces.hi = w;
    }
    return faces;
}

static inline float totalEnergy(Prim w, constant SolverUniforms &u) {
    return gasEnergy(w.rho, w.p, u.airModel, u.gamma) + 0.5f * w.rho * dot(w.v, w.v);
}

static inline Flux physicalFlux(Prim w, float energy) {
    Flux f;
    f.mass = w.rho * w.v.x;
    f.momentum = f.mass * w.v;
    f.momentum.x += w.p;
    f.energy = (energy + w.p) * w.v.x;
    return f;
}

static inline Flux riemannFlux(Prim l, Prim r, constant SolverUniforms &u) {
    float gamma = u.gamma;
    float el = totalEnergy(l, u);
    float er = totalEnergy(r, u);
    float cl = sqrt(l.g * l.p / l.rho);
    float cr = sqrt(r.g * r.p / r.rho);

    // Einfeldt wave-speed estimates from Roe averages.
    float sl = sqrt(l.rho);
    float sr = sqrt(r.rho);
    float inv = 1.0f / (sl + sr);
    float3 vRoe = (sl * l.v + sr * r.v) * inv;
    float hRoe = (sl * (el + l.p) / l.rho + sr * (er + r.p) / r.rho) * inv;
    // For an ideal gas the Roe-averaged sound speed follows from the averaged enthalpy; for
    // thermally perfect air the sound speeds themselves are averaged.
    float cRoe = airModelOf(u.airModel) == airIdeal ? sqrt(max((gamma - 1.0f) * (hRoe - 0.5f * dot(vRoe, vRoe)), 1e-12f))
                                        : (sl * cl + sr * cr) * inv;
    float waveL = min(l.v.x - cl, vRoe.x - cRoe);
    float waveR = max(r.v.x + cr, vRoe.x + cRoe);

    Flux fl = physicalFlux(l, el);
    Flux fr = physicalFlux(r, er);
    if (waveL >= 0.0f) {
        return fl;
    }
    if (waveR <= 0.0f) {
        return fr;
    }

    Flux f;
    if (u.riemannSolver == 1) {
        float scale = 1.0f / (waveR - waveL);
        f.mass = (waveR * fl.mass - waveL * fr.mass + waveL * waveR * (r.rho - l.rho)) * scale;
        f.momentum = (waveR * fl.momentum - waveL * fr.momentum
                      + waveL * waveR * (r.rho * r.v - l.rho * l.v)) * scale;
        f.energy = (waveR * fl.energy - waveL * fr.energy + waveL * waveR * (er - el)) * scale;
        return f;
    }

    float ml = l.rho * (waveL - l.v.x);
    float mr = r.rho * (waveR - r.v.x);
    float waveStar = (r.p - l.p + l.v.x * ml - r.v.x * mr) / (ml - mr);
    if (waveStar >= 0.0f) {
        float factor = ml / (waveL - waveStar);
        float3 starMomentum = factor * float3(waveStar, l.v.y, l.v.z);
        float starEnergy = factor * (el / l.rho + (waveStar - l.v.x) * (waveStar + l.p / ml));
        f.mass = fl.mass + waveL * (factor - l.rho);
        f.momentum = fl.momentum + waveL * (starMomentum - l.rho * l.v);
        f.energy = fl.energy + waveL * (starEnergy - el);
    } else {
        float factor = mr / (waveR - waveStar);
        float3 starMomentum = factor * float3(waveStar, r.v.y, r.v.z);
        float starEnergy = factor * (er / r.rho + (waveStar - r.v.x) * (waveStar + r.p / mr));
        f.mass = fr.mass + waveR * (factor - r.rho);
        f.momentum = fr.momentum + waveR * (starMomentum - r.rho * r.v);
        f.energy = fr.energy + waveR * (starEnergy - er);
    }
    return f;
}

static inline void recordWaveSpeed(device atomic_uint *maxSpeed, float speed) {
    // Positive floats order like their bit patterns, so an integer atomic max suffices.
    uint bits = as_type<uint>(speed);
    if (bits > atomic_load_explicit(maxSpeed, memory_order_relaxed)) {
        atomic_fetch_max_explicit(maxSpeed, bits, memory_order_relaxed);
    }
}

static inline bool isStill(Cell c, float2 species, constant SolverUniforms &u) {
    return c.rho == u.stillRho && c.mx == u.stillMx && c.my == u.stillMy && c.mz == u.stillMz
        && c.energy == u.stillEnergy
        && (u.afterburnEnergy == 0.0f || (species.x == 0.0f && species.y == u.stillOxygen));
}

// Marks every tile within `tileReach` cells of `cell` with `flag`, unless already awake.
static inline void wakeTilesAround(int3 cell, device uchar *tileFlags, uchar flag, constant SolverUniforms &u) {
    int3 dims = int3(u.nx, u.ny, u.nz);
    int3 low = max(cell - tileReach, 0) / tileSize;
    int3 high = min(cell + tileReach, dims - 1) / tileSize;
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                int tile = x + int(u.tileNx) * (y + int(u.tileNy) * z);
                if (tileFlags[tile] == tileStill) {
                    tileFlags[tile] = flag;
                }
            }
        }
    }
}

// What a cell contributes to the next step's limits: its fastest wave and its overpressure.
static inline void recordCell(device atomic_uint *maxSpeed, float3 momentum, float rho, float pressure,
                              constant SolverUniforms &u, float ambient) {
    float3 speed = fabs(momentum) / rho;
    float fastest = max(speed.x, max(speed.y, speed.z))
        + sqrt(gasGamma(rho, pressure, u.airModel, u.gamma) * pressure / rho);
    recordWaveSpeed(maxSpeed, fastest);
    // The second slot tracks how disturbed the air still is.
    recordWaveSpeed(maxSpeed + 1, fabs(pressure - ambient));
}

static inline void recordCell(device atomic_uint *maxSpeed, float3 momentum, float rho, float pressure,
                              constant SolverUniforms &u) {
    recordCell(maxSpeed, momentum, rho, pressure, u, u.ambientPressure);
}

// The fluxes through the low and high faces of the middle cell of a five-cell stencil, by
// MUSCL-Hancock over a step of `lambda` = dt / dx.
static inline void stencilFluxes(Prim wM2, Prim wM1, Prim w0, Prim wP1, Prim wP2, float lambda,
                                 constant SolverUniforms &u, thread Flux &low, thread Flux &high) {
    float halfLambda = 0.5f * lambda;
    float theta = u.limiterTheta;
    FacePair facesM1 = reconstruct(wM1, slope(wM2, wM1, w0, theta), halfLambda, u);
    FacePair faces0 = reconstruct(w0, slope(wM1, w0, wP1, theta), halfLambda, u);
    FacePair facesP1 = reconstruct(wP1, slope(w0, wP1, wP2, theta), halfLambda, u);
    low = riemannFlux(facesM1.hi, faces0.lo, u);
    high = riemannFlux(faces0.hi, facesP1.lo, u);
}

// Gravity, as an option: the air is held by a hydrostatic background, p_b(z) and rho_b(z) with
// dp_b/dz = -g rho_b, and the vertical sweep works on each cell's deviation from it, as
// atmospheric codes do (the "well-balanced" schemes of Botta, Klein and others, and of Kappeli
// and Mishra): the slopes and the Hancock predictor are those of the deviations, with the
// background's own gradient and gravity's pull on the deviation in the predictor; the faces carry
// the background at the face plus the deviation; the background's pressure at each face is taken
// back out of the momentum flux and gravity's pull on the background out of the source, which is
// -g (rho - rho_b). Air in the background state at rest has no deviation, so its fluxes and its
// source cancel to the bit. The energy gains -g times the mean of the cell's two faces' mass
// fluxes, so that the gas's energy and its potential energy are conserved together.

// The background at height z: density (x) and pressure (y), from the ideal gas law with air's gas
// constant and a temperature falling linearly with height (or constant).
static inline float2 hydrostatic(float z, constant SolverUniforms &u) {
    float t;
    float p;
    if (u.gravityLapse > 0.0f) {
        t = u.gravityT0 - u.gravityLapse * z;
        p = u.gravityP0 * pow(t / u.gravityT0, u.gravity / (airGasConstant * u.gravityLapse));
    } else {
        t = u.gravityT0;
        p = u.gravityP0 * exp(-u.gravity * z / (airGasConstant * t));
    }
    return float2(p / (airGasConstant * t), p);
}

// Gravity's background is worked out once for each level, into a table (see `gravityTable` in
// Gravity.metal), and read from it wherever it is needed, so that it is the same to the bit
// everywhere (the same expressions compiled in two kernels can differ in the last bit): for each
// cell k of the level's height, from 4 below the ground to 4 above the top, the background as a
// cell stores it (density, energy), then at the cell's lower face (density, pressure).
constant int gravityBelow = 4;

static inline float4 gravityCellOf(const device float4 *table, int k) {
    return table[2 * (k + gravityBelow)];
}

static inline float2 gravityFaceOf(const device float4 *table, int k) {
    return table[2 * (k + gravityBelow) + 1].xy;
}

// The background at rest in cell `k`, as a cell stores it.
static inline Cell gravityRestOf(const device float4 *table, int k) {
    float4 t = gravityCellOf(table, k);
    Cell c;
    c.rho = t.x;
    c.mx = 0.0f;
    c.my = 0.0f;
    c.mz = 0.0f;
    c.energy = t.y;
    return c;
}

// The pressure of air at rest in cell `k`, against which its overpressure is measured under
// gravity: the ambient pressure at its height.
static inline float gravityAmbientOf(const device float4 *table, int k, constant SolverUniforms &u) {
    return primOfCell(gravityRestOf(table, k), u).p;
}

// Whether cell `k` of the coarse grid is still: under gravity, at rest in the background at its
// height (and with afterburning, holding its oxygen and no products), which a sweep leaves as it
// is to the bit; otherwise `isStill`.
static inline bool isStillAt(Cell c, float2 species, int k, const device float4 *table,
                             constant SolverUniforms &u) {
    if (!airGravity) {
        return isStill(c, species, u);
    }
    Cell b = gravityRestOf(table, k);
    return c.rho == b.rho && c.mx == 0.0f && c.my == 0.0f && c.mz == 0.0f && c.energy == b.energy
        && (u.afterburnEnergy == 0.0f || (species.x == 0.0f && species.y == u.stillOxygen / u.stillRho * b.rho));
}

// Hancock's predictor for the deviation `e` of cell `w`, of slope `d`, and its faces, whose
// background is `below` and `above`, as full states. `rise` is the background's change across
// the cell the state comes from, and `pull` gravity, both reversed for a mirrored ghost.
static inline FacePair reconstructGravity(Prim w, Prim e, Prim d, float2 rise, float pull, float2 below,
                                          float2 above, float halfLambda, float halfDt, constant SolverUniforms &u) {
    Prim h;
    h.rho = e.rho - halfLambda * (w.v.x * (d.rho + rise.x) + w.rho * d.v.x);
    h.v.x = w.v.x - halfLambda * (w.v.x * d.v.x + d.p / w.rho) - halfDt * pull * e.rho / w.rho;
    h.v.y = w.v.y - halfLambda * (w.v.x * d.v.y);
    h.v.z = w.v.z - halfLambda * (w.v.x * d.v.z);
    h.p = e.p - halfLambda * (w.v.x * (d.p + rise.y) + w.g * w.p * d.v.x);
    FacePair faces;
    faces.lo.rho = below.x + (h.rho - 0.5f * d.rho);
    faces.lo.v = h.v - 0.5f * d.v;
    faces.lo.p = below.y + (h.p - 0.5f * d.p);
    faces.lo.g = w.g;
    faces.hi.rho = above.x + (h.rho + 0.5f * d.rho);
    faces.hi.v = h.v + 0.5f * d.v;
    faces.hi.p = above.y + (h.p + 0.5f * d.p);
    faces.hi.g = w.g;
    bool valid = min(faces.lo.rho, faces.hi.rho) > u.densityFloor
        && min(faces.lo.p, faces.hi.p) > u.pressureFloor;
    if (!valid) {
        faces.lo = w;
        faces.lo.rho = below.x + e.rho;
        faces.lo.p = below.y + e.p;
        faces.hi = w;
        faces.hi.rho = above.x + e.rho;
        faces.hi.p = above.y + e.p;
        // Near a vacuum (a cell at the pressure floor), the background's fall across half a cell
        // can be more than the cell holds, and the face would have no pressure, or none of its
        // density, for the Riemann solver to take a sound speed from: there, the cell's own state.
        if (!(faces.lo.rho > u.densityFloor && faces.lo.p > u.pressureFloor)) {
            faces.lo = w;
        }
        if (!(faces.hi.rho > u.densityFloor && faces.hi.p > u.pressureFloor)) {
            faces.hi = w;
        }
    }
    return faces;
}

// The flux through a face: where the two sides are the same, as at rest in the background, the
// physical flux, which the approximate Riemann solvers reach only to rounding.
static inline Flux gravityFlux(Prim l, Prim r, constant SolverUniforms &u) {
    bool same = l.rho == r.rho && l.p == r.p && all(l.v == r.v);
    return same ? physicalFlux(l, totalEnergy(l, u)) : riemannFlux(l, r, u);
}

// As `stencilFluxes`, for the vertical sweep under gravity, cell 0 being cell `k` of its level,
// whose background is `table`. `from` gives the cell each of the others' states came from, as an
// offset from cell 0 (M2, M1, P1, P2), and `mirror` -1 where it is a mirrored ghost of it. The
// momentum fluxes leave out the background's pressure at the face, so that at rest they are zero
// to the bit (and the coarse and fine levels leave out the same, so refluxing is unchanged).
static inline void stencilFluxesGravity(Prim wM2, Prim wM1, Prim w0, Prim wP1, Prim wP2, int4 from, float4 mirror,
                                        int k, const device float4 *table, float lambda, float dt,
                                        constant SolverUniforms &u, thread Flux &low, thread Flux &high) {
    float halfLambda = 0.5f * lambda;
    float halfDt = 0.5f * dt;
    float theta = u.limiterTheta;
    int ks[5] = {k + from.x, k + from.y, k, k + from.z, k + from.w};
    float signs[5] = {mirror.x, mirror.y, 1.0f, mirror.z, mirror.w};
    Prim w[5] = {wM2, wM1, w0, wP1, wP2};
    Prim e[5];
    float2 rise[5];
    for (int j = 0; j < 5; ++j) {
        // The background read back as the cells are, so that a cell holding it has no deviation.
        Prim b = primOfCell(gravityRestOf(table, ks[j]), u);
        e[j] = w[j];
        e[j].rho -= b.rho;
        e[j].p -= b.p;
        rise[j] = signs[j] * (gravityFaceOf(table, ks[j] + 1) - gravityFaceOf(table, ks[j]));
    }
    // The faces' background, below cell M1 to above cell P1.
    float2 f0 = gravityFaceOf(table, k - 1);
    float2 f1 = gravityFaceOf(table, k);
    float2 f2 = gravityFaceOf(table, k + 1);
    float2 f3 = gravityFaceOf(table, k + 2);
    FacePair facesM1 = reconstructGravity(w[1], e[1], slope(e[0], e[1], e[2], theta), rise[1],
                                          signs[1] * u.gravity, f0, f1, halfLambda, halfDt, u);
    FacePair faces0 = reconstructGravity(w[2], e[2], slope(e[1], e[2], e[3], theta), rise[2], u.gravity, f1, f2,
                                         halfLambda, halfDt, u);
    FacePair facesP1 = reconstructGravity(w[3], e[3], slope(e[2], e[3], e[4], theta), rise[3],
                                          signs[3] * u.gravity, f2, f3, halfLambda, halfDt, u);
    low = gravityFlux(facesM1.hi, faces0.lo, u);
    high = gravityFlux(faces0.hi, facesP1.lo, u);
    // The background's own pressure at each face, balanced by gravity's pull on the background.
    low.momentum.x -= f1.y;
    high.momentum.x -= f2.y;
}

// Gravity's share of a vertical sweep's update of cell `k`, whose density was `rho0` and whose
// faces passed `low` and `high`: -g (rho - rho_b) dt for the momentum (the background's share
// having left the fluxes), and -g times the faces' mean mass flux dt for the energy.
static inline void gravitySources(thread float3 &momentum, thread float &energy, float rho0, Flux low, Flux high,
                                  int k, const device float4 *table, float dt, constant SolverUniforms &u) {
    momentum.x -= dt * u.gravity * (rho0 - gravityCellOf(table, k).x);
    energy -= dt * u.gravity * 0.5f * (low.mass + high.mass);
}

// Sub-grid mixing, as an option: the turbulence the grid cannot resolve carries momentum, heat and
// the products and oxygen across each face as an eddy viscosity nu (see `eddyViscosity` in
// Mixing.metal) and diffusivities nu / Pr would: -rho nu dv/dx of momentum, its work and
// -rho (nu / Pr) dh/dx of heat (h the specific enthalpy), and -rho (nu / Pr) dY/dx of each of the
// species' mass fractions. The face takes the mean of its two cells' nu, at most a quarter of
// dx^2 / dt, which keeps the explicit diffusion stable, and both cells beside it work out the same
// flux, so the gas stays conserved. Walls and open faces pass none.
struct MixingFace {
    Flux flux;
    float carrier;  // rho nu / (Pr dx): what multiplies a species' difference in mass fraction
};

static inline MixingFace mixingFace(Prim a, Prim b, float nuA, float nuB, float dx, float dt,
                                    constant SolverUniforms &u) {
    float nu = min(0.5f * (nuA + nuB), 0.25f * dx * dx / dt);
    float scale = 0.5f * (a.rho + b.rho) * nu / dx;
    float ha = (gasEnergy(a.rho, a.p, u.airModel, u.gamma) + a.p) / a.rho;
    float hb = (gasEnergy(b.rho, b.p, u.airModel, u.gamma) + b.p) / b.rho;
    MixingFace face;
    face.flux.mass = 0.0f;
    face.flux.momentum = -scale * (b.v - a.v);
    face.flux.energy = dot(face.flux.momentum, 0.5f * (a.v + b.v)) - scale / u.mixingPrandtl * (hb - ha);
    face.carrier = scale / u.mixingPrandtl;
    return face;
}

// A cut cell's update along a sweep (see `cutCells`): its faces' fluxes times their apertures,
// less the wall's push, which is (apertureLow - apertureHigh) times the pressure of the state
// against its mirror across the wall's `normal` (in the sweep's frame), taken as each face's
// momentum flux less that pressure; and the difference from the whole cell's update of a cell with
// `share` of it fluid. Every level of the air updates its cut cells so.
struct CutUpdate {
    Flux low;
    Flux high;
    Flux defect;
};

static inline CutUpdate cutCellUpdate(Prim w0, Flux fluxLow, Flux fluxHigh, float apertureLow, float apertureHigh,
                                      float share, float3 normal, bool gravityHere, const device float4 *gravityTable,
                                      int k, float lambda, float dt, constant SolverUniforms &u) {
    Flux cutLow = fluxLow;
    Flux cutHigh = fluxHigh;
    // The pressure at the wall: of the state against its mirror across the wall's normal.
    float towards = dot(w0.v, normal);
    Prim into = w0;
    into.v = float3(towards, 0.0f, 0.0f);
    Prim back = into;
    back.v.x = -towards;
    float wallPressure = riemannFlux(into, back, u).momentum.x;
    // The Riemann solver's own rounding, between a state and itself: whole cells see it at
    // both faces, where it cancels, but weighted by unequal apertures it would not, so it is
    // taken out of the cut cell's fluxes (and its wall's), and air at rest stays at rest. (The
    // vertical sweep under gravity takes the physical flux between states alike already.)
    if (!gravityHere) {
        Flux self = riemannFlux(w0, w0, u);
        Flux exact = physicalFlux(w0, totalEnergy(w0, u));
        Flux residual = {self.mass - exact.mass, self.momentum - exact.momentum, self.energy - exact.energy};
        cutLow.mass -= residual.mass;
        cutLow.momentum -= residual.momentum;
        cutLow.energy -= residual.energy;
        cutHigh.mass -= residual.mass;
        cutHigh.momentum -= residual.momentum;
        cutHigh.energy -= residual.energy;
        wallPressure -= residual.momentum.x;
    }
    // Under gravity the vertical fluxes leave out the background's pressure at the faces, and
    // the wall's push is its pressure less the background's in the cell (which balances the
    // background's at the faces and its weight in the cell's fluid share).
    if (gravityHere) {
        // Still against the wall, its pressure is the cell's, exactly, as `gravityFlux` takes
        // the physical flux between states alike.
        if (towards == 0.0f) {
            wallPressure = w0.p;
        }
        wallPressure -= primOfCell(gravityRestOf(gravityTable, k), u).p;
    }
    // The wall's push, (apertureLow - apertureHigh) times its pressure, taken as the faces'
    // momentum fluxes less that pressure: the same sum, and nothing at rest.
    cutLow.momentum.x -= wallPressure;
    cutHigh.momentum.x -= wallPressure;
    cutLow.mass *= apertureLow;
    cutLow.momentum *= apertureLow;
    cutLow.energy *= apertureLow;
    cutHigh.mass *= apertureHigh;
    cutHigh.momentum *= apertureHigh;
    cutHigh.energy *= apertureHigh;
    Flux defect;
    defect.mass = -lambda * ((cutHigh.mass - cutLow.mass) - share * (fluxHigh.mass - fluxLow.mass));
    defect.momentum = -lambda * ((cutHigh.momentum - cutLow.momentum) - share * (fluxHigh.momentum - fluxLow.momentum));
    defect.energy = -lambda * ((cutHigh.energy - cutLow.energy) - share * (fluxHigh.energy - fluxLow.energy));
    if (gravityHere) {
        // Gravity's work, through the open part of each face (its pull on the momentum, over
        // the fluid share, is the whole cell's times it, so leaves no difference).
        defect.energy -= dt * u.gravity * 0.5f * ((cutHigh.mass + cutLow.mass) - share * (fluxHigh.mass + fluxLow.mass));
    }
    CutUpdate update = {cutLow, cutHigh, defect};
    return update;
}

// As `cutCellUpdate`, for a structure's cut cell: `wallFace` is 1 or -1 where its high or low face
// along the sweep is shut whole against a mirror, 0 otherwise.
static inline CutUpdate structureCutUpdate(Prim w0, Flux fluxLow, Flux fluxHigh, float apertureLow, float apertureHigh,
                                      float share, float3 normal, bool gravityHere, const device float4 *gravityTable,
                                      int k, float lambda, float dt, int wallFace, constant SolverUniforms &u) {
    Flux cutLow = fluxLow;
    Flux cutHigh = fluxHigh;
    // The pressure at the wall: of the state against its mirror across the wall's normal.
    float towards = dot(w0.v, normal);
    Prim into = w0;
    into.v = float3(towards, 0.0f, 0.0f);
    Prim back = into;
    back.v.x = -towards;
    float wallPressure = riemannFlux(into, back, u).momentum.x;
    // Where the wall shuts one of the cell's faces along the sweep whole and stands against its
    // mirror there, the sweep's own flux through that face is the wall's push, from the state
    // reconstructed to it as a whole cell beside a solid one takes it: from the cell's mean, the push
    // was lower, and a wall loaded by the cell read the lower the more of the cell was air, 8%
    // at nine tenths. (Not under gravity, whose vertical fluxes leave out the background's pressure.)
    if (wallFace != 0 && !gravityHere) {
        wallPressure = (wallFace > 0 ? fluxHigh : fluxLow).momentum.x;
    }
    // The Riemann solver's own rounding, between a state and itself: whole cells see it at
    // both faces, where it cancels, but weighted by unequal apertures it would not, so it is
    // taken out of the cut cell's fluxes (and its wall's), and air at rest stays at rest. (The
    // vertical sweep under gravity takes the physical flux between states alike already.)
    if (!gravityHere) {
        Flux self = riemannFlux(w0, w0, u);
        Flux exact = physicalFlux(w0, totalEnergy(w0, u));
        Flux residual = {self.mass - exact.mass, self.momentum - exact.momentum, self.energy - exact.energy};
        cutLow.mass -= residual.mass;
        cutLow.momentum -= residual.momentum;
        cutLow.energy -= residual.energy;
        cutHigh.mass -= residual.mass;
        cutHigh.momentum -= residual.momentum;
        cutHigh.energy -= residual.energy;
        wallPressure -= residual.momentum.x;
    }
    // Under gravity the vertical fluxes leave out the background's pressure at the faces, and
    // the wall's push is its pressure less the background's in the cell (which balances the
    // background's at the faces and its weight in the cell's fluid share).
    if (gravityHere) {
        // Still against the wall, its pressure is the cell's, exactly, as `gravityFlux` takes
        // the physical flux between states alike.
        if (towards == 0.0f) {
            wallPressure = w0.p;
        }
        wallPressure -= primOfCell(gravityRestOf(gravityTable, k), u).p;
    }
    // The wall's push, (apertureLow - apertureHigh) times its pressure, taken as the faces'
    // momentum fluxes less that pressure: the same sum, and nothing at rest.
    cutLow.momentum.x -= wallPressure;
    cutHigh.momentum.x -= wallPressure;
    cutLow.mass *= apertureLow;
    cutLow.momentum *= apertureLow;
    cutLow.energy *= apertureLow;
    cutHigh.mass *= apertureHigh;
    cutHigh.momentum *= apertureHigh;
    cutHigh.energy *= apertureHigh;
    Flux defect;
    defect.mass = -lambda * ((cutHigh.mass - cutLow.mass) - share * (fluxHigh.mass - fluxLow.mass));
    defect.momentum = -lambda * ((cutHigh.momentum - cutLow.momentum) - share * (fluxHigh.momentum - fluxLow.momentum));
    defect.energy = -lambda * ((cutHigh.energy - cutLow.energy) - share * (fluxHigh.energy - fluxLow.energy));
    if (gravityHere) {
        // Gravity's work, through the open part of each face (its pull on the momentum, over
        // the fluid share, is the whole cell's times it, so leaves no difference).
        defect.energy -= dt * u.gravity * 0.5f * ((cutHigh.mass + cutLow.mass) - share * (fluxHigh.mass + fluxLow.mass));
    }
    CutUpdate update = {cutLow, cutHigh, defect};
    return update;
}

static inline Flux sumOf(Flux a, Flux b) {
    a.mass += b.mass;
    a.momentum += b.momentum;
    a.energy += b.energy;
    return a;
}

// The patch refining coarse cell `cell`, or -1.
static inline int patchAt(int3 cell, const device int *patchOfTile, constant SolverUniforms &u) {
    int3 tile = cell / patchSize;
    return patchOfTile[tile.x + int(u.refineTileNx) * (tile.y + int(u.refineTileNy) * tile.z)];
}

// The refined levels as the exposure plane sees them (`finestPointPressure`): the
// first level's patch of each block, fine state and outline, and the second level's, each a
// placeholder without; `u.refineRatio` is 0 unrefined and `u.childTileNx` 0 with one level.
struct RefinedAir {
    const device int *patches;
    const device Cell *fine;
    const device uchar *mask;
    const device int *childPatches;
    const device Cell *childFine;
    const device uchar *childMask;
};

// A cell's overpressure, Pa.
static inline float cellOverpressure(Cell c, constant SolverUniforms &u) {
    float rho = max(c.rho, u.densityFloor);
    float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / rho;
    return gasPressure(rho, c.energy - kinetic, u.airModel, u.gamma) - u.ambientPressure;
}

// The overpressure on a face from the finest air touching it, where its fluid cell is refined: the
// mean of the fine cells (of the second level where that is refined) in the layer against the
// face, solid ones left out. False where the cell is not refined or the face has no solid side
// (an opening), when the coarse cell is read.
static inline bool refinedFaceOverpressure(uint fluid, uint solid, constant SolverUniforms &u,
                                           const device int *patchOfTile, const device Cell *fine,
                                           const device uchar *fineMask, const device int *childPatches,
                                           const device Cell *childFine, const device uchar *childMask,
                                           thread float &pressure) {
    if (u.refineRatio == 0 || solid == 0xFFFFFFFFu) return false;
    int3 cell = int3(fluid % u.nx, (fluid / u.nx) % u.ny, fluid / (u.nx * u.ny));
    int3 wall = int3(solid % u.nx, (solid / u.nx) % u.ny, solid / (u.nx * u.ny));
    int3 step = wall - cell;
    int axis = step.x != 0 ? 0 : (step.y != 0 ? 1 : 2);
    int patch = patchAt(cell, patchOfTile, u);
    if (patch < 0) return false;
    int r = int(u.refineRatio);
    int side = patchSize * r;
    int3 base = (cell % patchSize) * r;
    int a1 = (axis + 1) % 3;
    int a2 = (axis + 2) % 3;
    float sum = 0.0f;
    float count = 0.0f;
    for (int b = 0; b < r; ++b) {
        for (int a = 0; a < r; ++a) {
            int3 q = int3(0);
            q[axis] = step[axis] > 0 ? r - 1 : 0;
            q[a1] = a;
            q[a2] = b;
            // The second level's cells against the face, where this cell of the first is refined.
            bool deeper = false;
            if (u.childTileNx != 0) {
                int3 global = (cell * r + q) * r;
                int3 block = global / side;
                int child = childPatches[block.x + int(u.childTileNx) * (block.y + int(u.childTileNy) * block.z)];
                if (child >= 0) {
                    deeper = true;
                    int3 low = global - block * side;
                    for (int d = 0; d < r; ++d) {
                        for (int c = 0; c < r; ++c) {
                            int3 s = low;
                            s[axis] += step[axis] > 0 ? r - 1 : 0;
                            s[a1] += c;
                            s[a2] += d;
                            uint at = uint(child) * uint(side * side * side) + uint(s.x + side * (s.y + side * s.z));
                            if ((childMask[at] & 1) != 0) continue;
                            sum += cellOverpressure(childFine[at], u);
                            count += 1.0f;
                        }
                    }
                }
            }
            if (deeper) continue;
            int3 l = base + q;
            uint at = uint(patch) * uint(side * side * side) + uint(l.x + side * (l.y + side * l.z));
            if ((fineMask[at] & 1) != 0) continue;
            sum += cellOverpressure(fine[at], u);
            count += 1.0f;
        }
    }
    if (count == 0.0f) return false;
    pressure = sum / count;
    return true;
}

// The pressure of the finest fluid cell holding `point` (metres) in coarse cell `cell`, at the
// finest level refined there; false where neither covers it, or that cell is solid.
static inline bool finestPointPressure(int3 cell, float3 point, constant SolverUniforms &u, RefinedAir air,
                                       thread float &pressure) {
    if (u.refineRatio == 0) {
        return false;
    }
    int r = int(u.refineRatio);
    int side = patchSize * r;
    if (u.childTileNx != 0) {
        int deep = r * r;
        int3 global = clamp(int3(floor(point / (u.dx / float(deep)))), cell * deep, cell * deep + deep - 1);
        int3 block = global / side;
        int patch = air.childPatches[block.x + int(u.childTileNx) * (block.y + int(u.childTileNy) * block.z)];
        if (patch >= 0) {
            int3 local = global - block * side;
            uint at = uint(patch) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
            if ((air.childMask[at] & 1) == 0) {
                pressure = cellOverpressure(air.childFine[at], u) + u.ambientPressure;
                return true;
            }
        }
    }
    int patch = patchAt(cell, air.patches, u);
    if (patch < 0) {
        return false;
    }
    int3 global = clamp(int3(floor(point / (u.dx / float(r)))), cell * r, cell * r + r - 1);
    int3 local = global - cell / patchSize * patchSize * r;
    uint at = uint(patch) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
    if ((air.mask[at] & 1) != 0) {
        return false;
    }
    pressure = cellOverpressure(air.fine[at], u) + u.ambientPressure;
    return true;
}

// Where in the flux registers of `patch` its face `face` (2 axis + side) records the flux
// through the face at transverse position (a, b), cells along the next two axes in order, of
// `side` cells to an edge.
static inline uint registerSlot(uint patch, uint face, uint a, uint b, uint side) {
    return 5u * ((patch * 6u + face) * side * side + a + side * b);
}

// The same register's fuel and oxygen, in a buffer of their own.
static inline uint speciesSlot(uint patch, uint face, uint a, uint b, uint side) {
    return 2u * ((patch * 6u + face) * side * side + a + side * b);
}

// Fuel and oxygen carried through a face by mass flux `mass`, each at the mass fraction of the
// cell it leaves: `behind` when the flow is positive, `ahead` when negative.
static inline float2 speciesFlux(float mass, float2 behind, float2 ahead) {
    return mass * (mass > 0.0f ? behind : ahead);
}

// Componentwise minmod.
static inline float2 minmodPair(float2 a, float2 b) {
    return select(select(b, a, fabs(a) < fabs(b)), float2(0.0f), a * b <= 0.0f);
}

// Fuel burnt over `dt` in a cell holding `species`, as far as its oxygen allows, at `rate` (see
// `sweepCell`).
static inline float burnt(float2 species, float dt, float rate, constant SolverUniforms &u) {
    return min(species.x, species.y / u.oxygenPerFuel) * (1.0f - exp(-dt * rate));
}

// The rate at which a cell's mixed products burn: 1 / the fitted burning time, or with mixing-limited
// afterburning compiled in, an eddy-break-up rate (Spalding; Magnussen and Hjertager) where that is
// slower: C sqrt(k) / dx, the sub-grid turbulence's kinetic energy k = (nu / (C_k dx))^2 from the
// cell's eddy viscosity `nu` (scaled to the cell, `dx`, on refined levels), as a one-equation model
// and a deflagration's flame turbulence take it; `burnMixingRate` is C / C_k. Where the eddies are
// strong the fitted time governs; as they decay the products burn only as fast as oxygen is mixed
// in. A viscosity that is not finite and positive (the sigma model's can round a hair below zero)
// counts as no turbulence.
static inline float afterburnRateHere(float nu, float dx, constant SolverUniforms &u) {
    if (!burnMixing) {
        return u.afterburnRate;
    }
    float viscosity = as_type<uint>(nu) < 0x7F800000u ? nu : 0.0f;
    return min(u.afterburnRate, u.burnMixingRate * viscosity / (dx * dx));
}

// A refined cell's eddy viscosity, `fine` in its level's cells, `levels` of them along a coarse
// cell's edge: its coarse cell's scaled to its own size as an inertial range's is,
// (dx_fine / dx_coarse)^(4/3), as sub-grid mixing's fluxes take it in `fineSweepCell`.
static inline float fineEddyViscosity(int3 fine, int levels, int3 coarseDims, const device float *viscosity) {
    int3 at = clamp(fine / levels, int3(0), coarseDims - 1);
    return pow(1.0f / float(levels), 4.0f / 3.0f) * viscosity[at.x + coarseDims.x * (at.y + coarseDims.y * at.z)];
}

// Fuel burnt over `dt` in a cell of density `rho`, momentum `momentum` and energy `energy`
// holding `species`: as `burnt`, but with the extinction limit compiled in, only where the
// mixture can keep a flame going. It must be hot enough for the products' carbon monoxide to
// oxidise faster than the gas mixes, `ignitionTemperature` (Dryer and Glassman's rate puts that
// near 800 K for a fireball's mixing times); and burning all the fuel its oxygen allows must take
// it to `limitFlameTemperature`, the flame temperature mixtures at their flammability limits
// reach (about 1,500 K, Zabetakis), which makes a lean, cold mixture too dilute and a rich one too
// short of oxygen to burn, and widens the limits as the mixture warms, as real limits do.
// With mixing-limited afterburning compiled in, at `afterburnRateHere`'s rate for the cell's eddy
// viscosity `nu` and size `dx`.
static inline float afterburntHere(float2 species, float rho, float3 momentum, float energy, float dt, float nu,
                                   float dx, constant SolverUniforms &u) {
    float rate = afterburnRateHere(nu, dx, u);
    if (!burnLimit) {
        return burnt(species, dt, rate, u);
    }
    float density = max(rho, u.densityFloor);
    float internal = energy - 0.5f * dot(momentum, momentum) / density;
    float pressure = gasPressure(density, internal, u.airModel, u.gamma);
    float temperature = pressure / (density * airGasConstant);
    if (!(temperature >= u.ignitionTemperature)) {
        return 0.0f;
    }
    // The flame temperature at fixed volume, from the gas's heat capacity at its state.
    float g = gasGamma(density, pressure, u.airModel, u.gamma);
    float heat = density * airGasConstant / (g - 1.0f);
    float flame = temperature + min(species.x, species.y / u.oxygenPerFuel) * u.afterburnEnergy / heat;
    return flame >= u.limitFlameTemperature ? burnt(species, dt, rate, u) : 0.0f;
}

static inline void storeFlux(device float *registers, uint slot, Flux f, uint axis, float dt) {
    float3 momentum = fromSweep(f.momentum, axis);
    registers[slot] = f.mass * dt;
    registers[slot + 1] = momentum.x * dt;
    registers[slot + 2] = momentum.y * dt;
    registers[slot + 3] = momentum.z * dt;
    registers[slot + 4] = f.energy * dt;
}
