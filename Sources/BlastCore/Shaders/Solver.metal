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
};

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

// Fuel burnt over `dt` in a cell holding `species`, as far as its oxygen allows (see `sweepCell`).
static inline float burnt(float2 species, float dt, constant SolverUniforms &u) {
    return min(species.x, species.y / u.oxygenPerFuel) * (1.0f - exp(-dt * u.afterburnRate));
}

// Fuel burnt over `dt` in a cell of density `rho`, momentum `momentum` and energy `energy`
// holding `species`: as `burnt`, but with the extinction limit compiled in, only where the
// mixture can keep a flame going. It must be hot enough for the products' carbon monoxide to
// oxidise faster than the gas mixes, `ignitionTemperature` (Dryer and Glassman's rate puts that
// near 800 K for a fireball's mixing times); and burning all the fuel its oxygen allows must take
// it to `limitFlameTemperature`, the flame temperature mixtures at their flammability limits
// reach (about 1,500 K, Zabetakis), which makes a lean, cold mixture too dilute and a rich one too
// short of oxygen to burn, and widens the limits as the mixture warms, as real limits do.
static inline float afterburntHere(float2 species, float rho, float3 momentum, float energy, float dt,
                                   constant SolverUniforms &u) {
    if (!burnLimit) {
        return burnt(species, dt, u);
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
    return flame >= u.limitFlameTemperature ? burnt(species, dt, u) : 0.0f;
}

static inline void storeFlux(device float *registers, uint slot, Flux f, uint axis, float dt) {
    float3 momentum = fromSweep(f.momentum, axis);
    registers[slot] = f.mass * dt;
    registers[slot + 1] = momentum.x * dt;
    registers[slot + 2] = momentum.y * dt;
    registers[slot + 3] = momentum.z * dt;
    registers[slot + 4] = f.energy * dt;
}

// One-dimensional MUSCL-Hancock update of one cell along `u.axis`.
static inline void sweepCell(int3 cell, device Cell *src, device Cell *dst, const device uchar *mask,
                             device float *peak, device float *impulse, const device StepControl &control,
                             device atomic_uint *maxSpeed, constant SolverUniforms &u,
                             const device float *wallVelocity, device uchar *tileFlags,
                             device float2 *speciesSrc, device float2 *speciesDst,
                             const device int *patchOfTile, device float *coarseFlux,
                             device float *coarseSpeciesFlux, const device uchar *boxMask, device float *boxImpulse,
                             const device float4 *gravityTable, const device float *viscosity,
                             const device uint4 *cutColumns, const device float4 *cutRecords,
                             const device float4 *cutWalls, device float4 *cutDefects, const device uint *cutCeilings) {
    int index = cell.x + int(u.nx) * (cell.y + int(u.ny) * cell.z);
    // With cut cells, whether this cell lies below the highest the cut cells' work reaches over its
    // tile's columns (`TerrainCutGeometry.tileCeilings`): above it there is none to do.
    bool nearCut = cutCells
        && cell.z < int(cutCeilings[uint(cell.x / tileSize) + (u.nx + uint(tileSize) - 1u) / uint(tileSize) * uint(cell.y / tileSize)]);
    if (control.dt <= 0.0f) {
        // A step that does nothing (past the time limit) swaps the two buffers' cells, solid
        // ones included, as the host swaps the buffers: the air is then exactly as if the step
        // had never been encoded.
        Cell held = dst[index];
        dst[index] = src[index];
        src[index] = held;
        if (carriesSpecies(u)) {
            float2 species = speciesDst[index];
            speciesDst[index] = speciesSrc[index];
            speciesSrc[index] = species;
        }
        return;
    }
    if (mask[index] != 0) {
        return;
    }

    uint axis = u.axis;
    int n = axis == 0 ? int(u.nx) : (axis == 1 ? int(u.ny) : int(u.nz));
    int i = cell[axis];
    int stride = axis == 0 ? 1 : (axis == 1 ? int(u.nx) : int(u.nx * u.ny));
    bool lowWall = ((u.boundaryFlags >> (2 * axis)) & 1u) != 0;
    bool highWall = ((u.boundaryFlags >> (2 * axis + 1)) & 1u) != 0;

    // Five-cell stencil with walls replaced by mirrored ghosts and open faces by copies.
    Prim w0 = loadPrim(src, index, u);
    int kindP1 = classify(mask, index, 1, stride, i, n, lowWall, highWall);
    int kindM1 = classify(mask, index, -1, stride, i, n, lowWall, highWall);

    float speedP1 = kindP1 == kindWall ? wallSpeed(wallVelocity, cell, 1, u) : 0.0f;
    float speedM1 = kindM1 == kindWall ? wallSpeed(wallVelocity, cell, -1, u) : 0.0f;

    // With gravity, the cell each state came from (offsets M2, M1, P1, P2) and -1 for a mirror.
    int4 from = int4(-2, -1, 1, 2);
    float4 mirror = float4(1.0f);
    Prim wP1 = w0;
    if (kindP1 == kindFluid) {
        wP1 = loadPrim(src, index + stride, u);
    } else if (kindP1 == kindWall) {
        wP1 = mirrored(w0, speedP1);
        from.z = 0;
        mirror.z = -1.0f;
    } else {
        if (farFieldFaces(u)) { wP1 = farFieldGhost(w0, 1.0f, u); }
        from.z = 0;
    }
    Prim wM1 = w0;
    if (kindM1 == kindFluid) {
        wM1 = loadPrim(src, index - stride, u);
    } else if (kindM1 == kindWall) {
        wM1 = mirrored(w0, speedM1);
        from.y = 0;
        mirror.y = -1.0f;
    } else {
        if (farFieldFaces(u)) { wM1 = farFieldGhost(w0, -1.0f, u); }
        from.y = 0;
    }

    Prim wP2 = wP1;
    if (kindP1 == kindWall) {
        wP2 = mirrored(wM1, speedP1);
        from.w = from.y;
        mirror.w = -mirror.y;
    } else if (kindP1 == kindFluid) {
        int kind = classify(mask, index, 2, stride, i, n, lowWall, highWall);
        if (kind == kindFluid) {
            wP2 = loadPrim(src, index + 2 * stride, u);
        } else if (kind == kindWall) {
            wP2 = mirrored(wP1, wallSpeed(wallVelocity, cell, 2, u));
            from.w = 1;
            mirror.w = -1.0f;
        } else {
            from.w = 1;
        }
    } else {
        from.w = from.z;
    }
    Prim wM2 = wM1;
    if (kindM1 == kindWall) {
        wM2 = mirrored(wP1, speedM1);
        from.x = from.z;
        mirror.x = -mirror.z;
    } else if (kindM1 == kindFluid) {
        int kind = classify(mask, index, -2, stride, i, n, lowWall, highWall);
        if (kind == kindFluid) {
            wM2 = loadPrim(src, index - 2 * stride, u);
        } else if (kind == kindWall) {
            wM2 = mirrored(wM1, wallSpeed(wallVelocity, cell, -2, u));
            from.x = -1;
            mirror.x = -1.0f;
        } else {
            from.x = -1;
        }
    } else {
        from.x = from.y;
    }

    // A cut cell's solid neighbours stand for its wall, which faces along the cell's normal, not along
    // the sweep: a ghost beside a cut cell mirrors that cell's state (or, two away, the state as far
    // the other side of it) about the cut cell's normal. Every thread that needs a ghost builds it
    // by the same rule from the same cell, so both cells beside a face work out the same flux.
    if (nearCut) {
        int3 above = cell;
        int3 below = cell;
        int3 above2 = cell;
        int3 below2 = cell;
        above[axis] += 1;
        below[axis] -= 1;
        above2[axis] += 2;
        below2[axis] -= 2;
        bool cutHere = cutCellHere(cell, cutColumns, u);
        if (kindP1 == kindWall && cutHere && terrainSolid(above, cutColumns, u)) {
            float3 normal = cutNormalOf(cell, cutColumns, cutWalls, axis, u);
            wP1 = mirroredAbout(w0, normal);
            wP2 = mirroredAbout(wM1, normal);
        }
        if (kindM1 == kindWall && cutHere && terrainSolid(below, cutColumns, u)) {
            float3 normal = cutNormalOf(cell, cutColumns, cutWalls, axis, u);
            wM1 = mirroredAbout(w0, normal);
            wM2 = mirroredAbout(wP1, normal);
        }
        if (kindP1 == kindFluid && classify(mask, index, 2, stride, i, n, lowWall, highWall) == kindWall
            && terrainSolid(above2, cutColumns, u) && cutCellHere(above, cutColumns, u)) {
            wP2 = mirroredAbout(wP1, cutNormalOf(above, cutColumns, cutWalls, axis, u));
        }
        if (kindM1 == kindFluid && classify(mask, index, -2, stride, i, n, lowWall, highWall) == kindWall
            && terrainSolid(below2, cutColumns, u) && cutCellHere(below, cutColumns, u)) {
            wM2 = mirroredAbout(wM1, cutNormalOf(below, cutColumns, cutWalls, axis, u));
        }
    }

    float dt = control.dt;
    float lambda = dt / u.dx;
    Flux fluxLow;
    Flux fluxHigh;
    bool gravityHere = airGravity && axis == 2u;
    if (gravityHere) {
        stencilFluxesGravity(wM2, wM1, w0, wP1, wP2, from, mirror, cell.z, gravityTable, lambda, dt, u, fluxLow,
                             fluxHigh);
    } else {
        stencilFluxes(wM2, wM1, w0, wP1, wP2, lambda, u, fluxLow, fluxHigh);
    }
    // Sub-grid mixing's fluxes through the faces with fluid beyond them.
    float carrierLow = 0.0f;
    float carrierHigh = 0.0f;
    if (airMixing) {
        float nu0 = viscosity[index];
        if (kindM1 == kindFluid) {
            MixingFace face = mixingFace(wM1, w0, viscosity[index - stride], nu0, u.dx, dt, u);
            fluxLow = sumOf(fluxLow, face.flux);
            carrierLow = face.carrier;
        }
        if (kindP1 == kindFluid) {
            MixingFace face = mixingFace(w0, wP1, nu0, viscosity[index + stride], u.dx, dt, u);
            fluxHigh = sumOf(fluxHigh, face.flux);
            carrierHigh = face.carrier;
        }
    }

    // Experimental rigid-box path: impermeable moving-wall traction, recorded from the
    // same numerical face flux used by the gas. Each fluid thread owns six output scalars, one
    // for each of its faces (low and high along each axis); the host gives each face's impulse
    // to the box beyond it. Use gauge pressure for body loading; uniform atmospheric preload is
    // balanced externally.
    if (u.experimentalBox != 0 && (u.refineRatio == 0 || patchAt(cell, patchOfTile, u) < 0)) {
        for (int side = 0; side < 2; ++side) {
            int direction = side == 0 ? -1 : 1;
            bool inside = side == 0 ? i > 0 : i < n - 1;
            if (!inside || boxMask[index + direction * stride] == 0) continue;
            Flux f = side == 0 ? fluxLow : fluxHigh;
            float speed = side == 0 ? speedM1 : speedP1;
            float traction = f.momentum.x - f.mass * speed;
            f.mass = 0.0f;
            f.momentum = float3(traction, 0.0f, 0.0f);
            f.energy = traction * speed;
            if (side == 0) fluxLow = f; else fluxHigh = f;
            boxImpulse[6 * index + 2 * axis + side] +=
                float(direction) * (traction - u.ambientPressure) * dt * u.dx * u.dx;
        }
    }

    // A cell of unrefined air beside a patch records the flux it used through the face they
    // share, so that the patch's own fluxes can replace it (see Refine.metal).
    int speciesRegister = -1;  // where its fuel and oxygen flux goes, if it records one
    int fluxRegister = -1;  // and its flux
    bool registerLow = false;
    if (u.refineRatio != 0) {
        // The cell across may be fluid or solid here; either way this cell's flux through the
        // face is what the patch's fine fluxes replace.
        int local = i % patchSize;
        bool lowEdge = local == 0 && i > 0;
        bool highEdge = local == patchSize - 1 && i < n - 1;
        if ((lowEdge || highEdge) && patchAt(cell, patchOfTile, u) < 0) {
            int3 across = cell;
            across[axis] += lowEdge ? -1 : 1;
            int patch = patchAt(across, patchOfTile, u);
            if (patch >= 0) {
                int3 inPatch = cell % patchSize;
                uint face = 2u * axis + (lowEdge ? 1u : 0u);
                uint slot = registerSlot(uint(patch), face, uint(inPatch[(axis + 1) % 3]),
                                         uint(inPatch[(axis + 2) % 3]), uint(patchSize));
                fluxRegister = int(slot);
                speciesRegister = int(speciesSlot(uint(patch), face, uint(inPatch[(axis + 1) % 3]),
                                                  uint(inPatch[(axis + 2) % 3]), uint(patchSize)));
                registerLow = lowEdge;
            }
        }
    }

    // A cut cell: the conservative update (each face's flux times its aperture, the wall's pressure
    // on the wall's area along the sweep), against the whole cell's update that the sweep gives it;
    // the difference, for the volume it holds, is kept for `redistributeCutDefects`.
    int cutRecord = -1;
    Flux defect = {0.0f, float3(0.0f), 0.0f};
    Flux cutLow = fluxLow;
    Flux cutHigh = fluxHigh;
    float cutShare = 1.0f;
    float registerAperture = 1.0f;
    float cutApertureLow = 1.0f;
    float cutApertureHigh = 1.0f;
    if (nearCut) {
        uint4 column = cutColumnOf(cell, cutColumns, u);
        if (cell.z < int(column.z)) {
            cutRecord = int(column.x + uint(cell.z) - column.y);
            float4 own = cutRecords[cutRecord];
            int3 next = cell;
            next[axis] += 1;
            float apertureLow = own[1 + axis];
            float apertureHigh = cutRecordOf(next, cutColumns, cutRecords, u)[1 + axis];
            float4 wall = cutWalls[cutRecord];
            cutShare = own.x;
            CutUpdate update = cutCellUpdate(w0, fluxLow, fluxHigh, apertureLow, apertureHigh, cutShare,
                                             toSweep(wall.xyz, axis), gravityHere, gravityTable, cell.z, lambda, dt, u);
            cutLow = update.low;
            cutHigh = update.high;
            defect = update.defect;
            registerAperture = registerLow ? apertureLow : apertureHigh;
            cutApertureLow = apertureLow;
            cutApertureHigh = apertureHigh;
        }
    }
    if (fluxRegister >= 0) {
        // Through a cut cell's face, the face's own flux times its aperture (the wall's push is the
        // cell's own, not the face's), as the fine cells record theirs.
        Flux through = registerLow ? fluxLow : fluxHigh;
        if (registerAperture != 1.0f) {
            through.mass *= registerAperture;
            through.momentum *= registerAperture;
            through.energy *= registerAperture;
        }
        storeFlux(coarseFlux, uint(fluxRegister), through, axis, dt);
    }

    Cell c = src[index];
    float3 momentum = toSweep(float3(c.mx, c.my, c.mz), axis);
    float rho = c.rho - lambda * (fluxHigh.mass - fluxLow.mass);
    momentum -= lambda * (fluxHigh.momentum - fluxLow.momentum);
    float energy = c.energy - lambda * (fluxHigh.energy - fluxLow.energy);
    if (gravityHere) {
        gravitySources(momentum, energy, w0.rho, fluxLow, fluxHigh, cell.z, gravityTable, dt, u);
    }

    // Detonation products that have not yet burnt ("fuel") and oxygen, as densities, carried
    // by the same mass fluxes, each at the mass fraction of the cell it leaves (first-order
    // upwind, so they stay positive). Where they meet in a cell, the fuel burns at once, as far
    // as the oxygen allows, after the final sweep of the step: afterburning limited by mixing,
    // which here is the grid's own.
    float2 species = float2(0.0f);
    if (carriesSpecies(u)) {
        float2 own = speciesSrc[index];
        // A deflagration's cloud has a sharp edge, and on cut cells a small cell's whole-cell update
        // can take more of it than the cell holds, until its difference is shared out (see
        // `redistributeCutDefects`). Holding that at zero would make gas, so it is not; instead the
        // faces' mass fractions are of what is there, none for a cell left short, which both cells
        // beside a face take alike, and nothing short is carried on.
        bool leftShort = u.deflagration != 0u;
        float2 fraction = (leftShort ? max(own, 0.0f) : own) / max(c.rho, u.densityFloor);
        // Beyond a far-field face, still air: its oxygen and no products.
        float2 ambient = farFieldFaces(u) ? float2(0.0f, u.stillOxygen / u.stillRho) : fraction;
        float2 belowSpecies = kindM1 == kindFluid ? speciesSrc[index - stride] : float2(0.0f);
        float2 aboveSpecies = kindP1 == kindFluid ? speciesSrc[index + stride] : float2(0.0f);
        if (leftShort) {
            belowSpecies = max(belowSpecies, 0.0f);
            aboveSpecies = max(aboveSpecies, 0.0f);
        }
        float2 below = kindM1 == kindFluid ? belowSpecies / wM1.rho : (kindM1 == kindOpen ? ambient : fraction);
        float2 above = kindP1 == kindFluid ? aboveSpecies / wP1.rho : (kindP1 == kindOpen ? ambient : fraction);
        float2 inflow = speciesFlux(fluxLow.mass, below, fraction);
        float2 outflow = speciesFlux(fluxHigh.mass, fraction, above);
        float2 lowFace = float2(0.0f);
        float2 highFace = float2(0.0f);
        if (u.deflagration != 0u) {
            // A deflagration's mixture is carried at limited linear (MUSCL) mass fractions at the
            // faces instead: at the upwind cell's, the grid's diffusion would spread its flame
            // over many cells (see Deflagration.metal). Both cells beside a face work out the
            // same value, so the species stay conserved.
            float2 below2 = below;
            if (kindM1 == kindFluid && classify(mask, index, -2, stride, i, n, lowWall, highWall) == kindFluid) {
                below2 = max(speciesSrc[index - 2 * stride], 0.0f) / wM2.rho;
            }
            float2 above2 = above;
            if (kindP1 == kindFluid && classify(mask, index, 2, stride, i, n, lowWall, highWall) == kindFluid) {
                above2 = max(speciesSrc[index + 2 * stride], 0.0f) / wP2.rho;
            }
            lowFace = fluxLow.mass > 0.0f ? below + 0.5f * minmodPair(below - below2, fraction - below)
                                          : fraction - 0.5f * minmodPair(fraction - below, above - fraction);
            highFace = fluxHigh.mass > 0.0f ? fraction + 0.5f * minmodPair(fraction - below, above - fraction)
                                            : above - 0.5f * minmodPair(above - fraction, above2 - above);
            inflow = fluxLow.mass * lowFace;
            outflow = fluxHigh.mass * highFace;
        }
        if (airMixing) {
            // Sub-grid mixing carries the species down their gradients in mass fraction.
            inflow -= carrierLow * (fraction - below);
            outflow -= carrierHigh * (above - fraction);
        }
        if (cutRecord >= 0) {
            // The species' difference too, at the conservative mass fluxes and the faces' own mass
            // fractions (a deflagration's limited linear ones), and the mixing's carrying through
            // each face's open part: through each face as the cell beyond it takes them.
            float2 cutIn = u.deflagration != 0u ? cutLow.mass * lowFace : speciesFlux(cutLow.mass, below, fraction);
            float2 cutOut = u.deflagration != 0u ? cutHigh.mass * highFace : speciesFlux(cutHigh.mass, fraction, above);
            if (airMixing) {
                cutIn -= cutApertureLow * carrierLow * (fraction - below);
                cutOut -= cutApertureHigh * carrierHigh * (above - fraction);
            }
            float2 kept = -lambda * ((cutOut - cutIn) - cutShare * (outflow - inflow));
            float4 held = cutDefects[2 * cutRecord + 1];
            cutDefects[2 * cutRecord + 1] = float4(held.xy + kept, held.zw);
        }
        // Near a deflagration's cut cells nothing is held at zero (see `leftShort`).
        species = own - lambda * (outflow - inflow);
        if (!(leftShort && nearCut)) {
            species = max(species, 0.0f);
        }
        if (speciesRegister >= 0) {
            float2 through = (registerLow ? inflow : outflow) * (registerAperture * dt);
            coarseSpeciesFlux[speciesRegister] = through.x;
            coarseSpeciesFlux[speciesRegister + 1] = through.y;
        }
        if (u.finalSweep != 0 && u.afterburnEnergy > 0.0f) {
            float fuel = afterburntHere(species, rho, momentum, energy, control.dt, u);
            species.x -= fuel;
            species.y -= fuel * u.oxygenPerFuel;
            energy += fuel * u.afterburnEnergy;
        }
        speciesDst[index] = species;
    }

    if (cutRecord >= 0) {
        float4 held = cutDefects[2 * cutRecord];
        float4 heldEnergy = cutDefects[2 * cutRecord + 1];
        cutDefects[2 * cutRecord] = float4(held.x + defect.mass, held.yzw + fromSweep(defect.momentum, axis));
        cutDefects[2 * cutRecord + 1] = float4(heldEnergy.xy, heldEnergy.z + defect.energy, heldEnergy.w);
    }
    rho = max(rho, u.densityFloor);
    float kinetic = 0.5f * dot(momentum, momentum) / rho;
    float pressure = gasPressure(rho, energy - kinetic, u.airModel, u.gamma);
    if (pressure < u.pressureFloor) {
        pressure = u.pressureFloor;
        energy = gasEnergy(rho, pressure, u.airModel, u.gamma) + kinetic;
    }

    float3 worldMomentum = fromSweep(momentum, axis);
    Cell result;
    result.rho = rho;
    result.mx = worldMomentum.x;
    result.my = worldMomentum.y;
    result.mz = worldMomentum.z;
    result.energy = energy;
    dst[index] = result;

    if (u.finalSweep != 0) {
        // Under gravity, against the ambient pressure at the cell's height.
        float ambient = airGravity ? gravityAmbientOf(gravityTable, cell.z, u) : u.ambientPressure;
        float overpressure = pressure - ambient;
        peak[index] = max(peak[index], overpressure);
        // Under a patch, impulse is taken from the fine cells instead (see Refine.metal).
        if (u.refineRatio == 0 || patchAt(cell, patchOfTile, u) < 0) {
            impulse[index] += max(overpressure, 0.0f) * dt;
        }
        recordCell(maxSpeed, momentum, rho, pressure, u, ambient);
        // A changed cell near the edge of its tile wakes the tiles it can reach next step.
        if (u.tileNx != 0 && !isStillAt(result, species, cell.z, gravityTable, u)) {
            int3 local = cell % tileSize;
            if (any(local < tileReach) || any(local >= tileSize - tileReach)) {
                wakeTilesAround(cell, tileFlags, tileWoken, u);
            }
        }
    }
}

// Sweeps every cell.
kernel void sweep(device Cell *src [[buffer(0)]],
                  device Cell *dst [[buffer(1)]],
                  const device uchar *mask [[buffer(2)]],
                  device float *peak [[buffer(3)]],
                  device float *impulse [[buffer(4)]],
                  const device StepControl &control [[buffer(5)]],
                  device atomic_uint *maxSpeed [[buffer(6)]],
                  constant SolverUniforms &u [[buffer(7)]],
                  const device float *wallVelocity [[buffer(8)]],
                  device uchar *tileFlags [[buffer(10)]],
                  device float2 *speciesSrc [[buffer(11)]],
                  device float2 *speciesDst [[buffer(12)]],
                  const device int *patchOfTile [[buffer(13)]],
                  device float *coarseFlux [[buffer(14)]],
                  device float *coarseSpeciesFlux [[buffer(15)]],
                  const device uchar *boxMask [[buffer(16)]],
                  device float *boxImpulse [[buffer(17)]],
                  const device float4 *gravityTable [[buffer(18)]],
                  const device float *viscosity [[buffer(19)]],
                  const device uint4 *cutColumns [[buffer(20)]],
                  const device float4 *cutRecords [[buffer(21)]],
                  const device float4 *cutWalls [[buffer(22)]],
                  device float4 *cutDefects [[buffer(23)]],
                  const device uint *cutCeilings [[buffer(24)]],
                  uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    sweepCell(int3(tid), src, dst, mask, peak, impulse, control, maxSpeed, u, wallVelocity, tileFlags,
              speciesSrc, speciesDst, patchOfTile, coarseFlux, coarseSpeciesFlux, boxMask, boxImpulse,
              gravityTable, viscosity, cutColumns, cutRecords, cutWalls, cutDefects, cutCeilings);
}

// Sweeps the cells of the tiles listed in `tiles`, one threadgroup per tile; each thread takes
// a column of the tile through z.
kernel void sweepTiles(device Cell *src [[buffer(0)]],
                       device Cell *dst [[buffer(1)]],
                       const device uchar *mask [[buffer(2)]],
                       device float *peak [[buffer(3)]],
                       device float *impulse [[buffer(4)]],
                       const device StepControl &control [[buffer(5)]],
                       device atomic_uint *maxSpeed [[buffer(6)]],
                       constant SolverUniforms &u [[buffer(7)]],
                       const device float *wallVelocity [[buffer(8)]],
                       const device uint *tiles [[buffer(9)]],
                       device uchar *tileFlags [[buffer(10)]],
                       device float2 *speciesSrc [[buffer(11)]],
                       device float2 *speciesDst [[buffer(12)]],
                       const device int *patchOfTile [[buffer(13)]],
                       device float *coarseFlux [[buffer(14)]],
                       device float *coarseSpeciesFlux [[buffer(15)]],
                  const device uchar *boxMask [[buffer(16)]],
                  device float *boxImpulse [[buffer(17)]],
                       const device float4 *gravityTable [[buffer(18)]],
                  const device float *viscosity [[buffer(19)]],
                       const device uint4 *cutColumns [[buffer(20)]],
                       const device float4 *cutRecords [[buffer(21)]],
                       const device float4 *cutWalls [[buffer(22)]],
                       device float4 *cutDefects [[buffer(23)]],
                       const device uint *cutCeilings [[buffer(24)]],
                       uint3 group [[threadgroup_position_in_grid]],
                       uint3 local [[thread_position_in_threadgroup]],
                       uint3 groupSize [[threads_per_threadgroup]]) {
    uint tile = tiles[group.x];
    uint3 origin = uint3(tile % u.tileNx, (tile / u.tileNx) % u.tileNy, tile / (u.tileNx * u.tileNy))
        * uint(tileSize);
    for (uint z = local.z; z < uint(tileSize); z += groupSize.z) {
        uint3 cell = origin + uint3(local.x, local.y, z);
        if (cell.x < u.nx && cell.y < u.ny && cell.z < u.nz) {
            sweepCell(int3(cell), src, dst, mask, peak, impulse, control, maxSpeed, u, wallVelocity, tileFlags,
                      speciesSrc, speciesDst, patchOfTile, coarseFlux, coarseSpeciesFlux, boxMask, boxImpulse,
                      gravityTable, viscosity, cutColumns, cutRecords, cutWalls, cutDefects, cutCeilings);
        }
    }
}

// After a step's sweeps, with cut cells: each cut cell's difference between its conservative
// update and the whole cell's it was given (its fuel and oxygen's too) is shared out up its
// column: the cell keeps its share alpha of it, and the rest goes to the first cell above it at
// least half full (the next cell up, for a cell itself at least half full), in a fixed order. The
// differences are then cleared. One thread a column with cut cells, its index in `columnsCut`.
// Where the air is refined, this runs after refluxing: a cell under a patch drops its own
// difference (its fine cells hold its air, and have shared out theirs), and what reaches such a
// cell goes into its fine cells, as much a volume to each. A block standing in the column stops
// what is carried up; the last cell of air below it takes it.
kernel void redistributeCutDefects(device Cell *state [[buffer(0)]],
                                   device float2 *species [[buffer(1)]],
                                   const device uint4 *cutColumns [[buffer(2)]],
                                   const device float4 *cutRecords [[buffer(3)]],
                                   constant SolverUniforms &u [[buffer(4)]],
                                   const device StepControl &control [[buffer(5)]],
                                   device float *peak [[buffer(6)]],
                                   device atomic_uint *maxSpeed [[buffer(7)]],
                                   device float4 *cutDefects [[buffer(8)]],
                                   const device uint *columnsCut [[buffer(9)]],
                                   constant uint &columnCount [[buffer(10)]],
                                   const device float4 *gravityTable [[buffer(11)]],
                                   const device uchar *mask [[buffer(12)]],
                                   const device int *patchOfTile [[buffer(13)]],
                                   device Cell *fine [[buffer(14)]],
                                   const device float4 *fineCut [[buffer(15)]],
                                   device float2 *fineSpecies [[buffer(16)]],
                                   const device uchar *fineMask [[buffer(17)]],
                                   const device float4 *fineGravityTable [[buffer(18)]],
                                   device uchar *tileFlags [[buffer(19)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (!cutCells || gid >= columnCount) {
        return;
    }
    uint columnIndex = columnsCut[gid];
    uint4 column = cutColumns[columnIndex];
    bool withSpecies = carriesSpecies(u);
    if (control.dt <= 0.0f) {
        return;
    }
    int2 xy = int2(int(columnIndex % (u.nx + 1u)), int(columnIndex / (u.nx + 1u)));
    int stride = int(u.nx * u.ny);
    int base = xy.x + int(u.nx) * xy.y;
    int top = int(u.nz) - 1;
    bool refined = u.refineRatio != 0u;
    int r = int(u.refineRatio);
    int side = patchSize * r;
    // Adds `change` (mass, momentum) and `changeEnergy` (fuel, oxygen, energy), for its whole volume,
    // to the air of cell k, holding `alpha` of it: to its own state, or under a patch to each of its
    // fine cells of air.
    auto apply = [&](int k, float4 change, float4 changeEnergy, float alpha) {
        int3 cell = int3(xy, k);
        int index = base + stride * k;
        int holder = refined ? patchAt(cell, patchOfTile, u) : -1;
        if (holder >= 0) {
            int3 tile = cell / patchSize;
            for (int n = 0; n < r * r * r; ++n) {
                int3 f = cell * r + int3(n % r, (n / r) % r, n / (r * r));
                int3 local = f - tile * side;
                uint child = uint(holder) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
                if ((fineMask[child] & 1) != 0) {
                    continue;
                }
                Cell c = fine[child];
                c.rho = max(c.rho + change.x / alpha, u.densityFloor);
                c.mx += change.y / alpha;
                c.my += change.z / alpha;
                c.mz += change.w / alpha;
                c.energy += changeEnergy.z / alpha;
                float3 momentum = float3(c.mx, c.my, c.mz);
                float kinetic = 0.5f * dot(momentum, momentum) / c.rho;
                float pressure = gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma);
                if (pressure < u.pressureFloor) {
                    pressure = u.pressureFloor;
                    c.energy = gasEnergy(c.rho, pressure, u.airModel, u.gamma) + kinetic;
                }
                fine[child] = c;
                if (withSpecies) {
                    fineSpecies[child] = max(fineSpecies[child] + changeEnergy.xy / alpha, 0.0f);
                }
                float ambient = airGravity ? gravityAmbientOf(fineGravityTable, f.z, u) : u.ambientPressure;
                recordCell(maxSpeed, momentum, c.rho, pressure, u, ambient);
            }
            return;
        }
        Cell c = state[index];
        c.rho += change.x / alpha;
        c.mx += change.y / alpha;
        c.my += change.z / alpha;
        c.mz += change.w / alpha;
        c.energy += changeEnergy.z / alpha;
        c.rho = max(c.rho, u.densityFloor);
        float3 momentum = float3(c.mx, c.my, c.mz);
        float kinetic = 0.5f * dot(momentum, momentum) / c.rho;
        float pressure = gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma);
        if (pressure < u.pressureFloor) {
            pressure = u.pressureFloor;
            c.energy = gasEnergy(c.rho, pressure, u.airModel, u.gamma) + kinetic;
        }
        state[index] = c;
        if (withSpecies) {
            // A deflagration's are not held at zero: a cell above the cloud's edge can be given a
            // difference that takes what a small cell beneath gave too much of (see `sweepCell`).
            float2 given = species[index] + changeEnergy.xy / alpha;
            species[index] = u.deflagration != 0u ? given : max(given, 0.0f);
        }
        float ambient = airGravity ? gravityAmbientOf(gravityTable, k, u) : u.ambientPressure;
        peak[index] = max(peak[index], pressure - ambient);
        recordCell(maxSpeed, momentum, c.rho, pressure, u, ambient);
        // A cell changed here, perhaps in a tile asleep (the cell above a sliver), is swept next step.
        if (u.tileNx != 0) {
            wakeTilesAround(cell, tileFlags, tileWoken, u);
        }
    };
    // What each cell above the first gets from those below it, carried up the column.
    float4 passed = float4(0.0f);
    float4 passedEnergy = float4(0.0f);
    int lastK = -1;
    float lastAlpha = 1.0f;
    int last = min(max(int(column.z), int(column.w)), top);
    for (int k = int(column.y); k <= last; ++k) {
        float alpha = cutRecordOf(int3(xy, k), cutColumns, cutRecords, u).x;
        float4 change = float4(0.0f);
        float4 changeEnergy = float4(0.0f);
        // From the first cell at least half full up, each takes what those below passed on.
        if (k >= int(column.w)) {
            change += passed;
            changeEnergy += passedEnergy;
            passed = float4(0.0f);
            passedEnergy = float4(0.0f);
        }
        if (k < int(column.z)) {
            uint record = column.x + uint(k) - column.y;
            float4 d = cutDefects[2 * record];
            float4 e = cutDefects[2 * record + 1];
            cutDefects[2 * record] = float4(0.0f);
            cutDefects[2 * record + 1] = float4(0.0f);
            if (!refined || patchAt(int3(xy, k), patchOfTile, u) < 0) {
                // Its share, and the rest for the cell that takes it.
                change += alpha * d;
                changeEnergy += alpha * e;
                passed += (1.0f - alpha) * d;
                passedEnergy += (1.0f - alpha) * e;
            }
        }
        if (mask[base + stride * k] != 0) {
            // A block: what it would take goes to the last cell of air below it, and nothing
            // passes it.
            change += passed;
            changeEnergy += passedEnergy;
            passed = float4(0.0f);
            passedEnergy = float4(0.0f);
            if (lastK >= 0 && (any(change != 0.0f) || any(changeEnergy != 0.0f))) {
                apply(lastK, change, changeEnergy, lastAlpha);
            }
            continue;
        }
        lastK = k;
        lastAlpha = alpha;
        if (all(change == 0.0f) && all(changeEnergy == 0.0f)) {
            continue;
        }
        apply(k, change, changeEnergy, alpha);
    }
}

// After a restart: wakes the tiles within reach of every fluid cell that is not still.
kernel void wakeTiles(const device Cell *state [[buffer(0)]],
                      const device uchar *mask [[buffer(1)]],
                      device uchar *tileFlags [[buffer(2)]],
                      constant SolverUniforms &u [[buffer(3)]],
                      const device float2 *species [[buffer(4)]],
                      const device float4 *gravityTable [[buffer(5)]],
                      uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    int index = int(tid.x + u.nx * (tid.y + u.ny * tid.z));
    if (mask[index] == 0 && !isStillAt(state[index], species[index], int(tid.z), gravityTable, u)) {
        wakeTilesAround(int3(tid), tileFlags, tileActive, u);
    }
}

// Before each step: lists the awake tiles for the sweeps. Still air, and air woken during the
// last step, was not swept then, so its contribution to the time step is added here, exactly
// as the final sweep would have computed it for a still cell.
kernel void collectTiles(device uchar *tileFlags [[buffer(0)]],
                         device uint *tiles [[buffer(1)]],
                         device atomic_uint *tileCount [[buffer(2)]],
                         device atomic_uint *maxSpeed [[buffer(3)]],
                         constant SolverUniforms &u [[buffer(4)]],
                         const device float4 *gravityTable [[buffer(5)]],
                         uint tid [[thread_position_in_grid]]) {
    if (tid >= u.tileNx * u.tileNy * u.tileNz) {
        return;
    }
    uchar flag = tileFlags[tid];
    if (flag != tileActive && airGravity) {
        // Under gravity, the air at rest at the ground, the warmest and so the fastest; it sets
        // the step only while nothing moves, which a charge does from its first step.
        Prim w = primOfCell(gravityRestOf(gravityTable, 0), u);
        recordCell(maxSpeed, float3(0.0f), w.rho, w.p, u, w.p);
    } else if (flag != tileActive) {
        float rho = max(u.stillRho, u.densityFloor);
        float3 momentum = float3(u.stillMx, u.stillMy, u.stillMz);
        float kinetic = 0.5f * dot(momentum, momentum) / rho;
        float pressure = gasPressure(rho, u.stillEnergy - kinetic, u.airModel, u.gamma);
        if (pressure < u.pressureFloor) {
            pressure = u.pressureFloor;
        }
        recordCell(maxSpeed, momentum, rho, pressure, u);
    }
    if (flag != tileStill) {
        tiles[atomic_fetch_add_explicit(tileCount, 1u, memory_order_relaxed)] = tid;
        if (flag == tileWoken) {
            tileFlags[tid] = tileActive;
        }
    }
}

// Writes row `row` of the gauge log: the step's length, then each gauge's pressure.
static inline void logGauges(device float *gaugeLog, uint row, float dt, const device Cell *state,
                             const device uint *gaugeCells, constant SolverUniforms &u,
                             const device int *patchOfTile, const device Cell *fine,
                             const device uint *gaugeChildren, const device uchar *fineMask,
                             const device int *childPatches, const device Cell *childFine,
                             const device uchar *childMask, const device float4 *gravityTable,
                             const device uchar *mask, const device float4 *gaugePoints) {
    row *= u.gaugeCount + 1;
    gaugeLog[row] = dt;
    for (uint g = 0; g < u.gaugeCount; ++g) {
        Cell c = state[gaugeCells[g]];
        // A gauge whose cell a structure has moved into reads the fluid cell beside it nearest its
        // point, at the finest level it can, rather than the solid cell's stale state.
        bool read = mask[gaugeCells[g]] == 0;
        float3 point = gaugePoints[g].xyz;
        bool placed = gaugePoints[g].w != 0.0f;
        // Where the gauge's cell is refined, the finest cell holding the gauge's point: `child`
        // numbers the finest cells of its coarse cell.
        uint child = gaugeChildren[g];
        if (u.refineRatio != 0 && child != 0xFFFFFFFFu) {
            uint index = gaugeCells[g];
            int3 cell = int3(index % u.nx, (index / u.nx) % u.ny, index / (u.nx * u.ny));
            int r = int(u.refineRatio);
            int side = patchSize * r;
            int3 within = int3(child % uint(r), (child / uint(r)) % uint(r), child / uint(r * r));
            bool found = false;
            if (u.childTileNx != 0) {
                // Two levels: the cell of the second level, where it is refined.
                int deep = r * r;
                int3 finest = int3(child % uint(deep), (child / uint(deep)) % uint(deep), child / uint(deep * deep));
                int3 global = cell * deep + finest;
                int3 block = global / side;
                int patch = childPatches[block.x + int(u.childTileNx) * (block.y + int(u.childTileNy) * block.z)];
                if (patch >= 0) {
                    int3 local = global - block * side;
                    uint at = uint(patch) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
                    if ((childMask[at] & 1) == 0) {
                        c = childFine[at];
                        found = true;
                    }
                }
                within = finest / r;
            }
            int patch = found ? -1 : patchAt(cell, patchOfTile, u);
            if (patch >= 0) {
                int3 local = (cell % patchSize) * r + within;
                uint at = uint(patch) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
                if ((fineMask[at] & 1) == 0) {
                    c = fine[at];
                    found = true;
                } else {
                    // The fine cell is solid: the fluid one beside it in the patch nearest the point.
                    float fineCell = u.dx / float(r);
                    float3 origin = float3(cell / patchSize * patchSize) * u.dx;
                    float best = INFINITY;
                    for (int n = 0; n < 6; ++n) {
                        int3 q = local;
                        q[n / 2] += (n % 2) * 2 - 1;
                        if (any(q < 0) || any(q >= side)) { continue; }
                        uint there = uint(patch) * uint(side * side * side) + uint(q.x + side * (q.y + side * q.z));
                        if ((fineMask[there] & 1) != 0) { continue; }
                        float3 centre = origin + (float3(q) + 0.5f) * fineCell;
                        float distance = placed ? distance_squared(centre, point) : float(n);
                        if (distance < best) {
                            best = distance;
                            c = fine[there];
                            found = true;
                        }
                    }
                }
            }
            read = read || found;
        }
        if (!read) {
            // The coarse cell is solid and no fine cell stood in: its fluid neighbour nearest the point.
            uint index = gaugeCells[g];
            int3 cell = int3(index % u.nx, (index / u.nx) % u.ny, index / (u.nx * u.ny));
            float best = INFINITY;
            for (int n = 0; n < 6; ++n) {
                int3 q = cell;
                q[n / 2] += (n % 2) * 2 - 1;
                if (any(q < 0) || any(q >= int3(u.nx, u.ny, u.nz))) { continue; }
                uint there = uint(q.x) + u.nx * (uint(q.y) + u.ny * uint(q.z));
                if (mask[there] != 0) { continue; }
                float3 centre = (float3(q) + 0.5f) * u.dx;
                float distance = placed ? distance_squared(centre, point) : float(n);
                if (distance < best) {
                    best = distance;
                    c = state[there];
                }
            }
        }
        float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, u.densityFloor);
        float pressure = gasPressure(max(c.rho, u.densityFloor), c.energy - kinetic, u.airModel, u.gamma);
        if (airGravity) {
            // Under gravity, as if at the ground: its overpressure against the ambient pressure
            // at the gauge's height, as the coarse cell holds it.
            int k = int(gaugeCells[g] / (u.nx * u.ny));
            pressure += u.ambientPressure - gravityAmbientOf(gravityTable, k, u);
        }
        gaugeLog[row + 1 + g] = pressure;
    }
}

// Runs once per step on a single thread: turns the fastest wave speed of the previous
// step into the next dt, advances the batch clock and samples the gauges.
kernel void prepareStep(device StepControl &control [[buffer(0)]],
                        device atomic_uint *maxSpeed [[buffer(1)]],
                        const device Cell *state [[buffer(2)]],
                        device float *gaugeLog [[buffer(3)]],
                        const device uint *gaugeCells [[buffer(4)]],
                        constant SolverUniforms &u [[buffer(5)]],
                        device atomic_uint *tileCount [[buffer(6)]],
                        device uint *tileDispatch [[buffer(7)]],
                        const device int *patchOfTile [[buffer(8)]],
                        const device Cell *fine [[buffer(9)]],
                        const device uint *gaugeChildren [[buffer(10)]],
                        const device uchar *fineMask [[buffer(11)]],
                        const device int *childPatches [[buffer(12)]],
                        const device Cell *childFine [[buffer(13)]],
                        const device uchar *childMask [[buffer(14)]],
                        const device float4 *gravityTable [[buffer(15)]],
                        const device uchar *mask [[buffer(16)]],
                        const device float4 *gaugePoints [[buffer(17)]],
                        uint tid [[thread_position_in_grid]]) {
    if (tid != 0) {
        return;
    }
    uint tiles = 0;
    if (u.tileNx != 0) {
        // One threadgroup per awake tile in the sweeps that follow.
        tiles = atomic_exchange_explicit(tileCount, 0u, memory_order_relaxed);
        tileDispatch[0] = tiles;
        tileDispatch[1] = 1;
        tileDispatch[2] = 1;
        control.activeTiles = tiles;
    }
    float fastest = as_type<float>(atomic_load_explicit(maxSpeed, memory_order_relaxed));
    float dt = u.cfl * u.dx / max(fastest, 1e-6f);
    if (u.maxStep > 0.0f) {
        dt = min(dt, u.maxStep);
    }
    if (u.forcedStep > 0.0f) {
        dt = u.forcedStep;
    }
    // Only a batch's first step is clipped to the time limit, where the time left is exactly
    // what the host worked out. A later step that would come within a ten-thousandth of the
    // batch's time to it stops the batch instead (rounding in the batch's own clock is at most
    // a sixtieth of that), so that the rounding never decides how long a step is, and the steps
    // come out the same however they are batched.
    float unclipped = dt;
    if (control.stopped != 0) {
        dt = 0.0f;
    } else if (control.stepIndex == 0) {
        if (dt >= control.timeLimit) {
            dt = max(control.timeLimit, 0.0f);
            control.stopped = 2;
        }
    } else if (control.batchTime + dt >= 0.9999f * control.timeLimit) {
        dt = 0.0f;
        control.stopped = 1;
    }
    // A step that does nothing leaves the limits for the next step as they are.
    if (dt > 0.0f) {
        control.tileSweeps += tiles;
        control.lastStep = unclipped;
        atomic_store_explicit(maxSpeed, 0u, memory_order_relaxed);
        if (u.forcedStep == 0.0f) {
            control.maxOverpressure = as_type<float>(atomic_exchange_explicit(maxSpeed + 1, 0u, memory_order_relaxed));
        }
    }

    logGauges(gaugeLog, control.stepIndex, dt, state, gaugeCells, u, patchOfTile, fine, gaugeChildren, fineMask,
              childPatches, childFine, childMask, gravityTable, mask, gaugePoints);

    control.dt = dt;
    control.batchTime += dt;
    control.stepIndex += 1;
    control.activeSteps += dt > 0.0f ? 1 : 0;
}

// After a batch's last step: samples the gauges once more, so that the state a batch ends in is
// recorded however the steps were batched (the next batch's first sample repeats it).
kernel void sampleGauges(const device StepControl &control [[buffer(0)]],
                         const device Cell *state [[buffer(2)]],
                         device float *gaugeLog [[buffer(3)]],
                         const device uint *gaugeCells [[buffer(4)]],
                         constant SolverUniforms &u [[buffer(5)]],
                         const device int *patchOfTile [[buffer(8)]],
                         const device Cell *fine [[buffer(9)]],
                         const device uint *gaugeChildren [[buffer(10)]],
                         const device uchar *fineMask [[buffer(11)]],
                         const device int *childPatches [[buffer(12)]],
                         const device Cell *childFine [[buffer(13)]],
                         const device uchar *childMask [[buffer(14)]],
                         const device float4 *gravityTable [[buffer(15)]],
                         const device uchar *mask [[buffer(16)]],
                         const device float4 *gaugePoints [[buffer(17)]],
                         uint tid [[thread_position_in_grid]]) {
    if (tid == 0) {
        logGauges(gaugeLog, control.stepIndex, 0.0f, state, gaugeCells, u, patchOfTile, fine, gaugeChildren, fineMask,
                  childPatches, childFine, childMask, gravityTable, mask, gaugePoints);
    }
}

// Fixed Eulerian coarse-cell probes. Fine state has been conservatively restricted before
// this sample. Positive impulse uses a right-endpoint sum over complete fluid intervals.
kernel void sampleExposurePlane(const device Cell *state [[buffer(0)]],
                               const device uchar *mask [[buffer(1)]],
                               const device StepControl &control [[buffer(2)]],
                               device float4 *exposure [[buffer(3)]],
                               constant SolverUniforms &u [[buffer(4)]],
                               constant float4 &probe [[buffer(5)]],
                               constant float &weight [[buffer(6)]],
                               constant float4 &sampling [[buffer(7)]],
                               uint2 tid [[thread_position_in_grid]]) {
    if (tid.x >= uint(sampling.x) || tid.y >= uint(sampling.y) || (control.dt <= 0 && probe.w == 0)) {
        return;
    }
    uint point = tid.x + uint(sampling.x) * tid.y;
    float2 coordinate = sampling.z == u.dx ? float2(tid)
                                         : clamp((float2(tid) + 0.5f) * sampling.z / u.dx - 0.5f,
                                                 float2(0), float2(u.nx - 1, u.ny - 1));
    uint2 lower = uint2(floor(coordinate));
    float2 fraction = coordinate - float2(lower);
    float4 record = exposure[point];
    bool solid = false;
    float pressure = 0;
    for (uint k = 0; k < 2; ++k) {
        for (uint j = 0; j < 2; ++j) {
            for (uint i = 0; i < 2; ++i) {
                float w = (k == 0 ? 1 - weight : weight)
                          * (j == 0 ? 1 - fraction.y : fraction.y)
                          * (i == 0 ? 1 - fraction.x : fraction.x);
                if (w <= 0) {
                    continue;
                }
                uint x = min(lower.x + i, u.nx - 1);
                uint y = min(lower.y + j, u.ny - 1);
                uint z = uint(probe.x) + k;
                uint cell = x + u.nx * (y + u.ny * z);
                solid = solid || mask[cell] != 0;
                Cell c = state[cell];
                float rho = max(c.rho, u.densityFloor);
                float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / rho;
                pressure += w * gasPressure(rho, c.energy - kinetic, u.airModel, u.gamma);
            }
        }
    }
    if (solid) {
        record.w = 1;
    } else {
        float overpressure = max(pressure - u.ambientPressure, 0.0f);
        record.x = max(record.x, overpressure);
        record.y += overpressure * control.dt;
        if (record.z < 0 && overpressure >= probe.y) {
            record.z = probe.z + control.batchTime;
        }
    }
    exposure[point] = record;
}

// Read-only stationary voxel-face diagnostic; pressure at the adjacent fluid cell centre,
// not a Riemann wall flux. Each face has one writer, so no floating-point atomics are needed.
kernel void sampleEnvelopeExposure(const device Cell *state [[buffer(0)]],
                                  const device uchar *mask [[buffer(1)]],
                                  const device StepControl &control [[buffer(2)]],
                                  const device uint4 *faces [[buffer(3)]],
                                  device float4 *records [[buffer(4)]],
                                  device float *signedImpulse [[buffer(5)]],
                                  constant SolverUniforms &u [[buffer(6)]],
                                  constant uint4 &parameters [[buffer(7)]],
                                  const device uchar *tileFlags [[buffer(8)]],
                                  uint index [[thread_position_in_grid]]) {
    if (index >= parameters.x || (control.dt <= 0 && parameters.y == 0)) return;
    uint4 face = faces[index];
    // A face whose air is in a still tile has held the still air since the start (tiles do not
    // fall asleep again): read that, not the cell; and where it is ambient, nothing changes at all.
    bool still = false;
    if (parameters.z != 0 && u.tileNx > 0) {
        uint i = face.y % u.nx;
        uint j = (face.y / u.nx) % u.ny;
        uint k = face.y / (u.nx * u.ny);
        still = tileFlags[i / 8 + u.tileNx * (j / 8 + u.tileNy * (k / 8))] == tileStill;
    }
    if (!still && (mask[face.x] == 0 || mask[face.y] != 0)) {
        float4 record = records[index];
        record.w = 1;
        records[index] = record;
        return;
    }
    float rho;
    float3 momentum;
    float energy;
    if (still) {
        rho = u.stillRho;
        momentum = float3(u.stillMx, u.stillMy, u.stillMz);
        energy = u.stillEnergy;
    } else {
        Cell c = state[face.y];
        rho = c.rho;
        momentum = float3(c.mx, c.my, c.mz);
        energy = c.energy;
    }
    rho = max(rho, u.densityFloor);
    float kinetic = 0.5f * (momentum.x * momentum.x + momentum.y * momentum.y + momentum.z * momentum.z) / rho;
    float p = gasPressure(rho, energy - kinetic, u.airModel, u.gamma) - u.ambientPressure;
    // Zero, its record stays as it is, as it would adding nothing.
    if (still && as_type<uint>(p) == 0u) return;
    float4 record = records[index];
    record.x = p;
    record.y = max(record.y, max(p, 0.0f));
    record.z += max(p, 0.0f) * control.dt;
    signedImpulse[index] += p * control.dt;
    records[index] = record;
}

// Envelope components (EnvelopeComponentRecorder): after each complete fluid step, each
// component's two sides' area-weighted mean overpressure (its faces all have the cell's area).
// First every face's pressure, a thread a face, into a list laid out a component and a side at a
// time; then a SIMD group of 32 lanes a component, `componentsPerGroup` to a threadgroup, each lane
// summing every 32nd of its side's faces, a fixed tree of shuffles adding the lanes' sums, so the
// result repeats bit for bit. Each step's value, its right endpoint, is integrated into the bins
// it overlaps, [i w, (i + 1) w) from t = 0; the peaks are kept from every step.
struct ComponentRecording {
    uint components;
    uint capacity;
    uint initial;
    uint maxima;
    uint startBin;         // the bin the batch starts in
    float startFraction;   // and how far into it, in seconds
    float binWidth;
    uint faces;
    uint skipStill;        // 1: read a face in a still tile as the still air (no gravity)
};

constant uint componentLanes = 32;
// A face whose solid/fluid pair has changed, compared by its bits (fast math may drop a NaN test).
constant uint brokenFace = 0xFFFFFFFFu;

// The sum of a side's faces' pressures, a lane taking every 32nd; a fixed tree of shuffles adds
// the lanes' sums.
static inline float sideSum(const device float *pressures, uint first, uint count, uint lane, thread uint &broken) {
    float sum = 0.0f;
    for (uint n = lane; n < count; n += componentLanes) {
        float p = pressures[first + n];
        if (as_type<uint>(p) == brokenFace) {
            broken = 1u;
        } else {
            sum += p;
        }
    }
    return sum;
}

// The same sum for a side whose faces all hold the still air, without reading them: the value
// comes from a row of copies, an entry a turn, so that fast math cannot fold the additions.
static inline float stillSum(const device float *still, uint count, uint lane) {
    float sum = 0.0f;
    for (uint n = lane; n < count; n += componentLanes) {
        sum += still[(n / componentLanes) % componentLanes];
    }
    return sum;
}

// A component's step, from its lanes' sums: the sides' means, their peaks and the net's, and the
// bins the step overlaps. Lane 0 writes. The divisions are exact and the bins' sums explicit
// fused multiply-adds, so this rounds the same in each kernel that calls it.
static inline void finishComponent(uint index, float2 sum, uint broken, uint4 side, uint lane,
                                   const device StepControl &control, constant ComponentRecording &r,
                                   device float4 *peaks, device float2 *bins, device float2 *maxima,
                                   device atomic_uint *truncated) {
    for (ushort offset = componentLanes / 2; offset > 0; offset /= 2) {
        sum += simd_shuffle_down(sum, offset);
        broken |= simd_shuffle_down(broken, offset);
    }
    if (lane != 0) return;
    float outer = side.y > 0 ? precise::divide(sum.x, float(side.y)) : 0.0f;
    float inner = side.w > 0 ? precise::divide(sum.y, float(side.w)) : 0.0f;
    float4 peak = peaks[index];
    peak.x = max(peak.x, outer);
    peak.y = max(peak.y, inner);
    peak.z = max(peak.z, outer - inner);
    peak.w = broken != 0 ? 1.0f : peak.w;
    peaks[index] = peak;
    float dt = r.initial != 0 ? 0.0f : control.dt;
    // The step, in seconds from the start of the batch's first bin.
    float end = r.startFraction + (r.initial != 0 ? 0.0f : control.batchTime);
    float begin = end - dt;
    int first = int(floor(begin / r.binWidth));
    int last = r.initial != 0 ? first : int(ceil(end / r.binWidth)) - 1;
    for (int k = max(first, 0); k <= last; ++k) {
        float overlap = min(end, float(k + 1) * r.binWidth) - max(begin, float(k) * r.binWidth);
        if (overlap <= 0.0f && r.initial == 0) continue;
        uint slot = r.startBin + uint(k);
        if (slot >= r.capacity) {
            atomic_store_explicit(truncated, 1u, memory_order_relaxed);
            break;
        }
        ulong at = ulong(index) * ulong(r.capacity) + slot;
        float2 bin = bins[at];
        float share = max(overlap, 0.0f);
        bins[at] = float2(fma(outer, share, bin.x), fma(inner, share, bin.y));
        if (r.maxima != 0) {
            maxima[at] = max(maxima[at], float2(outer, inner));
        }
    }
}

// Each component's step begins here, a SIMD group a component: whether its air has woken, from the
// flags of the tiles its faces lie in. One whose tiles are all still holds the still air on every
// face, and after the first sample, which makes the row of the still air's pressure, it is finished
// here. The others are listed, in an order that varies, for the faces' pass and the sums, both
// dispatched indirectly: a step with nothing awake costs this one dispatch. At the first sample
// every component goes to the sums, after the faces' pass has made the row.
kernel void markEnvelopeComponents(const device StepControl &control [[buffer(2)]],
                                   const device uint2 *tileRanges [[buffer(3)]],
                                   const device uint *tiles [[buffer(4)]],
                                   const device uint4 *sides [[buffer(5)]],
                                   const device uchar *tileFlags [[buffer(7)]],
                                   device uint *awake [[buffer(8)]],
                                   constant SolverUniforms &u [[buffer(9)]],
                                   constant ComponentRecording &r [[buffer(10)]],
                                   device atomic_uint *faceDispatch [[buffer(11)]],
                                   device uint *faceList [[buffer(12)]],
                                   device atomic_uint *sumDispatch [[buffer(13)]],
                                   device uint *sumList [[buffer(14)]],
                                   const device float *stillPressure [[buffer(15)]],
                                   device float4 *peaks [[buffer(16)]],
                                   device float2 *bins [[buffer(17)]],
                                   device float2 *maxima [[buffer(18)]],
                                   device atomic_uint *truncated [[buffer(19)]],
                                   uint group [[threadgroup_position_in_grid]],
                                   uint simd [[simdgroup_index_in_threadgroup]],
                                   uint groups [[simdgroups_per_threadgroup]],
                                   uint lane [[thread_index_in_simdgroup]]) {
    uint index = group * groups + simd;
    if (index >= r.components || (control.dt <= 0 && r.initial == 0)) return;
    bool woken = r.skipStill == 0 || u.tileNx == 0;
    uint2 range = tileRanges[index];
    for (uint n = lane; !woken && n < range.y; n += componentLanes) {
        woken = tileFlags[tiles[range.x + n]] != tileStill;
    }
    woken = simd_any(woken);
    if (lane == 0) {
        awake[index] = woken ? 1u : 0u;
        // At the first sample the faces' pass's first threadgroup makes the still air's row.
        if (woken) {
            faceList[atomic_fetch_add_explicit(faceDispatch, 1u, memory_order_relaxed) - r.initial] = index;
        }
        if (woken || r.initial != 0) {
            sumList[atomic_fetch_add_explicit(sumDispatch, 1u, memory_order_relaxed)] = index;
        }
    }
    if (woken || r.initial != 0) return;
    uint4 side = sides[index];
    float2 sum = float2(stillSum(stillPressure, side.y, lane), stillSum(stillPressure, side.w, lane));
    finishComponent(index, sum, 0u, side, lane, control, r, peaks, bins, maxima, truncated);
}

// Every face's pressure: a threadgroup an awake component, its threads taking every
// `componentFaceThreads`th face; at the first sample, a threadgroup first that takes the still air,
// through the same instructions, as a row of 32 copies for components asleep.
constant uint componentFaceThreads = 256;

kernel void sampleEnvelopeComponentFaces(const device Cell *state [[buffer(0)]],
                                         const device uchar *mask [[buffer(1)]],
                                         const device StepControl &control [[buffer(2)]],
                                         const device uint2 *faces [[buffer(3)]],
                                         device float *pressures [[buffer(4)]],
                                         constant SolverUniforms &u [[buffer(5)]],
                                         constant ComponentRecording &r [[buffer(6)]],
                                         const device uchar *tileFlags [[buffer(7)]],
                                         const device uint4 *sides [[buffer(8)]],
                                         const device uint *faceList [[buffer(9)]],
                                         device float *stillPressure [[buffer(10)]],
                                         uint group [[threadgroup_position_in_grid]],
                                         uint local [[thread_index_in_threadgroup]]) {
    if (control.dt <= 0 && r.initial == 0) return;
    bool row = r.initial != 0 && group == 0;
    uint first = 0;
    uint count = componentLanes;
    if (!row) {
        uint4 side = sides[faceList[group - r.initial]];
        first = side.x;
        count = side.y + side.w;
    }
    for (uint n = local; n < count; n += componentFaceThreads) {
        bool still = row;
        uint2 face = still ? uint2(0) : faces[first + n];
        if (!still) {
            if (mask[face.x] != 0 || (face.y != 0xFFFFFFFFu && mask[face.y] == 0)) {
                pressures[first + n] = as_type<float>(brokenFace);
                continue;
            }
            // A cell in a still tile holds the still air: read that, not the cell.
            uint i = face.x % u.nx;
            uint j = (face.x / u.nx) % u.ny;
            uint k = face.x / (u.nx * u.ny);
            still = r.skipStill != 0 && u.tileNx > 0
                    && tileFlags[i / 8 + u.tileNx * (j / 8 + u.tileNy * (k / 8))] == tileStill;
        }
        float rho;
        float3 momentum;
        float energy;
        if (still) {
            rho = u.stillRho;
            momentum = float3(u.stillMx, u.stillMy, u.stillMz);
            energy = u.stillEnergy;
        } else {
            Cell c = state[face.x];
            rho = c.rho;
            momentum = float3(c.mx, c.my, c.mz);
            energy = c.energy;
        }
        rho = max(rho, u.densityFloor);
        float kinetic = 0.5f * (momentum.x * momentum.x + momentum.y * momentum.y + momentum.z * momentum.z) / rho;
        float p = gasPressure(rho, energy - kinetic, u.airModel, u.gamma) - u.ambientPressure;
        if (row) {
            stillPressure[n] = p;
        } else {
            pressures[first + n] = p;
        }
    }
}

// The sums of the components listed, a threadgroup of one SIMD group each: awake ones from their
// faces, and at the first sample the others from the still air's row. Its first thread clears both
// counts for the next step (they were read as the passes were dispatched).
kernel void sampleEnvelopeComponents(const device float *pressures [[buffer(0)]],
                                     const device uint *awake [[buffer(1)]],
                                     const device StepControl &control [[buffer(2)]],
                                     const device uint4 *sides [[buffer(3)]],
                                     const device uint *sumList [[buffer(4)]],
                                     device float4 *peaks [[buffer(5)]],
                                     device float2 *bins [[buffer(6)]],
                                     device float2 *maxima [[buffer(7)]],
                                     device atomic_uint *truncated [[buffer(8)]],
                                     constant ComponentRecording &r [[buffer(10)]],
                                     const device float *stillPressure [[buffer(11)]],
                                     device uint *faceDispatch [[buffer(12)]],
                                     device uint *sumDispatch [[buffer(13)]],
                                     uint group [[threadgroup_position_in_grid]],
                                     uint lane [[thread_index_in_simdgroup]]) {
    if (group == 0 && lane == 0) {
        faceDispatch[0] = 0u;
        sumDispatch[0] = 0u;
    }
    if (control.dt <= 0 && r.initial == 0) return;
    uint index = sumList[group];
    uint4 side = sides[index];
    uint broken = 0u;
    float2 sum;
    if (awake[index] != 0) {
        sum = float2(sideSum(pressures, side.x, side.y, lane, broken),
                     sideSum(pressures, side.z, side.w, lane, broken));
    } else {
        sum = float2(stillSum(stillPressure, side.y, lane), stillSum(stillPressure, side.w, lane));
    }
    finishComponent(index, sum, broken, side, lane, control, r, peaks, bins, maxima, truncated);
}

// Seeds the wave-speed maximum from the initial condition.
kernel void measureWaveSpeed(const device Cell *state [[buffer(0)]],
                             const device uchar *mask [[buffer(1)]],
                             device atomic_uint *maxSpeed [[buffer(2)]],
                             constant SolverUniforms &u [[buffer(3)]],
                             uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    int index = int(tid.x + u.nx * (tid.y + u.ny * tid.z));
    if (mask[index] != 0) {
        return;
    }
    Cell c = state[index];
    float rho = max(c.rho, u.densityFloor);
    float3 velocity = float3(c.mx, c.my, c.mz) / rho;
    float pressure = max(gasPressure(rho, c.energy - 0.5f * rho * dot(velocity, velocity), u.airModel, u.gamma),
                         u.pressureFloor);
    float3 speed = fabs(velocity);
    recordWaveSpeed(maxSpeed, max(speed.x, max(speed.y, speed.z))
                                  + sqrt(gasGamma(rho, pressure, u.airModel, u.gamma) * pressure / rho));
    recordWaveSpeed(maxSpeed + 1, fabs(pressure - u.ambientPressure));
}

static inline float cellPressure(const device Cell *state, int index, constant SolverUniforms &u) {
    Cell c = state[index];
    float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, u.densityFloor);
    return gasPressure(max(c.rho, u.densityFloor), c.energy - kinetic, u.airModel, u.gamma);
}

// Packs the fields the renderer needs into a filterable 3D texture:
//   r = overpressure / ambient, g = peak overpressure / ambient, b = impulse (Pa s),
//   a = pressure jump across one cell / ambient (a shock indicator for the volume view).
// Solid cells carry the largest value among their fluid face neighbours so that
// building surfaces can be shaded by sampling just inside the wall.
kernel void updateVisualization(const device Cell *state [[buffer(0)]],
                                const device uchar *mask [[buffer(1)]],
                                const device float *peak [[buffer(2)]],
                                const device float *impulse [[buffer(3)]],
                                constant SolverUniforms &u [[buffer(4)]],
                                texture3d<float, access::write> visualization [[texture(0)]],
                                uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    int3 dims = int3(u.nx, u.ny, u.nz);
    int3 position = int3(tid);
    int index = position.x + dims.x * (position.y + dims.y * position.z);
    float inverseAmbient = 1.0f / u.ambientPressure;
    bool solid = mask[index] != 0;
    float pressure = solid ? u.ambientPressure : cellPressure(state, index, u);

    const int3 offsets[6] = {
        int3(-1, 0, 0), int3(1, 0, 0), int3(0, -1, 0), int3(0, 1, 0), int3(0, 0, -1), int3(0, 0, 1),
    };
    float neighbours[6];
    float3 best = float3(0.0f);
    for (int n = 0; n < 6; ++n) {
        int3 q = position + offsets[n];
        neighbours[n] = pressure;
        if (any(q < 0) || any(q >= dims)) {
            continue;
        }
        int neighbour = q.x + dims.x * (q.y + dims.y * q.z);
        if (mask[neighbour] != 0) {
            continue;
        }
        neighbours[n] = cellPressure(state, neighbour, u);
        if (solid) {
            best = max(best, float3((neighbours[n] - u.ambientPressure) * inverseAmbient,
                                    peak[neighbour] * inverseAmbient, impulse[neighbour]));
        }
    }

    if (solid) {
        visualization.write(float4(clamp(best, 0.0f, 6.0e4f), 0.0f), tid);
        return;
    }
    float3 gradient = 0.5f * float3(neighbours[1] - neighbours[0], neighbours[3] - neighbours[2],
                                    neighbours[5] - neighbours[4]);
    float4 value = float4((pressure - u.ambientPressure) * inverseAmbient, peak[index] * inverseAmbient,
                          impulse[index], length(gradient) * inverseAmbient);
    visualization.write(clamp(value, -6.0e4f, 6.0e4f), tid);
}
