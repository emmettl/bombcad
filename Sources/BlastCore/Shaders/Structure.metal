// Explicit finite-element solver for deformable structures, appended to Solver.metal
// at compile time (it reuses `Cell` and `StepControl`).
//
// Elements are eight-node hexahedra on a regular lattice with one-point quadrature and
// Flanagan-Belytschko hourglass control scaled to the physical bending stiffness of the element.
// Nodes are integrated with central differences. Two material models are available:
//   0: von Mises plasticity with linear hardening (Jaumann stress rate), eroding at a
//      plastic-strain limit;
//   1: concrete as a total-strain model with cracks smeared over the lattice planes
//      (exponential tension softening and a parabolic compression curve, both regularised by
//      fracture energy, and aggregate-interlock shear across cracks), strain-rate strengthening,
//      and smeared elastic-plastic reinforcement along the lattice axes.
// Layouts here must match `StructureTypes.swift`.

struct StructureUniforms {
    uint ex;
    uint ey;
    uint ez;
    uint substep;
    float h;
    float originX;
    float originY;
    float originZ;
    float bulkLinear;
    float bulkQuadratic;
    float criticalStep;
    float fixedStep;  // > 0: use this step; 0: subdivide the fluid step in `StepControl`
    float gravity;
    float damping;
    float ambientPressure;
    float fluidGamma;
    float fluidCell;
    uint fluidNx;
    uint fluidNy;
    uint fluidNz;
    uint coupled;
    float minVolumeRatio;
    float groundFriction;
    uint contactMode;  // 0 = off, 1 = once something has failed, 2 = always
    uint stamp;        // unique per substep; marks fresh entries in the contact grid
    uint contactNx;  // the contact table wraps space every contactNx, Ny, Nz cells (powers of two)
    uint contactNy;
    uint contactNz;
    float gridOriginX;
    float gridOriginY;
    float gridOriginZ;
    float contactStiffness;  // per unit of nodal mass
    float contactDamping;    // fraction of critical
    float contactFriction;
    float rateFilter;       // 1 / time constant of the strain-rate average
    float loadTime;
    uint loadCount;  // entries in the applied-pressure table; 0 = none
    uint loadFace;   // 2 * axis + side of the element faces the pressure acts on
    uint debrisLoading;  // non-zero: loose debris is pushed by the air
    // Air cells around the structure in which debris and air exchange momentum and energy.
    int exchangeX;
    int exchangeY;
    int exchangeZ;
    int exchangeNx;
    int exchangeNy;
    int exchangeNz;
    uint fluidAirModel;  // the air's equation of state (`AirModel`)
    // How concrete's crack axes are chosen: 0 the lattice's; 1 the principal axes it first
    // cracked on; 2 the principal axes, followed until the crack has opened, then fixed.
    uint orientedCracks;
    uint interfaceLinks;  // shell nodes tied into this body's elements (see `InterfaceLink`)
    // The air's refinement (see Refine.metal): its ratio (0 when not refined) and the size of
    // its grid of blocks.
    uint fluidRefine;
    uint fluidBlocksX;
    uint fluidBlocksY;
    uint secondCracks;  // 1: concrete with fixed crack axes may open a second crack
};

// A shell node tied to a solid body: a rigid link to the line of the solid's nodes that spans
// the shell's thickness where its midsurface meets the solid. The node moves as the line does
// (their mean displacement, and their rotation about the line's middle) and hands its force to
// them in equal shares and its moment as forces across the line, the duals of those.
struct InterfaceLink {
    uint shellNode;
    uint count;
    uint nodes[8];            // compact indices of the solid's nodes on the line
    packed_float3 arms[8];    // their offsets from the line's middle
    float inverseSecondMoment;  // 1 / sum |arm|^2
};

// Rotation matrix (columns: the rotated axes) of a unit quaternion (x, y, z, w), and back.
static inline float3x3 rotationOf(float4 q) {
    float x = q.x, y = q.y, z = q.z, w = q.w;
    return float3x3(float3(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w)),
                    float3(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w)),
                    float3(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)));
}

static inline float4 quaternionOf(float3x3 r) {
    float trace = r[0][0] + r[1][1] + r[2][2];
    float4 q;
    if (trace > 0.0f) {
        float s = 0.5f / sqrt(trace + 1.0f);
        q = float4((r[1][2] - r[2][1]) * s, (r[2][0] - r[0][2]) * s, (r[0][1] - r[1][0]) * s, 0.25f / s);
    } else if (r[0][0] > r[1][1] && r[0][0] > r[2][2]) {
        float s = 2.0f * sqrt(1.0f + r[0][0] - r[1][1] - r[2][2]);
        q = float4(0.25f * s, (r[1][0] + r[0][1]) / s, (r[2][0] + r[0][2]) / s, (r[1][2] - r[2][1]) / s);
    } else if (r[1][1] > r[2][2]) {
        float s = 2.0f * sqrt(1.0f + r[1][1] - r[0][0] - r[2][2]);
        q = float4((r[1][0] + r[0][1]) / s, 0.25f * s, (r[2][1] + r[1][2]) / s, (r[2][0] - r[0][2]) / s);
    } else {
        float s = 2.0f * sqrt(1.0f + r[2][2] - r[0][0] - r[1][1]);
        q = float4((r[2][0] + r[0][2]) / s, (r[2][1] + r[1][2]) / s, 0.25f * s, (r[0][1] - r[1][0]) / s);
    }
    return normalize(q);
}

// What loose debris takes from the air is summed per air cell in fixed point, so that the
// GPU's integer atomics give the same total whatever order the nodes arrive in. Each sum is 64
// bits, kept as two 32-bit words with the carry passed from the low word to the high one, so it
// is exact and cannot overflow even beside a charge. The sums are per cubic metre of the cell:
// momentum in steps of 2^-24 kg/(m^2 s) and energy in steps of 2^-16 J/m^3, fine enough that
// the smallest pushes on single nodes are not rounded away. The frontal area of the debris in
// each cell, per cubic metre, is summed in 32 bits, in steps of 2^-16 per metre.
constant float exchangeMomentumScale = 16777216.0f;
constant float exchangeEnergyScale = 65536.0f;
constant float exchangeAreaScale = 65536.0f;
constant uint exchangeStride = 8;

// Adds a 64-bit integer to a pair of words (low, then high), exactly and in any order.
static inline void atomicAdd64(device atomic_uint *pair, long value) {
    uint2 words = as_type<uint2>(value);
    uint old = atomic_fetch_add_explicit(&pair[0], words.x, memory_order_relaxed);
    uint carry = old + words.x < old ? 1u : 0u;
    if (words.y + carry != 0u) {
        atomic_fetch_add_explicit(&pair[1], words.y + carry, memory_order_relaxed);
    }
}

// Properties of one material, as the element kernel needs them. A structure can have up to
// `maxMaterials`, each element naming its own. Layout matches `MaterialParameters` in
// `StructureTypes.swift`.
struct MaterialParameters {
    float density;
    float lambda;
    float mu;
    float yieldStress;
    float hardening;
    float failureStrain;
    float hourglassStiffness;
    float soundSpeed;
    uint materialModel;
    float youngsModulus;
    float compressiveStrength;
    float tensileStrength;
    float crackOnset;      // strain at peak tensile stress
    float crackSoftening;  // decay strain of the tension-softening exponential
    float crushPeak;       // strain at peak compressive stress
    float crushEnd;        // strain at which compression has softened to its residual
    float erosionStrain;
    float crushErosion;  // strain beyond the end of softening, as a multiple of the softening range
    float confinement;   // gain in strength per unit of lateral stress
    float steelModulus;
    uint steelPoints;       // entries in the reinforcement's hardening curve
    float steelStrain[8];   // plastic strain ...
    float steelStress[8];   // ... against stress
    float concreteRateCompression;
    float concreteRateTension;
    float steelRateYield;
    float steelRateUltimate;
    float crackBand;            // length a crack's opening is smeared over
    float interlockStrength;    // aggregate-interlock shear capacity of a closed crack
    float interlockWidthScale;  // its decay with crack width, per metre
    float shearRetention;       // fraction of the shear stiffness a cracked plane keeps
    float crackResidual;        // fraction of a crack's opening left when its stress is released
    uint crushRadius;           // elements either side over which crushing is averaged; 0 = local
    float steelHardeningRatio;  // slope of the reinforcement's yield asymptotes over its modulus
    float barReach;             // half the debonded length, in elements; 0 = judged locally
};

constant uint maxMaterials = 8;

// Set when the pipeline is built: true for a structure of one material, which lets the compiler
// fold the per-element lookup away.
constant bool singleMaterial [[function_constant(0)]];

// Each cell of the contact grid holds up to this many nodes, as the shells' does. With four,
// debris packed onto 25 mm elements overflowed it: the nodes left out sank into the others and
// were pushed back out when they reappeared, feeding energy to the debris until, in the chamber
// test, half a million elements had been torn off by it.
constant uint contactSlots = 8;
constant uint emptySlot = 0xFFFFFFFFu;
// Contact safeguards, for solids and shells alike: a pair separating faster than
// `separationLimit` is pushed no further, and contact changes a node's velocity by at most
// `contactKick` in one step. A penalty spring stores energy in its overlap, and nodes hidden from
// each other in a crowded entry of the table can meet already deeply overlapped; unguarded, the
// spring then flings them apart at hundreds of metres a second.
constant float separationLimit = 1.0f;  // m/s
constant float contactKick = 2.0f;      // m/s

struct ElementState {
    float stress[6];      // Cauchy stress: xx, yy, zz, xy, yz, zx
    float plasticStrain;  // von Mises: equivalent plastic strain; concrete: largest of `crushStrain`
    float display;        // 0 (sound) to 1 (failing), for rendering
    packed_float3 hourglass[4];
    packed_float3 crackStrain;   // concrete: largest tensile strain so far across x, y, z planes
    packed_float3 steelPlastic;  // plastic strain of the reinforcement along x, y, z
    float strainRate;            // running average of the effective strain rate
    float crackingFactor;        // tensile rate factor frozen when the element first cracked
    packed_float3 confinementGain;  // running average of each axis's confinement factor, less one
    packed_float3 crushStrain;      // concrete: largest compressive strain so far along x, y, z
    // With oriented cracks, the axes the concrete cracked across, as a rotation from the lattice
    // axes (a unit quaternion; all zero until it first cracks). The three crack, crush and
    // confinement histories above are then along these axes.
    packed_half4 crackFrame;
    float compaction;  // concrete: largest volumetric compression so far, mu = V0 / V - 1
    packed_float3 crackResidual;  // concrete: opening each crack keeps once closed, as a strain
    // Concrete whose crack axes are fixed: a second crack, where the tension has since turned
    // well away from them. Its normal in the crack axes (w is 1 once it has formed), and its
    // opening now and the largest it has reached, as strains across it.
    packed_half4 secondCrack;
    float secondOpening;
    float secondHistory;
    float inclinedPlastic;  // plastic strain of the inclined bars (1e9 once ruptured)
};

// Pressure in concrete compacted to mu = V0 / V - 1, after Holmquist, Johnson and Cook (1993):
// elastic (bulk modulus K) up to the crushing pressure fc / 3; then the pores collapse, and the
// pressure rises linearly to 0.8 GPa at mu = 0.1, keeping the compaction reached (unloading
// with K from the largest, `peak`); beyond that the concrete is fully dense, and
// p = K1 m + K2 m^2 + K3 m^3 with m = (mu - 0.1) / 1.1 above 0.8 GPa, K1 = 85, K2 = -171 and
// K3 = 208 GPa.
static inline float compactionPressure(float mu, float peak, float bulk, float fc) {
    float crushPressure = fc / 3.0f;
    float crushStrain = crushPressure / bulk;
    const float lockPressure = 0.8e9f;
    const float lockStrain = 0.1f;
    auto loading = [&](float x) {
        if (x <= crushStrain) {
            return bulk * x;
        }
        if (x <= lockStrain) {
            return crushPressure + (lockPressure - crushPressure) * (x - crushStrain) / (lockStrain - crushStrain);
        }
        float m = (x - lockStrain) / (1.0f + lockStrain);
        return lockPressure + m * (85e9f + m * (-171e9f + m * 208e9f));
    };
    if (mu >= peak || peak <= crushStrain) {
        return loading(mu);
    }
    // Unloading from the largest compaction, at the elastic bulk modulus.
    return max(loading(peak) - bulk * (peak - mu), 0.0f);
}

// Reinforcement area per unit area of concrete, along each lattice axis; and of one set of bars
// at 45 degrees to two lattice axes (such as the diagonal bars across a chamfered corner), with
// which: 0 none, or 1 + 2 * plane + (1 if the second axis runs backwards), the planes being
// those of x and y, y and z, z and x.
struct ElementSteel {
    packed_float3 ratio;
    half inclined;
    ushort inclinedAxes;
};

// The unit direction of inclined bars of `axes` (see `ElementSteel`).
static inline float3 inclinedDirection(uint axes) {
    uint plane = (axes - 1u) / 2u;
    float3 d = float3(0.0f);
    d[plane] = 0.70710678f;
    d[(plane + 1u) % 3u] = (axes - 1u) % 2u == 0u ? 0.70710678f : -0.70710678f;
    return d;
}

// Cyclic history of the bars along one axis of an element. Until the bars first reverse after
// yielding, they follow the measured monotonic curve and only the extreme point is tracked.
struct BarHistory {
    float reversalStrain;  // where the current branch began
    float reversalStress;
    float targetStrain;    // where its initial tangent meets the yield asymptote; equal to
    float targetStress;    // `reversalStrain` while the bars are still on the monotonic curve
    float extremeStrain;   // farthest point reached along the current branch
    float extremeStress;
    float maxStrain;  // largest and smallest strains at earlier reversals
    float minStrain;
};

struct ElementForces {
    packed_float3 force[8];
};

// Nodes store displacement from their lattice position rather than absolute position, so
// that small deflections keep full single-precision resolution.
struct StructureNode {
    packed_float3 displacement;
    float mass;
    packed_float3 velocity;
    uint flags;  // bits 0-2: x, y, z held still; bit 3: velocity prescribed (never updated);
                 // bit 4: rests on a support, cannot fall below its starting height;
                 // bit 5: buried, all eight elements around it intact (set by the node pass)
};

constant uint nodeBuried = 32u;

// An element that fails is first marked as failing, which the other elements still treat as
// intact for the rest of that pass, and becomes eroded in the node pass that follows. Without
// the intermediate mark, whether a neighbour saw the failure in the same pass would depend on
// thread timing, and two runs of a collapse would differ.
enum ElementFlag { elementEmpty = 0, elementActive = 1, elementEroded = 2, elementFailing = 3 };

// Time step of the current substep. When coupled, each fluid step is split into the fewest
// equal substeps that respect the structural stability limit; surplus dispatches do nothing.
static inline float structureStep(constant StructureUniforms &u, const device StepControl &control,
                                  thread bool &active) {
    if (u.fixedStep > 0.0f) {
        active = true;
        return u.fixedStep;
    }
    float fluidStep = control.dt;
    uint needed = max(1u, uint(ceil(fluidStep / u.criticalStep)));
    active = fluidStep > 0.0f && u.substep < needed;
    return fluidStep / float(needed);
}

static inline float3 cornerSign(uint a) {
    return float3(float(a & 1u), float((a >> 1) & 1u), float((a >> 2) & 1u)) * 2.0f - 1.0f;
}

// Overpressure of the air just outside an element face: the first fluid cell within two cells.
static inline float faceOverpressure(float3 point, float3 normal, const device Cell *fluid,
                                     const device uchar *fluidMask, const device int *patchOfTile,
                                     const device Cell *fine, const device uchar *fineMask,
                                     constant StructureUniforms &u) {
    return overpressureAlong(point, normal, 0.0f, 2, fluid, fluidMask, patchOfTile, fine, fineMask, u.fluidRefine,
                             u.fluidBlocksX, u.fluidBlocksY, u.fluidCell, int3(u.fluidNx, u.fluidNy, u.fluidNz),
                             u.fluidAirModel, u.fluidGamma, u.ambientPressure);
}

// Eigenvalues and eigenvectors (columns) of a symmetric matrix by cyclic Jacobi rotations.
static inline void symmetricEigen(float3x3 a, thread float3 &values, thread float3x3 &vectors) {
    float3x3 v = float3x3(1.0f);
    for (int sweep = 0; sweep < 5; ++sweep) {
        for (int pair = 0; pair < 3; ++pair) {
            int p = pair == 2 ? 1 : 0;
            int q = pair == 0 ? 1 : 2;
            float apq = a[q][p];
            if (fabs(apq) <= 1e-9f * (fabs(a[p][p]) + fabs(a[q][q])) + 1e-30f) {
                continue;
            }
            float theta = (a[q][q] - a[p][p]) / (2.0f * apq);
            float t = (theta >= 0.0f ? 1.0f : -1.0f) / (fabs(theta) + sqrt(theta * theta + 1.0f));
            float c = 1.0f / sqrt(t * t + 1.0f);
            float sn = t * c;
            float3x3 rotation = float3x3(1.0f);
            rotation[p][p] = c;
            rotation[q][q] = c;
            rotation[q][p] = sn;
            rotation[p][q] = -sn;
            a = transpose(rotation) * a * rotation;
            v = v * rotation;
        }
    }
    values = float3(a[0][0], a[1][1], a[2][2]);
    vectors = v;
}

// Tensile stress of concrete on its envelope, at the largest strain it has reached. `increase`
// is the dynamic increase factor: it raises the strength without changing the stiffness.
static inline float tensionEnvelope(float history, float increase, constant MaterialParameters &m) {
    float onset = m.crackOnset * increase;
    return history <= onset ? m.youngsModulus * history
                            : m.tensileStrength * increase * exp(-(history - onset) / m.crackSoftening);
}

// A second crack forms where the tension has turned more than 30 degrees from every crack axis.
constant float secondCrackCosine = 0.8660254f;

// The second crack's opening, as a strain across it, after a step in which the concrete beside
// it would carry `trial` across it with the crack opened to `opened`. The crack carries the
// tension law's stress for its opening: softening exponentially from the tensile strength as it
// opens, over the crack band (the same fracture energy as the first crack), and unloading
// along a straight line to the residual opening, below which it is shut. The concrete's
// stiffness across the crack, `stiffness`, relates the two: opening by d lowers the stress by
// about stiffness * d.
static inline float secondCrackOpening(float trial, float opened, float reached, float stiffness, float increase,
                                       constant MaterialParameters &m) {
    float strength = m.tensileStrength * increase;
    float softening = m.crackSoftening + 0.5f * m.crackOnset;
    auto envelope = [&](float e) { return strength * exp(-e / softening); };
    float drive = trial + stiffness * opened;  // the stress across it were it shut
    if (reached > 0.0f) {
        float residual = m.crackResidual * reached;
        float slope = envelope(reached) / (reached - residual);
        float e = (drive + slope * residual) / (stiffness + slope);
        if (e <= reached) {
            return max(e, residual);
        }
    } else if (drive <= strength) {
        return 0.0f;
    }
    // Opening further: drive - stiffness * e = envelope(e), by Newton's method from `reached`.
    float e = reached;
    for (int n = 0; n < 4; ++n) {
        float g = drive - stiffness * e - envelope(e);
        float slope = -stiffness + envelope(e) / softening;
        e = max(e - g / slope, reached);
    }
    return e;
}

// Strain at which a crack that has opened to `history` carries no stress. Fragments and
// misfit between the faces stop a crack closing completely: a fixed fraction of the crack's
// inelastic opening is left behind, as in the concrete damaged plasticity model.
static inline float crackResidual(float history, float increase, constant MaterialParameters &m) {
    if (history <= m.crackOnset * increase) {
        return 0.0f;
    }
    return m.crackResidual * (history - tensionEnvelope(history, increase, m) / m.youngsModulus);
}

// Uniaxial tensile stress of concrete at strain `strain`, having previously reached `history`.
// Unloading and reloading follow the straight line between the envelope and the residual strain.
static inline float concreteTension(float strain, float history, float residual, float increase,
                                    constant MaterialParameters &m) {
    if (history <= 0.0f) {
        return 0.0f;
    }
    return tensionEnvelope(history, increase, m) * max(strain - residual, 0.0f) / (history - residual);
}

// The residual opening a crack keeps, as a strain: it follows `crackResidual` of the crack's
// history, but never rises past the plane's own strain `uniaxial`. A diagonal crack is shared
// between the planes it cuts across, and raises their histories even where one of them is
// closed and its faces bear on each other; a residual rising with it would push those faces
// apart from nothing, putting energy into the solid at every turn.
static inline float settledResidual(float stored, float history, float uniaxial, float increase,
                                    constant MaterialParameters &m) {
    return max(stored, min(crackResidual(history, increase, m), uniaxial));
}

// Strains at which concrete in compression reaches its peak and its residual, for strength
// factor `increase` (strain rate) and confinement factor `confinement` (1 when unconfined).
// Confined concrete is stronger and far more ductile: the strain at peak grows five times as
// fast as the strength (Mander, Priestley and Park, 1988).
static inline float2 crushStrains(float increase, float confinement, constant MaterialParameters &m) {
    float ductility = 1.0f + 5.0f * (confinement - 1.0f);
    float peak = m.crushPeak * increase * ductility;
    return float2(peak, peak + (m.crushEnd - m.crushPeak) * ductility);
}

// Uniaxial compressive stress (negative) at compressive strain magnitude `strain`, having
// previously reached `history`. The rising branch of the envelope keeps the elastic stiffness
// at the origin whatever the confinement; unconfined, it is the usual parabola.
//
// Unloading leaves a permanent strain, so crushed concrete does not spring back to where it
// started: the stress falls linearly to zero at the plastic strain of Karsan and Jirsa (1969),
// eps_p / eps_c = 0.145 (eps_un / eps_c)^2 + 0.13 (eps_un / eps_c), never more steeply than
// elastic unloading, and reloading retraces the same line. Between that strain and zero the
// concrete carries nothing: crushed concrete has lost its tensile strength. (Measuring tension
// from the permanent strain instead was tried, and made slabs near their limit far more
// fragile, because concrete that sprang back then counted as cracked.)
// Compressive stress magnitude on the envelope at the largest compressive strain reached,
// `history`. Past the peak, the softening follows `softening`: the element's own history, or
// the average over its neighbourhood when crushing is nonlocal.
static inline float compressionEnvelope(float history, float softening, float increase, float confinement,
                                        constant MaterialParameters &m) {
    float strength = m.compressiveStrength * increase * confinement;
    float2 limits = crushStrains(increase, confinement, m);
    if (history <= limits.x) {
        float exponent = m.youngsModulus * limits.x / strength;
        // Rounding can put the ratio a hair above 1, and a fractional power of a negative
        // number is NaN.
        return strength * (1.0f - pow(max(1.0f - history / limits.x, 0.0f), exponent));
    }
    float fraction = clamp((softening - limits.x) / (limits.y - limits.x), 0.0f, 1.0f);
    return mix(strength, 0.2f * strength, fraction);
}

// Permanent compressive strain left by unloading from `history` (Karsan and Jirsa).
static inline float crushResidual(float history, float softening, float increase, float confinement,
                                  constant MaterialParameters &m) {
    float peak = crushStrains(increase, confinement, m).x;
    float ratio = history / peak;
    float plastic = peak * (0.145f * ratio * ratio + 0.13f * ratio);
    float envelope = compressionEnvelope(history, softening, increase, confinement, m);
    return clamp(plastic, 0.0f, max(history - envelope / m.youngsModulus, 0.0f));
}

static inline float concreteCompression(float strain, float history, float softening, float increase,
                                        float confinement, constant MaterialParameters &m) {
    float envelope = compressionEnvelope(history, softening, increase, confinement, m);
    if (strain >= history) {
        return -envelope;
    }
    float plastic = crushResidual(history, softening, increase, confinement, m);
    return strain <= plastic ? 0.0f : -envelope * (strain - plastic) / (history - plastic);
}

// Static yield stress of the reinforcement at accumulated plastic strain `plastic`, and the
// slope of its hardening curve there.
static inline float steelYield(float plastic, constant MaterialParameters &m, thread float &slope) {
    for (uint n = 1; n < m.steelPoints; ++n) {
        if (plastic <= m.steelStrain[n]) {
            slope = (m.steelStress[n] - m.steelStress[n - 1]) / max(m.steelStrain[n] - m.steelStrain[n - 1], 1e-9f);
            return m.steelStress[n - 1] + slope * (plastic - m.steelStrain[n - 1]);
        }
    }
    slope = 0.0f;
    return m.steelStress[m.steelPoints - 1];
}

// Cyclic reinforcement: the Menegotto-Pinto curve with the constants of Filippou, Popov and
// Bertero (1983), R0 = 20, a1 = 18.5, a2 = 0.15, and kinematic yield asymptotes. After yielding
// one way, a bar loaded the other way softens long before it reaches its yield stress there
// (the Bauschinger effect), the more so the larger its earlier plastic excursion.
constant float barCurvature = 20.0f;
constant float barCurvatureLoss = 18.5f;
constant float barCurvatureScale = 0.15f;

// Starts a new branch heading in direction `direction` (+1 tension, -1 compression) from the
// extreme point of the last one.
static inline void reverseBar(device BarHistory &bar, float direction, float yield,
                              constant MaterialParameters &m) {
    float modulus = m.steelModulus;
    float b = m.steelHardeningRatio;
    bar.reversalStrain = bar.extremeStrain;
    bar.reversalStress = bar.extremeStress;
    bar.maxStrain = max(bar.maxStrain, bar.reversalStrain);
    bar.minStrain = min(bar.minStrain, bar.reversalStrain);
    // Intersection of the elastic line from the reversal point with the asymptote
    // stress = direction * yield + b * modulus * (strain - direction * yield / modulus).
    float span = (direction * yield * (1.0f - b) - (bar.reversalStress - b * modulus * bar.reversalStrain))
        / (modulus * (1.0f - b));
    if (span * direction < 0.1f * yield / modulus) {
        span = direction * 0.1f * yield / modulus;
    }
    bar.targetStrain = bar.reversalStrain + span;
    bar.targetStress = bar.reversalStress + modulus * span;
}

static inline float barStress(device const BarHistory &bar, float strain, constant MaterialParameters &m) {
    float span = bar.targetStrain - bar.reversalStrain;
    float x = (strain - bar.reversalStrain) / span;
    float earlier = span > 0.0f ? bar.maxStrain : bar.minStrain;
    float yieldStrain = m.steelStress[0] / m.steelModulus;
    float excursion = fabs(earlier - bar.targetStrain) / yieldStrain;
    float r = barCurvature - barCurvatureLoss * excursion / (barCurvatureScale + excursion);
    float b = m.steelHardeningRatio;
    float y = b * x + (1.0f - b) * x / pow(1.0f + pow(fabs(x), r), 1.0f / r);
    return bar.reversalStress + y * (bar.targetStress - bar.reversalStress);
}

// Stress in bars that have yielded at least once, at fibre strain `strain`. `plastic` is the
// plastic strain on the monotonic curve until the first reversal, and the inelastic strain on
// the cyclic branches after it; it is never left at exactly zero.
static inline float cycleBar(device BarHistory &bar, float strain, thread float &plastic, float yield,
                             float hardening, float initialYield, constant MaterialParameters &m) {
    float modulus = m.steelModulus;
    // Reversals smaller than a tenth of the yield strain are elastic wobbles, not cycles.
    float tolerance = 0.1f * m.steelStress[0] / modulus;
    float stress;
    if (bar.targetStrain == bar.reversalStrain) {
        // Still on the measured monotonic curve.
        stress = modulus * (strain - plastic);
        if (fabs(stress) > yield) {
            float increment = (fabs(stress) - yield) / max(modulus + hardening, 0.1f * modulus);
            plastic += stress > 0.0f ? increment : -increment;
            stress = modulus * (strain - plastic);
        }
        float direction = sign(plastic);
        if ((strain - bar.extremeStrain) * direction >= 0.0f) {
            bar.extremeStrain = strain;
            bar.extremeStress = stress;
            return stress;
        }
        if ((bar.extremeStrain - strain) * direction <= tolerance) {
            return stress;
        }
        reverseBar(bar, -direction, initialYield, m);
    }
    float direction = sign(bar.targetStrain - bar.reversalStrain);
    if ((bar.extremeStrain - strain) * direction > tolerance) {
        reverseBar(bar, -direction, initialYield, m);
        direction = -direction;
    }
    stress = barStress(bar, strain, m);
    if ((strain - bar.extremeStrain) * direction >= 0.0f) {
        bar.extremeStrain = strain;
        bar.extremeStress = stress;
    }
    plastic = strain - stress / modulus;
    if (plastic == 0.0f) {
        plastic = 1e-12f;
    }
    return stress;
}

// Dynamic increase factors at effective strain rate `rate` (1/s).
// Concrete in compression: CEB-FIP Model Code 1990. In tension: Malvar and Ross (1998).
// Reinforcement: Malvar and Crawford (1998).
static inline float compressionIncrease(float rate, constant MaterialParameters &m) {
    if (m.concreteRateCompression <= 0.0f) {
        return 1.0f;
    }
    float exponent = 1.026f * m.concreteRateCompression;
    if (rate <= 30.0f) {
        return pow(max(rate, 30e-6f) / 30e-6f, exponent);
    }
    return pow(10.0f, 6.156f * m.concreteRateCompression - 2.0f) * pow(rate / 30e-6f, 1.0f / 3.0f);
}

static inline float tensionIncrease(float rate, constant MaterialParameters &m) {
    if (m.concreteRateTension <= 0.0f) {
        return 1.0f;
    }
    if (rate <= 1.0f) {
        return pow(max(rate, 1e-6f) / 1e-6f, m.concreteRateTension);
    }
    return pow(10.0f, 6.0f * m.concreteRateTension - 2.0f) * pow(rate / 1e-6f, 1.0f / 3.0f);
}

// Pressure of the applied-load table at time `time`, interpolated linearly.
static inline float tablePressure(const device float2 *table, uint count, float time) {
    if (count == 0 || time <= table[0].x) {
        return count == 0 ? 0.0f : table[0].y;
    }
    for (uint n = 1; n < count; ++n) {
        if (time <= table[n].x) {
            float span = max(table[n].x - table[n - 1].x, 1e-12f);
            return mix(table[n - 1].y, table[n].y, (time - table[n - 1].x) / span);
        }
    }
    return table[count - 1].y;
}

// Updates the stress of every active element and stores the forces it exerts on its nodes.
// Stress in a set of smeared bars stretched along them by Green-Lagrange strain `green`, with
// plastic strain `plastic` (updated) and cyclic history `bar`: the measured curve while loaded
// one way, the cyclic law once reversed, with the strength raised by the strain rate. `root` is
// the bars' stretch, and `yield` their current yield stress.
static inline float smearedBar(float green, thread float &plastic, device BarHistory &bar, float strainRate,
                               constant MaterialParameters &m, thread float &root, thread float &yield) {
    // Stretch of the fibre from its Green-Lagrange strain, without cancellation.
    root = sqrt(max(1.0f + 2.0f * green, 1e-6f));
    float fibre = 2.0f * green / (1.0f + root);
    float stress = m.steelModulus * (fibre - plastic);
    // The rate factor falls from its value at yield to its (smaller) value at ultimate.
    float accumulated = fabs(plastic);
    float slope;
    yield = steelYield(accumulated, m, slope);
    float first = m.steelStress[0];
    float top = m.steelStress[m.steelPoints - 1];
    float along = clamp((yield - first) / max(top - first, 1.0f), 0.0f, 1.0f);
    float rate = max(strainRate, 1e-4f) / 1e-4f;
    float factor = mix(pow(rate, m.steelRateYield), pow(rate, m.steelRateUltimate), along);
    yield *= factor;
    if (plastic == 0.0f) {
        // Not yet yielded: elastic, and no history to keep.
        if (fabs(stress) > yield) {
            float increment = (fabs(stress) - yield) / max(m.steelModulus + slope * factor, 0.1f * m.steelModulus);
            plastic = stress > 0.0f ? increment : -increment;
            stress = m.steelModulus * (fibre - plastic);
        }
    } else {
        float inelastic = plastic;
        stress = cycleBar(bar, fibre, inelastic, yield, slope * factor, first * pow(rate, m.steelRateYield), m);
        plastic = inelastic;
    }
    return stress;
}

kernel void structureElements(device ElementState *states [[buffer(0)]],
                              device ElementForces *forces [[buffer(1)]],
                              device uchar *flags [[buffer(2)]],
                              const device StructureNode *nodes [[buffer(3)]],
                              const device Cell *fluid [[buffer(4)]],
                              const device uchar *fluidMask [[buffer(5)]],
                              const device StepControl &control [[buffer(6)]],
                              constant StructureUniforms &u [[buffer(7)]],
                              const device uint *elementList [[buffer(8)]],
                              device uint *failureGate [[buffer(9)]],
                              const device ElementSteel *steel [[buffer(10)]],
                              const device float2 *loadTable [[buffer(11)]],
                              device BarHistory *bars [[buffer(12)]],
                              device float4 *crushOut [[buffer(13)]],
                              const device float4 *crushBefore [[buffer(14)]],
                              constant MaterialParameters *materials [[buffer(15)]],
                              const device uchar *materialIndex [[buffer(16)]],
                              device float4 *plasticOut [[buffer(17)]],
                              const device float4 *plasticBefore [[buffer(18)]],
                              const device uint *cellElement [[buffer(19)]],
                              const device uint *nodeMap [[buffer(20)]],
                              const device int *patchOfTile [[buffer(21)]],
                              const device Cell *fineAir [[buffer(22)]],
                              const device uchar *fineAirMask [[buffer(23)]],
                              uint threadIndex [[thread_position_in_grid]]) {
    // Threads run over the list of elements the body started with, not the whole lattice.
    bool active;
    float dt = structureStep(u, control, active);
    if (!active) {
        return;
    }
    // Element data is stored compactly, one entry per element the body started with, in the
    // order of `elementList`; `element` is the lattice cell, which flags and neighbours use.
    uint compact = threadIndex;
    uint element = elementList[compact];
    if (flags[element] != elementActive) {
        return;
    }
    uint3 tid = uint3(element % u.ex, (element / u.ex) % u.ey, element / (u.ex * u.ey));
    uchar own = singleMaterial ? 0 : materialIndex[compact];
    constant MaterialParameters &m = materials[singleMaterial ? 0u : min(uint(own), maxMaterials - 1)];

    uint nodesX = u.ex + 1;
    uint nodesY = u.ey + 1;
    float3 origin = float3(u.originX, u.originY, u.originZ);
    float3 x[8];
    float3 v[8];
    // Displacement gradient at the centre, built from displacements alone so that small strains
    // are not lost in the rounding of absolute positions.
    float3 g0 = float3(0.0f);
    float3 g1 = float3(0.0f);
    float3 g2 = float3(0.0f);
    for (uint a = 0; a < 8; ++a) {
        uint3 corner = tid + uint3(a & 1u, (a >> 1) & 1u, (a >> 2) & 1u);
        StructureNode node = nodes[nodeMap[corner.x + nodesX * (corner.y + nodesY * corner.z)]];
        float3 displacement = float3(node.displacement);
        x[a] = origin + float3(corner) * u.h + displacement;
        v[a] = node.velocity;
        float3 s = cornerSign(a);
        g0 += displacement * s.x;
        g1 += displacement * s.y;
        g2 += displacement * s.z;
    }

    // Jacobian of the isoparametric map at the element centre; its columns are dx/dxi_j.
    float3 c0 = float3(0.0f);
    float3 c1 = float3(0.0f);
    float3 c2 = float3(0.0f);
    for (uint a = 0; a < 8; ++a) {
        float3 s = cornerSign(a);
        c0 += x[a] * s.x;
        c1 += x[a] * s.y;
        c2 += x[a] * s.z;
    }
    c0 *= 0.125f;
    c1 *= 0.125f;
    c2 *= 0.125f;
    float detJ = dot(c0, cross(c1, c2));
    float volume = 8.0f * detJ;
    float referenceVolume = u.h * u.h * u.h;

    ElementState state = states[compact];
    bool eroded = volume < u.minVolumeRatio * referenceVolume;

    // Shape-function gradients b_a = J^-T xi_a / 8.
    float3 r0 = cross(c1, c2) / detJ;
    float3 r1 = cross(c2, c0) / detJ;
    float3 r2 = cross(c0, c1) / detJ;
    float3 b[8];
    float3 lx = float3(0.0f);
    float3 ly = float3(0.0f);
    float3 lz = float3(0.0f);
    for (uint a = 0; a < 8; ++a) {
        float3 s = cornerSign(a);
        b[a] = (r0 * s.x + r1 * s.y + r2 * s.z) * 0.125f;
        lx += v[a].x * b[a];
        ly += v[a].y * b[a];
        lz += v[a].z * b[a];
    }

    // Rate of deformation and spin.
    float dxx = lx.x;
    float dyy = ly.y;
    float dzz = lz.z;
    float dxy = 0.5f * (lx.y + ly.x);
    float dyz = 0.5f * (ly.z + lz.y);
    float dzx = 0.5f * (lz.x + lx.z);
    float wxy = 0.5f * (lx.y - ly.x);
    float wyz = 0.5f * (ly.z - lz.y);
    float wxz = 0.5f * (lx.z - lz.x);
    float3x3 spin = float3x3(float3(0.0f, -wxy, -wxz), float3(wxy, 0.0f, -wyz), float3(wxz, wyz, 0.0f));

    float trace = dxx + dyy + dzz;
    float sxx;
    float syy;
    float szz;
    float sxy;
    float syz;
    float szx;
    // Tensile stress the element can still carry, which caps its hourglass (bending) forces.
    float capacity;

    if (m.materialModel == 0) {
        // Jaumann rotation of the old stress, then the elastic trial increment.
        float3x3 sigma = float3x3(float3(state.stress[0], state.stress[3], state.stress[5]),
                                  float3(state.stress[3], state.stress[1], state.stress[4]),
                                  float3(state.stress[5], state.stress[4], state.stress[2]));
        float3x3 rotation = spin * sigma - sigma * spin;
        sxx = sigma[0][0] + dt * (rotation[0][0] + m.lambda * trace + 2.0f * m.mu * dxx);
        syy = sigma[1][1] + dt * (rotation[1][1] + m.lambda * trace + 2.0f * m.mu * dyy);
        szz = sigma[2][2] + dt * (rotation[2][2] + m.lambda * trace + 2.0f * m.mu * dzz);
        sxy = sigma[1][0] + dt * (rotation[1][0] + 2.0f * m.mu * dxy);
        syz = sigma[2][1] + dt * (rotation[2][1] + 2.0f * m.mu * dyz);
        szx = sigma[0][2] + dt * (rotation[0][2] + 2.0f * m.mu * dzx);

        // J2 plasticity: radial return onto the yield surface.
        float mean = (sxx + syy + szz) / 3.0f;
        float devX = sxx - mean;
        float devY = syy - mean;
        float devZ = szz - mean;
        float j2 = 0.5f * (devX * devX + devY * devY + devZ * devZ) + sxy * sxy + syz * syz + szx * szx;
        float equivalent = sqrt(3.0f * j2);
        float yield = m.yieldStress + m.hardening * state.plasticStrain;
        if (equivalent > yield) {
            float increment = (equivalent - yield) / (3.0f * m.mu + m.hardening);
            float scale = (yield + m.hardening * increment) / equivalent;
            devX *= scale;
            devY *= scale;
            devZ *= scale;
            sxy *= scale;
            syz *= scale;
            szx *= scale;
            state.plasticStrain += increment;
        }
        sxx = devX + mean;
        syy = devY + mean;
        szz = devZ + mean;
        eroded = eroded || state.plasticStrain >= m.failureStrain;
        capacity = m.yieldStress + m.hardening * state.plasticStrain;
        state.display = state.plasticStrain / m.failureStrain;
    } else {
        // Green-Lagrange strain from the displacement gradient H = du/dX, in the lattice axes.
        float3x3 gradient = float3x3(g0, g1, g2) * (0.25f / u.h);
        float3x3 latticeStrain = 0.5f * (gradient + transpose(gradient) + transpose(gradient) * gradient);
        // The bars lie along the lattice axes and are strained along them.
        float3 barStrain = float3(latticeStrain[0][0], latticeStrain[1][1], latticeStrain[2][2]);
        // With oriented cracks the concrete works in its crack axes (columns of `frame`), set
        // when it first cracks; before that, and without them, in the lattice axes. Axes that
        // still turn with the principal directions are stored with the sign bit of w set (q and
        // -q are the same rotation).
        float3x3 frame = float3x3(1.0f);
        bool framed = false;
        bool turning = false;
        if (u.orientedCracks != 0) {
            float4 stored = float4(state.crackFrame);
            if (any(stored != 0.0f)) {
                frame = rotationOf(normalize(stored));
                framed = true;
                turning = u.orientedCracks == 2 && signbit(stored.w);
            }
        }
        float3x3 strain = transpose(frame) * latticeStrain * frame;
        // A second crack's opening is not the concrete's strain (see below).
        float4 secondCrack = float4(state.secondCrack);
        if (u.secondCracks != 0 && framed && !turning && secondCrack.w != 0.0f) {
            float3 normal = normalize(secondCrack.xyz);
            strain -= state.secondOpening * float3x3(normal * normal.x, normal * normal.y, normal * normal.z);
        }
        float3 normalStrain = float3(strain[0][0], strain[1][1], strain[2][2]);

        // Strength rises with strain rate; a running average keeps element-scale noise out.
        float instantaneous = sqrt((2.0f / 3.0f) * (dxx * dxx + dyy * dyy + dzz * dzz
                                                     + 2.0f * (dxy * dxy + dyz * dyz + dzx * dzx)));
        state.strainRate += clamp(dt * u.rateFilter, 0.0f, 1.0f) * (instantaneous - state.strainRate);
        float3 history = float3(state.crackStrain);
        float worst = max(history.x, max(history.y, history.z));
        // Once a crack has formed, strain gathers in it at a rate that depends on the element
        // size and says nothing about the material, so the tensile factor is frozen at the value
        // it had when the element first cracked.
        float tensionFactor = state.crackingFactor;
        if (tensionFactor <= 0.0f) {
            tensionFactor = tensionIncrease(state.strainRate, m);
            if (worst > m.crackOnset * tensionFactor) {
                state.crackingFactor = tensionFactor;
            }
        }
        float compressionFactor = compressionIncrease(state.strainRate, m);
        float onset = m.crackOnset * tensionFactor;

        // Equivalent uniaxial strains along the axes: in the linear range these reproduce
        // isotropic elasticity. The Poisson coupling fades as the concrete cracks, since an open
        // crack's strain is not elastic strain and must not stretch the directions alongside it.
        float poisson = 0.5f * m.lambda / (m.lambda + m.mu);
        if (worst > onset) {
            poisson *= tensionEnvelope(worst, tensionFactor, m) / (m.youngsModulus * worst);
        }

        // Cracks are smeared over the three lattice planes, each with its own history, so that
        // cracking across one direction leaves the others intact. A diagonal crack (from shear)
        // is found from the principal values of the strain with the Poisson effect taken out,
        // which is the elastic stress over E: a Rankine criterion. (Principal values of the
        // strain itself would count the sideways swelling of squeezed concrete as cracking.)
        // It is shared between the planes it cuts across, in proportion to the squared direction
        // cosines.
        float3x3 effective = strain * (1.0f / (1.0f + poisson));
        float dilation = poisson * (strain[0][0] + strain[1][1] + strain[2][2])
            / ((1.0f + poisson) * (1.0f - 2.0f * poisson));
        effective[0][0] += dilation;
        effective[1][1] += dilation;
        effective[2][2] += dilation;
        float3 principal;
        float3x3 axes;
        symmetricEigen(effective, principal, axes);
        bool cracking = max(principal.x, max(principal.y, principal.z)) > onset;
        if (u.orientedCracks != 0 && ((!framed && cracking) || turning)) {
            // The crack axes become the principal axes of this strain: at the first crack, and
            // every step while they still turn. Turning, each axis takes the principal direction
            // nearest to it, so that each plane's history stays with its own direction.
            float3x3 aligned = axes;
            float3 values = principal;
            if (framed) {
                bool used[3] = {false, false, false};
                for (int i = 0; i < 3; ++i) {
                    int best = -1;
                    for (int k = 0; k < 3; ++k) {
                        if (!used[k] && (best < 0 || fabs(axes[k][i]) > fabs(axes[best][i]))) {
                            best = k;
                        }
                    }
                    used[best] = true;
                    aligned[i] = axes[best][i] < 0.0f ? -axes[best] : axes[best];
                    values[i] = principal[best];
                }
            }
            if (determinant(aligned) < 0.0f) {
                aligned[2] = -aligned[2];
            }
            frame = frame * aligned;
            framed = true;
            strain = transpose(aligned) * strain * aligned;
            effective = transpose(aligned) * effective * aligned;
            normalStrain = float3(strain[0][0], strain[1][1], strain[2][2]);
            principal = values;
            axes = float3x3(1.0f);
            // They stop turning once a crack has opened, its tension softened through a tenth of
            // the softening strain, or once the concrete has crushed past its peak: a crushed
            // axis turning with the stress would carry its crushing to directions that never saw
            // it. (With fixed cracks, at once.) Left turning through the whole softening, cracks
            // in a slab held down at its supports followed the stress round in the rebound
            // until no axis carried tension, and the slab came apart.
            float3 crushed = float3(state.crushStrain);
            bool fix = u.orientedCracks == 1 || worst > onset + 0.1f * m.crackSoftening
                || max(crushed.x, max(crushed.y, crushed.z)) > m.crushPeak;
            float4 q = quaternionOf(frame);
            q = (q.w < 0.0f) == fix ? -q : q;
            if (q.w == 0.0f) {
                q.w = fix ? 0.0f : -0.0f;
            }
            state.crackFrame = packed_half4(half4(q));
        }
        for (int i = 0; i < 3; ++i) {
            float3 weight = axes[i] * axes[i];
            float seen = dot(weight, history);
            if (principal[i] > seen && principal[i] > onset) {
                history += (principal[i] - seen) * weight / dot(weight, weight);
            }
        }

        float volumetric = normalStrain.x + normalStrain.y + normalStrain.z;
        float3 uniaxial = ((1.0f - 2.0f * poisson) * normalStrain + poisson * volumetric)
            / ((1.0f + poisson) * (1.0f - 2.0f * poisson));
        history = max(history, uniaxial);
        state.crackStrain = history;
        float crack = max(history.x, max(history.y, history.z));
        // A crack keeps a residual opening, and compression develops only once that has closed.
        float3 stored = float3(state.crackResidual);
        float3 residual = float3(settledResidual(stored.x, history.x, uniaxial.x, tensionFactor, m),
                                 settledResidual(stored.y, history.y, uniaxial.y, tensionFactor, m),
                                 settledResidual(stored.z, history.z, uniaxial.z, tensionFactor, m));
        state.crackResidual = residual;
        float3 squeeze = residual - uniaxial;  // compressive strain, past any crack's residual
        float3 crush = max(float3(state.crushStrain), squeeze);
        // Softening past the peak follows the crushing averaged over the intact elements within
        // `crushRadius` (as of the previous substep), so that it cannot collapse into one layer
        // of elements. Only elements already past the unconfined peak need the average.
        float3 softening = crush;
        if (m.crushRadius > 0) {
            crushOut[compact] = float4(crush, 0.0f);
            if (any(crush > m.crushPeak)) {
                // The neighbourhood is sampled at no more than nine points along each axis, so
                // the cost does not grow with refinement; up to a radius of four elements every
                // element is visited.
                int r = int(m.crushRadius);
                int samples = min(r, 4);
                int3 dims = int3(u.ex, u.ey, u.ez);
                float3 sum = float3(0.0f);
                float count = 0.0f;
                for (int c = -samples; c <= samples; ++c) {
                    int z = int(tid.z) + (c * r) / samples;
                    if (z < 0 || z >= dims.z) {
                        continue;
                    }
                    for (int b = -samples; b <= samples; ++b) {
                        int y = int(tid.y) + (b * r) / samples;
                        if (y < 0 || y >= dims.y) {
                            continue;
                        }
                        for (int a = -samples; a <= samples; ++a) {
                            int x = int(tid.x) + (a * r) / samples;
                            if (x < 0 || x >= dims.x) {
                                continue;
                            }
                            int other = x + dims.x * (y + dims.y * z);
                            uchar flag = flags[other];
                            uint neighbour = cellElement[other];
                            // Crushing is averaged within one material only.
                            if ((flag == elementActive || flag == elementFailing)
                                && (singleMaterial || materialIndex[neighbour] == own)) {
                                sum += crushBefore[neighbour].xyz;
                                count += 1.0f;
                            }
                        }
                    }
                }
                softening = count > 0.0f ? sum / count : crush;
            }
        }
        state.crushStrain = crush;
        state.plasticStrain = max(crush.x, max(crush.y, crush.z));

        // Normal stresses follow the uniaxial curves. An open crack unloads to its residual
        // strain, after which its faces bear on each other and compression is recovered.
        //
        // Concrete squeezed from the sides is stronger: each axis gains 4.1 times the smaller of
        // the compressive stresses the other two axes can supply (Richart, Brandtzaeg and Brown,
        // 1928). The lateral stress is estimated as elastic, capped at the unconfined strength.
        float unconfined = m.compressiveStrength * compressionFactor;
        // The factor follows its target through the same running average as the strain rate:
        // applied instantly, the coupling between axes would be several times stiffer than the
        // elastic solid and would outrun the explicit time step.
        float3 lateral = clamp(squeeze * m.youngsModulus, 0.0f, unconfined);
        float3 gain = float3(state.confinementGain);
        float blend = clamp(dt * u.rateFilter, 0.0f, 1.0f);
        float3 confinement = float3(1.0f);
        float3 normalStress;
        float crushed = 0.0f;
        bool pulverised = false;
        for (int j = 0; j < 3; ++j) {
            if (squeeze[j] <= 0.0f) {
                normalStress[j] = concreteTension(uniaxial[j], history[j], residual[j], tensionFactor, m);
                continue;
            }
            float support = min(lateral[(j + 1) % 3], lateral[(j + 2) % 3]);
            gain[j] += blend * (m.confinement * support / unconfined - gain[j]);
            confinement[j] = 1.0f + gain[j];
            normalStress[j] = concreteCompression(squeeze[j], crush[j], softening[j], compressionFactor,
                                                  confinement[j], m);
            float2 limits = crushStrains(compressionFactor, confinement[j], m);
            float driving = m.crushRadius > 0 ? min(squeeze[j], softening[j]) : squeeze[j];
            crushed = max(crushed, clamp((driving - limits.x) / (limits.y - limits.x), 0.0f, 1.0f));
            pulverised = pulverised || driving >= limits.y + m.crushErosion * (limits.y - limits.x);
        }
        state.confinementGain = gain;

        // Shear across cracked planes is carried by aggregate interlock, which weakens as the
        // crack widens (Vecchio and Collins, modified compression field theory), and by the
        // bars that cross the crack.
        float3 barRatio = float3(steel[compact].ratio);
        float3 shearStress;  // xy, yz, zx
        for (int pair = 0; pair < 3; ++pair) {
            int a = pair;
            int b = (pair + 1) % 3;
            float engineering = 2.0f * strain[b][a];
            float stress = m.mu * engineering;
            float opened = max(history[a], history[b]) - onset;
            if (opened > 0.0f) {
                float width = opened * m.crackBand;
                float interlock = m.interlockStrength * tensionFactor / (0.31f + m.interlockWidthScale * width);
                // The wider-open of the two planes is the crack that slides; the bars along its
                // normal cross it.
                int across = history[a] >= history[b] ? a : b;
                // Bars along lattice axis j cross a crack of unit normal n in proportion to |n_j|;
                // the most nearly crossing set ruptures if kinked too far.
                float3 normal = frame[across];
                float crossing = 0.0f;
                int crossingAxis = 0;
                for (int j = 0; j < 3; ++j) {
                    if (fabs(state.steelPlastic[j]) < 1e8f) {
                        crossing += barRatio[j] * fabs(normal[j]);
                    }
                    if (barRatio[j] * fabs(normal[j]) > barRatio[crossingAxis] * fabs(normal[crossingAxis])) {
                        crossingAxis = j;
                    }
                }
                uint inclinedSet = steel[compact].inclinedAxes;
                if (inclinedSet != 0u && fabs(state.inclinedPlastic) < 1e8f) {
                    crossing += float(steel[compact].inclined) * fabs(dot(inclinedDirection(inclinedSet), normal));
                }
                if (crossing > 0.0f) {
                    // Dowel action: each bar resists 1.3 d^2 sqrt(fc fy) of sliding (Rasmussen,
                    // 1963), which over the bars crossing a unit area is 1.65 rho sqrt(fc fy).
                    float yield = m.steelStress[0];
                    interlock += 1.65f * crossing * sqrt(m.compressiveStrength * yield);
                    // Kinking: slid by s, a bar debonded over a length L either side of the crack
                    // is stretched to sqrt(1 + (s/L)^2) - 1, and its tension leans along the
                    // slide. Stretched past rupture by it, the bars there have broken.
                    float slide = fabs(engineering) * u.h / max(m.crackBand, u.h);
                    float stretch = sqrt(1.0f + slide * slide) - 1.0f;
                    float elastic = yield / m.steelModulus;
                    float plasticStretch = stretch - elastic;
                    if (plasticStretch > m.steelStrain[m.steelPoints - 1]) {
                        state.steelPlastic[crossingAxis] = 1e9f;  // ruptured for good
                    } else {
                        float slope;
                        float tension = stretch <= elastic ? m.steelModulus * stretch
                                                           : steelYield(plasticStretch, m, slope);
                        interlock += crossing * tension * slide / sqrt(1.0f + slide * slide);
                    }
                }
                stress = clamp(m.shearRetention * stress, -interlock, interlock);
            }
            shearStress[pair] = stress;
        }
        float3x3 material = float3x3(float3(normalStress.x, shearStress.x, shearStress.z),
                                     float3(shearStress.x, normalStress.y, shearStress.y),
                                     float3(shearStress.z, shearStress.y, normalStress.z));
        // A second crack. Once the crack axes are fixed, tension that turns away from them is
        // carried across the cracked planes by their shear, which aggregate interlock holds up
        // to more than the tensile strength: the stress locks, and a cracked element pulled at
        // 45 degrees to its crack keeps half its tensile strength however far it is stretched.
        // Where the concrete's principal tension passes its tensile strength more than 30
        // degrees from every crack axis, a second crack forms across it, fixed from then on. Its
        // opening is a strain of its own, taken out of the strain the rest of the concrete
        // sees (above), and set each step so that the concrete's stress across it is what the
        // crack carries at that opening (the multi-directional fixed crack of de Borst and
        // Nauta). This step's stress is corrected for the change in opening elastically; the
        // next step's sees it in full.
        if (u.secondCracks != 0 && framed && !turning) {
            float4 second = float4(state.secondCrack);
            if (second.w == 0.0f) {
                float3 values;
                float3x3 directions;
                symmetricEigen(material, values, directions);
                int major = values.x >= values.y ? (values.x >= values.z ? 0 : 2) : (values.y >= values.z ? 1 : 2);
                float3 normal = directions[major];
                float3 cosines = abs(normal);
                if (values[major] > m.tensileStrength * tensionFactor
                    && max(cosines.x, max(cosines.y, cosines.z)) < secondCrackCosine) {
                    second = float4(normal, 1.0f);
                    state.secondCrack = packed_half4(half4(second));
                    state.secondOpening = 0.0f;
                    state.secondHistory = 0.0f;
                }
            }
            if (second.w != 0.0f) {
                float3 normal = normalize(second.xyz);
                float stiffness = m.lambda + 2.0f * m.mu;
                float opened = state.secondOpening;
                float e = secondCrackOpening(dot(normal, material * normal), opened, state.secondHistory, stiffness,
                                             tensionFactor, m);
                state.secondOpening = e;
                state.secondHistory = max(state.secondHistory, e);
                float3x3 outer = float3x3(normal * normal.x, normal * normal.y, normal * normal.z);
                material -= (e - opened) * (m.lambda * float3x3(1.0f) + 2.0f * m.mu * outer);
                crack = max(crack, state.secondHistory + onset);
            }
        }
        if (framed) {
            material = frame * material * transpose(frame);
        }
        // Under very high pressure the pores collapse: the concrete's mean stress is never less
        // compressive than the compaction curve gives, whatever its strength laws say. Only
        // where it is confined, squeezed on every axis by at least a fifth of the most (as in
        // the uniaxial strain of a shock, a quarter): squeezed from one side alone, concrete
        // dilates as it crushes, which this model does not represent, so its volume change says
        // nothing about its pores.
        float mu = referenceVolume / volume - 1.0f;
        bool confined = max(normalStress.x, max(normalStress.y, normalStress.z))
            < 0.2f * min(normalStress.x, min(normalStress.y, normalStress.z));
        // It takes over only where the confined pressure passes the unconfined strength, beyond
        // which the strength laws above are not meant to go; below that they already describe
        // concrete squeezed by an ordinary blast (starting at the curve's own crushing
        // pressure, fc / 3, doubled the deflection of a wall 8 m from 500 kg).
        float bulk = m.lambda + 2.0f * m.mu / 3.0f;
        float crushPressure = m.compressiveStrength / 3.0f;
        float crushStrain = crushPressure / bulk;
        float crushVolume = crushStrain
            + (m.compressiveStrength - crushPressure) * (0.1f - crushStrain) / (0.8e9f - crushPressure);
        if (confined && mu > crushVolume) {
            state.compaction = max(state.compaction, mu);
        }
        // While confined, once it has passed that, an element follows the curve.
        // (Following it afterwards too, once the element was cracking and bending, pressed open
        // cracks shut and weakened a wall that had been briefly squeezed by the shock.)
        if (confined && mu > 0.0f && state.compaction > crushVolume) {
            float compacted = compactionPressure(mu, state.compaction, bulk, m.compressiveStrength);
            float pressure = -(material[0][0] + material[1][1] + material[2][2]) / 3.0f;
            if (compacted > pressure) {
                float shift = pressure - compacted;
                material[0][0] += shift;
                material[1][1] += shift;
                material[2][2] += shift;
            }
        }

        // Smeared reinforcement: bars along the lattice axes, strained with the element. They
        // follow the measured curve while loaded one way, and the cyclic law once reversed.
        float3 ratio = float3(steel[compact].ratio);
        float3 plastic = float3(state.steelPlastic);
        float3 intact = float3(0.0f);
        float steelCapacity = 0.0f;
        for (int j = 0; j < 3; ++j) {
            if (ratio[j] <= 0.0f || fabs(plastic[j]) > 1e8f) {
                continue;
            }
            float root;
            float yield;
            float own = plastic[j];
            float stress = smearedBar(barStrain[j], own, bars[4 * compact + uint(j)], state.strainRate, m, root, yield);
            plastic[j] = own;
            // A bar slips in its concrete either side of a crack, so it is strained by the crack's
            // opening spread over a debonded length, not over the one element the crack happens
            // to run through. Its stress follows its own strain, but it ruptures when its plastic
            // strain averaged along its axis over that length (from the previous substep's
            // neighbours that still carry bars that way) passes the rupture strain.
            // The window is exactly the debonded length: elements at its ends count in part.
            float spread = plastic[j];
            if (m.barReach > 0.0f) {
                int3 dims = int3(u.ex, u.ey, u.ez);
                int r = int(ceil(m.barReach - 0.5f));
                float sum = plastic[j];
                float weights = 1.0f;
                for (int offset = -r; offset <= r; ++offset) {
                    int3 cell = int3(tid);
                    cell[j] += offset;
                    if (offset == 0 || cell[j] < 0 || cell[j] >= dims[j]) {
                        continue;
                    }
                    int other = cell.x + dims.x * (cell.y + dims.y * cell.z);
                    uchar flag = flags[other];
                    uint compactOther = cellElement[other];
                    float neighbour = (flag == elementActive || flag == elementFailing)
                        ? plasticBefore[compactOther][j] : 0.0f;
                    float weight = clamp(m.barReach + 0.5f - float(abs(offset)), 0.0f, 1.0f);
                    if ((flag == elementActive || flag == elementFailing) && steel[compactOther].ratio[j] > 0.0f
                        && fabs(neighbour) < 1e8f) {
                        sum += weight * neighbour;
                        weights += weight;
                    }
                }
                spread = sum / weights;
            }
            if (fabs(spread) > m.steelStrain[m.steelPoints - 1]) {
                plastic[j] = 1e9f;  // ruptured for good
                continue;
            }
            intact[j] = 1.0f;
            steelCapacity += ratio[j] * yield;
            // Bar force per unit reference area, as a second Piola-Kirchhoff stress.
            material[j][j] += ratio[j] * stress / root;
        }
        state.steelPlastic = plastic;

        // Inclined bars, strained along their own direction, which ruptures by the same rule
        // with the debonded length measured along them (each diagonal step is an element's
        // diagonal).
        float inclinedRatio = float(steel[compact].inclined);
        uint inclinedAxes = steel[compact].inclinedAxes;
        float3 inclined = inclinedAxes != 0u ? inclinedDirection(inclinedAxes) : float3(0.0f);
        bool inclinedIntact = false;
        if (inclinedRatio > 0.0f && inclinedAxes != 0u && fabs(state.inclinedPlastic) < 1e8f) {
            float root;
            float yield;
            float own = state.inclinedPlastic;
            float stress = smearedBar(dot(inclined, latticeStrain * inclined), own, bars[4 * compact + 3u],
                                      state.strainRate, m, root, yield);
            float spread = own;
            if (m.barReach > 0.0f) {
                float reach = m.barReach * 0.70710678f;
                int r = int(ceil(reach - 0.5f));
                int3 step = int3(round(inclined * 1.41421356f));
                int3 dims = int3(u.ex, u.ey, u.ez);
                float sum = own;
                float weights = 1.0f;
                for (int offset = -r; offset <= r; ++offset) {
                    int3 cell = int3(tid) + offset * step;
                    if (offset == 0 || any(cell < 0) || any(cell >= dims)) {
                        continue;
                    }
                    int other = cell.x + dims.x * (cell.y + dims.y * cell.z);
                    uchar flag = flags[other];
                    uint compactOther = cellElement[other];
                    float weight = clamp(reach + 0.5f - float(abs(offset)), 0.0f, 1.0f);
                    if ((flag == elementActive || flag == elementFailing) && steel[compactOther].inclinedAxes == inclinedAxes
                        && float(steel[compactOther].inclined) > 0.0f && fabs(plasticBefore[compactOther].w) < 1e8f) {
                        sum += weight * plasticBefore[compactOther].w;
                        weights += weight;
                    }
                }
                spread = sum / weights;
            }
            if (fabs(spread) > m.steelStrain[m.steelPoints - 1]) {
                own = 1e9f;  // ruptured for good
            } else {
                inclinedIntact = true;
                steelCapacity += inclinedRatio * yield;
                float3x3 outer = float3x3(inclined * inclined.x, inclined * inclined.y, inclined * inclined.z);
                material += outer * (inclinedRatio * stress / root);
            }
            state.inclinedPlastic = own;
        }
        if (m.barReach > 0.0f) {
            plasticOut[compact] = float4(plastic, state.inclinedPlastic);
        }
        bool anySteel = intact.x + intact.y + intact.z > 0.0f || inclinedIntact;

        // A crack wide enough to count as a gap removes the element, unless intact bars cross it.
        // The crack runs across the member, so bars that cross it elsewhere in the section hold
        // it closed here too: an element between the mats of a thick wall, or between a mat and
        // the far face, is bridged by them. The section is searched along the crack's plane,
        // from the element to the member's surface, for an element with intact bars across it
        // (as of the previous substep). The three planes of the crack axes are looked at, and a
        // second crack if there is one.
        bool torn = false;
        float4 second = float4(state.secondCrack);
        bool hasSecond = u.secondCracks != 0 && framed && !turning && second.w != 0.0f;
        for (int c = 0; c < (hasSecond ? 4 : 3) && !torn; ++c) {
            float reached = c < 3 ? history[c] : state.secondHistory + onset;
            if (reached < m.erosionStrain) {
                continue;
            }
            // Intact inclined bars across the crack bridge it.
            float3 crackNormal = c < 3 ? frame[c] : frame * normalize(second.xyz);
            if (inclinedIntact && fabs(dot(inclined, crackNormal)) >= 0.5f) {
                continue;
            }
            // The lattice axis most nearly across the crack carries the bars that cross it; the
            // section is searched along the other two.
            float3 normal = abs(crackNormal);
            int j = normal.x >= normal.y && normal.x >= normal.z ? 0 : (normal.y >= normal.z ? 1 : 2);
            if (intact[j] != 0.0f) {
                continue;
            }
            bool bridged = false;
            int3 dims = int3(u.ex, u.ey, u.ez);
            for (int side = 1; side < 3 && !bridged; ++side) {
                int axis = (j + side) % 3;
                for (int direction = -1; direction <= 1 && !bridged; direction += 2) {
                    int3 cell = int3(tid);
                    for (int step = 0; step < 32; ++step) {
                        cell[axis] += direction;
                        if (cell[axis] < 0 || cell[axis] >= dims[axis]) {
                            break;
                        }
                        int other = cell.x + dims.x * (cell.y + dims.y * cell.z);
                        uchar flag = flags[other];
                        if (flag != elementActive && flag != elementFailing) {
                            break;  // the member's surface
                        }
                        uint neighbour = cellElement[other];
                        if (!singleMaterial && materialIndex[neighbour] != own) {
                            break;  // another member: masonry is not held by its frame's bars
                        }
                        if (float(steel[neighbour].ratio[j]) > 0.0f
                            && (m.barReach <= 0.0f || fabs(plasticBefore[neighbour][j]) < 1e8f)) {
                            bridged = true;
                            break;
                        }
                    }
                }
            }
            torn = !bridged;
        }

        // Push forward to the Cauchy stress: sigma = F S F^T / J.
        float3x3 deformation = float3x3(1.0f) + gradient;
        float3x3 cauchy = deformation * material * transpose(deformation) * (referenceVolume / volume);
        sxx = cauchy[0][0];
        syy = cauchy[1][1];
        szz = cauchy[2][2];
        sxy = cauchy[1][0];
        syz = cauchy[2][1];
        szx = cauchy[0][2];

        // Whatever bridges it, an element stretched to three times the removal width (or by
        // 100%, on large elements) is gone. Bars bridging a single crack rupture before that.
        eroded = eroded || torn || pulverised || crack > max(1.0f, 3.0f * m.erosionStrain);
        // Squeezed concrete also resists the hourglass modes: a block at mean compressive stress s
        // and strength f can carry a bending moment in proportion to s (1 - s / f).
        float squeezed = max(-min(normalStress.x, min(normalStress.y, normalStress.z)), 0.0f);
        float strength = m.compressiveStrength * compressionFactor * max(confinement.x, max(confinement.y, confinement.z));
        float bending = squeezed * max(1.0f - squeezed / strength, 0.0f);
        capacity = max(max(tensionEnvelope(crack, tensionFactor, m) + steelCapacity, bending),
                       0.02f * m.tensileStrength);
        state.display = max(crack / (anySteel ? m.steelStrain[m.steelPoints - 1] : m.erosionStrain), crushed);
    }

    ElementForces out;
    if (eroded) {
        flags[element] = elementFailing;
        failureGate[0] = 1;
        for (uint a = 0; a < 8; ++a) {
            out.force[a] = float3(0.0f);
        }
        for (uint mode = 0; mode < 4; ++mode) {
            state.hourglass[mode] = float3(0.0f);
        }
        states[compact] = state;
        forces[compact] = out;
        return;
    }
    state.stress[0] = sxx;
    state.stress[1] = syy;
    state.stress[2] = szz;
    state.stress[3] = sxy;
    state.stress[4] = syz;
    state.stress[5] = szx;

    // Bulk viscosity damps the ringing behind stress waves; it acts in compression only.
    float viscous = 0.0f;
    if (trace < 0.0f) {
        viscous = m.density * u.h * (u.bulkQuadratic * u.h * trace * trace - u.bulkLinear * m.soundSpeed * trace);
    }
    float3x3 forceStress = float3x3(float3(sxx - viscous, sxy, szx), float3(sxy, syy - viscous, syz),
                                    float3(szx, syz, szz - viscous));

    // Hourglass control: resist the four non-constant-strain modes of the element.
    float3 modeShape[4];
    for (uint mode = 0; mode < 4; ++mode) {
        modeShape[mode] = float3(0.0f);
    }
    float gamma[4][8];
    for (uint a = 0; a < 8; ++a) {
        float3 s = cornerSign(a);
        gamma[0][a] = s.y * s.z;
        gamma[1][a] = s.x * s.z;
        gamma[2][a] = s.x * s.y;
        gamma[3][a] = s.x * s.y * s.z;
        for (uint mode = 0; mode < 4; ++mode) {
            modeShape[mode] += x[a] * gamma[mode][a];
        }
    }
    float3 rate[4];
    for (uint mode = 0; mode < 4; ++mode) {
        rate[mode] = float3(0.0f);
    }
    for (uint a = 0; a < 8; ++a) {
        for (uint mode = 0; mode < 4; ++mode) {
            gamma[mode][a] -= dot(b[a], modeShape[mode]);
            rate[mode] += v[a] * gamma[mode][a];
        }
    }
    // The hourglass forces act as the element's bending moments, so they are capped at its
    // fully plastic moment (strength * h^2 / 8 in these units) just as the stress is capped.
    float limit = 0.125f * capacity * u.h * u.h;
    for (uint mode = 0; mode < 4; ++mode) {
        float3 q = state.hourglass[mode];
        q += dt * (m.hourglassStiffness * rate[mode] + spin * q);
        float magnitude = length(q);
        if (magnitude > limit) {
            q *= limit / magnitude;
        }
        state.hourglass[mode] = q;
    }

    for (uint a = 0; a < 8; ++a) {
        float3 f = -volume * (forceStress * b[a]);
        for (uint mode = 0; mode < 4; ++mode) {
            f -= float3(state.hourglass[mode]) * gamma[mode][a];
        }
        out.force[a] = f;
    }

    // Pressure on faces that border the air or a failed element, on the deformed geometry: the
    // blast from the air solver, and any prescribed pressure history.
    if (u.coupled != 0 || u.loadCount != 0) {
        float applied = tablePressure(loadTable, u.loadCount, u.loadTime);
        float3 centre = float3(0.0f);
        for (uint a = 0; a < 8; ++a) {
            centre += 0.125f * x[a];
        }
        int3 dims = int3(u.ex, u.ey, u.ez);
        for (uint face = 0; face < 6; ++face) {
            uint axis = face >> 1;
            uint side = face & 1u;
            int3 neighbour = int3(tid);
            neighbour[axis] += side == 0 ? -1 : 1;
            bool inside = all(neighbour >= 0) && all(neighbour < dims);
            uint neighbourFlag =
                inside ? uint(flags[neighbour.x + dims.x * (neighbour.y + dims.y * neighbour.z)]) : 0u;
            if (neighbourFlag == elementActive || neighbourFlag == elementFailing) {
                continue;
            }
            // The face's four corners, in order around its perimeter.
            uint first = (axis + 1) % 3;
            uint second = (axis + 2) % 3;
            uint base = side << axis;
            float3 p00 = x[base];
            float3 p10 = x[base | (1u << first)];
            float3 p11 = x[base | (1u << first) | (1u << second)];
            float3 p01 = x[base | (1u << second)];
            float3 faceCentre = 0.25f * (p00 + p10 + p11 + p01);
            float3 areaVector = 0.5f * cross(p11 - p00, p01 - p10);
            float area = length(areaVector);
            if (area < 1e-12f) {
                continue;
            }
            float3 normal = areaVector / area;
            if (dot(normal, faceCentre - centre) < 0.0f) {
                normal = -normal;
            }
            float overpressure =
                u.coupled != 0 ? faceOverpressure(faceCentre, normal, fluid, fluidMask, patchOfTile, fineAir, fineAirMask, u) : 0.0f;
            // The prescribed pressure acts only on the original outer surface it was given for.
            if (face == u.loadFace && neighbourFlag == elementEmpty) {
                overpressure += applied;
            }
            float3 load = -overpressure * normal * (0.25f * area);
            for (uint a = 0; a < 8; ++a) {
                if (((a >> axis) & 1u) == side) {
                    out.force[a] = float3(out.force[a]) + load;
                }
            }
        }
    }

    states[compact] = state;
    forces[compact] = out;
}

static inline bool contactEnabled(constant StructureUniforms &u, const device uint *failureGate) {
    return u.contactMode == 2 || (u.contactMode == 1 && failureGate[0] != 0);
}

// Nodes are stored compactly, in the order of `nodeList`, which holds each one's lattice index.
static inline uint3 latticeNode(uint index, constant StructureUniforms &u) {
    uint nodesX = u.ex + 1;
    uint nodesY = u.ey + 1;
    return uint3(index % nodesX, (index / nodesX) % nodesY, index / (nodesX * nodesY));
}

static inline float3 nodePosition(uint compact, const device uint *nodeList, const device StructureNode *nodes,
                                  constant StructureUniforms &u) {
    return float3(u.originX, u.originY, u.originZ) + float3(latticeNode(nodeList[compact], u)) * u.h
        + float3(nodes[compact].displacement);
}

// Force of the air on a loose node of debris: the pressure gradient across the solid it stands
// for (its mass over the solid's density), plus drag on it as a cube in the relative wind with a
// drag coefficient of one. The air does not feel the reaction.
// The air loses the momentum it gives a loose node, and the work it does on it; the work that
// drag dissipates stays in the air as heat.
static inline void recordExchange(device atomic_uint *exchange, int exchangeCell, float3 airForce,
                                  float3 averageVelocity, float dt, float fluidCell) {
    float perVolume = dt / (fluidCell * fluidCell * fluidCell);
    float3 momentum = -airForce * perVolume * exchangeMomentumScale;
    float energy = -dot(airForce, averageVelocity) * perVolume * exchangeEnergyScale;
    const float limit = 1.0e15f;
    float4 values = clamp(float4(momentum, energy), -limit, limit);
    uint slot = exchangeStride * uint(exchangeCell);
    for (uint n = 0; n < 4; ++n) {
        atomicAdd64(exchange + slot + 2 * n, long(rint(values[n])));
    }
}

// The air cell, numbered within the exchange region, in which a loose node is loaded by the
// air, or -1 if it is not: outside the region, where the air could not be given the reaction,
// or in a solid cell.
// (Templated so that shells, with their own uniforms, share it.)
template <typename Uniforms>
static inline int debrisCell(float3 position, const device uchar *fluidMask, constant Uniforms &u) {
    int3 dims = int3(u.fluidNx, u.fluidNy, u.fluidNz);
    int3 cell = int3(floor(position / u.fluidCell));
    int3 local = cell - int3(u.exchangeX, u.exchangeY, u.exchangeZ);
    int3 region = int3(u.exchangeNx, u.exchangeNy, u.exchangeNz);
    if (any(cell < 0) || any(cell >= dims) || any(local < 0) || any(local >= region)) {
        return -1;
    }
    if (fluidMask[cell.x + dims.x * (cell.y + dims.y * cell.z)] != 0) {
        return -1;
    }
    return local.x + region.x * (local.y + region.y * local.z);
}

// A loose node stands for an eighth of each element the body started with around it, whatever
// they were made of.
static inline float debrisVolume(uint share, constant StructureUniforms &u) {
    return float(share) * 0.125f * u.h * u.h * u.h;
}

// Before each air step's substeps, every loose node adds its frontal area to its air cell.
kernel void debrisAreas(const device StructureNode *nodes [[buffer(0)]],
                        const device uchar *flags [[buffer(1)]],
                        const device StepControl &control [[buffer(2)]],
                        constant StructureUniforms &u [[buffer(3)]],
                        const device uint *nodeList [[buffer(4)]],
                        const device uchar *fluidMask [[buffer(5)]],
                        device atomic_int *area [[buffer(6)]],
                        const device uint *failureGate [[buffer(7)]],
                        uint threadIndex [[thread_position_in_grid]]) {
    if (control.dt <= 0.0f || failureGate[0] == 0) {
        return;
    }
    StructureNode node = nodes[threadIndex];
    if (node.mass <= 0.0f || (node.flags & nodeBuried) != 0) {
        return;
    }
    uint3 tid = latticeNode(nodeList[threadIndex], u);
    int3 dims = int3(u.ex, u.ey, u.ez);
    uint share = 0;
    for (uint a = 0; a < 8; ++a) {
        int3 cell = int3(tid) - int3(a & 1u, (a >> 1) & 1u, (a >> 2) & 1u);
        if (any(cell < 0) || any(cell >= dims)) {
            continue;
        }
        uchar flag = flags[cell.x + dims.x * (cell.y + dims.y * cell.z)];
        if (flag == elementActive) {
            return;
        }
        share += flag != elementEmpty ? 1u : 0u;
    }
    int exchangeCell = debrisCell(nodePosition(threadIndex, nodeList, nodes, u), fluidMask, u);
    if (exchangeCell < 0) {
        return;
    }
    float frontal = pow(debrisVolume(share, u), 2.0f / 3.0f) / (u.fluidCell * u.fluidCell * u.fluidCell);
    atomic_fetch_add_explicit(&area[exchangeCell], int(round(min(frontal * exchangeAreaScale, 1.0e9f))),
                              memory_order_relaxed);
}

template <typename Uniforms>
static inline float3 debrisAirForce(float3 position, float3 velocity, float volume, const device Cell *fluid,
                                    const device uchar *fluidMask, const device int *area, float airStep,
                                    constant Uniforms &u, thread int &exchangeCell) {
    exchangeCell = debrisCell(position, fluidMask, u);
    if (exchangeCell < 0) {
        return float3(0.0f);
    }
    int3 dims = int3(u.fluidNx, u.fluidNy, u.fluidNz);
    int3 cell = int3(floor(position / u.fluidCell));
    int index = cell.x + dims.x * (cell.y + dims.y * cell.z);
    // Pressure of a fluid cell, or -1 where there is none.
    auto pressureAt = [&](int3 c) -> float {
        if (any(c < 0) || any(c >= dims)) {
            return -1.0f;
        }
        int i = c.x + dims.x * (c.y + dims.y * c.z);
        if (fluidMask[i] != 0) {
            return -1.0f;
        }
        Cell s = fluid[i];
        float rho = max(s.rho, 1e-6f);
        float kinetic = 0.5f * (s.mx * s.mx + s.my * s.my + s.mz * s.mz) / rho;
        float pressure = gasPressure(rho, s.energy - kinetic, u.fluidAirModel, u.fluidGamma);
        return isfinite(pressure) ? pressure : -1.0f;
    };
    float here = pressureAt(cell);
    if (!isfinite(here)) {
        exchangeCell = -1;
        return float3(0.0f);
    }
    float3 gradient = float3(0.0f);
    for (int axis = 0; axis < 3; ++axis) {
        int3 step = int3(0);
        step[axis] = 1;
        float high = pressureAt(cell + step);
        float low = pressureAt(cell - step);
        if (high >= 0.0f && low >= 0.0f) {
            gradient[axis] = (high - low) / (2.0f * u.fluidCell);
        } else if (high >= 0.0f) {
            gradient[axis] = (high - here) / u.fluidCell;
        } else if (low >= 0.0f) {
            gradient[axis] = (here - low) / u.fluidCell;
        }
    }
    Cell s = fluid[index];
    // Gas thinner than a hundredth of the air's ambient density (a crack just opened) has
    // nothing to push debris with.
    if (s.rho < 0.012f) {
        exchangeCell = -1;
        return float3(0.0f);
    }
    float rho = s.rho;
    float3 wind = float3(s.mx, s.my, s.mz) / rho - velocity;
    float frontal = pow(volume, 2.0f / 3.0f);
    // The drag is held at the air's state for a whole air step. Where debris is packed densely
    // into a cell, that could take more than the air's relative momentum and reverse the flow,
    // so the drag takes its implicit (backward Euler) form for the cell's air relaxing towards
    // the debris: scaled by 1 / (1 + K dt / m), K the drag of all the cell's debris per unit
    // relative velocity and m the cell's air. Sparse debris is left almost alone.
    float speed = length(wind);
    float cellArea = max(float(area[exchangeCell]) / exchangeAreaScale, 0.0f);
    float factor = 1.0f / (1.0f + 0.5f * speed * cellArea * airStep);
    return -gradient * volume + factor * 0.5f * rho * frontal * speed * wind;
}

// Contact treats every node as a sphere one element across. Each substep the nodes are dropped
// into a grid of element-sized cells, then each node pushes away from strangers in the 27 cells
// around it. A cell's header packs the substep's stamp with a count of the slots in use, so
// stale cells read as empty and the grid never needs clearing.
// Contact cells are element-sized cubes over all of space, offset by half an element so that every
// undeformed node sits in the middle of its own cell. They map into a table that wraps space
// periodically, sized to the structure, so memory does not depend on how far debris travels;
// neighbouring cells stay neighbours in memory, and only cells a whole period apart share an
// entry and its slots.
static inline int3 contactCell(float3 position, constant StructureUniforms &u) {
    return int3(floor((position - float3(u.gridOriginX, u.gridOriginY, u.gridOriginZ)) / u.h));
}

static inline uint contactBucket(int3 cell, constant StructureUniforms &u) {
    uint3 wrapped = uint3(cell) & (uint3(u.contactNx, u.contactNy, u.contactNz) - 1u);
    return wrapped.x + u.contactNx * (wrapped.y + u.contactNy * wrapped.z);
}

// The contact grid is filled in two passes, so that what a cell holds does not depend on the
// order in which threads arrive. First every node marks its cell as current and empties it...
kernel void contactClear(const device uint *nodeList [[buffer(0)]],
                         const device StructureNode *nodes [[buffer(1)]],
                         device uint *heads [[buffer(2)]],
                         const device uint *failureGate [[buffer(3)]],
                         const device StepControl &control [[buffer(4)]],
                         constant StructureUniforms &u [[buffer(5)]],
                         device uint *slots [[buffer(6)]],
                         uint threadIndex [[thread_position_in_grid]]) {
    bool active;
    structureStep(u, control, active);
    if (!active || !contactEnabled(u, failureGate)) {
        return;
    }
    if ((nodes[threadIndex].flags & nodeBuried) != 0) {
        return;
    }
    float3 position = nodePosition(threadIndex, nodeList, nodes, u);
    int3 cell = contactCell(position, u);
    // Several nodes may write the same values here; that is harmless.
    uint target = contactBucket(cell, u);
    heads[target] = u.stamp;
    for (uint slot = 0; slot < contactSlots; ++slot) {
        slots[target * contactSlots + slot] = emptySlot;
    }
}

// ...then every node offers its index to its cell, which keeps the `contactSlots` smallest in
// ascending order: each slot keeps the smaller of what it holds and what arrives, and passes
// the larger on to the next. A crowded cell therefore always drops the same nodes.
kernel void contactHash(const device uint *nodeList [[buffer(0)]],
                        const device StructureNode *nodes [[buffer(1)]],
                        const device uint *heads [[buffer(2)]],
                        const device uint *failureGate [[buffer(3)]],
                        const device StepControl &control [[buffer(4)]],
                        constant StructureUniforms &u [[buffer(5)]],
                        device atomic_uint *slots [[buffer(6)]],
                        uint threadIndex [[thread_position_in_grid]]) {
    bool active;
    structureStep(u, control, active);
    if (!active || !contactEnabled(u, failureGate)) {
        return;
    }
    if ((nodes[threadIndex].flags & nodeBuried) != 0) {
        return;
    }
    float3 position = nodePosition(threadIndex, nodeList, nodes, u);
    int3 cell = contactCell(position, u);
    uint target = contactBucket(cell, u);
    // Compact indices follow lattice order, so the smallest are the same nodes either way.
    uint carried = threadIndex;
    for (uint slot = 0; slot < contactSlots && carried != emptySlot; ++slot) {
        uint held = atomic_fetch_min_explicit(&slots[target * contactSlots + slot], carried, memory_order_relaxed);
        carried = max(held, carried);
    }
}

kernel void contactForces(const device uint *nodeList [[buffer(0)]],
                          const device StructureNode *nodes [[buffer(1)]],
                          const device uint *heads [[buffer(2)]],
                          const device uint *failureGate [[buffer(3)]],
                          const device StepControl &control [[buffer(4)]],
                          constant StructureUniforms &u [[buffer(5)]],
                          device packed_float3 *contact [[buffer(7)]],
                          const device uint *slots [[buffer(8)]],
                          uint threadIndex [[thread_position_in_grid]]) {
    bool active;
    float dt = structureStep(u, control, active);
    if (!active || !contactEnabled(u, failureGate)) {
        return;
    }
    StructureNode node = nodes[threadIndex];
    if ((node.flags & nodeBuried) != 0) {
        contact[threadIndex] = float3(0.0f);
        return;
    }
    float3 position = nodePosition(threadIndex, nodeList, nodes, u);
    int3 lattice = int3(latticeNode(nodeList[threadIndex], u));

    int3 cell = contactCell(position, u);
    float3 force = float3(0.0f);
    // A node that its own crowded entry dropped is invisible to the others this step, so it does
    // not push them either: every pair then sees each other or neither does, and the forces
    // between them are equal and opposite.
    uint own = contactBucket(cell, u);
    bool listed = false;
    for (uint slot = 0; slot < contactSlots; ++slot) {
        listed = listed || slots[own * contactSlots + slot] == threadIndex;
    }
    if (!listed) {
        contact[threadIndex] = float3(0.0f);
        return;
    }
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                int3 c = cell + int3(dx, dy, dz);
                uint target = contactBucket(c, u);
                if (heads[target] != u.stamp) {
                    continue;  // not touched this substep: whatever it holds is stale
                }
                // The slots hold the cell's nodes in ascending order, so the forces are summed in
                // the same order whatever the timing of the threads that filled them.
                for (uint slot = 0; slot < contactSlots; ++slot) {
                    uint otherIndex = slots[target * contactSlots + slot];
                    if (otherIndex == emptySlot) {
                        break;
                    }
                    if (otherIndex == threadIndex) {
                        continue;
                    }
                    float3 otherPosition = nodePosition(otherIndex, nodeList, nodes, u);
                    // An entry can hold nodes of other cells that hash to it; count each node only
                    // when visiting its own cell.
                    if (any(contactCell(otherPosition, u) != c)) {
                        continue;
                    }
                    float3 offset = position - otherPosition;
                    float distance = length(offset);
                    if (distance >= u.h || distance < 1e-9f) {
                        continue;
                    }
                    int3 difference = int3(latticeNode(nodeList[otherIndex], u)) - lattice;
                    // Nodes that began as neighbours never repel each other. While joined they are
                    // held apart by their element; once it has failed they may already be closer
                    // than a sphere's width, and a spring switched on there would create energy.
                    // Separated pieces therefore overlap by up to one element before they touch.
                    if (all(abs(difference) <= 1)) {
                        continue;
                    }

                    StructureNode partner = nodes[otherIndex];
                    float3 normal = offset / distance;
                    float mass = min(node.mass, partner.mass);
                    float stiffness = u.contactStiffness * mass;
                    float damping = 2.0f * u.contactDamping * sqrt(stiffness * mass);
                    float3 relative = float3(node.velocity) - float3(partner.velocity);
                    float approach = dot(relative, normal);
                    float push = approach > separationLimit ? 0.0f : max(stiffness * (u.h - distance) - damping * approach, 0.0f);
                    force += push * normal;

                    // Coulomb friction, regularised as a damper at low sliding speed.
                    float3 sliding = relative - approach * normal;
                    float speed = length(sliding);
                    if (speed > 1e-6f) {
                        force -= min(u.contactFriction * push, damping * speed) * (sliding / speed);
                    }
                }
            }
        }
    }
    float largest = node.mass * contactKick / max(dt, 1e-12f);
    float size = length(force);
    if (size > largest) {
        force *= largest / size;
    }
    contact[threadIndex] = force;
}

// Gathers element forces at every node and advances velocity and position.
kernel void structureNodes(device StructureNode *nodes [[buffer(0)]],
                           const device ElementForces *forces [[buffer(1)]],
                           device uchar *flags [[buffer(2)]],
                           const device StepControl &control [[buffer(3)]],
                           constant StructureUniforms &u [[buffer(4)]],
                           const device uint *nodeList [[buffer(5)]],
                           const device packed_float3 *contact [[buffer(6)]],
                           const device uint *failureGate [[buffer(7)]],
                           const device uint *cellElement [[buffer(8)]],
                           const device Cell *fluid [[buffer(9)]],
                           const device uchar *fluidMask [[buffer(10)]],
                           device atomic_uint *exchange [[buffer(11)]],
                           const device int *debrisArea [[buffer(12)]],
                           const device uint *interfaceStart [[buffer(13)]],
                           const device uint2 *interfaceEntries [[buffer(14)]],
                           const device InterfaceLink *links [[buffer(15)]],
                           const device float4 *interfaceLoads [[buffer(16)]],
                           uint threadIndex [[thread_position_in_grid]]) {
    bool active;
    float dt = structureStep(u, control, active);
    if (!active) {
        return;
    }
    uint3 tid = latticeNode(nodeList[threadIndex], u);
    StructureNode node = nodes[threadIndex];

    int3 dims = int3(u.ex, u.ey, u.ez);
    // Each element's failure is committed by its lowest corner. The gather below only asks
    // whether an element is active, which failing and eroded elements are not.
    if (all(int3(tid) < dims)) {
        int own = int(tid.x) + dims.x * (int(tid.y) + dims.y * int(tid.z));
        if (flags[own] == elementFailing) {
            flags[own] = elementEroded;
        }
    }
    float3 force = float3(0.0f);
    uint intact = 0;
    uint share = 0;
    for (uint a = 0; a < 8; ++a) {
        // This node is corner `a` of the element offset by -a.
        int3 cell = int3(tid) - int3(a & 1u, (a >> 1) & 1u, (a >> 2) & 1u);
        if (any(cell < 0) || any(cell >= dims)) {
            continue;
        }
        int element = cell.x + dims.x * (cell.y + dims.y * cell.z);
        uchar flag = flags[element];
        if (flag == elementActive) {
            force += float3(forces[cellElement[element]].force[a]);
            intact += 1;
        }
        share += flag != elementEmpty ? 1u : 0u;
    }
    // Shell nodes tied into the elements around this node hand over their share: the force at
    // the trilinear weight, and the moment as forces across the element's corners, which turn it
    // as the shell node's rotation (energy-consistent with the way the shell node follows).
    if (u.interfaceLinks != 0) {
        for (uint e = interfaceStart[threadIndex]; e < interfaceStart[threadIndex + 1]; ++e) {
            uint2 entry = interfaceEntries[e];
            float3 linkForce = interfaceLoads[2 * entry.x].xyz;
            float3 linkMoment = interfaceLoads[2 * entry.x + 1].xyz;
            InterfaceLink link = links[entry.x];
            // The line's second moment, sum |r|^2 I - r r^T, is sum |r|^2 across the line (its
            // twist about itself, which a shell does not carry, is left out).
            force += linkForce / float(link.count)
                + cross(linkMoment, float3(link.arms[entry.y])) * link.inverseSecondMoment;
        }
    }
    bool attached = intact > 0;
    // A node inside intact solid cannot meet a node of another piece without one of the
    // surface nodes in front of it meeting that node first, so contact leaves it out.
    node.flags = intact == 8 ? (node.flags | nodeBuried) : (node.flags & ~nodeBuried);
    // Loose debris is not part of any element face the air loads, so the air pushes it directly.
    float3 airForce = float3(0.0f);
    int exchangeCell = -1;
    if (!attached && u.coupled != 0 && u.debrisLoading != 0) {
        airForce = debrisAirForce(nodePosition(threadIndex, nodeList, nodes, u), float3(node.velocity),
                                  debrisVolume(share, u),
                                  fluid, fluidMask, debrisArea, control.dt, u, exchangeCell);
        force += airForce;
    }

    if (contactEnabled(u, failureGate)) {
        force += float3(contact[threadIndex]);
    }

    float3 velocity = float3(node.velocity) + dt * (force / node.mass - float3(0.0f, 0.0f, u.gravity));
    velocity *= max(0.0f, 1.0f - u.damping * dt);
    if ((node.flags & 8u) != 0) {
        velocity = float3(node.velocity);  // prescribed motion
    }
    if ((node.flags & 1u) != 0) {
        velocity.x = 0.0f;
    }
    if ((node.flags & 2u) != 0) {
        velocity.y = 0.0f;
    }
    if ((node.flags & 4u) != 0) {
        velocity.z = 0.0f;
    }
    float3 displacement = float3(node.displacement) + dt * velocity;
    if ((node.flags & 16u) != 0 && displacement.z < 0.0f) {
        displacement.z = 0.0f;
        velocity.z = max(velocity.z, 0.0f);
    }
    float referenceHeight = u.originZ + float(tid.z) * u.h;
    if (referenceHeight + displacement.z < 0.0f && u.groundFriction >= 0.0f) {
        // Debris landing on the ground: stop the fall and shed horizontal speed.
        displacement.z = -referenceHeight;
        velocity.z = max(velocity.z, 0.0f);
        velocity.xy *= max(0.0f, 1.0f - u.groundFriction * dt);
    }
    if (exchangeCell >= 0) {
        recordExchange(exchange, exchangeCell, airForce, 0.5f * (float3(node.velocity) + velocity), dt,
                       u.fluidCell);
    }
    node.displacement = displacement;
    node.velocity = velocity;
    nodes[threadIndex] = node;
}

// Two-way coupling: the air's solid mask follows the structure. Each air step, intact elements
// are counted into the air cells they currently sit in; a cell is solid when it is rigid or at
// least a third full. Cells that open are refilled from their fluid neighbours.

struct CouplingUniforms {
    uint regionX;
    uint regionY;
    uint regionZ;
    uint regionNx;
    uint regionNy;
    uint regionNz;
    uint fluidNx;
    uint fluidNy;
    uint fluidNz;
    uint threshold;
    uint ex;
    uint ey;
    float fluidCell;
    float h;
    float originX;
    float originY;
    float originZ;
    float gamma;
    float ambientDensity;
    float ambientPressure;
    uint airModel;
    uint splatWeight;  // what each point counts for in a cell's occupancy, against `threshold`
    // The air's refinement (see Refine.metal): its ratio (0 when not refined), its grid of blocks,
    // the count that makes a fine cell solid, and the points along each edge of an element
    // sampled for the fine cells.
    uint refineRatio;
    uint blocksX;
    uint blocksY;
    uint fineThreshold;
    uint fineSamples;
    // Points along each edge an element is sampled at for the air cells: one, unless the
    // elements are larger than the cells (then each element would mark only the cell its centre
    // lies in, leaving the rest of a wall open to the air).
    uint coarseSamples;
};

// Where the air is refined, adds a point of the structure, moving with `fixed` (fixed point), to
// the occupancy of the fine cell holding it: four counters per fine cell, as for the coarse ones.
static inline void splatFine(float3 sample, int3 fixed, uint weight, const device int *patchOfTile,
                             device atomic_uint *fineOccupancy, constant CouplingUniforms &u) {
    if (u.refineRatio == 0) {
        return;
    }
    float fineCell = u.fluidCell / float(u.refineRatio);
    int3 fine = int3(floor(sample / fineCell));
    int3 cells = int3(u.fluidNx, u.fluidNy, u.fluidNz) * int(u.refineRatio);
    if (any(fine < 0) || any(fine >= cells)) {
        return;
    }
    int side = patchSize * int(u.refineRatio);
    int3 block = fine / side;
    int patch = patchOfTile[block.x + int(u.blocksX) * (block.y + int(u.blocksY) * block.z)];
    if (patch < 0) {
        return;
    }
    int3 local = fine - block * side;
    uint slot = 4u * (uint(patch) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z)));
    atomic_fetch_add_explicit(&fineOccupancy[slot], weight, memory_order_relaxed);
    atomic_fetch_add_explicit(&fineOccupancy[slot + 1], uint(fixed.x) * weight, memory_order_relaxed);
    atomic_fetch_add_explicit(&fineOccupancy[slot + 2], uint(fixed.y) * weight, memory_order_relaxed);
    atomic_fetch_add_explicit(&fineOccupancy[slot + 3], uint(fixed.z) * weight, memory_order_relaxed);
}

// Velocities handed to the air are limited to this (m/s) and summed in steps of 1/1024 m/s.
constant float wallSpeedLimit = 1000.0f;
constant float wallSpeedScale = 1024.0f;

kernel void splatStructure(const device uint *elementList [[buffer(0)]],
                           const device uchar *flags [[buffer(1)]],
                           const device StructureNode *nodes [[buffer(2)]],
                           device atomic_uint *occupancy [[buffer(3)]],
                           constant CouplingUniforms &u [[buffer(4)]],
                           const device uint *nodeMap [[buffer(5)]],
                           const device int *patchOfTile [[buffer(6)]],
                           device atomic_uint *fineOccupancy [[buffer(7)]],
                           uint threadIndex [[thread_position_in_grid]]) {
    uint element = elementList[threadIndex];
    if (flags[element] != elementActive) {
        return;
    }
    uint3 cell = uint3(element % u.ex, (element / u.ex) % u.ey, element / (u.ex * u.ey));
    uint nodesX = u.ex + 1;
    uint nodesY = u.ey + 1;
    uint lowCorner = cell.x + nodesX * (cell.y + nodesY * cell.z);
    uint low = nodeMap[lowCorner];
    uint high = nodeMap[lowCorner + 1 + nodesX + nodesX * nodesY];
    float3 centre = float3(u.originX, u.originY, u.originZ) + (float3(cell) + 0.5f) * u.h
        + 0.5f * (float3(nodes[low].displacement) + float3(nodes[high].displacement));
    float3 velocity = 0.5f * (float3(nodes[low].velocity) + float3(nodes[high].velocity));
    velocity = select(clamp(velocity, -wallSpeedLimit, wallSpeedLimit), float3(0.0f), isnan(velocity));
    int3 fixed = int3(round(velocity * wallSpeedScale));
    // Where the air is refined, the element is sampled at points no further apart than a fine
    // cell, each counting towards the fine cell it falls in.
    uint samples = u.fineSamples;
    for (uint n = 0; u.refineRatio != 0 && n < samples * samples * samples; ++n) {
        float3 offset = (float3(n % samples, (n / samples) % samples, n / (samples * samples)) + 0.5f) / float(samples)
            - 0.5f;
        splatFine(centre + offset * u.h, fixed, 1u, patchOfTile, fineOccupancy, u);
    }
    int3 dims = int3(u.regionNx, u.regionNy, u.regionNz);
    uint coarse = u.coarseSamples;
    for (uint n = 0; n < coarse * coarse * coarse; ++n) {
        float3 offset = coarse == 1 ? float3(0.0f)
            : (float3(n % coarse, (n / coarse) % coarse, n / (coarse * coarse)) + 0.5f) / float(coarse) - 0.5f;
        int3 target = int3(floor((centre + offset * u.h) / u.fluidCell)) - int3(u.regionX, u.regionY, u.regionZ);
        if (any(target < 0) || any(target >= dims)) {
            continue;
        }
        // Each cell has four counters: the number of elements, then the sum of their velocities
        // in fixed point (two's-complement addition makes the unsigned counters signed sums).
        uint slot = 4 * uint(target.x + dims.x * (target.y + dims.y * target.z));
        atomic_fetch_add_explicit(&occupancy[slot], u.splatWeight, memory_order_relaxed);
        atomic_fetch_add_explicit(&occupancy[slot + 1], uint(fixed.x) * u.splatWeight, memory_order_relaxed);
        atomic_fetch_add_explicit(&occupancy[slot + 2], uint(fixed.y) * u.splatWeight, memory_order_relaxed);
        atomic_fetch_add_explicit(&occupancy[slot + 3], uint(fixed.z) * u.splatWeight, memory_order_relaxed);
    }
}

// Writes the new solid flag into bit 1 of the mask, leaving the old flag in bit 0 so that
// neighbours read a consistent picture while cells that open are being refilled.
kernel void remaskPrepare(device uchar *mask [[buffer(0)]],
                          const device uchar *rigid [[buffer(1)]],
                          const device uint *occupancy [[buffer(2)]],
                          device Cell *state [[buffer(3)]],
                          constant CouplingUniforms &u [[buffer(4)]],
                          device float *wallVelocity [[buffer(5)]],
                          uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.regionNx || tid.y >= u.regionNy || tid.z >= u.regionNz) {
        return;
    }
    int3 dims = int3(u.fluidNx, u.fluidNy, u.fluidNz);
    int3 cell = int3(tid) + int3(u.regionX, u.regionY, u.regionZ);
    int index = cell.x + dims.x * (cell.y + dims.y * cell.z);
    uint local = tid.x + u.regionNx * (tid.y + u.regionNy * tid.z);
    uint count = occupancy[4 * local];
    bool wasSolid = (mask[index] & 1) != 0;
    bool solid = rigid[index] != 0 || count >= u.threshold;

    // The air sees a solid cell moving at the mean velocity of the elements in it.
    float3 velocity = float3(0.0f);
    if (rigid[index] == 0 && count >= u.threshold) {
        int3 sum = int3(int(occupancy[4 * local + 1]), int(occupancy[4 * local + 2]),
                        int(occupancy[4 * local + 3]));
        velocity = float3(sum) / (wallSpeedScale * float(count));
    }
    wallVelocity[3 * local] = velocity.x;
    wallVelocity[3 * local + 1] = velocity.y;
    wallVelocity[3 * local + 2] = velocity.z;

    if (wasSolid && !solid) {
        const int3 offsets[6] = {
            int3(-1, 0, 0), int3(1, 0, 0), int3(0, -1, 0), int3(0, 1, 0), int3(0, 0, -1), int3(0, 0, 1),
        };
        Cell sum = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        float neighbours = 0.0f;
        for (int n = 0; n < 6; ++n) {
            int3 q = cell + offsets[n];
            if (any(q < 0) || any(q >= dims)) {
                continue;
            }
            int neighbour = q.x + dims.x * (q.y + dims.y * q.z);
            if ((mask[neighbour] & 1) != 0) {
                continue;
            }
            Cell c = state[neighbour];
            sum.rho += c.rho;
            sum.mx += c.mx;
            sum.my += c.my;
            sum.mz += c.mz;
            sum.energy += c.energy;
            neighbours += 1.0f;
        }
        Cell fill = {u.ambientDensity, 0.0f, 0.0f, 0.0f,
                     gasEnergy(u.ambientDensity, u.ambientPressure, u.airModel, u.gamma)};
        if (neighbours > 0.0f) {
            float scale = 1.0f / neighbours;
            fill.rho = sum.rho * scale;
            fill.mx = sum.mx * scale;
            fill.my = sum.my * scale;
            fill.mz = sum.mz * scale;
            fill.energy = sum.energy * scale;
        }
        state[index] = fill;
    }
    mask[index] = (wasSolid ? 1 : 0) | (solid ? 2 : 0);
}

// Gives the air, once per air step, what the debris took from it in the structure's substeps,
// and clears the debris areas for the next step.
kernel void debrisExchange(device Cell *state [[buffer(0)]],
                           device uint *exchange [[buffer(1)]],
                           constant CouplingUniforms &u [[buffer(2)]],
                           device int *debrisArea [[buffer(3)]],
                           uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.regionNx || tid.y >= u.regionNy || tid.z >= u.regionNz) {
        return;
    }
    uint local = tid.x + u.regionNx * (tid.y + u.regionNy * tid.z);
    debrisArea[local] = 0;
    uint slot = exchangeStride * local;
    float4 sum;
    bool touched = false;
    for (uint n = 0; n < 4; ++n) {
        uint2 words = uint2(exchange[slot + 2 * n], exchange[slot + 2 * n + 1]);
        touched = touched || any(words != 0u);
        sum[n] = float(as_type<long>(words));
    }
    if (!touched) {
        return;
    }
    int3 cell = int3(tid) + int3(u.regionX, u.regionY, u.regionZ);
    int index = cell.x + int(u.fluidNx) * (cell.y + int(u.fluidNy) * cell.z);
    float3 momentum = sum.xyz / exchangeMomentumScale;
    float energy = sum.w / exchangeEnergyScale;
    Cell c = state[index];
    // A cell can be given at most 1,000 m/s of velocity change in one air step: debris packed
    // into a cell of thin gas (a crack just opened beside a chamber at megapascals) would
    // otherwise hand that little gas absurd speeds. Past the cap the exchange is scaled down,
    // and momentum is not conserved exactly.
    float limit = 1000.0f * max(c.rho, 0.0f);
    float size = length(momentum);
    if (size > limit) {
        float scale = limit / size;
        momentum *= scale;
        energy *= scale;
    }
    c.mx += momentum.x;
    c.my += momentum.y;
    c.mz += momentum.z;
    c.energy += energy;
    // Debris may not take the air below a small positive pressure (1% of ambient): in the
    // extreme gas beside a charge the drag and the pressure gradient, held for a whole air
    // step, could otherwise leave a cell with negative internal energy, which the air solver's
    // own floors never see because the exchange comes after its sweeps.
    float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, 1e-6f);
    float floorEnergy = kinetic + 0.01f * gasEnergy(max(c.rho, 1e-6f), u.ambientPressure, u.airModel, u.gamma);
    c.energy = max(c.energy, floorEnergy);
    if (all(isfinite(float4(c.mx, c.my, c.mz, c.energy)))) {
        state[index] = c;
    }
    for (uint n = 0; n < exchangeStride; ++n) {
        exchange[slot + n] = 0;
    }
}

kernel void remaskApply(device uchar *mask [[buffer(0)]],
                        device uint *occupancy [[buffer(1)]],
                        constant CouplingUniforms &u [[buffer(2)]],
                        uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.regionNx || tid.y >= u.regionNy || tid.z >= u.regionNz) {
        return;
    }
    int3 cell = int3(tid) + int3(u.regionX, u.regionY, u.regionZ);
    int index = cell.x + int(u.fluidNx) * (cell.y + int(u.fluidNy) * cell.z);
    mask[index] = mask[index] >> 1;
    uint slot = 4 * (tid.x + u.regionNx * (tid.y + u.regionNy * tid.z));
    for (uint n = 0; n < 4; ++n) {
        occupancy[slot + n] = 0;
    }
}

// Where the air is refined, the fine cells' own outline follows the structure the same way, at
// their resolution: a fine cell is solid when it lies in a rigid block, or when the structure's
// points counted into it (`splatFine`) reach `threshold`, and moves with their mean velocity. A
// fine cell that opens takes the mean of the fluid fine cells beside it in its patch, or failing
// those the coarse cell it lies in. Two passes, as for the coarse cells: bit 0 of `fineMask` is
// solid, bit 1 rigid, and bit 2 holds the new solid flag until `refineRemaskApply`.
kernel void refineRemaskPrepare(device uchar *fineMask [[buffer(0)]],
                                device packed_float3 *fineWall [[buffer(1)]],
                                const device uint *fineOccupancy [[buffer(2)]],
                                device Cell *fine [[buffer(3)]],
                                const device Cell *coarse [[buffer(4)]],
                                constant SolverUniforms &u [[buffer(5)]],
                                const device uint *tileOfPatch [[buffer(6)]],
                                const device uint *patchList [[buffer(7)]],
                                constant uint &threshold [[buffer(8)]],
                                const device uchar *mask [[buffer(9)]],
                                device uint *pinned [[buffer(10)]],
                                uint gid [[thread_position_in_grid]]) {
    int r = int(u.refineRatio);
    int side = patchSize * r;
    uint cells = uint(side * side * side);
    uint patch = patchList[gid / cells];
    uint position = gid % cells;
    int3 local = int3(position % uint(side), (position / uint(side)) % uint(side), position / uint(side * side));
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    int3 cell = (tile * side + local) / r;
    if (any(cell >= int3(u.nx, u.ny, u.nz))) {
        return;
    }
    uint at = patch * cells + position;
    uchar m = fineMask[at];
    bool rigid = (m & 2) != 0;
    uint count = fineOccupancy[4 * at];
    bool solid = rigid || count >= threshold;
    float3 velocity = float3(0.0f);
    if (!rigid && count >= threshold) {
        int3 sum = int3(int(fineOccupancy[4 * at + 1]), int(fineOccupancy[4 * at + 2]), int(fineOccupancy[4 * at + 3]));
        velocity = float3(sum) / (wallSpeedScale * float(count));
    }
    fineWall[at] = velocity;
    bool was = (m & 1) != 0;
    if (was && !solid) {
        Cell sum = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        float neighbours = 0.0f;
        for (int n = 0; n < 6; ++n) {
            int3 q = local;
            q[n / 2] += (n % 2) * 2 - 1;
            if (any(q < 0) || any(q >= side)) {
                continue;
            }
            uint there = patch * cells + uint(q.x + side * (q.y + side * q.z));
            if ((fineMask[there] & 1) != 0) {
                continue;
            }
            Cell c = fine[there];
            sum.rho += c.rho;
            sum.mx += c.mx;
            sum.my += c.my;
            sum.mz += c.mz;
            sum.energy += c.energy;
            neighbours += 1.0f;
        }
        Cell fill = coarse[cell.x + int(u.nx) * (cell.y + int(u.ny) * cell.z)];
        if (neighbours > 0.0f) {
            float scale = 1.0f / neighbours;
            fill.rho = sum.rho * scale;
            fill.mx = sum.mx * scale;
            fill.my = sum.my * scale;
            fill.mz = sum.mz * scale;
            fill.energy = sum.energy * scale;
        }
        fine[at] = fill;
    }
    fineMask[at] = (m & 3) | (solid ? 4 : 0);
    // A fine outline that differs from the coarse cells' pins the patch (see `refineRelease`).
    if (solid != (mask[cell.x + int(u.nx) * (cell.y + int(u.ny) * cell.z)] != 0)) {
        pinned[patch] = 1;
    }
}

kernel void refineRemaskApply(device uchar *fineMask [[buffer(0)]],
                              device uint *fineOccupancy [[buffer(1)]],
                              constant SolverUniforms &u [[buffer(2)]],
                              const device uint *patchList [[buffer(3)]],
                              uint gid [[thread_position_in_grid]]) {
    uint side = uint(patchSize) * u.refineRatio;
    uint cells = side * side * side;
    uint at = patchList[gid / cells] * cells + gid % cells;
    uchar m = fineMask[at];
    fineMask[at] = (m & 2) | ((m >> 2) & 1);
    for (uint n = 0; n < 4; ++n) {
        fineOccupancy[4 * at + n] = 0;
    }
}
