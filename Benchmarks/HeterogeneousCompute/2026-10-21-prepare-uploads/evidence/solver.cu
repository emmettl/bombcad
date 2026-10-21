#define float2 bc_float2
#define float3 bc_float3
#define float4 bc_float4
#define int2 bc_int2
#define int3 bc_int3
#define int4 bc_int4
#define uint2 bc_uint2
#define uint3 bc_uint3
#define uint4 bc_uint4
// Minimal Metal value semantics for the generated CUDA air sweep.
// Vector alignment is internal: the wire types are scalar-only Cell and uniforms.
typedef unsigned int uint;
typedef unsigned char uchar;
typedef unsigned long long ulong;
typedef uint atomic_uint;
constexpr int memory_order_relaxed = 0;
#define D __device__ __forceinline__
template<class T, int N> struct V {
    T x, y, z, w;
    D V() : x(0), y(0), z(0), w(0) {}
    D V(T a) : x(a), y(a), z(a), w(a) {}
    D V(T a,T b) : x(a), y(b), z(0), w(0) {}
    D V(T a,T b,T c) : x(a), y(b), z(c), w(0) {}
    D V(T a,T b,T c,T d) : x(a), y(b), z(c), w(d) {}
    template<class U> D V(V<U,N> a) : x(T(a.x)),y(T(a.y)),z(T(a.z)),w(T(a.w)) {}
    D V(V<T,2> a,T b):x(a.x),y(a.y),z(b),w(0){}
    D V(V<T,2> a,V<T,2> b):x(a.x),y(a.y),z(b.x),w(b.y){}
    D V(V<T,3> a,T b):x(a.x),y(a.y),z(a.z),w(b){}
    D V(T a,V<T,3> b):x(a),y(b.x),z(b.y),w(b.z){}
    D V(V<T,2> a,T b,T c):x(a.x),y(a.y),z(b),w(c){}
    D T& operator[](int i) { return (&x)[i]; }
    D T operator[](int i) const { return (&x)[i]; }
    D V<T,2> xy() const {return {x,y};}
    D V<T,2> zw() const {return {z,w};}
    D V<T,3> xyz() const {return {x,y,z};}
    D V<T,3> yzw() const {return {y,z,w};}
    D V<T,3> yzx() const {return {y,z,x};}
    D V<T,3> zxy() const {return {z,x,y};}
};
// Metal float2 arrays have an 8-byte stride, unlike padded float3 values.
template<class T> struct V<T,2> {
    T x,y;
    D V():x(0),y(0){}
    D V(T a):x(a),y(a){}
    D V(T a,T b):x(a),y(b){}
    template<class U> D V(V<U,2>a):x(T(a.x)),y(T(a.y)){}
    D T& operator[](int i){return (&x)[i];}
    D T operator[](int i)const{return (&x)[i];}
    D V<T,2> xy()const{return *this;}
};
static_assert(sizeof(V<float,2>) == 8, "species ABI");
using float2=V<float,2>; using float3=V<float,3>; using float4=V<float,4>;
using int2=V<int,2>; using int3=V<int,3>; using int4=V<int,4>;
using uint2=V<uint,2>; using uint3=V<uint,3>; using uint4=V<uint,4>;
#define BINARY(OP) \
template<class T,int N> D V<T,N> operator OP(V<T,N>a,V<T,N>b){V<T,N>r;for(int i=0;i<N;i++)r[i]=a[i] OP b[i];return r;} \
template<class T,int N,class U> D V<T,N> operator OP(V<T,N>a,U b){return a OP V<T,N>(T(b));} \
template<class T,int N,class U> D V<T,N> operator OP(U a,V<T,N>b){return V<T,N>(T(a)) OP b;}
BINARY(+) BINARY(-) BINARY(*) BINARY(/) BINARY(%)
#define COMP(OP) \
template<class T,int N> D V<int,N> operator OP(V<T,N>a,V<T,N>b){V<int,N>r;for(int i=0;i<N;i++)r[i]=a[i] OP b[i];return r;} \
template<class T,int N,class U> D V<int,N> operator OP(V<T,N>a,U b){return a OP V<T,N>(T(b));}
COMP(<) COMP(>) COMP(<=) COMP(>=) COMP(==) COMP(!=)
template<class T,int N> D V<T,N> operator-(V<T,N>a){for(int i=0;i<N;i++)a[i]=-a[i];return a;}
template<class T,int N> D V<T,N>& operator+=(V<T,N>&a,V<T,N>b){a=a+b;return a;}
template<class T,int N> D V<T,N>& operator-=(V<T,N>&a,V<T,N>b){a=a-b;return a;}
template<class T,int N> D V<T,N>& operator*=(V<T,N>&a,T b){a=a*b;return a;}
template<class T,int N> D V<T,N>& operator/=(V<T,N>&a,T b){a=a/b;return a;}
template<class T,int N> D bool all(V<T,N>a){for(int i=0;i<N;i++)if(!a[i])return false;return true;}
template<class T,int N> D bool any(V<T,N>a){for(int i=0;i<N;i++)if(a[i])return true;return false;}
template<class T> D T min(T a,T b){return a<b?a:b;}
template<class T> D T max(T a,T b){return a>b?a:b;}
template<class T> D T clamp(T a,T b,T c){return min(max(a,b),c);}
template<class T,int N> D V<T,N> fabs(V<T,N>a){for(int i=0;i<N;i++)a[i]=fabsf(a[i]);return a;}
template<class T,int N> D V<T,N> abs(V<T,N>a){for(int i=0;i<N;i++)a[i]=a[i]<0?-a[i]:a[i];return a;}
template<class T,int N> D V<T,N> select(V<T,N>a,V<T,N>b,V<int,N>c){for(int i=0;i<N;i++)if(c[i])a[i]=b[i];return a;}
D float dot(float3 a,float3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
D float3 cross(float3 a,float3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
D float powr(float a,float b){return powf(a,b);}
D uint floatBits(float a){return __float_as_uint(a);}
D uint atomic_load_explicit(uint*p,int){return atomicAdd(p,0u);}
D uint atomic_fetch_max_explicit(uint*p,uint a,int){return atomicMax(p,a);}
D void atomic_store_explicit(uint*p,uint a,int){atomicExch(p,a);}

template<class T,int N> D V<T,N> min(V<T,N>a,V<T,N>b){for(int i=0;i<N;i++)a[i]=min(a[i],b[i]);return a;}
template<class T,int N> D V<T,N> max(V<T,N>a,V<T,N>b){for(int i=0;i<N;i++)a[i]=max(a[i],b[i]);return a;}
template<class T,int N> D V<T,N> max(V<T,N>a,T b){return max(a,V<T,N>(b));}
template<class T,int N> D V<T,N> min(V<T,N>a,T b){return min(a,V<T,N>(b));}
template<int N> D V<float,N> floor(V<float,N>a){for(int i=0;i<N;i++)a[i]=floorf(a[i]);return a;}

D float bitsFloat(uint a){return __uint_as_float(a);}
D uint atomic_exchange_explicit(uint*p,uint a,int){return atomicExch(p,a);}
#ifndef NAN
#define NAN __uint_as_float(0x7fc00000u)
#endif
#ifndef M_PI_F
#define M_PI_F 3.14159265358979323846f
#endif

#ifndef BOMBCAD_CUDA_CUT_CELLS
#define BOMBCAD_CUDA_CUT_CELLS 0
#endif

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
static __device__ __forceinline__ bool carriesSpecies(const SolverUniforms &u) {
    return u.afterburnEnergy > 0.0f || u.deflagration != 0u;
}

// Each experimental box has `boxVectors` definition vectors: quaternion, half-size, local
// centre-of-mass offset, velocity, spin, centre, and its bounds' low and high corners.
const uint boxVectors = 8;
static __device__ __forceinline__ bool experimentalBoxContains(float3 point, float dx, const float4 *definition) {
    float4 q = definition[0]; q.x = -q.x; q.y = -q.y; q.z = -q.z;
    float3 v = point-definition[5].xyz();
    float3 local = v+2.0f*cross(q.xyz(),cross(q.xyz(),v)+q.w*v)+definition[2].xyz();
    return all(abs(local) <= definition[1].xyz() + dx*1e-5f);
}
static __device__ __forceinline__ float3 experimentalBoxVelocity(float3 point, const float4 *definition) {
    return definition[3].xyz()+cross(definition[4].xyz(),point-definition[5].xyz());
}
// The first of the boxes that holds the point, or -1. Its bounds pass over boxes far from it.
static __device__ __forceinline__ int experimentalBoxOwner(float3 point, float dx, const SolverUniforms &u,
                                       const float4 *definitions) {
    for (uint b = 0; b < u.experimentalBox; ++b) {
        const float4 *definition = definitions + boxVectors * b;
        if (any(point < definition[6].xyz() - dx) || any(point > definition[7].xyz() + dx)) continue;
        if (experimentalBoxContains(point, dx, definition)) return int(b);
    }
    return -1;
}

const int tileSize = 8;
// The air is refined in patches of this many cells along each edge (see Refine.metal).
const int patchSize = 4;
// How far a change spreads in one step, along each axis.
const int tileReach = 2;
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

// The run's clock in ticks of 2^-40 s: each step's dt, a float, converts exactly, so that the time
// at a step is the same however the run's steps are cut into batches (a batch's float sum of its
// steps from its start rounded with each cut). The host carries it from batch to batch.
static __device__ __forceinline__ ulong runClock(const StepControl &control) {
    return ulong(control.clockLow) | (ulong(control.clockHigh) << 32);
}

static __device__ __forceinline__ float runClockSeconds(const StepControl &control) {
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
constexpr uint airModelConstant = 0;
static __device__ __forceinline__ uint airModelOf(uint model) {
    return false ? airModelConstant : model;
}
const float airGasConstant = 287.05f;
// Gravity in the air, when a kernel is compiled for it (see `stencilFluxesGravity`): without it,
// its code is left out of the kernels, which then run exactly as they did before it.
constexpr bool airGravityConstant = 0;
const bool airGravity = false && airGravityConstant;
// Sub-grid mixing, when a kernel is compiled for it (see `mixingFace`), likewise.
constexpr bool airMixingConstant = 0;
const bool airMixing = false && airMixingConstant;
// Afterburning's extinction limit, when a kernel is compiled for it (see `afterburntHere`).
constexpr bool burnLimitConstant = 0;
const bool burnLimit = false && burnLimitConstant;
// Mixing-limited afterburning, when a kernel is compiled for it (see `afterburnRateHere`); it reads
// sub-grid mixing's eddy viscosity, so it takes effect only with that compiled in too.
constexpr bool burnMixingConstant = 0;
const bool burnMixing = false && burnMixingConstant && airMixing;

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
constexpr bool cutCellsConstant = 0;
const bool cutCells = BOMBCAD_CUDA_CUT_CELLS;
// Structures' outlines as cut cells (StructureCutCells.swift): per cell its record or -1, each
// record's air share and low faces' apertures, its wall, and its differences, as the terrain's.
constexpr bool structureCutConstant = 0;
const bool structureCut = false && structureCutConstant;

// Congestion below the grid (`CongestionArray`, docs/congestion-model.md): cells holding obstacles
// too small to resolve are porous. Each keeps the share β_v of its volume open to the air, and a
// face the smaller of its two cells' shares (so that the update never outruns the step's Courant
// number); the update is each face's flux times its open share over the open volume, with the
// pressure on the obstacles' faces, p (β_high - β_low), so that still air stays still. Their drag
// is applied after the step (`congestionDrag`). Without congestion its code is left out.
constexpr bool porousAirConstant = 0;
const bool porousAir = false && porousAirConstant;

// A column's cut cells: where its records start, its first cell of air (cells below are solid),
// its first whole cell (cells from it up are whole), and its first cell at least half full (the
// one its smaller cells give the rest of their difference to). Columns run to nx and ny
// inclusive, so that the domain's high faces have apertures.
static __device__ __forceinline__ uint4 cutColumnOf(int3 cell, const uint4 *columns, const SolverUniforms &u) {
    return columns[uint(cell.x) + (u.nx + 1u) * uint(cell.y)];
}

// A cell's fluid share and the apertures of its low faces (x, y, z): zero below its column's cut
// cells, one above them.
static __device__ __forceinline__ float4 cutRecordOf(int3 cell, const uint4 *columns, const float4 *records,
                                 const SolverUniforms &u) {
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
const float dissociatingShare[2] = {0.767f, 0.233f};
const float dissociatingGasConstant[2] = {296.8f, 259.8f};
const float dissociationTemperature[2] = {113000.0f, 59500.0f};
const float dissociationDensity[2] = {1.3e5f, 1.5e5f};
const float dissociatingVibration[2] = {3390.0f, 2270.0f};

// Dissociating air at a density and temperature: internal energy per kilogram and its
// derivative in temperature with the composition in equilibrium; the mixture's gas const as
// it stands, p / (rho T), and its derivative; and the heat capacity at fixed composition.
struct DissociatingAir {
    float energy;
    float energySlope;
    float gasConstant;
    float gasConstantSlope;
    float frozenHeat;
};

static __device__ __forceinline__ DissociatingAir dissociatingAir(float rho, float t) {
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
static __device__ __forceinline__ float dissociatingTemperature(float rho, float e, float start) {
    float t = max(start, 1e-12f);
    for (int n = 0; n < 6; ++n) {
        DissociatingAir air = dissociatingAir(rho, t);
        t = max(t - (air.energy - e) / max(air.energySlope, 1e-12f), 0.5f * t);
    }
    return t;
}

// Temperature of dissociating air of density `rho` at pressure `p`, from above likewise: the
// temperature at which undissociated air would have that pressure.
static __device__ __forceinline__ float dissociatingTemperatureAt(float rho, float p) {
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
static __device__ __forceinline__ float2 vibration(float temperature) {
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
static __device__ __forceinline__ float2 airTemperatureAndHeat(float e) {
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
static __device__ __forceinline__ float airTemperature(float e) { return airTemperatureAndHeat(e).x; }

// Pressure from density and internal energy per volume.
static __device__ __forceinline__ float gasPressure(float rho, float internalEnergy, uint model, float gamma) {
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
static __device__ __forceinline__ float2 gasState(float rho, float internalEnergy, uint model, float gamma) {
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
static __device__ __forceinline__ float gasEnergy(float rho, float pressure, uint model, float gamma) {
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
static __device__ __forceinline__ float gasGamma(float rho, float pressure, uint model, float gamma) {
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

static __device__ __forceinline__ float3 toSweep(float3 v, uint axis) {
    return axis == 0 ? v : (axis == 1 ? v.yzx() : v.zxy());
}

static __device__ __forceinline__ float3 fromSweep(float3 s, uint axis) {
    return axis == 0 ? s : (axis == 1 ? s.zxy() : s.yzx());
}

static __device__ __forceinline__ Prim primOfCell(Cell c, const SolverUniforms &u) {
    Prim w;
    w.rho = max(c.rho, u.densityFloor);
    float3 velocity = float3(c.mx, c.my, c.mz) / w.rho;
    w.v = toSweep(velocity, u.axis);
    float2 gas = gasState(w.rho, c.energy - 0.5f * w.rho * dot(velocity, velocity), u.airModel, u.gamma);
    w.p = max(gas.x, u.pressureFloor);
    w.g = gas.y;
    return w;
}

static __device__ __forceinline__ Prim loadPrim(const Cell *state, int index, const SolverUniforms &u) {
    return primOfCell(state[index], u);
}

// Reflection in a wall moving at `wallSpeed` along the sweep axis.
static __device__ __forceinline__ Prim mirrored(Prim w, float wallSpeed) {
    w.v.x = 2.0f * wallSpeed - w.v.x;
    return w;
}

// Whether the open faces stand still ambient air beyond them (`OpenFaces.farField`).
static __device__ __forceinline__ bool farFieldFaces(const SolverUniforms &u) { return (u.boundaryFlags & (1u << 6)) != 0; }

// The ghost beyond an open face for the far field, from the state `w` inside it; `side` is +1 on
// the high face of the sweep and -1 on the low. Across the face's normal the waves are taken as
// acoustic: the one leaving, p + ρc u, comes from inside, and the one entering is still air's,
// so a wave passing out is let through, and gas at ambient pressure, however hot, stays at rest
// (Riemann invariants would not keep it so, the two sides' ratios of specific heats differing).
// Leaving supersonically the ghost is the inside state, and drawn in supersonically still air;
// otherwise the density follows the isentrope of the side the flow comes from, and the speeds
// along the face come from that side.
static __device__ __forceinline__ Prim farFieldGhost(Prim w, float side, const SolverUniforms &u) {
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
static __device__ __forceinline__ Prim mirroredAbout(Prim w, float3 normal) {
    w.v -= 2.0f * dot(w.v, normal) * normal;
    return w;
}

// The wall normal of a cut cell, in the sweep's frame (out of the air into the ground).
static __device__ __forceinline__ float3 cutNormalOf(int3 cell, const uint4 *columns, const float4 *walls, uint axis,
                                 const SolverUniforms &u) {
    uint4 column = cutColumnOf(cell, columns, u);
    return toSweep(walls[column.x + uint(cell.z) - column.y].xyz(), axis);
}

// Whether `cell` is one of its column's cut cells, and so has a wall and a normal of its own. A
// whole cell beside the terrain's solid cells (above ground lying on a cell's face, or beside a
// cliff) meets them across its face, as a staircase does.
static __device__ __forceinline__ bool cutCellHere(int3 cell, const uint4 *columns, const SolverUniforms &u) {
    uint4 column = cutColumnOf(cell, columns, u);
    return cell.z >= int(column.y) && cell.z < int(column.z);
}

// Whether `cell` is inside the domain and solid by the terrain, below its column's cut cells.
static __device__ __forceinline__ bool terrainSolid(int3 cell, const uint4 *columns, const SolverUniforms &u) {
    return all(cell >= 0) && cell.x < int(u.nx) && cell.y < int(u.ny) && cell.z < int(u.nz)
        && cell.z < int(cutColumnOf(cell, columns, u).y);
}

// A compact coarse-boundary page is 4^3 cells. Wall storage starts with a tile count,
// an overflow flag and one world-tile -> pool-slot entry (UINT_MAX when absent).
const int couplingSide = 4;
const uint couplingCells = 64u;
static __device__ __forceinline__ int sparseCouplingSlot(int3 cell, int3 dims, const uint *map) {
    if (any(cell < 0) || any(cell >= dims)) { return -1; }
    int3 tiles = (dims + couplingSide - 1) / couplingSide;
    int3 tile = cell / couplingSide;
    uint slot = map[2 + tile.x + tiles.x * (tile.y + tiles.y * tile.z)];
    if (slot == 0xffffffffu) { return -1; }
    int3 local = cell % couplingSide;
    return int(slot * couplingCells) + local.x + couplingSide * (local.y + couplingSide * local.z);
}
static __device__ __forceinline__ int checkedCouplingSlot(int3 cell, int3 dims, atomic_uint *map) {
    int slot = sparseCouplingSlot(cell, dims, (const uint *)map);
    if (slot < 0 && all(cell >= 0) && all(cell < dims)) {
        atomic_store_explicit(map + 1, 1u, memory_order_relaxed);
    }
    return slot;
}
static __device__ __forceinline__ float3 movingWallVelocity(const float *velocity, int3 cell, const SolverUniforms &u) {
    int3 local = cell - int3(u.regionX, u.regionY, u.regionZ);
    int3 dims = int3(u.regionNx, u.regionNy, u.regionNz);
    if (any(local < 0) || any(local >= dims)) { return float3(0); }
    int at = local.x + dims.x * (local.y + dims.y * local.z);
    uint header = 0;
    if (u.couplingMapCount != 0u) {
        at = sparseCouplingSlot(cell, int3(u.nx, u.ny, u.nz), (const uint *)velocity);
        if (at < 0) { return float3(0); }
        header = u.couplingMapCount + 2u;
    }
    uint offset = header + 3u * uint(at);
    return float3(velocity[offset], velocity[offset + 1], velocity[offset + 2]);
}

// Speed along the sweep axis of the solid `offset` cells from `cell`; zero outside the region
// where solids move.
static __device__ __forceinline__ float wallSpeed(const float *wallVelocity, int3 cell, int offset,
                              const SolverUniforms &u) {
    cell[u.axis] += offset;
    return movingWallVelocity(wallVelocity, cell, u)[u.axis];
}

static __device__ __forceinline__ int classify(const uchar *mask, int index, int offset, int stride, int i, int n,
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
static __device__ __forceinline__ bool structureClosedBelow(const int *structureCutIndex, const float4 *structureCutRecords,
                                        int index, uint axis) {
    int record = structureCutIndex[index];
    return record >= 0 && structureCutRecords[record][1 + axis] == 0.0f;
}

static __device__ __forceinline__ float limitedSlope(float a, float b, float theta) {
    if ((a > 0.0f && b > 0.0f) || (a < 0.0f && b < 0.0f)) {
        float magnitude = min(theta * fabs(a), min(0.5f * fabs(a + b), theta * fabs(b)));
        return a > 0.0f ? magnitude : -magnitude;
    }
    return 0.0f;
}

static __device__ __forceinline__ Prim slope(Prim lo, Prim mid, Prim hi, float theta) {
    Prim d;
    d.rho = limitedSlope(mid.rho - lo.rho, hi.rho - mid.rho, theta);
    d.v.x = limitedSlope(mid.v.x - lo.v.x, hi.v.x - mid.v.x, theta);
    d.v.y = limitedSlope(mid.v.y - lo.v.y, hi.v.y - mid.v.y, theta);
    d.v.z = limitedSlope(mid.v.z - lo.v.z, hi.v.z - mid.v.z, theta);
    d.p = limitedSlope(mid.p - lo.p, hi.p - mid.p, theta);
    return d;
}

// Hancock half-step predictor in primitive variables, then extrapolation to both faces.
static __device__ __forceinline__ FacePair reconstruct(Prim w, Prim d, float halfLambda, const SolverUniforms &u) {
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

static __device__ __forceinline__ float totalEnergy(Prim w, const SolverUniforms &u) {
    return gasEnergy(w.rho, w.p, u.airModel, u.gamma) + 0.5f * w.rho * dot(w.v, w.v);
}

static __device__ __forceinline__ Flux physicalFlux(Prim w, float energy) {
    Flux f;
    f.mass = w.rho * w.v.x;
    f.momentum = f.mass * w.v;
    f.momentum.x += w.p;
    f.energy = (energy + w.p) * w.v.x;
    return f;
}

static __device__ __forceinline__ Flux riemannFlux(Prim l, Prim r, const SolverUniforms &u) {
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

static __device__ __forceinline__ void recordWaveSpeed(atomic_uint *maxSpeed, float speed) {
    // Positive floats order like their bit patterns, so an integer atomic max suffices.
    uint bits = floatBits(speed);
    if (bits > atomic_load_explicit(maxSpeed, memory_order_relaxed)) {
        atomic_fetch_max_explicit(maxSpeed, bits, memory_order_relaxed);
    }
}

static __device__ __forceinline__ bool isStill(Cell c, float2 species, const SolverUniforms &u) {
    return c.rho == u.stillRho && c.mx == u.stillMx && c.my == u.stillMy && c.mz == u.stillMz
        && c.energy == u.stillEnergy
        && (u.afterburnEnergy == 0.0f || (species.x == 0.0f && species.y == u.stillOxygen));
}

// Marks every tile within `tileReach` cells of `cell` with `flag`, unless already awake.
static __device__ __forceinline__ void wakeTilesAround(int3 cell, uchar *tileFlags, uchar flag, const SolverUniforms &u) {
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
static __device__ __forceinline__ void recordCell(atomic_uint *maxSpeed, float3 momentum, float rho, float pressure,
                              const SolverUniforms &u, float ambient) {
    float3 speed = fabs(momentum) / rho;
    float fastest = max(speed.x, max(speed.y, speed.z))
        + sqrt(gasGamma(rho, pressure, u.airModel, u.gamma) * pressure / rho);
    recordWaveSpeed(maxSpeed, fastest);
    // The second slot tracks how disturbed the air still is.
    recordWaveSpeed(maxSpeed + 1, fabs(pressure - ambient));
}

static __device__ __forceinline__ void recordCell(atomic_uint *maxSpeed, float3 momentum, float rho, float pressure,
                              const SolverUniforms &u) {
    recordCell(maxSpeed, momentum, rho, pressure, u, u.ambientPressure);
}

// The fluxes through the low and high faces of the middle cell of a five-cell stencil, by
// MUSCL-Hancock over a step of `lambda` = dt / dx.
static __device__ __forceinline__ void stencilFluxes(Prim wM2, Prim wM1, Prim w0, Prim wP1, Prim wP2, float lambda,
                                 const SolverUniforms &u, Flux &low, Flux &high) {
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
// const and a temperature falling linearly with height (or constant).
static __device__ __forceinline__ float2 hydrostatic(float z, const SolverUniforms &u) {
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
const int gravityBelow = 4;

static __device__ __forceinline__ float4 gravityCellOf(const float4 *table, int k) {
    return table[2 * (k + gravityBelow)];
}

static __device__ __forceinline__ float2 gravityFaceOf(const float4 *table, int k) {
    return table[2 * (k + gravityBelow) + 1].xy();
}

// The background at rest in cell `k`, as a cell stores it.
static __device__ __forceinline__ Cell gravityRestOf(const float4 *table, int k) {
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
static __device__ __forceinline__ float gravityAmbientOf(const float4 *table, int k, const SolverUniforms &u) {
    return primOfCell(gravityRestOf(table, k), u).p;
}

// Whether cell `k` of the coarse grid is still: under gravity, at rest in the background at its
// height (and with afterburning, holding its oxygen and no products), which a sweep leaves as it
// is to the bit; otherwise `isStill`.
static __device__ __forceinline__ bool isStillAt(Cell c, float2 species, int k, const float4 *table,
                             const SolverUniforms &u) {
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
static __device__ __forceinline__ FacePair reconstructGravity(Prim w, Prim e, Prim d, float2 rise, float pull, float2 below,
                                          float2 above, float halfLambda, float halfDt, const SolverUniforms &u) {
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
static __device__ __forceinline__ Flux gravityFlux(Prim l, Prim r, const SolverUniforms &u) {
    bool same = l.rho == r.rho && l.p == r.p && all(l.v == r.v);
    return same ? physicalFlux(l, totalEnergy(l, u)) : riemannFlux(l, r, u);
}

// As `stencilFluxes`, for the vertical sweep under gravity, cell 0 being cell `k` of its level,
// whose background is `table`. `from` gives the cell each of the others' states came from, as an
// offset from cell 0 (M2, M1, P1, P2), and `mirror` -1 where it is a mirrored ghost of it. The
// momentum fluxes leave out the background's pressure at the face, so that at rest they are zero
// to the bit (and the coarse and fine levels leave out the same, so refluxing is unchanged).
static __device__ __forceinline__ void stencilFluxesGravity(Prim wM2, Prim wM1, Prim w0, Prim wP1, Prim wP2, int4 from, float4 mirror,
                                        int k, const float4 *table, float lambda, float dt,
                                        const SolverUniforms &u, Flux &low, Flux &high) {
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
static __device__ __forceinline__ void gravitySources(float3 &momentum, float &energy, float rho0, Flux low, Flux high,
                                  int k, const float4 *table, float dt, const SolverUniforms &u) {
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

static __device__ __forceinline__ MixingFace mixingFace(Prim a, Prim b, float nuA, float nuB, float dx, float dt,
                                    const SolverUniforms &u) {
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

static __device__ __forceinline__ CutUpdate cutCellUpdate(Prim w0, Flux fluxLow, Flux fluxHigh, float apertureLow, float apertureHigh,
                                      float share, float3 normal, bool gravityHere, const float4 *gravityTable,
                                      int k, float lambda, float dt, const SolverUniforms &u) {
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
static __device__ __forceinline__ CutUpdate structureCutUpdate(Prim w0, Flux fluxLow, Flux fluxHigh, float apertureLow, float apertureHigh,
                                      float share, float3 normal, bool gravityHere, const float4 *gravityTable,
                                      int k, float lambda, float dt, int wallFace, const SolverUniforms &u) {
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

static __device__ __forceinline__ Flux sumOf(Flux a, Flux b) {
    a.mass += b.mass;
    a.momentum += b.momentum;
    a.energy += b.energy;
    return a;
}

// The patch refining coarse cell `cell`, or -1.
static __device__ __forceinline__ int patchAt(int3 cell, const int *patchOfTile, const SolverUniforms &u) {
    int3 tile = cell / patchSize;
    return patchOfTile[tile.x + int(u.refineTileNx) * (tile.y + int(u.refineTileNy) * tile.z)];
}

// The refined levels as the exposure plane sees them (`finestPointPressure`): the
// first level's patch of each block, fine state and outline, and the second level's, each a
// placeholder without; `u.refineRatio` is 0 unrefined and `u.childTileNx` 0 with one level.
struct RefinedAir {
    const int *patches;
    const Cell *fine;
    const uchar *mask;
    const int *childPatches;
    const Cell *childFine;
    const uchar *childMask;
};

// A cell's overpressure, Pa.
static __device__ __forceinline__ float cellOverpressure(Cell c, const SolverUniforms &u) {
    float rho = max(c.rho, u.densityFloor);
    float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / rho;
    return gasPressure(rho, c.energy - kinetic, u.airModel, u.gamma) - u.ambientPressure;
}

// The overpressure on a face from the finest air touching it, where its fluid cell is refined: the
// mean of the fine cells (of the second level where that is refined) in the layer against the
// face, solid ones left out. False where the cell is not refined or the face has no solid side
// (an opening), when the coarse cell is read.
static __device__ __forceinline__ bool refinedFaceOverpressure(uint fluid, uint solid, const SolverUniforms &u,
                                           const int *patchOfTile, const Cell *fine,
                                           const uchar *fineMask, const int *childPatches,
                                           const Cell *childFine, const uchar *childMask,
                                           float &pressure) {
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
static __device__ __forceinline__ bool finestPointPressure(int3 cell, float3 point, const SolverUniforms &u, RefinedAir air,
                                       float &pressure) {
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
static __device__ __forceinline__ uint registerSlot(uint patch, uint face, uint a, uint b, uint side) {
    return 5u * ((patch * 6u + face) * side * side + a + side * b);
}

// The same register's fuel and oxygen, in a buffer of their own.
static __device__ __forceinline__ uint speciesSlot(uint patch, uint face, uint a, uint b, uint side) {
    return 2u * ((patch * 6u + face) * side * side + a + side * b);
}

// Fuel and oxygen carried through a face by mass flux `mass`, each at the mass fraction of the
// cell it leaves: `behind` when the flow is positive, `ahead` when negative.
static __device__ __forceinline__ float2 speciesFlux(float mass, float2 behind, float2 ahead) {
    return mass * (mass > 0.0f ? behind : ahead);
}

// Componentwise minmod.
static __device__ __forceinline__ float2 minmodPair(float2 a, float2 b) {
    return select(select(b, a, fabs(a) < fabs(b)), float2(0.0f), a * b <= 0.0f);
}

// Fuel burnt over `dt` in a cell holding `species`, as far as its oxygen allows, at `rate` (see
// `sweepCell`).
static __device__ __forceinline__ float burnt(float2 species, float dt, float rate, const SolverUniforms &u) {
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
static __device__ __forceinline__ float afterburnRateHere(float nu, float dx, const SolverUniforms &u) {
    if (!burnMixing) {
        return u.afterburnRate;
    }
    float viscosity = floatBits(nu) < 0x7F800000u ? nu : 0.0f;
    return min(u.afterburnRate, u.burnMixingRate * viscosity / (dx * dx));
}

// A refined cell's eddy viscosity, `fine` in its level's cells, `levels` of them along a coarse
// cell's edge: its coarse cell's scaled to its own size as an inertial range's is,
// (dx_fine / dx_coarse)^(4/3), as sub-grid mixing's fluxes take it in `fineSweepCell`.
static __device__ __forceinline__ float fineEddyViscosity(int3 fine, int levels, int3 coarseDims, const float *viscosity) {
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
static __device__ __forceinline__ float afterburntHere(float2 species, float rho, float3 momentum, float energy, float dt, float nu,
                                   float dx, const SolverUniforms &u) {
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

static __device__ __forceinline__ void storeFlux(float *registers, uint slot, Flux f, uint axis, float dt) {
    float3 momentum = fromSweep(f.momentum, axis);
    registers[slot] = f.mass * dt;
    registers[slot + 1] = momentum.x * dt;
    registers[slot + 2] = momentum.y * dt;
    registers[slot + 3] = momentum.z * dt;
    registers[slot + 4] = f.energy * dt;
}

// The air's sweeps, appended to Solver.metal at compile time (ShaderLibrary): one cell's update
// along an axis, and the kernels that sweep the grid or its tiles of moving air.

// One-dimensional MUSCL-Hancock update of one cell along `u.axis`.
static __device__ __forceinline__ void sweepCell(int3 cell, Cell *src, Cell *dst, const uchar *mask,
                             float *peak, float *impulse, const StepControl &control,
                             atomic_uint *maxSpeed, const SolverUniforms &u,
                             const float *wallVelocity, uchar *tileFlags,
                             float2 *speciesSrc, float2 *speciesDst,
                             const int *patchOfTile, float *coarseFlux,
                             float *coarseSpeciesFlux, const uchar *boxMask, float *boxImpulse,
                             const float4 *gravityTable, const float *viscosity,
                             const uint4 *cutColumns, const float4 *cutRecords,
                             const float4 *cutWalls, float4 *cutDefects, const uint *cutCeilings,
                             const float4 *congestion, const int *structureCutIndex,
                             const float4 *structureCutRecords, const float4 *structureCutWalls,
                             float4 *structureCutDefects) {
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
    // A structure's face closed between two cells of air (a wall thinner than two cells leaves
    // air either side of it) is a wall to the stencil, as a solid cell is, so that neither side
    // reads the other's air through it.
    if (structureCut) {
        if (kindP1 == kindFluid && structureClosedBelow(structureCutIndex, structureCutRecords, index + stride, axis)) {
            kindP1 = kindWall;
        }
        if (kindM1 == kindFluid && structureClosedBelow(structureCutIndex, structureCutRecords, index, axis)) {
            kindM1 = kindWall;
        }
    }

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
        if (structureCut && kind == kindFluid
            && structureClosedBelow(structureCutIndex, structureCutRecords, index + 2 * stride, axis)) {
            kind = kindWall;
        }
        if (kind == kindFluid) {
            wP2 = loadPrim(src, index + 2 * stride, u);
        } else if (kind == kindWall) {
            wP2 = mirrored(wP1, wallSpeed(wallVelocity, cell, 2, u));
            from.w = 1;
            mirror.w = -1.0f;
        } else {
            // An open face beyond the next cell: its ghost as that cell builds it (`farFieldGhost`
            // of its state), so that both cells reconstruct the face between them alike and the
            // flux through it is one. A copy here left the two fluxes apart wherever the ghost
            // differed: a tube's far-field ends took in mass without the oxygen it carried.
            if (farFieldFaces(u)) { wP2 = farFieldGhost(wP1, 1.0f, u); }
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
        if (structureCut && kind == kindFluid
            && structureClosedBelow(structureCutIndex, structureCutRecords, index - stride, axis)) {
            kind = kindWall;
        }
        if (kind == kindFluid) {
            wM2 = loadPrim(src, index - 2 * stride, u);
        } else if (kind == kindWall) {
            wM2 = mirrored(wM1, wallSpeed(wallVelocity, cell, -2, u));
            from.x = -1;
            mirror.x = -1.0f;
        } else {
            // As above, the open face beyond the previous cell.
            if (farFieldFaces(u)) { wM2 = farFieldGhost(wM1, -1.0f, u); }
            from.x = -1;
        }
    } else {
        from.x = from.y;
    }

    // A cut cell's solid neighbours stand for its wall, which faces along the cell's normal, not along
    // the sweep: a ghost beside a cut cell mirrors that cell's state (or, two away, the state as far
    // the other side of it) about the cut cell's normal. Every that needs a ghost builds it
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
        bool groundP1 = kindP1 == kindWall && cutHere && terrainSolid(above, cutColumns, u);
        bool groundM1 = kindM1 == kindWall && cutHere && terrainSolid(below, cutColumns, u);
        if (groundP1 || groundM1) {
            float3 normal = cutNormalOf(cell, cutColumns, cutWalls, axis, u);
            if (groundP1) {
                wP1 = mirroredAbout(w0, normal);
            }
            if (groundM1) {
                wM1 = mirroredAbout(w0, normal);
            }
            // The ghost beyond each wall mirrors the near ghost across the cell from it, as it
            // now stands, by that wall's own rule: a block's plainly, the terrain's about the
            // normal. (Built from the near ghost as it stood before, beside a block on one side
            // and the ground on the other, the face's two states were no longer each other's
            // mirror, and gas passed through the block's face.)
            if (kindP1 == kindWall) {
                wP2 = groundP1 ? mirroredAbout(wM1, normal) : mirrored(wM1, speedP1);
            }
            if (kindM1 == kindWall) {
                wM2 = groundM1 ? mirroredAbout(wP1, normal) : mirrored(wP1, speedM1);
            }
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
    // same numerical face flux used by the gas. Each fluid owns six output scalars, one
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
                                             toSweep(wall.xyz(), axis), gravityHere, gravityTable, cell.z, lambda, dt, u);
            cutLow = update.low;
            cutHigh = update.high;
            defect = update.defect;
            registerAperture = registerLow ? apertureLow : apertureHigh;
            cutApertureLow = apertureLow;
            cutApertureHigh = apertureHigh;
        }
    }
    // A cell a structure's outline cuts, as the terrain's (its high face's aperture is the next
    // cell's low face's: closed against a solid cell, open against one without a record).
    int structureRecord = -1;
    if (structureCut && cutRecord < 0) {
        structureRecord = structureCutIndex[index];
        if (structureRecord >= 0) {
            float4 own = structureCutRecords[structureRecord];
            float apertureLow = own[1 + axis];
            float apertureHigh = 1.0f;
            if (kindP1 == kindWall) {
                apertureHigh = 0.0f;
            } else if (i + 1 < n) {
                int next = structureCutIndex[index + stride];
                apertureHigh = next >= 0 ? structureCutRecords[next][1 + axis] : 1.0f;
            }
            float4 wall = structureCutWalls[structureRecord];
            cutShare = own.x;
            int wallFace = apertureHigh == 0.0f && kindP1 == kindWall && apertureLow > 0.0f
                               ? 1
                               : (apertureLow == 0.0f && kindM1 == kindWall && apertureHigh > 0.0f ? -1 : 0);
            CutUpdate update = structureCutUpdate(w0, fluxLow, fluxHigh, apertureLow, apertureHigh, cutShare,
                                                  toSweep(wall.xyz(), axis), gravityHere, gravityTable, cell.z, lambda,
                                                  dt, wallFace, u);
            cutLow = update.low;
            cutHigh = update.high;
            defect = update.defect;
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
    // Porous cells: each face's flux through its open share, over the cell's open volume.
    float porosity = 1.0f;
    float porosityLow = 1.0f;
    float porosityHigh = 1.0f;
    if (porousAir) {
        porosity = congestion[index].x;
        porosityLow = kindM1 == kindFluid ? min(porosity, congestion[index - stride].x) : porosity;
        porosityHigh = kindP1 == kindFluid ? min(porosity, congestion[index + stride].x) : porosity;
        float open = 1.0f / porosity;
        fluxLow.mass *= porosityLow * open;
        fluxLow.momentum *= porosityLow * open;
        fluxLow.energy *= porosityLow * open;
        fluxHigh.mass *= porosityHigh * open;
        fluxHigh.momentum *= porosityHigh * open;
        fluxHigh.energy *= porosityHigh * open;
        // The obstacles' push back: what the pressure on the open faces leaves unbalanced.
        momentum.x += lambda * w0.p * (porosityHigh - porosityLow) * open;
    }
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
        if (cutRecord >= 0 || structureRecord >= 0) {
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
            float4 *defects = cutRecord >= 0 ? cutDefects : structureCutDefects;
            int slot = cutRecord >= 0 ? cutRecord : structureRecord;
            float4 held = defects[2 * slot + 1];
            defects[2 * slot + 1] = float4(held.xy() + kept, held.zw());
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
            float nu = burnMixing ? viscosity[index] : 0.0f;
            float fuel = afterburntHere(species, rho, momentum, energy, control.dt, nu, u.dx, u);
            species.x -= fuel;
            species.y -= fuel * u.oxygenPerFuel;
            energy += fuel * u.afterburnEnergy;
        }
        speciesDst[index] = species;
    }

    if (cutRecord >= 0 || structureRecord >= 0) {
        float4 *defects = cutRecord >= 0 ? cutDefects : structureCutDefects;
        int slot = cutRecord >= 0 ? cutRecord : structureRecord;
        float4 held = defects[2 * slot];
        float4 heldEnergy = defects[2 * slot + 1];
        defects[2 * slot] = float4(held.x + defect.mass, held.yzw() + fromSweep(defect.momentum, axis));
        defects[2 * slot + 1] = float4(heldEnergy.xy(), heldEnergy.z + defect.energy, heldEnergy.w);
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

static __device__ __forceinline__ void portablePrepare(StepControl &control, atomic_uint *maxSpeed, const SolverUniforms &u) {
    uint tiles = 0;
    float fastest = bitsFloat(atomic_load_explicit(maxSpeed, memory_order_relaxed));
    // A cell whose density has fallen to nothing reads a wave speed that is NaN, or negative from
    // a negative density, and either outranks every real speed in the bitwise maximum; the step
    // would then be far longer than the air allows (a refined district once took steps of 0.6 s
    // where 3 ms were right). The batch stops there instead, unstable. Tested on the bits, as fast
    // math may fold a test for NaN or infinity away: NaN, infinity and every negative lie at or
    // above infinity's.
    if (floatBits(fastest) >= 0x7F800000u) {
        control.stopped = 3;
        control.maxOverpressure = NAN;
    }
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
            control.maxOverpressure = bitsFloat(atomic_exchange_explicit(maxSpeed + 1, 0u, memory_order_relaxed));
        }
    }


    control.dt = dt;
    control.batchTime += dt;
    ulong clock = (ulong(control.clockLow) | (ulong(control.clockHigh) << 32))
        + ulong(max(dt, 0.0f) * 1099511627776.0f);
    control.clockLow = uint(clock);
    control.clockHigh = uint(clock >> 32);
    control.stepIndex += 1;
    control.activeSteps += dt > 0.0f ? 1 : 0;
}
static __device__ __forceinline__ void portableFirstPhase(const Cell *state, const StepControl &control, const float4 *columns, float4 *records, float *open, const SolverUniforms &u, uint4 parameters, uint2 tid) {
    if (tid.x >= parameters.x || tid.y >= parameters.y || (control.dt <= 0 && parameters.z == 0)) {
        return;
    }
    uint n = tid.x + parameters.x * tid.y;
    float4 column = columns[n];
    if (column.w == 0) {
        return;
    }
    float pressure = 0;
    for (uint side = 0; side < 2; ++side) {
        float w = side == 0 ? 1 - column.z : column.z;
        if (w <= 0) {
            continue;
        }
        uint k = uint(side == 0 ? column.x : column.y);
        Cell c = state[tid.x + u.nx * (tid.y + u.ny * k)];
        float rho = max(c.rho, u.densityFloor);
        float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / rho;
        pressure += w * gasPressure(rho, c.energy - kinetic, u.airModel, u.gamma);
    }
    float p = pressure - u.ambientPressure;
    float dt = max(control.dt, 0.0f);
    float4 record = records[n];
    float going = open[n];
    record.y += max(p, 0.0f) * dt;
    record.x = max(record.x, p);
    if (going != 0) {
        if (p < 0) {
            going = 0;
        } else {
            record.z = record.y;
            record.w = max(record.w, p);
        }
    }
    if (p > 0 && record.w < 0.5f * record.x) {
        record.z = record.y;
        record.w = p;
        going = 1;
    }
    records[n] = record;
    open[n] = going;
}
// Cut cells' redistribution, appended to Solver.metal at compile time (ShaderLibrary): what a cut
// cell could not hold over a step shared up the terrain's column or along a structure's wall.

// The share of its density and pressure a cell keeps, at least, when the cut cells' redistribution
// gives it a difference: a difference that would take more (a strong expansion over a small cut
// cell beside a charge can ask a cell for more than it holds; docs/terrain.md, "A cell above a hot
// sliver") is given only in part, and the rest goes on up the column.
const float cutKeepShare = 0.1f;

// Cell `c`'s density and pressure (the pressure from its own state, as the redistribution works it
// out), for `cutChangeKeeps`.
static __device__ __forceinline__ float2 cutCellDensityPressure(Cell c, const SolverUniforms &u) {
    float rho = max(c.rho, u.densityFloor);
    float3 momentum = float3(c.mx, c.my, c.mz);
    float kinetic = 0.5f * dot(momentum, momentum) / rho;
    return float2(rho, gasPressure(rho, c.energy - kinetic, u.airModel, u.gamma));
}

// Whether cell `c`, of density and pressure `before`, given `change` (mass, momentum) and
// `changeEnergy` for its whole volume over its air share `alpha`, keeps `cutKeepShare` of its
// density and pressure and stays above the floors, worked out as the redistribution applies a
// change.
static __device__ __forceinline__ bool cutChangeKeeps(Cell c, float2 before, float4 change, float changeEnergy, float alpha,
                                  const SolverUniforms &u) {
    float rho = c.rho + change.x / alpha;
    if (!(rho > max(u.densityFloor, cutKeepShare * before.x))) {
        return false;
    }
    float3 momentum = float3(c.mx + change.y / alpha, c.my + change.z / alpha, c.mz + change.w / alpha);
    float energy = c.energy + changeEnergy / alpha;
    float kinetic = 0.5f * dot(momentum, momentum) / rho;
    return gasPressure(rho, energy - kinetic, u.airModel, u.gamma) >= max(u.pressureFloor, cutKeepShare * before.y);
}

// The share of `change` the cut cells' redistribution gives cell `c`: all of it (1) where the cell
// keeps `cutKeepShare` of its density and pressure, as always; otherwise the most that leaves it
// that, found by bisection, so that the rest goes on up its column to cells that can take it,
// rather than draining this one and the pressure floor adding energy.
static __device__ __forceinline__ float positiveCutShare(Cell c, float4 change, float4 changeEnergy, float alpha,
                                     const SolverUniforms &u) {
    float2 before = cutCellDensityPressure(c, u);
    if (cutChangeKeeps(c, before, change, changeEnergy.z, alpha, u)) {
        return 1.0f;
    }
    if (!(before.x > u.densityFloor && before.y >= u.pressureFloor)) {
        return 1.0f;
    }
    float low = 0.0f;
    float high = 1.0f;
    for (int n = 0; n < 20; ++n) {
        float middle = 0.5f * (low + high);
        if (cutChangeKeeps(c, before, middle * change, middle * changeEnergy.z, alpha, u)) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return low;
}

// After a step's sweeps, with cut cells: each cut cell's difference between its conservative
// update and the whole cell's it was given (its fuel and oxygen's too) is shared out up its
// column: the cell keeps its share alpha of it, and the rest goes to the first cell above it at
// least half full (the next cell up, for a cell itself at least half full), in a fixed order. The
// differences are then cleared. One a column with cut cells, its index in `columnsCut`.
// Where the air is refined, this runs after refluxing: a cell under a patch drops its own
// difference (its fine cells hold its air, and have shared out theirs), and what reaches such a
// cell goes into its fine cells, as much a volume to each. A block standing in the column stops
// what is carried up; the last cell of air below it takes it.

static __device__ __forceinline__ void portableRedistribute(Cell *state ,
                                   float2 *species ,
                                   const uint4 *cutColumns ,
                                   const float4 *cutRecords ,
                                   const SolverUniforms &u ,
                                   const StepControl &control ,
                                   float *peak ,
                                   atomic_uint *maxSpeed ,
                                   float4 *cutDefects ,
                                   const uint *columnsCut ,
                                   const uint &columnCount ,
                                   const float4 *gravityTable ,
                                   const uchar *mask ,
                                   const int *patchOfTile ,
                                   Cell *fine ,
                                   const float4 *fineCut ,
                                   float2 *fineSpecies ,
                                   const uchar *fineMask ,
                                   const float4 *fineGravityTable ,
                                   uchar *tileFlags ,
                                   uint gid ) {
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
    // fine cells of air. Unless `whole`, a cell of its own takes no more than leaves it positive
    // (`positiveCutShare`), and what it could not take is returned, for the cells above.
    struct Left {
        float4 change;
        float4 changeEnergy;
    };
    auto apply = [&](int k, float4 change, float4 changeEnergy, float alpha, bool whole) -> Left {
        Left left = {float4(0.0f), float4(0.0f)};
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
                    fineSpecies[child] = max(fineSpecies[child] + changeEnergy.xy() / alpha, 0.0f);
                }
                float ambient = airGravity ? gravityAmbientOf(fineGravityTable, f.z, u) : u.ambientPressure;
                recordCell(maxSpeed, momentum, c.rho, pressure, u, ambient);
            }
            return left;
        }
        Cell c = state[index];
        float share = whole ? 1.0f : positiveCutShare(c, change, changeEnergy, alpha, u);
        if (share < 1.0f) {
            left.change = change - share * change;
            left.changeEnergy = changeEnergy - share * changeEnergy;
            change *= share;
            changeEnergy *= share;
        }
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
            float2 given = species[index] + changeEnergy.xy() / alpha;
            species[index] = u.deflagration != 0u ? given : max(given, 0.0f);
        }
        float ambient = airGravity ? gravityAmbientOf(gravityTable, k, u) : u.ambientPressure;
        peak[index] = max(peak[index], pressure - ambient);
        recordCell(maxSpeed, momentum, c.rho, pressure, u, ambient);
        // A cell changed here, perhaps in a tile asleep (the cell above a sliver), is swept next step.
        if (u.tileNx != 0) {
            wakeTilesAround(cell, tileFlags, tileWoken, u);
        }
        return left;
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
                apply(lastK, change, changeEnergy, lastAlpha, true);
            }
            continue;
        }
        lastK = k;
        lastAlpha = alpha;
        if (all(change == 0.0f) && all(changeEnergy == 0.0f)) {
            continue;
        }
        Left left = apply(k, change, changeEnergy, alpha, false);
        passed += left.change;
        passedEnergy += left.changeEnergy;
    }
    // What a cell could not take goes on up, through whole cells, to the first that can; the last
    // cell of air, under a block or at the top, takes whatever is left.
    for (int k = last + 1; k <= top && (any(passed != 0.0f) || any(passedEnergy != 0.0f)); ++k) {
        if (mask[base + stride * k] != 0) {
            break;
        }
        lastK = k;
        lastAlpha = 1.0f;
        Left left = apply(k, passed, passedEnergy, 1.0f, k == top);
        passed = left.change;
        passedEnergy = left.changeEnergy;
    }
    if (lastK >= 0 && (any(passed != 0.0f) || any(passedEnergy != 0.0f))) {
        apply(lastK, passed, passedEnergy, lastAlpha, true);
    }
}
static __device__ __forceinline__ bool finiteBits(float x) {
    return (floatBits(x) & 0x7f800000u) != 0x7f800000u;
}
static __device__ __forceinline__ float luminousTemperatureOf(Cell c, float luminous, const SolverUniforms &u) {
    float3 velocity = float3(c.mx, c.my, c.mz) / c.rho;
    float kinetic = 0.5f * c.rho * dot(velocity, velocity);
    float pressure = gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma);
    // Dissociating air is never hotter than this, so it bounds the search.
    float bound = pressure / (c.rho * airGasConstant);
    if (!finiteBits(bound) || !(bound >= luminous)) {
        return 0.0f;
    }
    float t = airModelOf(u.airModel) == airDissociating ? dissociatingTemperatureAt(c.rho, pressure) : bound;
    if (!finiteBits(t) || !(t >= luminous)) {
        return 0.0f;
    }
    return t;
}
struct RadiationUniforms {
    float luminous;         // K: the gas is luminous at or above this
    float absorption;       // 1/m: the hot gas's own absorption
    float sootAbsorption;   // 1/(m K) per kg/m^3 of unburnt products: 1817 x the soot yield / 1800
    uint hasSpecies;        // whether the air carries unburnt products
    float largestShare;     // the most of a cell's internal energy one step may take
    float luminousEnergy;   // J/kg: no gas with less internal energy is luminous
    uint capacity;          // box cells the 13 directions' slices hold
};
const float radiationFaceWeight = 0.57506f;
const float radiationEdgeWeight = 0.46493f;
const float radiationCornerWeight = 0.44210f;
const float stefanBoltzmann = 5.670374e-8f;

// The medium in one cell: its absorption coefficient (x) and black-body radiance (y), zero
// unless it is luminous air.
static __device__ __forceinline__ float2 radiationMediumOf(uint index, const Cell *state, const uchar *mask,
                                       const float2 *species, const SolverUniforms &u,
                                       const RadiationUniforms &r) {
    if (mask[index] != 0) {
        return float2(0.0f);
    }
    // Most cells are far too cool, which their energy shows without solving for their temperature.
    Cell c = state[index];
    float internal = c.energy - 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / c.rho;
    if (!(internal >= r.luminousEnergy * c.rho)) {
        return float2(0.0f);
    }
    float t = luminousTemperatureOf(c, r.luminous, u);
    if (t == 0.0f) {
        return float2(0.0f);
    }
    float products = r.hasSpecies != 0u ? max(species[index].x, 0.0f) : 0.0f;
    float kappa = r.absorption + r.sootAbsorption * products * t;
    float square = t * t;
    return float2(kappa, stefanBoltzmann * square * square / M_PI_F);
}
static __device__ __forceinline__ uint3 radiationExtent(const uint *box) {
    return box[0] > box[4] ? uint3(0u) : uint3(box[4], box[5], box[6]) - uint3(box[0], box[1], box[2]) + 1u;
}
static __device__ __forceinline__ float radiationAbsorbed(float x) {
    return x < 1e-2f ? x * (1.0f - x * (0.5f - x / 6.0f)) : 1.0f - exp(-x);
}

// What a cell takes from a beam of radiance `beam` crossing it over `path` metres, a cubic metre
// of it and per steradian, and the beam as it leaves.
static __device__ __forceinline__ float radiationExchange(float2 m, float path, float &beam) {
    float a = radiationAbsorbed(m.x * path);
    float gained = (m.y - beam) * a;
    beam += gained;
    return gained / path;
}
static __device__ __forceinline__ void portableRadiationLines(const float2 *medium, const uchar *mask, float *loss, const uint *box, const SolverUniforms &u, int4 direction, uint3 tid) {
    int3 low = int3(box[0], box[1], box[2]);
    int3 high = int3(box[4], box[5], box[6]);
    int3 start = low + int3(tid);
    int3 d = direction.xyz();
    if (any(start > high) || all(clamp(start - d, low, high) == start - d)) {
        return;
    }
    int steps = abs(d.x) + abs(d.y) + abs(d.z);
    float weight = steps == 1 ? radiationFaceWeight : (steps == 2 ? radiationEdgeWeight : radiationCornerWeight);
    float path = u.dx * sqrt(float(steps));
    bool first = direction.w != 0;
    // Forwards, from the start.
    float beam = 0.0f;
    int3 cell = start;
    int3 last = start;
    while (all(cell >= low) && all(cell <= high)) {
        uint index = uint(cell.x) + u.nx * (uint(cell.y) + u.ny * uint(cell.z));
        float taken = 0.0f;
        if (mask[index] != 0) {
            beam = 0.0f;
        } else {
            float2 m = medium[index];
            if (m.x > 0.0f) {
                taken = weight * radiationExchange(m, path, beam);
            }
        }
        loss[index] = first ? taken : loss[index] + taken;
        last = cell;
        cell += d;
    }
    // And back.
    beam = 0.0f;
    cell = last;
    while (all(cell >= low) && all(cell <= high)) {
        uint index = uint(cell.x) + u.nx * (uint(cell.y) + u.ny * uint(cell.z));
        if (mask[index] != 0) {
            beam = 0.0f;
        } else {
            float2 m = medium[index];
            if (m.x > 0.0f) {
                loss[index] += weight * radiationExchange(m, path, beam);
            }
        }
        cell -= d;
    }
}
static __device__ __forceinline__ void portableRadiationApply(Cell *state, const float2 *medium, const float *loss, const uint *box, float elapsed, const SolverUniforms &u, const RadiationUniforms &r, const float *slices, uint3 tid) {
    int3 cell = int3(box[0], box[1], box[2]) + int3(tid);
    float given = 0.0f;
    if (all(cell <= int3(box[4], box[5], box[6]))) {
        uint index = uint(cell.x) + u.nx * (uint(cell.y) + u.ny * uint(cell.z));
        if (medium[index].x > 0.0f) {
            uint3 extent = radiationExtent(box);
            float lost = 0.0f;
            if (extent.x * extent.y * extent.z <= r.capacity) {
                uint at = tid.x + extent.x * (tid.y + extent.y * tid.z);
                for (uint n = 0; n < 13; ++n) {
                    lost += slices[n * r.capacity + at];
                }
            } else {
                lost = loss[index];
            }
            Cell c = state[index];
            float internal = c.energy - 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / c.rho;
            float energy = min(lost * elapsed, r.largestShare * max(internal, 0.0f));
            c.energy -= energy;
            state[index] = c;
            given = energy * u.dx * u.dx * u.dx;
        }
    }

}
extern "C" __global__ void cudaSweep(Cell* src, Cell* dst, const uchar* mask,
    float* peak, float* impulse, const StepControl* control, uint* maxSpeed,
    const SolverUniforms* uniforms, float2* speciesSrc, float2* speciesDst,
    const uint4* cutColumns,const float4* cutRecords,const float4* cutWalls,
    float4* cutDefects,const uint* cutCeilings) {
    const SolverUniforms &u = *uniforms;
    uint i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= u.nx*u.ny*u.nz) return;
    int3 cell(i % u.nx, (i/u.nx)%u.ny, i/(u.nx*u.ny));
    sweepCell(cell, src, dst, mask, peak, impulse, *control, maxSpeed, u,
        nullptr, nullptr, speciesSrc, speciesDst, nullptr, nullptr, nullptr,
        nullptr, nullptr, nullptr, nullptr, cutColumns, cutRecords, cutWalls, cutDefects,
        cutCeilings, nullptr, nullptr, nullptr, nullptr, nullptr);
}

extern "C" __global__ void cudaPrepare(StepControl* control, uint* maxSpeed, const SolverUniforms* u) {
    if (blockIdx.x == 0 && threadIdx.x == 0) portablePrepare(*control, maxSpeed, *u);
}
extern "C" __global__ void cudaMeasure(const Cell* state, const uchar* mask, uint* maxSpeed,
                                      const SolverUniforms* uniforms) {
    const SolverUniforms &u = *uniforms;
    uint i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= u.nx*u.ny*u.nz || mask[i]) return;
    Cell c = state[i];
    float rho = max(c.rho, u.densityFloor);
    float3 v = float3(c.mx,c.my,c.mz)/rho;
    float p = max(gasPressure(rho,c.energy-0.5f*rho*dot(v,v),u.airModel,u.gamma),u.pressureFloor);
    recordWaveSpeed(maxSpeed,max(fabs(v.x),max(fabs(v.y),fabs(v.z)))+sqrt(gasGamma(rho,p,u.airModel,u.gamma)*p/rho));
    recordWaveSpeed(maxSpeed+1,fabs(p-u.ambientPressure));
}
extern "C" __global__ void cudaFirstPhase(const Cell* state, const StepControl* control,
    const float4* columns, float4* records, float* open, const SolverUniforms* u) {
    uint i = blockIdx.x*blockDim.x+threadIdx.x;
    if(i >= u->nx*u->ny) return;
    uint4 parameters(u->nx,u->ny,control->stepIndex==0 && control->dt==0 ? 1u : 0u,0);
    portableFirstPhase(state,*control,columns,records,open,*u,parameters,uint2(i%u->nx,i/u->nx));
}
extern "C" __global__ void cudaCoolingClock(const StepControl* c,float* elapsed) {
    if(blockIdx.x==0 && threadIdx.x==0) *elapsed+=max(c->dt,0.0f);
}
extern "C" __global__ void cudaCoolingReset(const StepControl* c,float* elapsed) {
    if(blockIdx.x==0 && threadIdx.x==0 && c->dt>0) *elapsed=0;
}
extern "C" __global__ void cudaCoolingMedium(const Cell* state,const uchar* mask,const float2* species,
    const SolverUniforms* u,const RadiationUniforms* r,float2* medium) {
    uint i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<u->nx*u->ny*u->nz) medium[i]=radiationMediumOf(i,state,mask,species,*u,*r);
}
extern "C" __global__ void cudaCoolingLines(const float2* medium,const uchar* mask,float* loss,
    const uint* box,const SolverUniforms* u,const int4* direction) {
    uint i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<u->nx*u->ny*u->nz)
        portableRadiationLines(medium,mask,loss,box,*u,*direction,uint3(i%u->nx,(i/u->nx)%u->ny,i/(u->nx*u->ny)));
}
extern "C" __global__ void cudaCoolingApply(Cell* state,const float2* medium,const float* loss,
    const uint* box,const float* elapsed,const SolverUniforms* u,const RadiationUniforms* r,const StepControl* c) {
    uint i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<u->nx*u->ny*u->nz && c->dt>0)
        portableRadiationApply(state,medium,loss,box,*elapsed,*u,*r,nullptr,uint3(i%u->nx,(i/u->nx)%u->ny,i/(u->nx*u->ny)));
}

extern "C" __global__ void cudaRedistribute(Cell* state,float2* species,
    const uint4* columns,const float4* records,const SolverUniforms* u,const StepControl* control,
    float* peak,uint* maxSpeed,float4* defects,const uint* columnsCut,const uint* columnCount,
    const uchar* mask) {
    uint gid=blockIdx.x*blockDim.x+threadIdx.x;
    portableRedistribute(state,species,columns,records,*u,*control,peak,maxSpeed,defects,
        columnsCut,*columnCount,nullptr,mask,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,gid);
}
