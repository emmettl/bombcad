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
    uint padding0;
    uint padding1;
};

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

// State of one layer at one of the four in-plane points.
struct ShellLayer {
    float2 crack;  // concrete: largest tensile strain across the planes normal to the element's
                   // axes; von Mises: plastic strain along them
    float2 crush;  // concrete: largest compressive strain along the axes; von Mises: plastic
                   // shear strain and equivalent plastic strain
    float rate;    // running average of the effective strain rate
    float crackingFactor;  // tensile rate factor frozen when the layer first cracked
    float display;         // 0 (sound) to 1 (failing)
    float spare;
};

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

// Overpressure of the air on one side of a shell: the first fluid cell beyond the shell's face.
static inline float shellOverpressure(float3 point, float3 normal, float halfThickness, const device Cell *fluid,
                                      const device uchar *fluidMask, constant ShellUniforms &u) {
    int3 dims = int3(u.fluidNx, u.fluidNy, u.fluidNz);
    float3 sample = point + normal * (halfThickness + 0.5f * u.fluidCell);
    for (int attempt = 0; attempt < 3; ++attempt) {
        int3 cell = int3(floor(sample / u.fluidCell));
        if (any(cell < 0) || any(cell >= dims)) {
            return 0.0f;
        }
        int index = cell.x + dims.x * (cell.y + dims.y * cell.z);
        if (fluidMask[index] == 0) {
            Cell c = fluid[index];
            float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, 1e-6f);
            return (u.fluidGamma - 1.0f) * (c.energy - kinetic) - u.ambientPressure;
        }
        sample += normal * u.fluidCell;
    }
    return 0.0f;
}

// What a layer reports besides its stresses.
struct LayerOutcome {
    float2 torn;      // per in-plane axis: 1 where the crack across that axis is wide enough to remove
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
                                   constant ShellUniforms &u, thread float2 &shear, thread LayerOutcome &outcome) {
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
    float compressionFactor = compressionIncrease(state.rate, m);
    float onset = m.crackOnset * tensionFactor;

    float poisson = 0.5f * m.lambda / (m.lambda + m.mu);
    if (worst > onset) {
        poisson *= concreteTension(worst, worst, tensionFactor, m) / (m.youngsModulus * worst);
    }
    float scale = 1.0f / (1.0f - poisson * poisson);
    float2 uniaxial = float2(strain.x + poisson * strain.y, strain.y + poisson * strain.x) * scale;

    // Rankine: principal values of the elastic stress over E, shared between the two planes in
    // proportion to the squared direction cosines.
    float shearOverE = strain.z / (1.0f + poisson);
    float centre = 0.5f * (uniaxial.x + uniaxial.y);
    float radius = sqrt(0.25f * (uniaxial.x - uniaxial.y) * (uniaxial.x - uniaxial.y) + shearOverE * shearOverE);
    float angle = 0.5f * atan2(2.0f * shearOverE, uniaxial.x - uniaxial.y);
    float c = cos(angle);
    float s = sin(angle);
    float2 principal = float2(centre + radius, centre - radius);
    float2 directions[2] = {float2(c * c, s * s), float2(s * s, c * c)};
    for (int i = 0; i < 2; ++i) {
        float2 weight = directions[i];
        float seen = dot(weight, history);
        if (principal[i] > seen && principal[i] > onset) {
            history += (principal[i] - seen) * weight / dot(weight, weight);
        }
    }
    history = max(history, uniaxial);
    state.crack = history;
    float crack = max(history.x, history.y);

    float2 residual = float2(crackResidual(history.x, tensionFactor, m), crackResidual(history.y, tensionFactor, m));
    float2 squeeze = residual - uniaxial;
    float2 crush = max(state.crush, squeeze);
    state.crush = crush;

    float2 normalStress;
    float crushed = 0.0f;
    bool pulverised = false;
    for (int j = 0; j < 2; ++j) {
        if (squeeze[j] <= 0.0f) {
            normalStress[j] = concreteTension(uniaxial[j], history[j], tensionFactor, m);
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
    float inPlane = m.mu * 2.0f * strain.z;
    if (opened > 0.0f) {
        inPlane = clamp(m.shearRetention * inPlane, -interlock, interlock);
    }
    for (int j = 0; j < 2; ++j) {
        float stress = u.shearFactor * m.mu * transverse[j];
        float across = history[j] - onset;
        if (across > 0.0f) {
            float w = across * m.crackBand;
            float limit = m.interlockStrength * tensionFactor / (0.31f + m.interlockWidthScale * w);
            stress = clamp(m.shearRetention * stress, -limit, limit);
        }
        shear[j] = stress;
    }

    outcome.torn = float2(history.x >= m.erosionStrain ? 1.0f : 0.0f, history.y >= m.erosionStrain ? 1.0f : 0.0f);
    outcome.destroyed = pulverised || crack >= m.erosionStrain;
    outcome.open = crack > max(1.0f, 3.0f * m.erosionStrain);
    outcome.failed = false;
    state.display = max(crack / m.erosionStrain, crushed);
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
    outcome.destroyed = false;
    outcome.open = false;
    outcome.failed = plastic >= m.failureStrain;
    state.display = plastic / m.failureStrain;
    return stress;
}

// Stress in one direction of a bar layer, as the solid elements' bars: the measured curve while
// loaded one way, the cyclic law once reversed. Returns false once the bars have ruptured.
static inline bool shellBar(device ShellBar &bar, float green, float rate, constant MaterialParameters &m,
                            thread float &stress, thread float &root, thread float &yieldOut) {
    float plastic = bar.plastic;
    if (fabs(plastic) > 1e8f) {
        return false;
    }
    root = sqrt(max(1.0f + 2.0f * green, 1e-6f));
    float fibre = 2.0f * green / (1.0f + root);
    stress = m.steelModulus * (fibre - plastic);
    float accumulated = fabs(plastic);
    float slope;
    float yield = steelYield(accumulated, m, slope);
    float first = m.steelStress[0];
    float top = m.steelStress[m.steelPoints - 1];
    float along = clamp((yield - first) / max(top - first, 1.0f), 0.0f, 1.0f);
    float ratio = max(rate, 1e-4f) / 1e-4f;
    float factor = mix(pow(ratio, m.steelRateYield), pow(ratio, m.steelRateUltimate), along);
    yield *= factor;
    if (plastic == 0.0f) {
        if (fabs(stress) > yield) {
            float increment = (fabs(stress) - yield) / max(m.steelModulus + slope * factor, 0.1f * m.steelModulus);
            plastic = stress > 0.0f ? increment : -increment;
            stress = m.steelModulus * (fibre - plastic);
        }
    } else {
        stress = cycleBar(bar.history, fibre, plastic, yield, slope * factor, first * pow(ratio, m.steelRateYield), m);
    }
    if (fabs(plastic) > m.steelStrain[m.steelPoints - 1]) {
        bar.plastic = 1e9f;  // ruptured for good
        return false;
    }
    bar.plastic = plastic;
    yieldOut = yield;
    return true;
}

kernel void shellElements(device ShellLayer *layers [[buffer(0)]],
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
                          uint e [[thread_position_in_grid]]) {
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
    float worstDisplay = 0.0f;
    const float gauss = 0.57735026919f;

    for (uint g = 0; g < 4; ++g) {
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
        float2 tornEverywhere = float2(1.0f);
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
            ShellLayer state = layers[slot];
            float2 shear;
            LayerOutcome outcome;
            float3 stress = m.materialModel == 0
                ? shellVonMises(strain, transverse, state, m, u, shear, outcome)
                : shellConcrete(strain, transverse, instantaneous, dt, state, m, u, shear, outcome);
            layers[slot] = state;
            rateSum += state.rate;
            worstDisplay = max(worstDisplay, state.display);
            remove = remove || outcome.failed;
            tornEverywhere *= outcome.torn;
            destroyedEverywhere = destroyedEverywhere && outcome.destroyed;
            openEverywhere = openEverywhere && outcome.open;

            float3 r1 = stress.x * f1 + stress.z * f2;
            float3 r2 = stress.y * f2 + stress.z * f1;
            p1 += layerWeight * r1;
            q1 += layerWeight * zeta * r1;
            p2 += layerWeight * r2;
            q2 += layerWeight * zeta * r2;
            shearSum += layerWeight * shear;
        }

        // Bar layers, at their own depths, both ways.
        float2 barsIntact = float2(0.0f);
        bool anyBars = false;
        for (uint s = 0; s < el.barCount && s < u.barSlots; ++s) {
            float4 layout = barLayout[e * u.barSlots + s];
            float zeta = layout.x;
            for (uint j = 0; j < 2; ++j) {
                float area = layout[1 + j];
                if (area <= 0.0f) {
                    continue;
                }
                anyBars = true;
                float3 h = j == 0 ? h1m + zeta * h1b : h2m + zeta * h2b;
                float green = (j == 0 ? h[i1] : h[i2]) + 0.5f * dot(h, h);
                float3 f = (j == 0 ? e1 : e2) + h;
                float stress;
                float root;
                float yield;
                device ShellBar &bar = bars[((e * 4 + g) * u.barSlots + s) * 2 + j];
                if (!shellBar(bar, green, rateSum / float(n), m, stress, root, yield)) {
                    continue;
                }
                barsIntact[j] = 1.0f;
                float3 r = (areaWeight * area * stress / root) * f;
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
        remove = remove || torn || (destroyedEverywhere && bare) || openEverywhere;

        float tieWeight[4] = {0.5f * (1.0f - p.y), 0.5f * (1.0f + p.y), 0.5f * (1.0f - p.x), 0.5f * (1.0f + p.x)};
        for (uint q = 0; q < 4; ++q) {
            tieForce[q] += tieWeight[q] * shearSum[q < 2 ? 0 : 1];
        }

        // Pressure: the difference between the air on the two sides, on the deformed midsurface.
        float3 f1m = e1 + h1m;
        float3 f2m = e2 + h2m;
        float3 areaVector = cross(f1m, f2m) * areaWeight;
        float3 load = float3(0.0f);
        if (u.coupled != 0) {
            float3 unit = normalize(areaVector);
            float front = shellOverpressure(centre, unit, 0.5f * t, fluid, fluidMask, u);
            float back = shellOverpressure(centre, -unit, 0.5f * t, fluid, fluidMask, u);
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

    display[e] = worstDisplay;
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
                       uint n [[thread_position_in_grid]]) {
    bool active;
    float dt = shellStep(u, control, active);
    if (!active || n >= u.nodeCount) {
        return;
    }
    ShellNode node = nodes[n];
    float3 force = float3(0.0f);
    float3 moment = float3(0.0f);
    for (uint i = incidenceStart[n]; i < incidenceStart[n + 1]; ++i) {
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
        }
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
    if (referenceHeight + displacement.z < 0.0f && u.groundFriction >= 0.0f) {
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
    node.displacement = displacement;
    node.velocity = velocity;
    node.spin = spin;
    node.rotation = rotation;
    nodes[n] = node;
}
