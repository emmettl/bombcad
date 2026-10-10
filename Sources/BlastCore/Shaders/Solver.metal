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
    uint experimentalBox;
    float boxCentreX;
    float boxCentreY;
    float boxCentreZ;
    float boxMinX; float boxMinY; float boxMinZ;
    float boxMaxX; float boxMaxY; float boxMaxZ;
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
    // 1 when the species carry a deflagration's unburnt mixture (x) instead of afterburning's fuel
    // and oxygen: they are carried as afterburning's are, and burnt by Deflagration.metal.
    uint deflagration;
};

// Whether the air carries species, for afterburning or a deflagration.
static inline bool carriesSpecies(constant SolverUniforms &u) {
    return u.afterburnEnergy > 0.0f || u.deflagration != 0u;
}

// Definition vectors: quaternion, half-size, local centre-of-mass offset, velocity, spin.
static inline bool experimentalBoxContains(float3 point, float dx, constant SolverUniforms &u,
                                           const device float4 *definition) {
    float4 q = definition[0]; q.xyz = -q.xyz;
    float3 v = point-float3(u.boxCentreX,u.boxCentreY,u.boxCentreZ);
    float3 local = v+2.0f*cross(q.xyz,cross(q.xyz,v)+q.w*v)+definition[2].xyz;
    return all(abs(local) <= definition[1].xyz + dx*1e-5f);
}
static inline float3 experimentalBoxVelocity(float3 point, constant SolverUniforms &u,
                                             const device float4 *definition) {
    return definition[3].xyz+cross(definition[4].xyz,point-float3(u.boxCentreX,u.boxCentreY,u.boxCentreZ));
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

// Temperature of thermally perfect air of internal energy `e` per kilogram: Newton's method
// from the temperature without vibration, which lies above the root; two steps reach single
// precision everywhere from room temperature to 20,000 K.
static inline float airTemperature(float e) {
    float t = max(e, 0.0f) / (2.5f * airGasConstant);
    for (int n = 0; n < 2; ++n) {
        float2 v = vibration(t);
        t -= (2.5f * airGasConstant * t + v.x - e) / (2.5f * airGasConstant + v.y);
    }
    return max(t, 0.0f);
}

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
    float t = airTemperature(e);
    if (model == airDissociating) {
        t = dissociatingTemperature(rho, e, t);
        DissociatingAir air = dissociatingAir(rho, t);
        return float2(rho * air.gasConstant * t, 1.0f + air.gasConstant / air.frozenHeat);
    }
    return float2(rho * airGasConstant * t, 1.0f + airGasConstant / (2.5f * airGasConstant + vibration(t).y));
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

static inline Prim loadPrim(const device Cell *state, int index, constant SolverUniforms &u) {
    Cell c = state[index];
    Prim w;
    w.rho = max(c.rho, u.densityFloor);
    float3 velocity = float3(c.mx, c.my, c.mz) / w.rho;
    w.v = toSweep(velocity, u.axis);
    float2 gas = gasState(w.rho, c.energy - 0.5f * w.rho * dot(velocity, velocity), u.airModel, u.gamma);
    w.p = max(gas.x, u.pressureFloor);
    w.g = gas.y;
    return w;
}

// Reflection in a wall moving at `wallSpeed` along the sweep axis.
static inline Prim mirrored(Prim w, float wallSpeed) {
    w.v.x = 2.0f * wallSpeed - w.v.x;
    return w;
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
                              constant SolverUniforms &u) {
    float3 speed = fabs(momentum) / rho;
    float fastest = max(speed.x, max(speed.y, speed.z))
        + sqrt(gasGamma(rho, pressure, u.airModel, u.gamma) * pressure / rho);
    recordWaveSpeed(maxSpeed, fastest);
    // The second slot tracks how disturbed the air still is.
    recordWaveSpeed(maxSpeed + 1, fabs(pressure - u.ambientPressure));
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
                             device float *coarseSpeciesFlux, const device uchar *boxMask, device float *boxImpulse) {
    int index = cell.x + int(u.nx) * (cell.y + int(u.ny) * cell.z);
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

    Prim wP1 = w0;
    if (kindP1 == kindFluid) {
        wP1 = loadPrim(src, index + stride, u);
    } else if (kindP1 == kindWall) {
        wP1 = mirrored(w0, speedP1);
    }
    Prim wM1 = w0;
    if (kindM1 == kindFluid) {
        wM1 = loadPrim(src, index - stride, u);
    } else if (kindM1 == kindWall) {
        wM1 = mirrored(w0, speedM1);
    }

    Prim wP2 = wP1;
    if (kindP1 == kindWall) {
        wP2 = mirrored(wM1, speedP1);
    } else if (kindP1 == kindFluid) {
        int kind = classify(mask, index, 2, stride, i, n, lowWall, highWall);
        if (kind == kindFluid) {
            wP2 = loadPrim(src, index + 2 * stride, u);
        } else if (kind == kindWall) {
            wP2 = mirrored(wP1, wallSpeed(wallVelocity, cell, 2, u));
        }
    }
    Prim wM2 = wM1;
    if (kindM1 == kindWall) {
        wM2 = mirrored(wP1, speedM1);
    } else if (kindM1 == kindFluid) {
        int kind = classify(mask, index, -2, stride, i, n, lowWall, highWall);
        if (kind == kindFluid) {
            wM2 = loadPrim(src, index - 2 * stride, u);
        } else if (kind == kindWall) {
            wM2 = mirrored(wM1, wallSpeed(wallVelocity, cell, -2, u));
        }
    }

    float dt = control.dt;
    float lambda = dt / u.dx;
    Flux fluxLow;
    Flux fluxHigh;
    stencilFluxes(wM2, wM1, w0, wP1, wP2, lambda, u, fluxLow, fluxHigh);

    // Experimental rigid-box path: impermeable moving-wall traction, recorded from the
    // same numerical face flux used by the gas. Each fluid thread owns six output scalars.
    // Use gauge pressure for body loading; uniform atmospheric preload is balanced externally.
    if (u.experimentalBox != 0 && (u.refineRatio == 0 || patchAt(cell, patchOfTile, u) < 0)) {
        float3 received = float3(0.0f);
        float3 moment = float3(0.0f);
        float3 centre = float3(u.boxCentreX, u.boxCentreY, u.boxCentreZ);
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
            float3 impulse = float3(0.0f);
            impulse[axis] = float(direction) * (traction - u.ambientPressure) * dt * u.dx * u.dx;
            float3 face = (float3(cell) + 0.5f) * u.dx;
            face[axis] += 0.5f * float(direction) * u.dx;
            received += impulse;
            moment += cross(face - centre, impulse);
        }
        for (uint a = 0; a < 3; ++a) {
            boxImpulse[6 * index + a] += received[a];
            boxImpulse[6 * index + 3 + a] += moment[a];
        }
    }

    // A cell of unrefined air beside a patch records the flux it used through the face they
    // share, so that the patch's own fluxes can replace it (see Refine.metal).
    int speciesRegister = -1;  // where its fuel and oxygen flux goes, if it records one
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
                storeFlux(coarseFlux, slot, lowEdge ? fluxLow : fluxHigh, axis, dt);
                speciesRegister = int(speciesSlot(uint(patch), face, uint(inPatch[(axis + 1) % 3]),
                                                  uint(inPatch[(axis + 2) % 3]), uint(patchSize)));
                registerLow = lowEdge;
            }
        }
    }

    Cell c = src[index];
    float3 momentum = toSweep(float3(c.mx, c.my, c.mz), axis);
    float rho = c.rho - lambda * (fluxHigh.mass - fluxLow.mass);
    momentum -= lambda * (fluxHigh.momentum - fluxLow.momentum);
    float energy = c.energy - lambda * (fluxHigh.energy - fluxLow.energy);

    // Detonation products that have not yet burnt ("fuel") and oxygen, as densities, carried
    // by the same mass fluxes, each at the mass fraction of the cell it leaves (first-order
    // upwind, so they stay positive). Where they meet in a cell, the fuel burns at once, as far
    // as the oxygen allows, after the final sweep of the step: afterburning limited by mixing,
    // which here is the grid's own.
    float2 species = float2(0.0f);
    if (carriesSpecies(u)) {
        float2 own = speciesSrc[index];
        float2 fraction = own / max(c.rho, u.densityFloor);
        float2 below = kindM1 == kindFluid ? speciesSrc[index - stride] / wM1.rho : fraction;
        float2 above = kindP1 == kindFluid ? speciesSrc[index + stride] / wP1.rho : fraction;
        float2 inflow = speciesFlux(fluxLow.mass, below, fraction);
        float2 outflow = speciesFlux(fluxHigh.mass, fraction, above);
        if (u.deflagration != 0u) {
            // A deflagration's mixture is carried at limited linear (MUSCL) mass fractions at the
            // faces instead: at the upwind cell's, the grid's diffusion would spread its flame
            // over many cells (see Deflagration.metal). Both cells beside a face work out the
            // same value, so the species stay conserved.
            float2 below2 = below;
            if (kindM1 == kindFluid && classify(mask, index, -2, stride, i, n, lowWall, highWall) == kindFluid) {
                below2 = speciesSrc[index - 2 * stride] / wM2.rho;
            }
            float2 above2 = above;
            if (kindP1 == kindFluid && classify(mask, index, 2, stride, i, n, lowWall, highWall) == kindFluid) {
                above2 = speciesSrc[index + 2 * stride] / wP2.rho;
            }
            float2 lowFace = fluxLow.mass > 0.0f ? below + 0.5f * minmodPair(below - below2, fraction - below)
                                                 : fraction - 0.5f * minmodPair(fraction - below, above - fraction);
            float2 highFace = fluxHigh.mass > 0.0f ? fraction + 0.5f * minmodPair(fraction - below, above - fraction)
                                                   : above - 0.5f * minmodPair(above - fraction, above2 - above);
            inflow = fluxLow.mass * lowFace;
            outflow = fluxHigh.mass * highFace;
        }
        species = max(own - lambda * (outflow - inflow), 0.0f);
        if (speciesRegister >= 0) {
            float2 through = (registerLow ? inflow : outflow) * dt;
            coarseSpeciesFlux[speciesRegister] = through.x;
            coarseSpeciesFlux[speciesRegister + 1] = through.y;
        }
        if (u.finalSweep != 0 && u.afterburnEnergy > 0.0f) {
            float fuel = burnt(species, control.dt, u);
            species.x -= fuel;
            species.y -= fuel * u.oxygenPerFuel;
            energy += fuel * u.afterburnEnergy;
        }
        speciesDst[index] = species;
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
        float overpressure = pressure - u.ambientPressure;
        peak[index] = max(peak[index], overpressure);
        // Under a patch, impulse is taken from the fine cells instead (see Refine.metal).
        if (u.refineRatio == 0 || patchAt(cell, patchOfTile, u) < 0) {
            impulse[index] += max(overpressure, 0.0f) * dt;
        }
        recordCell(maxSpeed, momentum, rho, pressure, u);
        // A changed cell near the edge of its tile wakes the tiles it can reach next step.
        if (u.tileNx != 0 && !isStill(result, species, u)) {
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
                  uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    sweepCell(int3(tid), src, dst, mask, peak, impulse, control, maxSpeed, u, wallVelocity, tileFlags,
              speciesSrc, speciesDst, patchOfTile, coarseFlux, coarseSpeciesFlux, boxMask, boxImpulse);
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
                      speciesSrc, speciesDst, patchOfTile, coarseFlux, coarseSpeciesFlux, boxMask, boxImpulse);
        }
    }
}

// After a restart: wakes the tiles within reach of every fluid cell that is not still.
kernel void wakeTiles(const device Cell *state [[buffer(0)]],
                      const device uchar *mask [[buffer(1)]],
                      device uchar *tileFlags [[buffer(2)]],
                      constant SolverUniforms &u [[buffer(3)]],
                      const device float2 *species [[buffer(4)]],
                      uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    int index = int(tid.x + u.nx * (tid.y + u.ny * tid.z));
    if (mask[index] == 0 && !isStill(state[index], species[index], u)) {
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
                         uint tid [[thread_position_in_grid]]) {
    if (tid >= u.tileNx * u.tileNy * u.tileNz) {
        return;
    }
    uchar flag = tileFlags[tid];
    if (flag != tileActive) {
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
                             const device uchar *childMask) {
    row *= u.gaugeCount + 1;
    gaugeLog[row] = dt;
    for (uint g = 0; g < u.gaugeCount; ++g) {
        Cell c = state[gaugeCells[g]];
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
                }
            }
        }
        float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, u.densityFloor);
        gaugeLog[row + 1 + g] = gasPressure(max(c.rho, u.densityFloor), c.energy - kinetic, u.airModel, u.gamma);
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
              childPatches, childFine, childMask);

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
                         uint tid [[thread_position_in_grid]]) {
    if (tid == 0) {
        logGauges(gaugeLog, control.stepIndex, 0.0f, state, gaugeCells, u, patchOfTile, fine, gaugeChildren, fineMask,
                  childPatches, childFine, childMask);
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
                                  constant uint2 &parameters [[buffer(7)]],
                                  uint index [[thread_position_in_grid]]) {
    if (index >= parameters.x || (control.dt <= 0 && parameters.y == 0)) return;
    uint4 face = faces[index];
    float4 record = records[index];
    if (mask[face.x] == 0 || mask[face.y] != 0) {
        record.w = 1;
    } else {
        Cell c = state[face.y];
        float rho = max(c.rho, u.densityFloor);
        float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / rho;
        float p = gasPressure(rho, c.energy - kinetic, u.airModel, u.gamma) - u.ambientPressure;
        record.x = p;
        record.y = max(record.y, max(p, 0.0f));
        record.z += max(p, 0.0f) * control.dt;
        signedImpulse[index] += p * control.dt;
    }
    records[index] = record;
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
