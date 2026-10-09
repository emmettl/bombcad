// Rigid footings under connected bases (`Footing`, `FootingSystem` in Swift): one threadgroup
// moves each footing by a step, after the body's node pass has worked out the connection's
// forces on it (`footingJoint` in Structure.metal).

struct FootingUniforms {
    float fixedStep;     // seconds; 0 when coupled to the air
    float criticalStep;  // the body's, to divide the air's step as the body does
    uint substep;
    float gravity;
    float damping;  // the body's mass-proportional damping, 1/s
    uint footings;
    uint unused0;
    uint unused1;
};

// A point of the bed of springs under a footing: where it is from the base centre (x, y), its
// vertical stiffness (N/m) and the force it bears before the soil yields (0: any); then its
// horizontal stiffnesses along x and y, and its vertical and horizontal dashpots (N s/m).
struct BedPoint {
    float4 placeAndBearing;
    float4 shearAndDamping;
};

constant uint footingThreads = 256;
// Samples of the echoes' history per round trip of a wave through the layer.
constant uint footingSamples = 32;

static inline float footingStepLength(constant FootingUniforms &u, const device StepControl &control,
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

// The value of a mode's history `delay` seconds ago, linearly between its samples (zero before
// the start). `ring` holds `capacity` samples taken every `interval` s, `written` of them so far.
static inline float footingHistory(const device float *ring, uint capacity, float interval, uint written,
                                   float time, float delay) {
    float at = (time - delay) / interval;
    if (at < 0.0f || written == 0) {
        return 0.0f;
    }
    uint first = uint(floor(at));
    float fraction = at - float(first);
    uint last = written - 1;
    uint a = min(first, last);
    uint b = min(first + 1, last);
    return mix(ring[a % capacity], ring[b % capacity], fraction);
}

kernel void footingStep(device FootingState *states [[buffer(0)]],
                        const device FootingConstants *constants [[buffer(1)]],
                        const device BedPoint *bed [[buffer(2)]],
                        device float4 *bedState [[buffer(3)]],
                        const device uint *members [[buffer(4)]],
                        const device float4 *links [[buffer(5)]],
                        device float *history [[buffer(6)]],
                        const device float *echoes [[buffer(7)]],
                        const device StepControl &control [[buffer(8)]],
                        constant FootingUniforms &u [[buffer(9)]],
                        uint footing [[threadgroup_position_in_grid]],
                        uint worker [[thread_index_in_threadgroup]],
                        uint lane [[thread_index_in_simdgroup]],
                        uint group [[simdgroup_index_in_threadgroup]]) {
    bool active;
    float dt = footingStepLength(u, control, active);
    if (!active || footing >= u.footings) {
        return;
    }
    FootingConstants c = constants[footing];
    FootingState s = states[footing];
    float3 centre = c.rest.xyz + s.centre.xyz;
    float3 baseArm = footingRotate(s.rotation, c.base.xyz);
    float3 baseVelocity = s.velocity.xyz + cross(s.spin.xyz, baseArm);
    bool pointDamping = c.base.w > 0.5f;

    // The body's pull on the footing through the connection, as the node pass left it.
    float3 jointForce = float3(0.0f);
    float3 springs = float3(0.0f);  // the bed's springs alone, without its dashpots
    float3 jointMoment = float3(0.0f);
    for (uint m = c.ranges.z + worker; m < c.ranges.z + c.ranges.w; m += footingThreads) {
        uint entity = members[m];
        jointForce += links[2 * entity].xyz;
        jointMoment += links[2 * entity + 1].xyz;
    }

    // The soil's push on the footing's base, point by point of the bed.
    float3 soilForce = float3(0.0f);
    float3 soilMoment = float3(0.0f);  // about the centre of mass
    float bearing = 0.0f, bearingX = 0.0f, bearingY = 0.0f;  // sum k, k x^2, k y^2 of the points that bear
    float lift = 0.0f, sunk = 0.0f;
    float4 extent = float4(INFINITY, -INFINITY, INFINITY, -INFINITY);
    for (uint p = c.ranges.x + worker; p < c.ranges.x + c.ranges.y; p += footingThreads) {
        BedPoint point = bed[p];
        float4 state = bedState[p];  // slip x, slip y, settlement, unused
        float2 place = point.placeAndBearing.xy;
        float k = point.placeAndBearing.z;
        float capacity = point.placeAndBearing.w;
        float3 rest = c.base.xyz + float3(place, 0.0f);
        float3 arm = footingRotate(s.rotation, rest);
        float3 displacement = s.centre.xyz + arm - rest;
        float3 velocity = pointDamping ? s.velocity.xyz + cross(s.spin.xyz, arm) : baseVelocity;
        float opening = displacement.z - state.z;
        float3 force = float3(0.0f);
        if (opening < 0.0f) {
            float push = -k * opening;
            if (capacity > 0.0f && push > capacity) {
                state.z = displacement.z + capacity / k;  // the soil yields, and the footing sinks for good
                push = capacity;
            }
            float normal = max(push - point.shearAndDamping.z * velocity.z, 0.0f);
            if (capacity > 0.0f) {
                normal = min(normal, capacity);
            }
            float2 stiffness = point.shearAndDamping.xy;
            float2 elastic = -stiffness * (displacement.xy - state.xy);
            // Coulomb friction, on the point's share of all the soil bears, the echoes' too.
            float limit = normal * c.totals.w * (s.elastic.w > 0.0f ? s.elastic.w : 1.0f);
            float size = length(elastic);
            if (size > limit) {
                elastic *= limit / size;
                state.xy = displacement.xy + elastic / stiffness;
            }
            springs += float3(elastic, push);
            float2 shear = elastic - point.shearAndDamping.w * velocity.xy;
            float total = length(shear);
            if (total > limit) {
                shear *= limit / total;
            }
            force = float3(shear, normal);
            bearing += k;
            bearingX += k * place.x * place.x;
            bearingY += k * place.y * place.y;
            extent = float4(min(extent.x, place.x), max(extent.y, place.x), min(extent.z, place.y),
                            max(extent.w, place.y));
        } else {
            state.xy = displacement.xy;  // off the ground: it lands again unstrained
            lift = max(lift, opening);
        }
        sunk = max(sunk, -state.z);
        bedState[p] = state;
        soilForce += force;
        soilMoment += cross(arm, force);
    }

    // Add up over the threadgroup: sums, then greatest and least.
    threadgroup float sums[8][16];
    threadgroup float4 bounds[8];
    threadgroup float greatest[8][2];
    float values[16] = {jointForce.x, jointForce.y, jointForce.z, jointMoment.x, jointMoment.y, jointMoment.z,
                        soilForce.x,  soilForce.y,  soilForce.z,  soilMoment.x, soilMoment.y, soilMoment.z,
                        bearing,      springs.x,    springs.y,    springs.z};
    for (uint i = 0; i < 16; ++i) {
        float total = simd_sum(values[i]);
        if (lane == 0) {
            sums[group][i] = total;
        }
    }
    float2 partial = float2(simd_sum(bearingX), simd_sum(bearingY));
    float4 groupExtent = float4(simd_min(extent.x), simd_max(extent.y), simd_min(extent.z), simd_max(extent.w));
    float groupLift = simd_max(lift);
    float groupSunk = simd_max(sunk);
    threadgroup float2 seconds[8];
    if (lane == 0) {
        bounds[group] = groupExtent;
        greatest[group][0] = groupLift;
        greatest[group][1] = groupSunk;
        seconds[group] = partial;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (worker != 0) {
        return;
    }
    uint groups = (footingThreads + 31) / 32;
    float total[16];
    for (uint i = 0; i < 16; ++i) {
        total[i] = 0.0f;
        for (uint g = 0; g < groups; ++g) {
            total[i] += sums[g][i];
        }
    }
    float2 second = float2(0.0f);
    extent = float4(INFINITY, -INFINITY, INFINITY, -INFINITY);
    lift = 0.0f;
    sunk = 0.0f;
    for (uint g = 0; g < groups; ++g) {
        second += seconds[g];
        extent = float4(min(extent.x, bounds[g].x), max(extent.y, bounds[g].y), min(extent.z, bounds[g].z),
                        max(extent.w, bounds[g].w));
        lift = max(lift, greatest[g][0]);
        sunk = max(sunk, greatest[g][1]);
    }
    jointForce = float3(total[0], total[1], total[2]);
    jointMoment = float3(total[3], total[4], total[5]);
    soilForce = float3(total[6], total[7], total[8]);
    soilMoment = float3(total[9], total[10], total[11]);
    // The fraction of the bed that bears, in each mode: vertical (and horizontal), rocking about
    // x, rocking about y.
    float3 bearingShare = float3(total[12] / max(c.totals.x, 1e-30f), second.y / max(c.totals.z, 1e-30f),
                                 second.x / max(c.totals.y, 1e-30f));

    // The soil's own mass and the waves it carries away: lumped at the base centre.
    float3 lumpedForce = float3(0.0f);
    float2 lumpedMoment = float2(0.0f);
    // Small rotations about x and y, and their rates.
    float2 tilt = 2.0f * s.rotation.xy * (s.rotation.w < 0.0f ? -1.0f : 1.0f);
    float2 tiltRate = s.spin.xy;
    float4 cone = s.cone;
    // Rocking cones: a dashpot to an internal rotary mass, moving it exactly over the step.
    for (uint axis = 0; axis < 2; ++axis) {
        float dashpot = c.rocking[axis] * bearingShare[axis + 1];
        float mass = c.rocking[axis + 2];
        if (dashpot <= 0.0f || mass <= 0.0f) {
            continue;
        }
        float before = cone[axis];
        float after = tiltRate[axis] - (tiltRate[axis] - before) * exp(-dashpot * dt / mass);
        cone[axis] = after;
        lumpedMoment[axis] -= mass * (after - before) / dt;
    }

    // Over a layer, each wave sent down comes back as a train of echoes. The half-space's
    // response ũ(t) to the footing's motion u(t) is u − Σ wⱼ ũ(t − j T); the soil's force is the
    // half-space's on ũ, so the echoes add its force on Δ = ũ − u, a sum over ũ's past.
    float4 sampleCount = float4(s.velocity.w, s.spin.w, 0.0f, 0.0f);
    if (c.stiffness.w > 0.5f) {
        uint capacity = c.history.z;
        // The soil's own deformation under the footing, from its springs: not the footing's
        // motion, which lifts and slides past what the soil carries. Its rate, from the last
        // step's.
        float3 elastic = float3(-total[13] / c.stiffness.y, -total[14] / c.stiffness.z, -total[15] / c.stiffness.x);
        float3 elasticRate = s.elastic.w > 0.0f ? (elastic - s.elastic.xyz) / dt : float3(0.0f);
        s.elastic.xyz = elastic;
        float mode[5] = {elastic.z, elastic.x, elastic.y, tilt.x, tilt.y};
        float rate[5] = {elasticRate.z, elasticRate.x, elasticRate.y, tiltRate.x, tiltRate.y};
        float stiffness[5] = {c.stiffness.x, c.stiffness.y, c.stiffness.z, c.moreStiffness.x, c.moreStiffness.y};
        float share[5] = {bearingShare.x, bearingShare.x, bearingShare.x, bearingShare.y, bearingShare.z};
        float time = s.centre.w;
        float response[5];
        for (uint m = 0; m < 5; ++m) {
            bool shear = m == 1 || m == 2;
            float period = shear ? c.layer.y : c.layer.x;
            float interval = shear ? c.layer.w : c.layer.z;
            uint written = uint(shear ? sampleCount.y : sampleCount.x);
            const device float *values = history + c.history.x + (2 * m) * capacity;
            const device float *rates = values + capacity;
            float delta = 0.0f;
            float deltaRate = 0.0f;
            for (uint j = 1; j <= c.history.w; ++j) {
                float weight = echoes[c.history.y + m * 64 + j - 1];
                if (weight == 0.0f) {
                    break;
                }
                delta -= weight * footingHistory(values, capacity, interval, written, time, float(j) * period);
                deltaRate -= weight * footingHistory(rates, capacity, interval, written, time, float(j) * period);
            }
            float force = -share[m] * stiffness[m] * delta;
            if (m == 0) {
                force -= share[m] * c.moreStiffness.z * deltaRate;
            } else if (shear) {
                force -= share[m] * c.moreStiffness.w * deltaRate;
            } else {
                // The rocking cone's dashpot and internal mass, driven by the echoes alone.
                uint axis = m - 3;
                float dashpot = c.rocking[axis] * share[m];
                float mass = c.rocking[axis + 2];
                if (dashpot > 0.0f && mass > 0.0f) {
                    float before = cone[axis + 2];
                    float after = deltaRate - (deltaRate - before) * exp(-dashpot * dt / mass);
                    cone[axis + 2] = after;
                    force -= mass * (after - before) / dt;
                }
            }
            if (m == 0) {
                lumpedForce.z += force;
            } else if (m == 1) {
                lumpedForce.x += force;
            } else if (m == 2) {
                lumpedForce.y += force;
            } else {
                lumpedMoment[m - 3] += force;
            }
            response[m] = mode[m] + delta;
            rate[m] += deltaRate;
        }
        // The echoes cannot make the soil pull on the footing, nor hold it past its friction.
        // They bear part of its weight, which the bed's points take into their friction next
        // step.
        float normal = soilForce.z;
        lumpedForce.z = max(lumpedForce.z, -normal);
        s.elastic.w = normal > 0.0f ? max((normal + lumpedForce.z) / normal, 1e-3f) : 1.0f;
        float2 sideways = soilForce.xy + lumpedForce.xy;
        float grip = c.totals.w * (normal + lumpedForce.z);
        if (length(sideways) > grip) {
            lumpedForce.xy = sideways * (grip / max(length(sideways), 1e-30f)) - soilForce.xy;
        }
        // Record ũ and its rate at every sample time this step has reached.
        for (uint kind = 0; kind < 2; ++kind) {
            float interval = kind == 1 ? c.layer.w : c.layer.z;
            uint written = uint(sampleCount[kind]);
            while (float(written) * interval <= time && written < 0xFFFFFF) {
                for (uint m = 0; m < 5; ++m) {
                    if ((m == 1 || m == 2) != (kind == 1)) {
                        continue;
                    }
                    device float *values = history + c.history.x + (2 * m) * capacity;
                    values[written % capacity] = response[m];
                    values[capacity + written % capacity] = rate[m];
                }
                written += 1;
            }
            sampleCount[kind] = float(written);
        }
    }

    // Move the footing: forces and moments about its centre of mass, gravity, and the body's
    // damping.
    float3 force = jointForce + soilForce + lumpedForce - float3(0.0f, 0.0f, c.rest.w * u.gravity);
    float3 moment = jointMoment + soilMoment + cross(baseArm, lumpedForce) + float3(lumpedMoment, 0.0f);
    float decay = max(0.0f, 1.0f - u.damping * dt);
    float3 mass = float3(c.rest.w, c.rest.w, c.rest.w + c.inertia.w);
    float3 velocity = (s.velocity.xyz + dt * force / mass) * decay;
    // Euler's equations in the space frame: I dω/dt = M - ω × I ω, I = R diag(I) Rᵀ.
    float3x3 r = rotationOf(s.rotation);
    float3x3 rt = transpose(r);
    float3 bodySpin = rt * s.spin.xyz;
    float3 bodyMoment = rt * moment;
    float3 principal = c.inertia.xyz;
    float3 bodyAcceleration = (bodyMoment - cross(bodySpin, principal * bodySpin)) / principal;
    float3 spin = (s.spin.xyz + dt * (r * bodyAcceleration)) * decay;
    float3 angle = spin * dt;
    float size = length(angle);
    float4 rotation = s.rotation;
    if (size > 0.0f) {
        float4 q = float4(angle / size * sin(0.5f * size), cos(0.5f * size));
        float4 p = rotation;
        rotation = normalize(float4(q.w * p.xyz + p.w * q.xyz + cross(q.xyz, p.xyz), q.w * p.w - dot(q.xyz, p.xyz)));
    }
    s.centre = float4(s.centre.xyz + dt * velocity, s.centre.w + dt);
    s.rotation = rotation;
    s.velocity = float4(velocity, sampleCount.x);
    s.spin = float4(spin, sampleCount.y);
    s.cone = cone;
    s.soilForce = float4(soilForce + lumpedForce, bearingShare.x);
    s.soilMoment = float4(soilMoment - cross(baseArm, soilForce) + float3(lumpedMoment, 0.0f), lift);
    s.jointForce = float4(jointForce, sunk);
    s.contact = extent;
    states[footing] = s;
}
