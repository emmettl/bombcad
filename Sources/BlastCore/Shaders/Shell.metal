// Explicit shell elements for walls and slabs, appended to Structure.metal at compile time (it
// reuses `MaterialParameters`, `BarHistory`, the concrete and steel laws, `Cell` and
// `StepControl`).
//
// Each element is a flat four-node quadrilateral on a wall's or slab's midsurface, a
// degenerated solid: a point at height zeta (-1 to 1) through the thickness t lies at
// x = sum N_a (x_a + zeta t/2 d_a), where d_a is the director (the rotated normal) at node a.
// Nodes carry a rotation as well as a displacement. Strains are total Green-Lagrange strains in
// the element's reference axes, which are lattice axes, as in the solid elements. Membrane and
// bending use 2 x 2 points in the plane, each with a stack of layers through the thickness in
// plane stress; transverse shear uses the assumed strains of MITC4 (Bathe and Dvorkin, 1986),
// which avoids shear locking and leaves no spurious modes, so no hourglass control is needed.
// Layouts here must match `ShellTypes.swift`.

struct ShellUniforms {
    uint elementCount;
    uint nodeCount;
    uint layers;    // through the thickness of every element
    uint barSlots;  // bar layers stored per element
    uint substep;
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
    float groundFriction;  // < 0: no ground
    float rateFilter;      // 1 / time constant of the strain-rate average
    float loadTime;
    uint loadCount;  // entries in the applied-pressure table; 0 = none
    uint loadFace;   // 2 * axis + side of the face the applied pressure acts on
    float shearFactor;  // transverse shear correction, 5/6
    uint contactMode;   // 0 = off, 1 = once something has failed, 2 = always
    uint stamp;         // unique per substep; marks fresh entries in the contact table
    uint contactNx;     // the contact table wraps space every contactNx, Ny, Nz cells (powers of two)
    uint contactNy;
    uint contactNz;
    float contactRadius;     // nodes are spheres this far across; also the table's cell size
    float gridOriginX;
    float gridOriginY;
    float gridOriginZ;
    float contactStiffness;  // per unit of nodal mass
    float contactDamping;    // fraction of critical
    float contactFriction;
    float neighbourDistance;  // nodes that start closer than this never repel
    uint beamCount;
    float elementSize;  // nominal, for the removal width (`erosionStrain` is per element size)
    uint debrisLoading;  // non-zero: loose nodes are pushed by the air
    // Air cells around the structure in which debris and air exchange momentum and energy.
    int exchangeX;
    int exchangeY;
    int exchangeZ;
    int exchangeNx;
    int exchangeNy;
    int exchangeNz;
    uint fluidAirModel;  // the air's equation of state (`AirModel`)
    // The air's refinement, as in `StructureUniforms`.
    uint fluidRefine;
    uint fluidBlocksX;
    uint fluidBlocksY;
    uint crackSlip;  // 1: shear past a crack's interlock slides it for good, and it rides up
    // The base's connection to the ground (`Anchorage`), as in `StructureUniforms`.
    uint anchored;
    float anchorNormalStiffness;
    float anchorShearStiffness;
    float anchorTension;
    float anchorPlateau;
    float anchorOpening;
    float anchorCohesion;
    float anchorCohesionSlip;
    float anchorFriction;
    uint couplingMapCount;
};

AnchorLaw anchorLaw(constant ShellUniforms &u) {
    return AnchorLaw{u.anchorNormalStiffness, u.anchorShearStiffness, u.anchorTension, u.anchorPlateau,
                     u.anchorOpening, u.anchorCohesion, u.anchorCohesionSlip, u.anchorFriction, 0.0f,
                     {0.0f, 0.0f, 0.0f}};
}

// Slip through the thickness at which concrete cracked across a plane fails in direct shear:
// the removal width where no intact bars cross the plane; where they do, the slip at which the
// bars, kinking across the crack over their debonded length, reach their rupture strain.
static inline float debondedLength(constant MaterialParameters &m, constant ShellUniforms &u) {
    // The crack spacing (twice `barReach` elements), or the crack band where rupture is judged
    // locally.
    return m.barReach > 0.0f ? 2.0f * m.barReach * u.elementSize : m.crackBand;
}

static inline float slipLimit(bool bars, constant MaterialParameters &m, constant ShellUniforms &u) {
    if (bars && m.steelPoints > 0) {
        return sqrt(2.0f * m.steelStrain[m.steelPoints - 1]) * debondedLength(m, u);
    }
    return m.erosionStrain * u.elementSize;
}

// Shear stress that bars crossing a crack carry as it slides: dowel action, 1.65 rho
// sqrt(fc fy) for a ratio rho of bars across the crack (Rasmussen, 1963), as in the solid
// elements, until the bars have kinked past rupture across it (`slide` is the slide over the
// debonded length), when the element is also removed. Kinking itself, the bars' tension
// leaning along the slide, needs no term of its own here: a shell that slides across a crack
// tilts (or, in its plane, shears) as a whole, and its bar layers' tension turns with it.
static inline float barShear(float crossing, float slide, constant MaterialParameters &m) {
    if (crossing <= 0.0f || m.steelPoints == 0) {
        return 0.0f;
    }
    float yield = m.steelStress[0];
    float stretch = sqrt(1.0f + slide * slide) - 1.0f;
    if (stretch - yield / m.steelModulus > m.steelStrain[m.steelPoints - 1]) {
        return 0.0f;
    }
    return m.dowelFactor * 1.65f * crossing * sqrt(m.compressiveStrength * yield);
}

// Shear strength of a concrete member's section, as a mean stress over its whole depth, by the
// simplified modified compression field theory (Bentz, Vecchio and Collins, 2006; the general
// method of CSA A23.3): V = (beta sqrt(fc) + rho_v fy cot theta) b d_v, where
// beta = 0.4 / (1 + 1500 e_x) times the size factor 1300 / (1000 + s_ze) for a member without
// enough stirrups (worked out with d_v when the mesh is made, `sizeFactor`), and
// theta = 29 + 7000 e_x degrees. e_x is the longitudinal strain at mid-depth, taken from the
// element itself. `depthRatio` is d_v over the depth; `stirrups` the stirrups' ratio. The
// concrete's part rises with strain rate as its tensile strength does (`rate`). The second
// value is the stirrups' part alone, which is what is left once the section has failed.
// The method's longitudinal strain at mid-depth, from the section's forces: e_x = (|M| / d_v + |V|
// + N / 2) / (2 Es As), As being the bars on the tension side. The element's own strain at
// mid-depth would not do: where a crack has gathered into one element, as at a hinge, it is far
// larger than the average over a crack spacing that the method is built on, and a section that
// yielded in bending would at once lose its shear strength.
static inline float sectionStrain(float moment, float shear, float normal, float dv, float tensionBars,
                                  constant MaterialParameters &m) {
    if (tensionBars <= 0.0f || m.steelPoints == 0) {
        return 3e-3f;
    }
    return (fabs(moment) / max(dv, 1e-6f) + fabs(shear) + 0.5f * normal) / (2.0f * m.steelModulus * tensionBars);
}

// Near a support or a point load, within about an effective depth, the load goes straight to
// it by arching and no diagonal crack forms between: the concrete's part is raised by the
// shear-span factor of earlier editions of ACI 318, 3.5 - 2.5 M / (V d), between 1 and 2.5.
// Without it, the sudden shear at the supports of a slab struck by a blast, which is direct
// shear and not diagonal tension, broke them at once.
static inline float shearSpanFactor(float moment, float shear, float d) {
    float span = fabs(moment) / max(fabs(shear) * d, 1e-6f);
    return clamp(3.5f - 2.5f * span, 1.0f, 2.5f);
}

static inline float2 sectionShearStrength(float strain, float depthRatio, float sizeFactor, float stirrups, float rate,
                                          constant MaterialParameters &m) {
    float ex = clamp(strain, -0.2e-3f, 3e-3f);
    float beta = 0.4f / (1.0f + 1500.0f * ex) * sizeFactor;
    float root = min(sqrt(m.compressiveStrength / 1e6f), 8.0f) * 1e6f;
    float theta = (29.0f + 7000.0f * ex) * M_PI_F / 180.0f;
    float steel = m.steelPoints > 0 ? stirrups * m.steelStress[0] / tan(theta) : 0.0f;
    return float2(beta * root * rate + steel, steel) * depthRatio;
}

struct BeamElement {
    uint node[2];
    uint axis;  // along the beam; the section's sides are along the next two axes, in order
    uint material;
    float width;   // side of the section along the first of those
    float depth;   // along the second
    float length;
    uint barCount;  // bar groups, in `beamBarLayout`
    float tieRatio;
    float padding0;
    float padding1;
};

constant uint maxBeamBars = 8;

struct BeamForces {
    packed_float3 force[2];
    packed_float3 moment[2];
};

// Incidence entries with this bit set refer to beams.
constant uint beamIncidence = 0x80000000u;

// Fibres across a beam's section: 4 x 4 Gauss-Legendre points.
constant uint beamFibres = 4;
constant float beamFibrePoints[4] = {-0.86113631159f, -0.33998104541f, 0.33998104541f, 0.86113631159f};
constant float beamFibreWeights[4] = {0.34785484514f, 0.65214515486f, 0.65214515486f, 0.34785484514f};

struct ShellElement {
    uint node[4];  // corners (0, 0), (1, 0), (1, 1), (0, 1) along the element's own axes
    uint axis;     // through the thickness; the element's own axes are the next two, in order
    uint material;
    uint barCount;
    float thickness;
    float a;  // side along the first axis
    float b;  // side along the second
};

struct ShellNode {
    packed_float3 displacement;
    float mass;
    packed_float3 velocity;
    uint flags;  // bits 0-2: x, y, z held still; bit 3: motion prescribed; bit 4: rests on a
                 // support; bit 6: rotation held
    packed_float3 spin;  // angular velocity
    float inertia;       // rotational inertia, the same about every axis
    float4 rotation;     // unit quaternion (x, y, z, w) from the reference orientation
};

constant uint shellRotationHeld = 64u;
// A node tied rigidly to another (a slab node within a column's footprint): it is moved with
// the other, which takes its forces.
constant uint shellTied = 128u;
// Tied into a solid element of another body, which moves it (see `InterfaceLink`).
constant uint shellOnSolid = 256u;

// State of one layer at one of the four in-plane points (or one fibre of a beam), as stored:
// 40 bytes. The strain-rate average and the frozen tensile factor need only half precision.
struct ShellLayerStore {
    packed_float2 crack;  // concrete: largest tensile strain across the planes normal to the
                          // element's axes; von Mises: plastic strain along them
    packed_float2 crush;  // concrete: largest compressive strain along the axes; von Mises:
                          // plastic shear strain and equivalent plastic strain
    half rate;            // running average of the effective strain rate
    half crackingFactor;  // tensile rate factor frozen when the layer first cracked
    packed_float2 residual;  // concrete: opening each crack keeps once closed, as a strain
    // Concrete: what its cracks have slid for good, as shear strains: through the thickness
    // across the planes normal to x and y, and in-plane (a beam fibre: its two shears).
    packed_float3 slip;
};

// The same, as worked on, with the layer's damage for display (0 sound, 1 failing).
struct ShellLayer {
    float2 crack;
    float2 crush;
    float rate;
    float crackingFactor;
    float2 residual;
    float3 slip;
    float display;
};

static inline ShellLayer loadLayer(const device ShellLayerStore &stored) {
    ShellLayer layer;
    layer.crack = float2(stored.crack);
    layer.crush = float2(stored.crush);
    layer.rate = float(stored.rate);
    layer.crackingFactor = float(stored.crackingFactor);
    layer.residual = float2(stored.residual);
    layer.slip = float3(stored.slip);
    layer.display = 0.0f;
    return layer;
}

static inline void storeLayer(device ShellLayerStore &stored, thread const ShellLayer &layer) {
    stored.crack = layer.crack;
    stored.crush = layer.crush;
    stored.rate = half(min(layer.rate, 60000.0f));
    stored.crackingFactor = half(layer.crackingFactor);
    stored.residual = layer.residual;
    stored.slip = layer.slip;
}

// One bar layer, one direction, at one in-plane point.
struct ShellBar {
    BarHistory history;
    float plastic;
};

struct ShellForces {
    packed_float3 force[4];
    packed_float3 moment[4];
};

static inline float shellStep(constant ShellUniforms &u, const device StepControl &control, thread bool &active) {
    if (u.fixedStep > 0.0f) {
        active = true;
        return u.fixedStep;
    }
    float fluidStep = control.dt;
    uint needed = max(1u, uint(ceil(fluidStep / u.criticalStep)));
    active = fluidStep > 0.0f && u.substep < needed;
    return fluidStep / float(needed);
}

// v rotated by the unit quaternion q, less v itself, without the cancellation of forming both.
static inline float3 rotationOffset(float4 q, float3 v) {
    float3 t = 2.0f * cross(q.xyz, v);
    return q.w * t + cross(q.xyz, t);
}

static inline float shapeValue(float2 corner, float2 p) {
    return 0.25f * (1.0f + corner.x * p.x) * (1.0f + corner.y * p.y);
}

static inline float2 shapeSlope(float2 corner, float2 p) {
    return 0.25f * float2(corner.x * (1.0f + corner.y * p.y), corner.y * (1.0f + corner.x * p.x));
}

constant float2 shellCorners[4] = {float2(-1.0f, -1.0f), float2(1.0f, -1.0f), float2(1.0f, 1.0f), float2(-1.0f, 1.0f)};

// Overpressure of the air on one side of a shell: the first fluid cell beyond the shell's face,
// within three cells.
static inline float shellOverpressure(float3 point, float3 normal, float halfThickness, const device Cell *fluid,
                                      const device uchar *fluidMask, const device int *patchOfTile,
                                      const device Cell *fine, const device uchar *fineMask,
                                      constant ShellUniforms &u) {
    return overpressureAlong(point, normal, halfThickness, 3, fluid, fluidMask, patchOfTile, fine, fineMask,
                             u.fluidRefine,
                             u.fluidBlocksX, u.fluidBlocksY, u.fluidCell, int3(u.fluidNx, u.fluidNy, u.fluidNz),
                             u.fluidAirModel, u.fluidGamma, u.ambientPressure);
}

// What a layer reports besides its stresses.
struct LayerOutcome {
    float2 torn;      // per in-plane axis: 1 where the crack across that axis is wide enough to remove
    float2 slid;      // per in-plane axis: 1 where the layer is cracked across it
    bool destroyed;   // crushed through, or cracked wide enough to remove, whatever the bars do
    bool failed;      // von Mises: past its failure strain
    bool open;        // cracked wider than the hard limit that removes it whatever bridges it
};

// Plane-stress concrete: the solid elements' law with the through-thickness stress zero. The
// layer's in-plane strains (E11, E22 and the tensor shear E12) give equivalent uniaxial strains
// along the element's axes, cracks are smeared over the two planes normal to them, and a
// diagonal crack is found from the principal values of the elastic stress over E. There is no
// confinement, since a plate in plane stress is free through its thickness. Transverse shear
// across a cracked plane is carried by aggregate interlock, as in-plane shear is.
static inline float3 shellConcrete(float3 strain, float2 transverse, float instantaneous, float dt,
                                   thread ShellLayer &state, constant MaterialParameters &m,
                                   constant ShellUniforms &u, bool reinforced, float2 crossing, float2 lengths,
                                   bool punched, uint sheared, thread float2 &shear, thread LayerOutcome &outcome) {
    state.rate += clamp(dt * u.rateFilter, 0.0f, 1.0f) * (instantaneous - state.rate);
    float2 history = state.crack;
    float worst = max(history.x, history.y);
    float tensionFactor = state.crackingFactor;
    if (tensionFactor <= 0.0f) {
        tensionFactor = tensionIncrease(state.rate, m);
        if (worst > m.crackOnset * tensionFactor) {
            state.crackingFactor = tensionFactor;
        }
    }
    float onset = m.crackOnset * tensionFactor;

    float poisson = 0.5f * m.lambda / (m.lambda + m.mu);
    if (worst > onset) {
        poisson *= tensionEnvelope(worst, tensionFactor, m) / (m.youngsModulus * worst);
    }
    float scale = 1.0f / (1.0f - poisson * poisson);
    float2 uniaxial = float2(strain.x + poisson * strain.y, strain.y + poisson * strain.x) * scale;

    // Rankine: principal values of the elastic stress over E, shared between the two planes in
    // proportion to the squared direction cosines.
    float shearOverE = strain.z / (1.0f + poisson);
    float centre = 0.5f * (uniaxial.x + uniaxial.y);
    float radius = sqrt(0.25f * (uniaxial.x - uniaxial.y) * (uniaxial.x - uniaxial.y) + shearOverE * shearOverE);
    // Squared direction cosines of the major principal direction, without trigonometry.
    float c2 = radius > 0.0f ? 0.5f * (1.0f + 0.5f * (uniaxial.x - uniaxial.y) / radius) : 1.0f;
    float s2 = 1.0f - c2;
    float2 principal = float2(centre + radius, centre - radius);
    float2 directions[2] = {float2(c2, s2), float2(s2, c2)};
    for (int i = 0; i < 2; ++i) {
        float2 weight = directions[i];
        float seen = dot(weight, history);
        if (principal[i] > seen && principal[i] > onset) {
            history += (principal[i] - seen) * weight / dot(weight, weight);
        }
    }
    // Diagonal cracks through the thickness, from the normal stress along each axis with the
    // transverse shear across it: the principal tension in that plane, shared with the plane
    // across the thickness (which is not tracked, and taken as cracked alike), so that pure
    // shear cracks as much as the solid elements' shared planes do.
    for (int j = 0; j < 2; ++j) {
        float normalOverE = uniaxial[j];
        float shearOverE = u.shearFactor * transverse[j] / (2.0f * (1.0f + poisson));
        float radius = sqrt(0.25f * normalOverE * normalOverE + shearOverE * shearOverE);
        float tension = 0.5f * normalOverE + radius;
        if (tension > history[j] && tension > onset && radius > 0.0f) {
            float c2 = 0.5f * (1.0f + 0.5f * normalOverE / radius);
            float s2 = 1.0f - c2;
            history[j] += (tension - history[j]) * c2 / (c2 * c2 + s2 * s2);
        }
    }
    history = max(history, uniaxial);
    state.crack = history;
    float crack = max(history.x, history.y);

    float2 residual = float2(settledResidual(state.residual.x, history.x, uniaxial.x, tensionFactor, m),
                             settledResidual(state.residual.y, history.y, uniaxial.y, tensionFactor, m));
    // A crack that has slid cannot close: it keeps `crackDilatancy` times its slip open (see the
    // solid elements), the plane normal to x sliding in-plane and through the thickness across x.
    if (u.crackSlip != 0 && m.crackDilatancy > 0.0f) {
        float2 across = float2(length(float2(state.slip.z, state.slip.x)), length(float2(state.slip.z, state.slip.y)));
        for (int j = 0; j < 2; ++j) {
            if (history[j] > onset) {
                float held = min(m.crackDilatancy * across[j], min(uniaxial[j], 0.9f * history[j]));
                residual[j] = max(residual[j], held);
            }
        }
    }
    state.residual = residual;
    float2 squeeze = residual - uniaxial;
    float2 crush = max(state.crush, squeeze);
    state.crush = crush;

    float2 normalStress;
    float crushed = 0.0f;
    bool pulverised = false;
    // The compressive rate factor is wanted only where the layer is squeezed.
    float compressionFactor = any(squeeze > 0.0f) ? compressionIncrease(state.rate, m) : 1.0f;
    for (int j = 0; j < 2; ++j) {
        if (squeeze[j] <= 0.0f) {
            normalStress[j] = concreteTension(uniaxial[j], history[j], residual[j], tensionFactor, m);
            continue;
        }
        normalStress[j] = concreteCompression(squeeze[j], crush[j], crush[j], compressionFactor, 1.0f, m);
        float2 limits = crushStrains(compressionFactor, 1.0f, m);
        crushed = max(crushed, clamp((squeeze[j] - limits.x) / (limits.y - limits.x), 0.0f, 1.0f));
        pulverised = pulverised || squeeze[j] >= limits.y + m.crushErosion * (limits.y - limits.x);
    }

    // Shear on the planes normal to the axes, in-plane (xy) and through the thickness (x3, y3),
    // reduced and capped once the plane it crosses has cracked.
    float opened = crack - onset;
    float width = max(opened, 0.0f) * m.crackBand;
    float interlock = m.interlockStrength * tensionFactor / (0.31f + m.interlockWidthScale * width);
    // With `crackSlip`, the shear is that of the strain less what the cracks have slid by for good;
    // what interlock and dowels cannot hold, they slide by (see the solid elements).
    bool slides = u.crackSlip != 0;
    float3 slip = slides ? state.slip : float3(0.0f);
    float inPlane = m.mu * (2.0f * strain.z - slip.z);
    // Bars across a crack add dowel action to the interlock: those along the axis the crack
    // lies across, sliding by the shear strain over the element's length.
    float debonded = debondedLength(m, u);
    if (opened > 0.0f) {
        int across = history.x >= history.y ? 0 : 1;
        float slide = fabs(2.0f * strain.z) * lengths[across] / max(debonded, lengths[across]);
        float limit = interlock + barShear(crossing[across], slide, m);
        float trial = m.shearRetention * inPlane;
        inPlane = clamp(trial, -limit, limit);
        if (slides && trial != inPlane) {
            slip.z += (trial - inPlane) / (m.shearRetention * m.mu);
        }
    }
    for (int j = 0; j < 2; ++j) {
        float stress = u.shearFactor * m.mu * (transverse[j] - slip[j]);
        float across = history[j] - onset;
        float slide = fabs(transverse[j]) * lengths[j] / max(debonded, lengths[j]);
        if (((sheared >> j) & 1u) != 0u) {
            // The section has failed in shear this way: the concrete carries none, and a shell
            // has no stirrups.
            stress = 0.0f;
        } else if (punched) {
            // Punched through at a column head: the concrete's cone has sheared off, and only
            // the bars crossing it hold the slab.
            float limit = barShear(crossing[j], slide, m);
            stress = clamp(m.shearRetention * stress, -limit, limit);
        } else if (across > 0.0f) {
            float w = across * m.crackBand;
            float limit = m.interlockStrength * tensionFactor / (0.31f + m.interlockWidthScale * w)
                + barShear(crossing[j], slide, m);
            float trial = m.shearRetention * stress;
            stress = clamp(trial, -limit, limit);
            if (slides && trial != stress) {
                slip[j] += (trial - stress) / (m.shearRetention * u.shearFactor * m.mu);
            }
        }
        shear[j] = stress;
    }
    if (slides) {
        state.slip = slip;
    }

    outcome.torn = float2(history.x >= m.erosionStrain ? 1.0f : 0.0f, history.y >= m.erosionStrain ? 1.0f : 0.0f);
    for (int j = 0; j < 2; ++j) {
        outcome.slid[j] = history[j] > onset ? 1.0f : 0.0f;
    }
    outcome.destroyed = pulverised || crack >= m.erosionStrain;
    outcome.open = crack > max(1.0f, 3.0f * m.erosionStrain);
    outcome.failed = false;
    // Damage as the solid elements show it: cracking against the bars' rupture strain where
    // there are bars, or the removal strain where there are none.
    state.display = max(crack / (reinforced ? m.steelStrain[m.steelPoints - 1] : m.erosionStrain), crushed);
    return float3(normalStress, inPlane);
}

// Plane-stress von Mises plasticity with linear hardening on the Green-Lagrange strain (a
// St Venant-Kirchhoff material): the return of Simo and Taylor (1986), solving for the plastic
// multiplier by Newton's method. Transverse shear stays elastic.
static inline float3 shellVonMises(float3 strain, float2 transverse, thread ShellLayer &state,
                                   constant MaterialParameters &m, constant ShellUniforms &u, thread float2 &shear,
                                   thread LayerOutcome &outcome) {
    float young = m.youngsModulus;
    float nu = 0.5f * m.lambda / (m.lambda + m.mu);
    float g = m.mu;
    float plate = young / (1.0f - nu * nu);
    float3 elastic = strain - float3(state.crack, state.crush.x);  // E11, E22, E12 (tensor shear)
    float3 trial = float3(plate * (elastic.x + nu * elastic.y), plate * (elastic.y + nu * elastic.x),
                          2.0f * g * elastic.z);
    float plastic = state.crush.y;
    float sumA = (trial.x + trial.y) / sqrt(2.0f);
    float diffB = (trial.y - trial.x) / sqrt(2.0f);
    float shearC = trial.z;
    float kA = young / (3.0f * (1.0f - nu));
    float kB = 2.0f * g;
    // f^2(dg) = (1/2) xi^T P xi after the return, with xi scaled mode by mode.
    auto squared = [&](float dg) {
        float a = sumA / (1.0f + kA * dg);
        float b = diffB / (1.0f + kB * dg);
        float c = shearC / (1.0f + kB * dg);
        return (1.0f / 6.0f) * a * a + 0.5f * (b * b + 2.0f * c * c);
    };
    auto residual = [&](float dg) {
        float f2 = squared(dg);
        float equivalent = plastic + sqrt(2.0f / 3.0f) * dg * sqrt(2.0f * f2);
        return sqrt(3.0f * f2) - (m.yieldStress + m.hardening * equivalent);
    };
    float3 stress = trial;
    if (residual(0.0f) > 0.0f) {
        float dg = 0.0f;
        for (int iteration = 0; iteration < 12; ++iteration) {
            float r = residual(dg);
            float step = max(1e-12f, 1e-6f * (dg + 1e-9f));
            float slope = (residual(dg + step) - r) / step;
            float next = dg - r / min(slope, -1e-30f);
            dg = max(next, 0.5f * dg);
        }
        float f2 = squared(dg);
        float a = sumA / (1.0f + kA * dg);
        float b = diffB / (1.0f + kB * dg);
        stress = float3((a - b) / sqrt(2.0f), (a + b) / sqrt(2.0f), shearC / (1.0f + kB * dg));
        plastic += sqrt(2.0f / 3.0f) * dg * sqrt(2.0f * f2);
        // The plastic strain is what the stress no longer accounts for.
        float3 recovered = float3((stress.x - nu * stress.y) / young, (stress.y - nu * stress.x) / young,
                                  stress.z / (2.0f * g));
        float3 plasticStrain = strain - recovered;
        state.crack = plasticStrain.xy;
        state.crush = float2(plasticStrain.z, plastic);
    }
    shear = u.shearFactor * g * transverse;
    outcome.torn = float2(0.0f);
    outcome.slid = float2(0.0f);
    outcome.destroyed = false;
    outcome.open = false;
    outcome.failed = plastic >= m.failureStrain;
    state.display = plastic / m.failureStrain;
    return stress;
}

// Stress in one direction of a bar layer, as the solid elements' bars: the measured curve while
// loaded one way, the cyclic law once reversed. A bar slips in its concrete either side of a
// crack, so it ruptures when its plastic strain averaged over the debonded length passes the
// rupture strain: `spread` gives that average from this bar's plastic strain. Returns false once
// the bars have ruptured.
static inline bool shellBar(device ShellBar &bar, float green, float rate, constant MaterialParameters &m,
                            thread float &stress, thread float &root, thread float &yieldOut,
                            thread float2 &spread) {
    float plastic = bar.plastic;
    if (fabs(plastic) > 1e8f) {
        return false;
    }
    root = sqrt(max(1.0f + 2.0f * green, 1e-6f));
    float fibre = 2.0f * green / (1.0f + root);
    stress = m.steelModulus * (fibre - plastic);
    if (plastic == 0.0f && fabs(stress) <= m.steelStress[0]) {
        // Below the static yield stress a bar that has never yielded is elastic whatever its
        // rate factor (which is at least one), so the factor need not be worked out.
        if (fabs(spread.y) > m.steelStrain[m.steelPoints - 1]) {
            bar.plastic = 1e9f;  // its neighbours have pulled it past rupture
            return false;
        }
        yieldOut = m.steelStress[0];
        spread.x = 0.0f;
        return true;
    }
    float accumulated = fabs(plastic);
    float slope;
    float yield = steelYield(accumulated, m, slope);
    float first = m.steelStress[0];
    float top = m.steelStress[m.steelPoints - 1];
    float along = clamp((yield - first) / max(top - first, 1.0f), 0.0f, 1.0f);
    float2 factors = steelRateFactors(rate, m);
    float factor = mix(factors.x, factors.y, along);
    yield *= factor;
    if (plastic == 0.0f) {
        if (fabs(stress) > yield) {
            float increment = (fabs(stress) - yield) / max(m.steelModulus + slope * factor, 0.1f * m.steelModulus);
            plastic = stress > 0.0f ? increment : -increment;
            stress = m.steelModulus * (fibre - plastic);
        }
    } else {
        stress = cycleBar(bar.history, fibre, plastic, yield, slope * factor, first * factors.x, m);
    }
    float averaged = (plastic * spread.x + spread.y);
    if (fabs(averaged) > m.steelStrain[m.steelPoints - 1]) {
        bar.plastic = 1e9f;  // ruptured for good
        return false;
    }
    bar.plastic = plastic;
    spread.x = plastic;
    yieldOut = yield;
    return true;
}

kernel void shellElements(device ShellLayerStore *layers [[buffer(0)]],
                          device ShellForces *forces [[buffer(1)]],
                          device uchar *flags [[buffer(2)]],
                          const device ShellNode *nodes [[buffer(3)]],
                          const device float4 *reference [[buffer(4)]],
                          const device ShellElement *elements [[buffer(5)]],
                          const device float4 *barLayout [[buffer(6)]],
                          device ShellBar *bars [[buffer(7)]],
                          constant MaterialParameters *materials [[buffer(8)]],
                          constant ShellUniforms &u [[buffer(9)]],
                          const device StepControl &control [[buffer(10)]],
                          const device Cell *fluid [[buffer(11)]],
                          const device uchar *fluidMask [[buffer(12)]],
                          const device float2 *loadTable [[buffer(13)]],
                          device uint *failureGate [[buffer(14)]],
                          device float *display [[buffer(15)]],
                          constant float2 *thickness [[buffer(16)]],
                          const device int4 *neighbours [[buffer(17)]],
                          device float *barPlasticOut [[buffer(18)]],
                          const device float *barPlasticBefore [[buffer(19)]],
                          const device int *patchOfTile [[buffer(20)]],
                          const device Cell *fineAir [[buffer(21)]],
                          const device uchar *fineAirMask [[buffer(22)]],
                          const device float *punchStrength [[buffer(23)]],
                          device uchar *punched [[buffer(24)]],
                          const device int *ringOfElement [[buffer(25)]],
                          const device uint *ringStart [[buffer(26)]],
                          const device uint *ringMember [[buffer(27)]],
                          device float *ringShearOut [[buffer(28)]],
                          const device float *ringShearBefore [[buffer(29)]],
                          device float4 *section [[buffer(30)]],
                          uint lane [[thread_position_in_grid]]) {
    // Four threads per element, one for each of its in-plane points, in adjacent lanes (a quad);
    // their shares of the forces are summed across the quad at the end.
    uint e = lane >> 2;
    uint g = lane & 3u;
    bool active;
    float dt = shellStep(u, control, active);
    if (!active || e >= u.elementCount || flags[e] != elementActive) {
        return;
    }
    ShellElement el = elements[e];
    constant MaterialParameters &m = materials[min(el.material, maxMaterials - 1)];
    uint k = el.axis;
    uint i1 = (k + 1) % 3;
    uint i2 = (k + 2) % 3;
    float3 e1 = float3(0.0f);
    float3 e2 = float3(0.0f);
    float3 normal = float3(0.0f);
    e1[i1] = 1.0f;
    e2[i2] = 1.0f;
    normal[k] = 1.0f;
    float t = el.thickness;
    float a = el.a;
    float b = el.b;

    float3 x[4];
    float3 disp[4];
    float3 vel[4];
    float3 offset[4];  // director less the reference normal
    float3 director[4];
    float3 turn[4];  // rate of change of the director
    for (uint c = 0; c < 4; ++c) {
        ShellNode node = nodes[el.node[c]];
        disp[c] = float3(node.displacement);
        vel[c] = float3(node.velocity);
        x[c] = reference[el.node[c]].xyz + disp[c];
        offset[c] = rotationOffset(node.rotation, normal);
        director[c] = normal + offset[c];
        turn[c] = cross(float3(node.spin), director[c]);
    }

    // Transverse shear strains at the MITC4 tying points: gamma13 at the middles of the edges
    // eta = -1 and +1, gamma23 at the middles of xi = -1 and +1.
    const float2 tying[4] = {float2(0.0f, -1.0f), float2(0.0f, 1.0f), float2(-1.0f, 0.0f), float2(1.0f, 0.0f)};
    float gammaTie[4];
    float3 tangentTie[4];  // f1 at the first two points, f2 at the last two
    float3 directorTie[4];
    for (uint p = 0; p < 4; ++p) {
        float3 h = float3(0.0f);
        float3 delta = float3(0.0f);
        for (uint c = 0; c < 4; ++c) {
            float2 slope = shapeSlope(shellCorners[c], tying[p]);
            h += (p < 2 ? 2.0f / a * slope.x : 2.0f / b * slope.y) * disp[c];
            delta += shapeValue(shellCorners[c], tying[p]) * offset[c];
        }
        uint along = p < 2 ? i1 : i2;
        gammaTie[p] = delta[along] + h[k] + dot(h, delta);
        tangentTie[p] = (p < 2 ? e1 : e2) + h;
        directorTie[p] = normal + delta;
    }

    float3 nodeForce[4] = {float3(0.0f), float3(0.0f), float3(0.0f), float3(0.0f)};
    float3 directorForce[4] = {float3(0.0f), float3(0.0f), float3(0.0f), float3(0.0f)};
    float tieForce[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    float applied = tablePressure(loadTable, u.loadCount, u.loadTime);
    uint n = u.layers;
    float areaWeight = 0.25f * a * b;
    bool remove = false;
    bool punching = false;
    float meanShear = 0.0f;
    float2 shearRatio = float2(0.0f);  // mean shear through the thickness over the section's strength
    float worstDisplay = 0.0f;
    // Each bar layer's plastic strain, averaged over the element, for its neighbours' rupture.
    float barMean[8] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    const float gauss = 0.57735026919f;

    {
        float2 p = shellCorners[g] * gauss;
        float3 h1m = float3(0.0f);
        float3 h1b = float3(0.0f);
        float3 h2m = float3(0.0f);
        float3 h2b = float3(0.0f);
        float3 r1m = float3(0.0f);
        float3 r1b = float3(0.0f);
        float3 r2m = float3(0.0f);
        float3 r2b = float3(0.0f);
        float3 centre = float3(0.0f);
        for (uint c = 0; c < 4; ++c) {
            float2 slope = shapeSlope(shellCorners[c], p);
            float s1 = 2.0f / a * slope.x;
            float s2 = 2.0f / b * slope.y;
            h1m += s1 * disp[c];
            h2m += s2 * disp[c];
            h1b += 0.5f * t * s1 * offset[c];
            h2b += 0.5f * t * s2 * offset[c];
            r1m += s1 * vel[c];
            r2m += s2 * vel[c];
            r1b += 0.5f * t * s1 * turn[c];
            r2b += 0.5f * t * s2 * turn[c];
            centre += shapeValue(shellCorners[c], p) * x[c];
        }
        float2 transverse = float2(0.5f * (1.0f - p.y) * gammaTie[0] + 0.5f * (1.0f + p.y) * gammaTie[1],
                                   0.5f * (1.0f - p.x) * gammaTie[2] + 0.5f * (1.0f + p.x) * gammaTie[3]);

        float3 p1 = float3(0.0f);
        float3 q1 = float3(0.0f);
        float3 p2 = float3(0.0f);
        float3 q2 = float3(0.0f);
        float2 shearSum = float2(0.0f);
        float2 normalSum = float2(0.0f);  // the section's normal force and moment across each axis,
        float2 momentSum = float2(0.0f);  // times the element's area weight
        // Intact bars per unit area of concrete along each axis, for the shear they carry
        // across cracks. Once punched, only the bars in the bottom face (away from the top, the
        // face a slab hogs towards over its column) count: the top bars are pushed up against
        // their cover and rip it off, while the bottom bars run on over the column and hold.
        // The element's state as a member: bit 0, punched at a column head; bits 1 and 2, its
        // section failed in shear across the first and second axes.
        uint memberState = punched[e];
        bool punchedThrough = (memberState & 1u) != 0u;
        uint sheared = (memberState >> 1) & 3u;
        float2 crossing = float2(0.0f);
        for (uint s = 0; s < el.barCount && s < u.barSlots; ++s) {
            float4 layout = barLayout[e * u.barSlots + s];
            if (punchedThrough && layout.x > 0.0f) {
                continue;
            }
            for (uint j = 0; j < 2; ++j) {
                if (layout[1 + j] > 0.0f && fabs(bars[((e * 4 + g) * u.barSlots + s) * 2 + j].plastic) < 1e8f) {
                    crossing[j] += layout[1 + j] / t;
                }
            }
        }
        float2 tornEverywhere = float2(1.0f);
        float2 slidEverywhere = float2(1.0f);
        bool destroyedEverywhere = true;
        bool openEverywhere = true;
        float rateSum = 0.0f;
        for (uint l = 0; l < n; ++l) {
            // Gauss-Legendre points through the thickness, exact for elastic bending.
            float zeta = thickness[l].x;
            float layerWeight = areaWeight * 0.5f * t * thickness[l].y;
            float3 h1 = h1m + zeta * h1b;
            float3 h2 = h2m + zeta * h2b;
            float3 f1 = e1 + h1;
            float3 f2 = e2 + h2;
            float3 strain = float3(h1[i1] + 0.5f * dot(h1, h1), h2[i2] + 0.5f * dot(h2, h2),
                                   0.5f * (h1[i2] + h2[i1] + dot(h1, h2)));
            float3 d1 = r1m + zeta * r1b;
            float3 d2 = r2m + zeta * r2b;
            float3 rate = float3(dot(f1, d1), dot(f2, d2), 0.5f * (dot(f1, d2) + dot(f2, d1)));
            float instantaneous = sqrt((2.0f / 3.0f) * (rate.x * rate.x + rate.y * rate.y + 2.0f * rate.z * rate.z));
            uint slot = (e * 4 + g) * n + l;
            ShellLayer state = loadLayer(layers[slot]);
            float2 shear;
            LayerOutcome outcome;
            float3 stress = m.materialModel == 0
                ? shellVonMises(strain, transverse, state, m, u, shear, outcome)
                : shellConcrete(strain, transverse, instantaneous, dt, state, m, u, el.barCount > 0, crossing,
                                float2(a, b), punchedThrough, sheared, shear, outcome);
            storeLayer(layers[slot], state);
            rateSum += state.rate;
            worstDisplay = max(worstDisplay, state.display);
            remove = remove || outcome.failed;
            tornEverywhere *= outcome.torn;
            slidEverywhere *= outcome.slid;
            destroyedEverywhere = destroyedEverywhere && outcome.destroyed;
            openEverywhere = openEverywhere && outcome.open;

            float3 r1 = stress.x * f1 + stress.z * f2;
            float3 r2 = stress.y * f2 + stress.z * f1;
            p1 += layerWeight * r1;
            q1 += layerWeight * zeta * r1;
            p2 += layerWeight * r2;
            q2 += layerWeight * zeta * r2;
            shearSum += layerWeight * shear;
            normalSum += layerWeight * stress.xy;
            momentSum += layerWeight * 0.5f * t * zeta * stress.xy;
        }

        // Bar layers, at their own depths, both ways.
        float2 barsIntact = float2(0.0f);
        bool anyBars = false;
        for (uint s = 0; s < el.barCount && s < u.barSlots; ++s) {
            float4 layout = barLayout[e * u.barSlots + s];
            float zeta = layout.x;
            // Punched, the top bars have ripped out of their cover and hold nothing.
            if (punchedThrough && zeta > 0.0f) {
                continue;
            }
            for (uint j = 0; j < 2; ++j) {
                float area = layout[1 + j];
                if (area <= 0.0f) {
                    continue;
                }
                anyBars = true;
                // The neighbours along the bars, out to the debonded length, as of the previous
                // substep; elements at the ends of the window count in part.
                float2 spread = float2(1.0f, 0.0f);
                if (m.barReach > 0.0f) {
                    float weights = 1.0f;
                    float sum = 0.0f;
                    int r = int(ceil(m.barReach - 0.5f));
                    for (int side = 0; side < 2; ++side) {
                        int current = int(e);
                        for (int step = 1; step <= r; ++step) {
                            current = neighbours[current][2 * j + side];
                            if (current < 0) {
                                break;
                            }
                            float neighbour = barPlasticBefore[(uint(current) * u.barSlots + s) * 2 + j];
                            if (fabs(neighbour) < 1e8f) {
                                float weight = clamp(m.barReach + 0.5f - float(step), 0.0f, 1.0f);
                                sum += weight * neighbour;
                                weights += weight;
                            }
                        }
                    }
                    spread = float2(1.0f / weights, sum / weights);
                }
                float3 h = j == 0 ? h1m + zeta * h1b : h2m + zeta * h2b;
                float green = (j == 0 ? h[i1] : h[i2]) + 0.5f * dot(h, h);
                float3 f = (j == 0 ? e1 : e2) + h;
                float stress;
                float root;
                float yield;
                device ShellBar &bar = bars[((e * 4 + g) * u.barSlots + s) * 2 + j];
                if (!shellBar(bar, green, rateSum / float(n), m, stress, root, yield, spread)) {
                    continue;
                }
                barMean[s * 2 + j] += 0.25f * spread.x;
                barsIntact[j] = 1.0f;
                float3 r = (areaWeight * area * stress / root) * f;
                normalSum[j] += areaWeight * area * stress;
                momentSum[j] += areaWeight * area * stress * 0.5f * t * zeta;
                if (j == 0) {
                    p1 += r;
                    q1 += zeta * r;
                } else {
                    p2 += r;
                    q2 += zeta * r;
                }
            }
        }
        // A crack wide enough to count as a gap through the whole thickness removes the element,
        // unless intact bars cross it; so does concrete destroyed through its whole thickness
        // with no bars left at all, and any crack past the hard limit.
        bool torn = (tornEverywhere.x > 0.0f && barsIntact.x == 0.0f) || (tornEverywhere.y > 0.0f && barsIntact.y == 0.0f);
        bool bare = !anyBars || (barsIntact.x + barsIntact.y == 0.0f);
        // Punching: the ring of elements around a column head punches through together when
        // their mean shear through the thickness, averaged around the ring (as of the previous
        // substep), passes the connection's punching strength, raised with strain rate as
        // tension is. From then on they are held only by their bars (above).
        meanShear = length(shearSum) / (areaWeight * t);
        int ring = ringOfElement[e];
        if (ring >= 0 && !punchedThrough && m.materialModel != 0) {
            float sum = 0.0f;
            uint first = ringStart[ring];
            uint last = ringStart[ring + 1];
            for (uint r = first; r < last; ++r) {
                sum += ringShearBefore[ringMember[r]];
            }
            float average = sum / float(max(last - first, 1u));
            punching = average > punchStrength[e] * tensionIncrease(rateSum / float(n), m);
        }
        // One-way shear: the mean shear through the thickness across each axis against the
        // section's strength there, with the strain at mid-depth along that axis.
        float4 member = section[2 * e];
        if (member.x > 0.0f && m.materialModel != 0) {
            float rate = tensionIncrease(rateSum / float(n), m);
            for (uint j = 0; j < 2; ++j) {
                // Per unit width: the moment, shear and normal force, and the bars on the side the
                // moment puts in tension (the side whose position has the moment's sign).
                float moment = momentSum[j] / areaWeight;
                float tensionBars = 0.0f;
                float allBars = 0.0f;
                for (uint s = 0; s < el.barCount && s < u.barSlots; ++s) {
                    float4 layout = barLayout[e * u.barSlots + s];
                    allBars += layout[1 + j];
                    if (layout.x * moment >= 0.0f) {
                        tensionBars += layout[1 + j];
                    }
                }
                // Where the moment is small, as at a simple support, its sign says little and the
                // strain is the shear's: all the bars count.
                tensionBars = tensionBars > 0.0f ? tensionBars : allBars;
                float dv = member[2 * j] * t;
                float strain = sectionStrain(moment, shearSum[j] / areaWeight, normalSum[j] / areaWeight, dv,
                                             tensionBars, m);
                float arching = shearSpanFactor(moment, shearSum[j] / areaWeight, dv / 0.9f);
                float strength =
                    sectionShearStrength(strain, member[2 * j], member[2 * j + 1], 0.0f, rate * arching, m).x;
                shearRatio[j] = fabs(shearSum[j]) / (areaWeight * t) / max(strength, 1.0f);
            }
        }
        if (punchedThrough) {
            slidEverywhere = float2(1.0f);
            worstDisplay = max(worstDisplay, 0.9f);
        }
        if (sheared != 0u) {
            slidEverywhere = max(slidEverywhere, float2(float(sheared & 1u), float((sheared >> 1) & 1u)));
            worstDisplay = max(worstDisplay, 0.9f);
        }
        // Concrete cracked through its thickness fails in direct shear once it has slipped
        // through the thickness, over the element's own length, by the slip limit.
        float2 slip = abs(transverse) * float2(a, b);
        bool slid = (slidEverywhere.x > 0.0f && slip.x >= slipLimit(barsIntact.x > 0.0f, m, u))
            || (slidEverywhere.y > 0.0f && slip.y >= slipLimit(barsIntact.y > 0.0f, m, u));
        remove = remove || torn || slid || (destroyedEverywhere && bare) || openEverywhere;

        float tieWeight[4] = {0.5f * (1.0f - p.y), 0.5f * (1.0f + p.y), 0.5f * (1.0f - p.x), 0.5f * (1.0f + p.x)};
        for (uint q = 0; q < 4; ++q) {
            tieForce[q] += tieWeight[q] * shearSum[q < 2 ? 0 : 1];
        }

        // Pressure: the difference between the air on the two sides, on the deformed midsurface.
        float3 f1m = e1 + h1m;
        float3 f2m = e2 + h2m;
        float3 areaVector = cross(f1m, f2m) * areaWeight;
        // An element crushed to a quarter of its area, or turned inside out, is removed: it would
        // otherwise outrun the time step, which is set by the undeformed mesh.
        float stretch = dot(cross(f1m, f2m), normalize(normal + 0.25f * (offset[0] + offset[1] + offset[2] + offset[3])));
        remove = remove || stretch < 0.25f;
        float3 load = float3(0.0f);
        if (u.coupled != 0) {
            float3 unit = normalize(areaVector);
            float front = shellOverpressure(centre, unit, 0.5f * t, fluid, fluidMask, patchOfTile, fineAir,
                                            fineAirMask, u);
            float back = shellOverpressure(centre, -unit, 0.5f * t, fluid, fluidMask, patchOfTile, fineAir,
                                            fineAirMask, u);
            load += (back - front) * areaVector;
        }
        if (u.loadCount != 0 && (u.loadFace >> 1) == k) {
            float side = (u.loadFace & 1u) != 0 ? 1.0f : -1.0f;
            load -= applied * side * areaVector;
        }

        for (uint c = 0; c < 4; ++c) {
            float2 slope = shapeSlope(shellCorners[c], p);
            float s1 = 2.0f / a * slope.x;
            float s2 = 2.0f / b * slope.y;
            nodeForce[c] += s1 * p1 + s2 * p2 - shapeValue(shellCorners[c], p) * load;
            directorForce[c] += 0.5f * t * (s1 * q1 + s2 * q2);
        }
    }

    // Transverse shear through the tying points.
    for (uint q = 0; q < 4; ++q) {
        for (uint c = 0; c < 4; ++c) {
            float2 slope = shapeSlope(shellCorners[c], tying[q]);
            float s = q < 2 ? 2.0f / a * slope.x : 2.0f / b * slope.y;
            nodeForce[c] += tieForce[q] * s * directorTie[q];
            directorForce[c] += tieForce[q] * shapeValue(shellCorners[c], tying[q]) * tangentTie[q];
        }
    }

    // Sum the four points' shares across the quad.
    for (uint c = 0; c < 4; ++c) {
        nodeForce[c] = quad_sum(nodeForce[c]);
        directorForce[c] = quad_sum(directorForce[c]);
    }
    remove = quad_max(remove ? 1.0f : 0.0f) > 0.0f;
    punching = quad_max(punching ? 1.0f : 0.0f) > 0.0f;
    meanShear = 0.25f * quad_sum(meanShear);
    shearRatio = 0.25f * quad_sum(shearRatio);
    worstDisplay = quad_max(worstDisplay);
    for (uint s = 0; s < 8; ++s) {
        barMean[s] = quad_sum(barMean[s]);
    }
    if (g != 0) {
        return;
    }
    if (m.barReach > 0.0f) {
        for (uint s = 0; s < el.barCount && s < u.barSlots; ++s) {
            for (uint j = 0; j < 2; ++j) {
                // A ruptured layer drops out of its neighbours' averages.
                float mean = barMean[s * 2 + j];
                bool broken = fabs(bars[((e * 4) * u.barSlots + s) * 2 + j].plastic) > 1e8f;
                barPlasticOut[(e * u.barSlots + s) * 2 + j] = broken ? 1e9f : mean;
            }
        }
    }
    display[e] = worstDisplay;
    {
        // The section fails when its shear, averaged over the time a shear wave takes to cross
        // its depth and back twice, passes its strength: a section fails as a diagonal crack
        // forms through it, not as a stress wave passes (pushed suddenly at 0.12 m/s, a strip in
        // bending carries a passing shear of 0.6 MPa, near its whole strength).
        float window = 4.0f * t / sqrt(m.mu / m.density);
        float4 averaged = section[2 * e + 1];
        averaged.xy += clamp(dt / window, 0.0f, 1.0f) * (shearRatio - averaged.xy);
        if (section[2 * e].x > 0.0f) {
            section[2 * e + 1] = averaged;
        }
        uint state = punched[e];
        uint next = state | (punching ? 1u : 0u) | (averaged.x > 1.0f ? 2u : 0u) | (averaged.y > 1.0f ? 4u : 0u);
        if (next != state) {
            punched[e] = uchar(next);
        }
    }
    ringShearOut[e] = remove ? 0.0f : meanShear;
    ShellForces out;
    if (remove) {
        flags[e] = elementFailing;
        failureGate[0] = 1;
        for (uint c = 0; c < 4; ++c) {
            out.force[c] = float3(0.0f);
            out.moment[c] = float3(0.0f);
        }
    } else {
        // These are the derivatives of the strain energy; the forces on the nodes are their negatives.
        for (uint c = 0; c < 4; ++c) {
            out.force[c] = -nodeForce[c];
            out.moment[c] = -cross(director[c], directorForce[c]);
        }
    }
    forces[e] = out;
}

// Contact, as for the solid elements: once anything has failed, every node is a sphere one
// element across, found through a table of element-sized cells over all of space that wraps
// periodically. Each entry keeps the four lowest-numbered nodes that arrive, whatever the
// thread timing, so runs repeat exactly. Nodes that began close together (within about an
// element) never repel: while joined their elements hold them apart.
// Nodes kept in each entry of the shell contact table; debris piles up more densely on shell
// meshes, whose cells are an element (250 mm) across.
constant uint shellContactSlots = 8;

static inline bool shellContactEnabled(constant ShellUniforms &u, const device uint *failureGate) {
    return u.contactMode == 2 || (u.contactMode == 1 && failureGate[0] != 0);
}

static inline int3 shellContactCell(float3 position, constant ShellUniforms &u) {
    return int3(floor((position - float3(u.gridOriginX, u.gridOriginY, u.gridOriginZ)) / u.contactRadius));
}

static inline uint shellContactBucket(int3 cell, constant ShellUniforms &u) {
    uint3 wrapped = uint3(cell) & (uint3(u.contactNx, u.contactNy, u.contactNz) - 1u);
    return wrapped.x + u.contactNx * (wrapped.y + u.contactNy * wrapped.z);
}

kernel void shellContactClear(const device ShellNode *nodes [[buffer(0)]],
                              const device float4 *reference [[buffer(1)]],
                              device uint *heads [[buffer(2)]],
                              device uint *slots [[buffer(3)]],
                              constant ShellUniforms &u [[buffer(4)]],
                              const device StepControl &control [[buffer(5)]],
                              const device uint *failureGate [[buffer(6)]],
                              uint n [[thread_position_in_grid]]) {
    bool active;
    shellStep(u, control, active);
    if (!active || n >= u.nodeCount || !shellContactEnabled(u, failureGate)) {
        return;
    }
    uint target = shellContactBucket(shellContactCell(reference[n].xyz + float3(nodes[n].displacement), u), u);
    heads[target] = u.stamp;
    for (uint slot = 0; slot < shellContactSlots; ++slot) {
        slots[target * shellContactSlots + slot] = emptySlot;
    }
}

kernel void shellContactHash(const device ShellNode *nodes [[buffer(0)]],
                             const device float4 *reference [[buffer(1)]],
                             device atomic_uint *slots [[buffer(3)]],
                             constant ShellUniforms &u [[buffer(4)]],
                             const device StepControl &control [[buffer(5)]],
                             const device uint *failureGate [[buffer(6)]],
                             uint n [[thread_position_in_grid]]) {
    bool active;
    shellStep(u, control, active);
    if (!active || n >= u.nodeCount || !shellContactEnabled(u, failureGate)) {
        return;
    }
    uint target = shellContactBucket(shellContactCell(reference[n].xyz + float3(nodes[n].displacement), u), u);
    uint carried = n;
    for (uint slot = 0; slot < shellContactSlots && carried != emptySlot; ++slot) {
        uint held = atomic_fetch_min_explicit(&slots[target * shellContactSlots + slot], carried, memory_order_relaxed);
        carried = max(held, carried);
    }
}

kernel void shellContactForces(const device ShellNode *nodes [[buffer(0)]],
                               const device float4 *reference [[buffer(1)]],
                               const device uint *heads [[buffer(2)]],
                               const device uint *slots [[buffer(3)]],
                               constant ShellUniforms &u [[buffer(4)]],
                               const device StepControl &control [[buffer(5)]],
                               const device uint *failureGate [[buffer(6)]],
                               device packed_float3 *contact [[buffer(7)]],
                               uint n [[thread_position_in_grid]]) {
    bool active;
    float dt = shellStep(u, control, active);
    if (!active || n >= u.nodeCount || !shellContactEnabled(u, failureGate)) {
        return;
    }
    ShellNode node = nodes[n];
    float3 home = reference[n].xyz;
    float3 position = home + float3(node.displacement);
    int3 cell = shellContactCell(position, u);
    float radius = u.contactRadius;
    float3 force = float3(0.0f);
    // A node that its own crowded entry dropped is invisible to the others this step, so it must
    // not push them either: then every pair sees each other or neither does, the forces between
    // them are equal and opposite, and contact cannot pump momentum into a pile of debris.
    uint own = shellContactBucket(cell, u);
    bool listed = false;
    for (uint slot = 0; slot < shellContactSlots; ++slot) {
        listed = listed || slots[own * shellContactSlots + slot] == n;
    }
    if (!listed) {
        contact[n] = float3(0.0f);
        return;
    }
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                int3 c = cell + int3(dx, dy, dz);
                uint target = shellContactBucket(c, u);
                if (heads[target] != u.stamp) {
                    continue;
                }
                for (uint slot = 0; slot < shellContactSlots; ++slot) {
                    uint other = slots[target * shellContactSlots + slot];
                    if (other == emptySlot) {
                        break;
                    }
                    if (other == n) {
                        continue;
                    }
                    float3 otherHome = reference[other].xyz;
                    float3 otherPosition = otherHome + float3(nodes[other].displacement);
                    if (any(shellContactCell(otherPosition, u) != c)) {
                        continue;
                    }
                    if (distance(home, otherHome) < u.neighbourDistance) {
                        continue;
                    }
                    float3 offset = position - otherPosition;
                    float gap = length(offset);
                    if (gap >= radius || gap < 1e-9f) {
                        continue;
                    }
                    ShellNode partner = nodes[other];
                    float3 normal = offset / gap;
                    float mass = min(node.mass, partner.mass);
                    float stiffness = u.contactStiffness * mass;
                    float damping = 2.0f * u.contactDamping * sqrt(stiffness * mass);
                    float3 relative = float3(node.velocity) - float3(partner.velocity);
                    float approach = dot(relative, normal);
                    // A penalty spring stores energy in its overlap. Nodes that were hidden from
                    // each other in a crowded entry can meet already deeply overlapped, and the
                    // spring would then fling them apart at hundreds of metres a second. So once
                    // a pair is separating faster than `separationLimit` it is not pushed
                    // further: contact stops pieces and keeps them apart, but never throws them.
                    float push = approach > separationLimit
                        ? 0.0f : max(stiffness * (radius - gap) - damping * approach, 0.0f);
                    force += push * normal;
                    float3 sliding = relative - approach * normal;
                    float speed = length(sliding);
                    if (speed > 1e-6f) {
                        force -= min(u.contactFriction * push, damping * speed) * (sliding / speed);
                    }
                }
            }
        }
    }
    // Contact may change a node's velocity by at most `contactKick` in one step. Pieces
    // meeting at tens of metres a second are still stopped within a few steps, but nodes that
    // already overlap deeply (a crowded entry of the table hides some until then) are eased
    // apart instead of being shot off at hundreds of metres a second.
    float largest = node.mass * contactKick / max(dt, 1e-12f);
    float size = length(force);
    if (size > largest) {
        force *= largest / size;
    }
    contact[n] = force;
}

// One concrete fibre of a beam: the uniaxial laws along the beam, confined by its ties, with
// shear across it carried by aggregate interlock once cracked, and diagonal cracks from the
// principal tension of the axial stress with the shear.
static inline float beamConcrete(float axial, float2 shear, float instantaneous, float dt, float confinement,
                                 bool reinforced, thread ShellLayer &state, constant MaterialParameters &m,
                                 constant ShellUniforms &u, float crossing, float slide, float2 cap,
                                 thread float2 &shearStress, thread LayerOutcome &outcome) {
    state.rate += clamp(dt * u.rateFilter, 0.0f, 1.0f) * (instantaneous - state.rate);
    float history = state.crack.x;
    float tensionFactor = state.crackingFactor;
    if (tensionFactor <= 0.0f) {
        tensionFactor = tensionIncrease(state.rate, m);
        if (history > m.crackOnset * tensionFactor) {
            state.crackingFactor = tensionFactor;
        }
    }
    float onset = m.crackOnset * tensionFactor;
    float poisson = 0.5f * m.lambda / (m.lambda + m.mu);
    float magnitude = length(shear);
    float shearOverE = u.shearFactor * magnitude / (2.0f * (1.0f + poisson));
    float radius = sqrt(0.25f * axial * axial + shearOverE * shearOverE);
    float tension = 0.5f * axial + radius;
    if (tension > history && tension > onset && radius > 0.0f) {
        float c2 = 0.5f * (1.0f + 0.5f * axial / radius);
        float s2 = 1.0f - c2;
        history += (tension - history) * c2 / (c2 * c2 + s2 * s2);
    }
    history = max(history, axial);
    state.crack.x = history;
    float residual = settledResidual(state.residual.x, history, axial, tensionFactor, m);
    // A crack that has slid cannot close (see the shells).
    if (u.crackSlip != 0 && m.crackDilatancy > 0.0f && history > onset) {
        float held = min(m.crackDilatancy * length(state.slip.xy), min(axial, 0.9f * history));
        residual = max(residual, held);
    }
    state.residual.x = residual;
    float squeeze = residual - axial;
    float crush = max(state.crush.x, squeeze);
    state.crush.x = crush;
    float stress;
    float crushed = 0.0f;
    bool pulverised = false;
    if (squeeze <= 0.0f) {
        stress = concreteTension(axial, history, residual, tensionFactor, m);
    } else {
        float compressionFactor = compressionIncrease(state.rate, m);
        stress = concreteCompression(squeeze, crush, crush, compressionFactor, confinement, m);
        float2 limits = crushStrains(compressionFactor, confinement, m);
        crushed = clamp((squeeze - limits.x) / (limits.y - limits.x), 0.0f, 1.0f);
        pulverised = squeeze >= limits.y + m.crushErosion * (limits.y - limits.x);
    }
    bool slides = u.crackSlip != 0;
    float2 slip = slides ? state.slip.xy : float2(0.0f);
    shearStress = u.shearFactor * m.mu * (shear - slip);
    float opened = history - onset;
    if (opened > 0.0f) {
        float width = opened * m.crackBand;
        // The bars along the beam cross the crack and add their dowel action (see the shells).
        float limit = m.interlockStrength * tensionFactor / (0.31f + m.interlockWidthScale * width)
            + barShear(crossing, slide, m);
        float carried = m.shearRetention * length(shearStress);
        if (carried > 0.0f) {
            float2 trial = m.shearRetention * shearStress;
            shearStress *= min(carried, limit) / length(shearStress);
            // What interlock and dowels cannot hold, the crack slides by for good.
            if (slides && carried > limit) {
                slip += (trial - shearStress) / (m.shearRetention * u.shearFactor * m.mu);
            }
        }
    }
    if (slides) {
        state.slip.xy = slip;
    }
    // Once the section has failed in shear, only its stirrups carry shear across it.
    shearStress = clamp(shearStress, -cap, cap);
    outcome.torn = float2(history >= m.erosionStrain ? 1.0f : 0.0f, 0.0f);
    outcome.slid = float2(history > onset ? 1.0f : 0.0f, 0.0f);
    outcome.destroyed = pulverised || history >= m.erosionStrain;
    outcome.open = history > max(1.0f, 3.0f * m.erosionStrain);
    outcome.failed = false;
    state.display = max(history / (reinforced ? m.steelStrain[m.steelPoints - 1] : m.erosionStrain), crushed);
    return stress;
}

// One steel fibre of a beam: uniaxial von Mises with linear hardening; shear stays elastic.
static inline float beamVonMises(float axial, float2 shear, thread ShellLayer &state, constant MaterialParameters &m,
                                 constant ShellUniforms &u, thread float2 &shearStress, thread LayerOutcome &outcome) {
    float young = m.youngsModulus;
    float stress = young * (axial - state.crack.x);
    float yield = m.yieldStress + m.hardening * state.crush.y;
    if (fabs(stress) > yield) {
        float increment = (fabs(stress) - yield) / (young + m.hardening);
        state.crack.x += stress > 0.0f ? increment : -increment;
        state.crush.y += increment;
        stress = young * (axial - state.crack.x);
    }
    shearStress = u.shearFactor * m.mu * shear;
    outcome.torn = float2(0.0f);
    outcome.slid = float2(0.0f);
    outcome.destroyed = false;
    outcome.open = false;
    outcome.failed = state.crush.y >= m.failureStrain;
    state.display = state.crush.y / m.failureStrain;
    return stress;
}

// Two-node beams on the centrelines of columns, the line counterpart of the shells: a
// degenerated solid whose section is carried by two directors at each node (the rotated
// reference axes of the section), with one point along the beam, which neither locks in shear
// nor has spurious modes, and 4 x 4 fibres across the section.
kernel void beamElements(device ShellLayerStore *fibres [[buffer(0)]],
                         device BeamForces *forces [[buffer(1)]],
                         device uchar *flags [[buffer(2)]],
                         const device ShellNode *nodes [[buffer(3)]],
                         const device float4 *reference [[buffer(4)]],
                         const device BeamElement *beams [[buffer(5)]],
                         device ShellBar *bars [[buffer(6)]],
                         constant MaterialParameters *materials [[buffer(7)]],
                         constant ShellUniforms &u [[buffer(8)]],
                         const device StepControl &control [[buffer(9)]],
                         const device Cell *fluid [[buffer(10)]],
                         const device uchar *fluidMask [[buffer(11)]],
                         device uint *failureGate [[buffer(12)]],
                         device float *display [[buffer(13)]],
                         const device float4 *barLayout [[buffer(14)]],
                         const device int *patchOfTile [[buffer(15)]],
                         const device Cell *fineAir [[buffer(16)]],
                         const device uchar *fineAirMask [[buffer(17)]],
                         device float4 *section [[buffer(18)]],
                         device uchar *sheared [[buffer(19)]],
                         uint e [[thread_position_in_grid]]) {
    bool active;
    float dt = shellStep(u, control, active);
    if (!active || e >= u.beamCount || flags[e] != elementActive) {
        return;
    }
    BeamElement beam = beams[e];
    constant MaterialParameters &m = materials[min(beam.material, maxMaterials - 1)];
    uint k = beam.axis;
    uint i2 = (k + 1) % 3;
    uint i3 = (k + 2) % 3;
    float3 e1 = float3(0.0f);
    float3 e2 = float3(0.0f);
    float3 e3 = float3(0.0f);
    e1[k] = 1.0f;
    e2[i2] = 1.0f;
    e3[i3] = 1.0f;
    float L = beam.length;

    float3 x[2];
    float3 disp[2];
    float3 vel[2];
    float3 offset2[2];
    float3 offset3[2];
    float3 director2[2];
    float3 director3[2];
    float3 turn2[2];
    float3 turn3[2];
    for (uint c = 0; c < 2; ++c) {
        ShellNode node = nodes[beam.node[c]];
        disp[c] = float3(node.displacement);
        vel[c] = float3(node.velocity);
        x[c] = reference[beam.node[c]].xyz + disp[c];
        offset2[c] = rotationOffset(node.rotation, e2);
        offset3[c] = rotationOffset(node.rotation, e3);
        director2[c] = e2 + offset2[c];
        director3[c] = e3 + offset3[c];
        turn2[c] = cross(float3(node.spin), director2[c]);
        turn3[c] = cross(float3(node.spin), director3[c]);
    }
    // Derivatives along the beam, and the directors at its middle.
    float3 hm = (disp[1] - disp[0]) / L;
    float3 h2 = 0.5f * beam.width * (offset2[1] - offset2[0]) / L;
    float3 h3 = 0.5f * beam.depth * (offset3[1] - offset3[0]) / L;
    float3 rm = (vel[1] - vel[0]) / L;
    float3 r2 = 0.5f * beam.width * (turn2[1] - turn2[0]) / L;
    float3 r3 = 0.5f * beam.depth * (turn3[1] - turn3[0]) / L;
    float3 delta2 = 0.5f * (offset2[0] + offset2[1]);
    float3 delta3 = 0.5f * (offset3[0] + offset3[1]);
    float3 d2 = e2 + delta2;
    float3 d3 = e3 + delta3;

    // Ties confine the concrete: lateral pressure half the tie ratio times the bars' yield stress.
    float confinement = 1.0f;
    if (m.materialModel != 0 && beam.tieRatio > 0.0f && m.steelPoints > 0) {
        confinement = 1.0f + m.confinement * 0.5f * beam.tieRatio * m.steelStress[0] / m.compressiveStrength;
    }

    float3 p = float3(0.0f);   // conjugate of the derivative along the beam
    float3 q2 = float3(0.0f);  // ... weighted by position across the first side
    float3 q3 = float3(0.0f);
    float3 g2 = float3(0.0f);  // conjugate of the middle directors
    float3 g3 = float3(0.0f);
    float area = beam.width * beam.depth;
    bool removeAll = true;
    bool tornAll = true;
    bool slidAll = true;
    bool openAll = true;
    bool failed = false;
    float worst = 0.0f;
    float rateSum = 0.0f;
    // Intact bars along the beam per unit area of its section, for the shear they carry across
    // cracks, and how far a crack has slid over their debonded length.
    float crossing = 0.0f;
    for (uint c = 0; c < beam.barCount && c < maxBeamBars; ++c) {
        if (fabs(bars[e * maxBeamBars + c].plastic) < 1e8f) {
            crossing += barLayout[e * maxBeamBars + c].z / area;
        }
    }
    float2 meanShear = float2(hm[i2] + delta2[k] + dot(hm, delta2), hm[i3] + delta3[k] + dot(hm, delta3));
    float slide = length(meanShear) * L / max(debondedLength(m, u), L);
    // The section's shear strength across each side, with its ties as stirrups and the strain
    // along the beam's axis as the strain at mid-depth; and, once it has failed, what is left.
    float4 member = section[2 * e];
    bool concrete = m.materialModel != 0 && member.x > 0.0f;
    uint failedShear = concrete ? uint(sheared[e]) : 0u;
    float2 cap = float2(1e30f);
    for (uint j = 0; j < 2; ++j) {
        if (((failedShear >> j) & 1u) != 0u) {
            // With the stirrups at an angle for a moderate strain, 0.001 (36 degrees).
            cap[j] = sectionShearStrength(1e-3f, member[2 * j], member[2 * j + 1], beam.tieRatio, 1.0f, m).y;
        }
    }
    float2 sectionShear = float2(0.0f);
    float sectionNormal = 0.0f;
    float2 sectionMoment = float2(0.0f);  // about the axes that shear across each side bends
    for (uint a = 0; a < beamFibres; ++a) {
        for (uint b = 0; b < beamFibres; ++b) {
            float eta = beamFibrePoints[a];
            float zeta = beamFibrePoints[b];
            float weight = 0.25f * area * beamFibreWeights[a] * beamFibreWeights[b] * L;
            float3 h = hm + eta * h2 + zeta * h3;
            float3 f1 = e1 + h;
            float axial = h[k] + 0.5f * dot(h, h);
            float2 shear = float2(h[i2] + delta2[k] + dot(h, delta2), h[i3] + delta3[k] + dot(h, delta3));
            float3 rate = rm + eta * r2 + zeta * r3;
            float instantaneous = fabs(dot(f1, rate));
            uint slot = e * beamFibres * beamFibres + a * beamFibres + b;
            ShellLayer state = loadLayer(fibres[slot]);
            float2 shearStress;
            LayerOutcome outcome;
            float stress = m.materialModel == 0
                ? beamVonMises(axial, shear, state, m, u, shearStress, outcome)
                : beamConcrete(axial, shear, instantaneous, dt, confinement, beam.barCount > 0 && m.steelPoints > 0,
                               state, m, u, crossing, slide, cap, shearStress, outcome);
            storeLayer(fibres[slot], state);
            rateSum += state.rate;
            worst = max(worst, state.display);
            failed = failed || outcome.failed;
            removeAll = removeAll && outcome.destroyed;
            tornAll = tornAll && outcome.torn.x > 0.0f;
            slidAll = slidAll && outcome.slid.x > 0.0f;
            openAll = openAll && outcome.open;
            float3 t = stress * f1 + shearStress.x * d2 + shearStress.y * d3;
            p += weight * t;
            q2 += weight * eta * t;
            q3 += weight * zeta * t;
            g2 += weight * shearStress.x * f1;
            g3 += weight * shearStress.y * f1;
            sectionShear += weight * shearStress;
            sectionNormal += weight * stress;
            sectionMoment += weight * stress * float2(0.5f * beam.width * eta, 0.5f * beam.depth * zeta);
        }
    }
    uint nextShear = failedShear;
    if (concrete) {
        float rate = tensionIncrease(rateSum / float(beamFibres * beamFibres), m);
        // Averaged over the time a shear wave takes to cross the section and back twice, as in
        // the shells.
        float4 averaged = section[2 * e + 1];
        for (uint j = 0; j < 2; ++j) {
            float moment = sectionMoment[j] / L;
            float tensionBars = 0.0f;
            float allBars = 0.0f;
            for (uint c = 0; c < beam.barCount && c < maxBeamBars; ++c) {
                float4 layout = barLayout[e * maxBeamBars + c];
                allBars += layout.z;
                if (layout[j] * moment >= 0.0f) {
                    tensionBars += layout.z;
                }
            }
            tensionBars = tensionBars > 0.0f ? tensionBars : allBars;
            float side = j == 0 ? beam.width : beam.depth;
            float strain = sectionStrain(moment, sectionShear[j] / L, sectionNormal / L, member[2 * j] * side,
                                         tensionBars, m);
            float arching = shearSpanFactor(moment, sectionShear[j] / L, member[2 * j] * side / 0.9f);
            float strength =
                sectionShearStrength(strain, member[2 * j], member[2 * j + 1], beam.tieRatio, rate * arching, m).x;
            float window = 4.0f * (j == 0 ? beam.width : beam.depth) / sqrt(m.mu / m.density);
            float ratio = fabs(sectionShear[j]) / (area * L) / max(strength, 1.0f);
            averaged[j] += clamp(dt / window, 0.0f, 1.0f) * (ratio - averaged[j]);
            if (averaged[j] > 1.0f) {
                nextShear |= 1u << j;
            }
        }
        section[2 * e + 1] = averaged;
        if (nextShear != failedShear) {
            sheared[e] = uchar(nextShear);
        }
        if (failedShear != 0u) {
            worst = max(worst, 0.9f);
        }
    }
    // Bars along the beam.
    bool barsIntact = false;
    for (uint c = 0; c < beam.barCount && c < maxBeamBars; ++c) {
        float4 layout = barLayout[e * maxBeamBars + c];
        float eta = layout.x;
        float zeta = layout.y;
        float barArea = layout.z;
        {
            float3 h = hm + eta * h2 + zeta * h3;
            float green = h[k] + 0.5f * dot(h, h);
            float stress;
            float root;
            float yield;
            float2 spread = float2(1.0f, 0.0f);
            if (!shellBar(bars[e * maxBeamBars + c], green, rateSum / float(beamFibres * beamFibres), m, stress, root,
                          yield, spread)) {
                continue;
            }
            barsIntact = true;
            sectionNormal += barArea * L * stress;
            sectionMoment += barArea * L * stress * float2(0.5f * beam.width * eta, 0.5f * beam.depth * zeta);
            float3 t = (barArea * L * stress / root) * (e1 + h);
            p += t;
            q2 += eta * t;
            q3 += zeta * t;
        }
    }
    // A beam shortened to half its length is removed, as a crushed shell is.
    bool crushedFlat = length(e1 + hm) < 0.5f;
    // Direct shear: the section cracked through and slipped across the crack by the slip limit.
    float2 shearStrain = float2(hm[i2] + delta2[k] + dot(hm, delta2), hm[i3] + delta3[k] + dot(hm, delta3));
    bool slid = (slidAll || failedShear != 0u) && length(shearStrain) * L >= slipLimit(barsIntact, m, u);
    bool remove = failed || (tornAll && !barsIntact) || slid || (removeAll && !barsIntact) || openAll || crushedFlat;

    // Air pressure on the four sides.
    float3 load[2] = {float3(0.0f), float3(0.0f)};
    if (u.coupled != 0) {
        float3 centre = 0.5f * (x[0] + x[1]);
        float3 normals[2] = {normalize(d2), normalize(d3)};
        float halves[2] = {0.5f * beam.width, 0.5f * beam.depth};
        float faces[2] = {beam.depth * L, beam.width * L};
        for (uint s = 0; s < 2; ++s) {
            float plus = shellOverpressure(centre, normals[s], halves[s], fluid, fluidMask, patchOfTile, fineAir,
                                            fineAirMask, u);
            float minus = shellOverpressure(centre, -normals[s], halves[s], fluid, fluidMask, patchOfTile, fineAir,
                                            fineAirMask, u);
            float3 force = (minus - plus) * faces[s] * normals[s];
            load[0] += 0.5f * force;
            load[1] += 0.5f * force;
        }
    }

    display[e] = worst;
    BeamForces out;
    if (remove) {
        flags[e] = elementFailing;
        failureGate[0] = 1;
        for (uint c = 0; c < 2; ++c) {
            out.force[c] = float3(0.0f);
            out.moment[c] = float3(0.0f);
        }
    } else {
        // Derivatives of the strain energy: the derivative along the beam takes the difference of
        // the two nodes over the length, the middle directors half of each.
        float3 sign[2] = {float3(-1.0f), float3(1.0f)};
        for (uint c = 0; c < 2; ++c) {
            float3 force = sign[c] * p / L;
            float3 onDirector2 = sign[c] * 0.5f * beam.width * q2 / L + 0.5f * g2;
            float3 onDirector3 = sign[c] * 0.5f * beam.depth * q3 / L + 0.5f * g3;
            out.force[c] = load[c] - force;
            out.moment[c] = -(cross(director2[c], onDirector2) + cross(director3[c], onDirector3));
        }
    }
    forces[e] = out;
}

// The forces and moments of the intact elements around node n, and its contact force.
static inline void gatherNode(uint n, const device ShellForces *forces, device uchar *flags,
                              const device uint *incidenceStart, const device uint *incidence,
                              const device BeamForces *beamForces, device uchar *beamFlags,
                              const device packed_float3 *contact, constant ShellUniforms &u,
                              const device uint *failureGate, thread float3 &force, thread float3 &moment,
                              thread bool &attached) {
    for (uint i = incidenceStart[n]; i < incidenceStart[n + 1]; ++i) {
        if ((incidence[i] & beamIncidence) != 0) {
            uint beam = (incidence[i] & ~beamIncidence) >> 2;
            uint end = incidence[i] & 3u;
            uchar flag = beamFlags[beam];
            if (end == 0 && flag == elementFailing) {
                beamFlags[beam] = elementEroded;
            }
            if (flag == elementActive) {
                force += float3(beamForces[beam].force[end]);
                moment += float3(beamForces[beam].moment[end]);
                attached = true;
            }
            continue;
        }
        uint element = incidence[i] >> 2;
        uint corner = incidence[i] & 3u;
        uchar flag = flags[element];
        // Each element's failure is committed by its first corner.
        if (corner == 0 && flag == elementFailing) {
            flags[element] = elementEroded;
        }
        if (flag == elementActive) {
            force += float3(forces[element].force[corner]);
            moment += float3(forces[element].moment[corner]);
            attached = true;
        }
    }
    if (shellContactEnabled(u, failureGate)) {
        force += float3(contact[n]);
    }
}

static inline float4 quaternionProduct(float4 p, float4 q) {
    return float4(p.w * q.xyz + q.w * p.xyz + cross(p.xyz, q.xyz), p.w * q.w - dot(p.xyz, q.xyz));
}

// Gathers the forces and moments of the elements around every node and advances its motion.
kernel void shellNodes(device ShellNode *nodes [[buffer(0)]],
                       const device ShellForces *forces [[buffer(1)]],
                       device uchar *flags [[buffer(2)]],
                       const device uint *incidenceStart [[buffer(3)]],
                       const device uint *incidence [[buffer(4)]],
                       const device float4 *reference [[buffer(5)]],
                       constant ShellUniforms &u [[buffer(6)]],
                       const device StepControl &control [[buffer(7)]],
                       const device packed_float3 *contact [[buffer(8)]],
                       const device uint *failureGate [[buffer(9)]],
                       const device BeamForces *beamForces [[buffer(10)]],
                       device uchar *beamFlags [[buffer(11)]],
                       const device uint *tiedStart [[buffer(12)]],
                       const device uint *tied [[buffer(13)]],
                       const device Cell *fluid [[buffer(14)]],
                       const device uchar *fluidMask [[buffer(15)]],
                       device atomic_uint *exchange [[buffer(16)]],
                       const device int *debrisArea [[buffer(17)]],
                       const device uint *interfaceLink [[buffer(18)]],
                       device float4 *interfaceLoads [[buffer(19)]],
                       const device uint *anchorStart [[buffer(20)]],
                       const device float4 *anchorPoints [[buffer(21)]],
                       device float4 *anchorState [[buffer(22)]],
                       device float4 *anchorForces [[buffer(23)]],
                       const device AnchorLaw *anchorLaws [[buffer(24)]],
                       device atomic_uint *couplingMap [[buffer(25)]],
                       uint n [[thread_position_in_grid]]) {
    bool active;
    float dt = shellStep(u, control, active);
    if (!active || n >= u.nodeCount) {
        return;
    }
    ShellNode node = nodes[n];
    if ((node.flags & shellTied) != 0) {
        return;  // moved by the node it is tied to
    }
    float3 force = float3(0.0f);
    float3 moment = float3(0.0f);
    bool attached = false;
    gatherNode(n, forces, flags, incidenceStart, incidence, beamForces, beamFlags, contact, u, failureGate, force,
               moment, attached);
    // The nodes tied to this one hand over their forces, with the moments of those forces about it.
    float3 position = reference[n].xyz + float3(node.displacement);
    for (uint i = tiedStart[n]; i < tiedStart[n + 1]; ++i) {
        uint other = tied[i];
        float3 tiedForce = float3(0.0f);
        float3 tiedMoment = float3(0.0f);
        bool tiedAttached = false;
        gatherNode(other, forces, flags, incidenceStart, incidence, beamForces, beamFlags, contact, u, failureGate,
                   tiedForce, tiedMoment, tiedAttached);
        attached = attached || tiedAttached;
        float3 arm = reference[other].xyz + float3(nodes[other].displacement) - position;
        force += tiedForce;
        moment += tiedMoment + cross(arm, tiedForce);
    }
    // A node tied into a solid hands its force and moment to that body, which moves it.
    if ((node.flags & shellOnSolid) != 0) {
        uint link = interfaceLink[n];
        interfaceLoads[2 * link] = float4(force, 0.0f);
        interfaceLoads[2 * link + 1] = float4(moment, 0.0f);
        return;
    }
    // A node on a connected base: the connection acts at points of its footprint (through a
    // wall's thickness, or over a column's section), each moving with the node's rotation, so
    // that the base can open at its heel while it bears at its toe.
    bool anchoredNode = finiteConnections && u.anchored != 0 && anchorStart[n + 1] > anchorStart[n];
    if (anchoredNode) {
        for (uint f = anchorStart[n]; f < anchorStart[n + 1]; ++f) {
            AnchorLaw law = anchorLaws[f];
            float4 point = anchorPoints[f];
            float3 arm = float3(point.xy, 0.0f);
            float3 turn = rotationOffset(node.rotation, arm);
            float rise = node.velocity.z + cross(float3(node.spin), arm + turn).z;
            float damper = 2.0f * u.contactDamping * sqrt(law.kn * node.mass / point.w);
            float4 state = anchorState[f];
            float settlement = anchorForces[f].w;  // the ground's, kept beside the force
            float3 pointForce =
                -point.z * anchorTraction(state, settlement, float3(node.displacement) + turn, rise, damper, law);
            anchorState[f] = state;
            anchorForces[f] = float4(pointForce, settlement);
            force += pointForce;
            moment += cross(arm + turn, pointForce);
        }
    }
    // Loose debris is part of no element the air loads, so the air pushes it directly, as solid
    // debris is; its volume is its share of the elements it belonged to.
    float3 airForce = float3(0.0f);
    int exchangeCell = -1;
    if (!attached && u.coupled != 0 && u.debrisLoading != 0) {
        airForce = debrisAirForce(position, float3(node.velocity), reference[n].w, fluid, fluidMask, debrisArea,
                                  control.dt, u, couplingMap, exchangeCell);
        force += airForce;
    }
    float decay = max(0.0f, 1.0f - u.damping * dt);
    float3 velocity = float3(node.velocity) + dt * (force / node.mass - float3(0.0f, 0.0f, u.gravity));
    velocity *= decay;
    float3 spin = (float3(node.spin) + dt * moment / node.inertia) * decay;
    if ((node.flags & 8u) != 0) {
        velocity = float3(node.velocity);  // prescribed motion
        spin = float3(node.spin);
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
    if ((node.flags & shellRotationHeld) != 0) {
        spin = float3(0.0f);
    }
    float3 displacement = float3(node.displacement) + dt * velocity;
    if ((node.flags & 16u) != 0 && displacement.z < 0.0f) {
        displacement.z = 0.0f;
        velocity.z = max(velocity.z, 0.0f);
    }
    float referenceHeight = reference[n].z;
    if (referenceHeight + displacement.z < 0.0f && u.groundFriction >= 0.0f && !anchoredNode) {
        displacement.z = -referenceHeight;
        velocity.z = max(velocity.z, 0.0f);
        velocity.xy *= max(0.0f, 1.0f - u.groundFriction * dt);
    }
    // Rotate by the spin over the step, about axes fixed in space.
    float3 angle = spin * dt;
    float size = length(angle);
    float4 rotation = node.rotation;
    if (size > 0.0f) {
        float4 increment = float4(angle / size * sin(0.5f * size), cos(0.5f * size));
        rotation = normalize(quaternionProduct(increment, rotation));
    }
    if (exchangeCell >= 0) {
        recordExchange(exchange, exchangeCell, airForce, 0.5f * (float3(node.velocity) + velocity), dt, u.fluidCell);
    }
    node.displacement = displacement;
    node.velocity = velocity;
    node.spin = spin;
    node.rotation = rotation;
    nodes[n] = node;
}

// Two-way coupling: each active shell marks the air cells its thickness occupies, at points no
// more than half a cell apart over its midsurface and through its thickness. Each point counts
// once towards its cell (the threshold for shells is one), with its velocity, so a cell any
// shell passes through is solid and moves with the mean velocity of the points in it.
kernel void shellSplat(const device ShellElement *elements [[buffer(0)]],
                       const device uchar *flags [[buffer(1)]],
                       const device ShellNode *nodes [[buffer(2)]],
                       const device float4 *reference [[buffer(3)]],
                       device atomic_uint *occupancy [[buffer(4)]],
                       constant CouplingUniforms &u [[buffer(5)]],
                       constant uint &elementCount [[buffer(6)]],
                       const device int *patchOfTile [[buffer(7)]],
                       device atomic_uint *fineOccupancy [[buffer(8)]],
                       device atomic_uint *couplingMap [[buffer(9)]],
                       uint e [[thread_position_in_grid]]) {
    if (e >= elementCount || flags[e] != elementActive) {
        return;
    }
    ShellElement el = elements[e];
    float3 normal = float3(0.0f);
    normal[el.axis] = 1.0f;
    float3 x[4];
    float3 v[4];
    float3 d[4];
    for (uint c = 0; c < 4; ++c) {
        ShellNode node = nodes[el.node[c]];
        x[c] = reference[el.node[c]].xyz + float3(node.displacement);
        v[c] = float3(node.velocity);
        d[c] = normal + rotationOffset(node.rotation, normal);
    }
    // Points no more than half a cell apart, or half a fine cell where the air is refined.
    float spacing = 0.5f * u.fluidCell / float(max(u.refineRatio, 1u));
    uint most = u.refineRatio != 0 ? 33u : 17u;
    uint along = clamp(uint(ceil(max(el.a, el.b) / spacing)) + 1u, 2u, most);
    uint through = clamp(uint(ceil(el.thickness / spacing)), 1u, most / 2u);
    int3 dims = int3(u.regionNx, u.regionNy, u.regionNz);
    for (uint i = 0; i < along; ++i) {
        float s = float(i) / float(along - 1);
        for (uint j = 0; j < along; ++j) {
            float t = float(j) / float(along - 1);
            float3 point = mix(mix(x[0], x[1], s), mix(x[3], x[2], s), t);
            float3 velocity = mix(mix(v[0], v[1], s), mix(v[3], v[2], s), t);
            float3 director = mix(mix(d[0], d[1], s), mix(d[3], d[2], s), t);
            velocity = select(clamp(velocity, -wallSpeedLimit, wallSpeedLimit), float3(0.0f), isnan(velocity));
            int3 fixed = int3(round(velocity * wallSpeedScale));
            for (uint l = 0; l < through; ++l) {
                float zeta = -1.0f + (2.0f * float(l) + 1.0f) / float(through);
                float3 sample = point + 0.5f * zeta * el.thickness * director;
                splatFine(sample, fixed, u.fineThreshold, patchOfTile, fineOccupancy, u);
                int3 target = int3(floor(sample / u.fluidCell)) - int3(u.regionX, u.regionY, u.regionZ);
                if (any(target < 0) || any(target >= dims)) {
                    continue;
                }
                int at = coarseCouplingSlot(target, u, couplingMap);
                if (at < 0) { continue; }
                uint slot = 4u * uint(at);
                atomic_fetch_add_explicit(&occupancy[slot], u.splatWeight, memory_order_relaxed);
                atomic_fetch_add_explicit(&occupancy[slot + 1], uint(fixed.x) * u.splatWeight, memory_order_relaxed);
                atomic_fetch_add_explicit(&occupancy[slot + 2], uint(fixed.y) * u.splatWeight, memory_order_relaxed);
                atomic_fetch_add_explicit(&occupancy[slot + 3], uint(fixed.z) * u.splatWeight, memory_order_relaxed);
            }
        }
    }
}

// The air cells a beam's volume occupies, at points no more than half a cell apart.
kernel void beamSplat(const device BeamElement *beams [[buffer(0)]],
                      const device uchar *flags [[buffer(1)]],
                      const device ShellNode *nodes [[buffer(2)]],
                      const device float4 *reference [[buffer(3)]],
                      device atomic_uint *occupancy [[buffer(4)]],
                      constant CouplingUniforms &u [[buffer(5)]],
                      constant uint &beamCount [[buffer(6)]],
                      const device int *patchOfTile [[buffer(7)]],
                      device atomic_uint *fineOccupancy [[buffer(8)]],
                      device atomic_uint *couplingMap [[buffer(9)]],
                      uint e [[thread_position_in_grid]]) {
    if (e >= beamCount || flags[e] != elementActive) {
        return;
    }
    BeamElement beam = beams[e];
    float3 e2 = float3(0.0f);
    float3 e3 = float3(0.0f);
    e2[(beam.axis + 1) % 3] = 1.0f;
    e3[(beam.axis + 2) % 3] = 1.0f;
    float3 x[2];
    float3 v[2];
    float3 d2[2];
    float3 d3[2];
    for (uint c = 0; c < 2; ++c) {
        ShellNode node = nodes[beam.node[c]];
        x[c] = reference[beam.node[c]].xyz + float3(node.displacement);
        v[c] = float3(node.velocity);
        d2[c] = e2 + rotationOffset(node.rotation, e2);
        d3[c] = e3 + rotationOffset(node.rotation, e3);
    }
    float spacing = 0.5f * u.fluidCell / float(max(u.refineRatio, 1u));
    uint most = u.refineRatio != 0 ? 33u : 17u;
    uint along = clamp(uint(ceil(beam.length / spacing)) + 1u, 2u, most);
    uint across2 = clamp(uint(ceil(beam.width / spacing)), 1u, most / 2u);
    uint across3 = clamp(uint(ceil(beam.depth / spacing)), 1u, most / 2u);
    int3 dims = int3(u.regionNx, u.regionNy, u.regionNz);
    for (uint i = 0; i < along; ++i) {
        float s = float(i) / float(along - 1);
        float3 centre = mix(x[0], x[1], s);
        float3 velocity = mix(v[0], v[1], s);
        float3 side2 = mix(d2[0], d2[1], s);
        float3 side3 = mix(d3[0], d3[1], s);
        velocity = select(clamp(velocity, -wallSpeedLimit, wallSpeedLimit), float3(0.0f), isnan(velocity));
        int3 fixed = int3(round(velocity * wallSpeedScale));
        for (uint a = 0; a < across2; ++a) {
            float eta = -1.0f + (2.0f * float(a) + 1.0f) / float(across2);
            for (uint b = 0; b < across3; ++b) {
                float zeta = -1.0f + (2.0f * float(b) + 1.0f) / float(across3);
                float3 sample = centre + 0.5f * eta * beam.width * side2 + 0.5f * zeta * beam.depth * side3;
                splatFine(sample, fixed, u.fineThreshold, patchOfTile, fineOccupancy, u);
                int3 target = int3(floor(sample / u.fluidCell)) - int3(u.regionX, u.regionY, u.regionZ);
                if (any(target < 0) || any(target >= dims)) {
                    continue;
                }
                int at = coarseCouplingSlot(target, u, couplingMap);
                if (at < 0) { continue; }
                uint slot = 4u * uint(at);
                atomic_fetch_add_explicit(&occupancy[slot], u.splatWeight, memory_order_relaxed);
                atomic_fetch_add_explicit(&occupancy[slot + 1], uint(fixed.x) * u.splatWeight, memory_order_relaxed);
                atomic_fetch_add_explicit(&occupancy[slot + 2], uint(fixed.y) * u.splatWeight, memory_order_relaxed);
                atomic_fetch_add_explicit(&occupancy[slot + 3], uint(fixed.z) * u.splatWeight, memory_order_relaxed);
            }
        }
    }
}

// After the node pass, every tied node is put where the node it is tied to carries it: its
// reference offset from that node turned by that node's rotation, moving with its velocity and
// spin.
kernel void shellTies(device ShellNode *nodes [[buffer(0)]],
                      const device float4 *reference [[buffer(1)]],
                      const device uint2 *ties [[buffer(2)]],
                      constant uint &tieCount [[buffer(3)]],
                      constant ShellUniforms &u [[buffer(4)]],
                      const device StepControl &control [[buffer(5)]],
                      uint i [[thread_position_in_grid]]) {
    bool active;
    shellStep(u, control, active);
    if (!active || i >= tieCount) {
        return;
    }
    uint2 tie = ties[i];
    ShellNode master = nodes[tie.y];
    ShellNode slave = nodes[tie.x];
    float3 offset = reference[tie.x].xyz - reference[tie.y].xyz;
    float3 shift = rotationOffset(master.rotation, offset);
    float3 turned = offset + shift;
    slave.displacement = float3(master.displacement) + shift;
    slave.velocity = float3(master.velocity) + cross(float3(master.spin), turned);
    slave.spin = master.spin;
    slave.rotation = master.rotation;
    nodes[tie.x] = slave;
}

// Before each air step's substeps, every loose shell node adds its frontal area to its air cell,
// for the implicit form of the debris drag (see `debrisAirForce`).
kernel void shellDebrisAreas(const device ShellNode *nodes [[buffer(0)]],
                             const device float4 *reference [[buffer(1)]],
                             const device uchar *flags [[buffer(2)]],
                             const device uchar *beamFlags [[buffer(3)]],
                             const device uint *incidenceStart [[buffer(4)]],
                             const device uint *incidence [[buffer(5)]],
                             const device uchar *fluidMask [[buffer(6)]],
                             device atomic_int *area [[buffer(7)]],
                             constant ShellUniforms &u [[buffer(8)]],
                             const device StepControl &control [[buffer(9)]],
                             const device uint *failureGate [[buffer(10)]],
                             device atomic_uint *couplingMap [[buffer(11)]],
                             uint n [[thread_position_in_grid]]) {
    if (n >= u.nodeCount || control.dt <= 0.0f || failureGate[0] == 0) {
        return;
    }
    ShellNode node = nodes[n];
    if ((node.flags & shellTied) != 0 || node.mass <= 0.0f) {
        return;
    }
    for (uint i = incidenceStart[n]; i < incidenceStart[n + 1]; ++i) {
        uint entry = incidence[i];
        uchar flag = (entry & beamIncidence) != 0 ? beamFlags[(entry & ~beamIncidence) >> 2] : flags[entry >> 2];
        if (flag == elementActive) {
            return;
        }
    }
    int exchangeCell = debrisCell(reference[n].xyz + float3(node.displacement), fluidMask, u, couplingMap);
    if (exchangeCell < 0) {
        return;
    }
    float frontal = pow(reference[n].w, 2.0f / 3.0f) / (u.fluidCell * u.fluidCell * u.fluidCell);
    atomic_fetch_add_explicit(&area[exchangeCell], int(round(min(frontal * exchangeAreaScale, 1.0e9f))),
                              memory_order_relaxed);
}

// After the solid body's node pass: each shell node tied to the solid takes the motion of its
// line of solid nodes: their mean displacement and velocity, and their rotation about the
// line's middle, the duals of the way its force and moment are handed to them.
kernel void shellFollowSolid(device ShellNode *nodes [[buffer(0)]],
                             const device StructureNode *solidNodes [[buffer(1)]],
                             const device InterfaceLink *links [[buffer(2)]],
                             constant uint &linkCount [[buffer(3)]],
                             uint n [[thread_position_in_grid]]) {
    if (n >= linkCount) {
        return;
    }
    InterfaceLink link = links[n];
    float3 displacement = float3(0.0f);
    float3 velocity = float3(0.0f);
    float3 turn = float3(0.0f);
    float3 spin = float3(0.0f);
    for (uint a = 0; a < link.count; ++a) {
        StructureNode line = solidNodes[link.nodes[a]];
        float3 arm = float3(link.arms[a]);
        displacement += float3(line.displacement);
        velocity += float3(line.velocity);
        turn += cross(arm, float3(line.displacement));
        spin += cross(arm, float3(line.velocity));
    }
    ShellNode node = nodes[link.shellNode];
    node.displacement = displacement / float(link.count);
    node.velocity = velocity / float(link.count);
    turn *= link.inverseSecondMoment;
    node.spin = spin * link.inverseSecondMoment;
    float angle = length(turn);
    float3 axis = angle > 1e-9f ? turn / angle : float3(0.0f, 0.0f, 1.0f);
    node.rotation = float4(axis * sin(0.5f * angle), cos(0.5f * angle));
    nodes[link.shellNode] = node;
}

// Contact between the two parts of a mixed body. Each part has its own contact table; these
// passes let each node of one part meet the nodes of the other through the other's table, after
// both tables have been filled and each part's own contact found, and before either part moves.
// A solid node and a shell node touch closer than half the sum of their spheres' widths. Every
// pair is worked out the same way from both sides, from positions and velocities at the start of
// the substep, so the forces are equal and opposite, and each sum runs in table order, so runs
// repeat exactly. As within a part, nodes dropped by their own crowded entry take no part, shell
// nodes tied into the solid (which move with it) are left out, and pairs that began closer than
// `neighbourDistance` never repel. The solid pass marks each shell node it finds within reach, so
// the shell pass, whose search of the solid's smaller cells is the wider, runs only for those:
// they are exactly the shell nodes that have a solid partner.
struct CrossContact {
    float reach;
    float neighbourDistance;
};

// The force on the first of two nodes from the second, `offset` and `relative` being its position
// and velocity relative to the second's: the same spring, damper and friction as within a part.
static inline float3 crossPairForce(float3 offset, float3 relative, float mass, float reach,
                                    constant StructureUniforms &u) {
    float gap = length(offset);
    if (gap >= reach || gap < 1e-9f) {
        return float3(0.0f);
    }
    float3 normal = offset / gap;
    float stiffness = u.contactStiffness * mass;
    float damping = 2.0f * u.contactDamping * sqrt(stiffness * mass);
    float approach = dot(relative, normal);
    float push = approach > separationLimit ? 0.0f : max(stiffness * (reach - gap) - damping * approach, 0.0f);
    float3 force = push * normal;
    float3 sliding = relative - approach * normal;
    float speed = length(sliding);
    if (speed > 1e-6f) {
        force -= min(u.contactFriction * push, damping * speed) * (sliding / speed);
    }
    return force;
}

// Each surface node of the solid part, against the shell nodes near it.
kernel void crossContactSolid(const device uint *nodeList [[buffer(0)]],
                              const device StructureNode *nodes [[buffer(1)]],
                              const device uint *slots [[buffer(2)]],
                              constant StructureUniforms &u [[buffer(3)]],
                              const device StepControl &control [[buffer(4)]],
                              device packed_float3 *contact [[buffer(5)]],
                              const device ShellNode *shellNodes [[buffer(6)]],
                              const device float4 *reference [[buffer(7)]],
                              const device uint *shellHeads [[buffer(8)]],
                              const device uint *shellSlots [[buffer(9)]],
                              constant ShellUniforms &su [[buffer(10)]],
                              constant CrossContact &cross [[buffer(11)]],
                              device uint *nearSolid [[buffer(12)]],
                              uint threadIndex [[thread_position_in_grid]]) {
    bool active;
    float dt = structureStep(u, control, active);
    if (!active) {
        return;
    }
    StructureNode node = nodes[threadIndex];
    if ((node.flags & nodeBuried) != 0) {
        return;
    }
    float3 position = nodePosition(threadIndex, nodeList, nodes, u);
    uint own = contactBucket(contactCell(position, u), u);
    bool listed = false;
    for (uint slot = 0; slot < contactSlots; ++slot) {
        listed = listed || slots[own * contactSlots + slot] == threadIndex;
    }
    if (!listed) {
        return;
    }
    float3 home = float3(u.originX, u.originY, u.originZ) + float3(latticeNode(nodeList[threadIndex], u)) * u.h;
    int3 low = shellContactCell(position - cross.reach, su);
    int3 high = shellContactCell(position + cross.reach, su);
    float3 force = float3(0.0f);
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                int3 c = int3(x, y, z);
                uint target = shellContactBucket(c, su);
                if (shellHeads[target] != su.stamp) {
                    continue;
                }
                for (uint slot = 0; slot < shellContactSlots; ++slot) {
                    uint other = shellSlots[target * shellContactSlots + slot];
                    if (other == emptySlot) {
                        break;
                    }
                    ShellNode partner = shellNodes[other];
                    float3 otherPosition = reference[other].xyz + float3(partner.displacement);
                    if ((partner.flags & shellOnSolid) != 0 || any(shellContactCell(otherPosition, su) != c)
                        || distance(home, reference[other].xyz) < cross.neighbourDistance
                        || distance(position, otherPosition) >= cross.reach) {
                        continue;
                    }
                    nearSolid[other] = 1u;
                    force += crossPairForce(position - otherPosition,
                                            float3(node.velocity) - float3(partner.velocity),
                                            min(node.mass, partner.mass), cross.reach, u);
                }
            }
        }
    }
    float3 total = float3(contact[threadIndex]) + force;
    float largest = node.mass * contactKick / max(dt, 1e-12f);
    float size = length(total);
    contact[threadIndex] = size > largest ? total * (largest / size) : total;
}

// Each shell node, against the surface nodes of the solid part near it.
kernel void crossContactShell(const device ShellNode *nodes [[buffer(0)]],
                              const device float4 *reference [[buffer(1)]],
                              const device uint *slots [[buffer(2)]],
                              constant ShellUniforms &su [[buffer(3)]],
                              const device StepControl &control [[buffer(4)]],
                              device packed_float3 *contact [[buffer(5)]],
                              const device uint *solidList [[buffer(6)]],
                              const device StructureNode *solidNodes [[buffer(7)]],
                              const device uint *solidHeads [[buffer(8)]],
                              const device uint *solidSlots [[buffer(9)]],
                              constant StructureUniforms &u [[buffer(10)]],
                              constant CrossContact &cross [[buffer(11)]],
                              device uint *nearSolid [[buffer(12)]],
                              uint n [[thread_position_in_grid]]) {
    bool active;
    float dt = shellStep(su, control, active);
    if (!active || n >= su.nodeCount || nearSolid[n] == 0) {
        return;
    }
    nearSolid[n] = 0;
    ShellNode node = nodes[n];
    if ((node.flags & shellOnSolid) != 0) {
        return;
    }
    float3 home = reference[n].xyz;
    float3 position = home + float3(node.displacement);
    uint own = shellContactBucket(shellContactCell(position, su), su);
    bool listed = false;
    for (uint slot = 0; slot < shellContactSlots; ++slot) {
        listed = listed || slots[own * shellContactSlots + slot] == n;
    }
    if (!listed) {
        return;
    }
    int3 low = contactCell(position - cross.reach, u);
    int3 high = contactCell(position + cross.reach, u);
    float3 force = float3(0.0f);
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                int3 c = int3(x, y, z);
                uint target = contactBucket(c, u);
                if (solidHeads[target] != u.stamp) {
                    continue;
                }
                for (uint slot = 0; slot < contactSlots; ++slot) {
                    uint other = solidSlots[target * contactSlots + slot];
                    if (other == emptySlot) {
                        break;
                    }
                    float3 otherPosition = nodePosition(other, solidList, solidNodes, u);
                    float3 otherHome = float3(u.originX, u.originY, u.originZ)
                        + float3(latticeNode(solidList[other], u)) * u.h;
                    if (any(contactCell(otherPosition, u) != c) || distance(home, otherHome) < cross.neighbourDistance) {
                        continue;
                    }
                    StructureNode partner = solidNodes[other];
                    force += crossPairForce(position - otherPosition,
                                            float3(node.velocity) - float3(partner.velocity),
                                            min(node.mass, partner.mass), cross.reach, u);
                }
            }
        }
    }
    float3 total = float3(contact[n]) + force;
    float largest = node.mass * contactKick / max(dt, 1e-12f);
    float size = length(total);
    contact[n] = size > largest ? total * (largest / size) : total;
}

kernel void shellBodyEnvelope(const device ShellNode *nodes [[buffer(0)]],
                              const device float4 *reference [[buffer(1)]],
                              device atomic_uint *bounds [[buffer(2)]],
                              constant uint4 &layout [[buffer(3)]],
                              constant float4 &parameters [[buffer(4)]],
                              const device StepControl &control [[buffer(5)]],
                              constant float2 &timing [[buffer(6)]],
                              uint tid [[thread_position_in_grid]]) {
    if (tid >= layout.w) { return; }
    if (timing.x > 0.0f && (control.dt <= 0.0f || timing.y >= ceil(control.dt / timing.x))) { return; }
    bodyEnvelopePoint(reference[tid].xyz + float3(nodes[tid].displacement), parameters.w, layout.x, bounds);
}
