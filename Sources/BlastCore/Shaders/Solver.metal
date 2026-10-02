// Compressible Euler solver for air blast on a uniform Cartesian grid.
//
// Scheme: dimensionally split MUSCL-Hancock (second order in smooth regions) with a
// minmod-family limiter and an HLLC (or HLL) approximate Riemann solver. Solid cells
// and reflective domain faces are handled with mirrored ghost states, so stationary
// obstacles are exactly conservative. A moving solid mirrors the gas about its own
// velocity, which makes it act as a piston. Layouts here must match `SolverTypes.swift`.

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
};

struct StepControl {
    float dt;
    float batchTime;
    float timeLimit;
    uint stepIndex;
    uint activeSteps;
    float maxOverpressure;  // largest |overpressure| anywhere after the previous step
};

// Primitive state in the sweep frame: v.x is the velocity along the sweep axis.
struct Prim {
    float rho;
    float3 v;
    float p;
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
    w.p = max((u.gamma - 1.0f) * (c.energy - 0.5f * w.rho * dot(velocity, velocity)), u.pressureFloor);
    return w;
}

// Reflection in a wall moving at `wallSpeed` along the sweep axis.
static inline Prim mirrored(Prim w, float wallSpeed) {
    w.v.x = 2.0f * wallSpeed - w.v.x;
    return w;
}

// Speed along the sweep axis of the solid `offset` cells from `cell`; zero outside the region
// where solids move.
static inline float wallSpeed(const device float *wallVelocity, int3 cell, int offset,
                              constant SolverUniforms &u) {
    cell[u.axis] += offset;
    int3 local = cell - int3(u.regionX, u.regionY, u.regionZ);
    int3 dims = int3(u.regionNx, u.regionNy, u.regionNz);
    if (any(local < 0) || any(local >= dims)) {
        return 0.0f;
    }
    return wallVelocity[3 * (local.x + dims.x * (local.y + dims.y * local.z)) + int(u.axis)];
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
    h.p = w.p - halfLambda * (w.v.x * d.p + u.gamma * w.p * d.v.x);

    FacePair faces;
    faces.lo.rho = h.rho - 0.5f * d.rho;
    faces.lo.v = h.v - 0.5f * d.v;
    faces.lo.p = h.p - 0.5f * d.p;
    faces.hi.rho = h.rho + 0.5f * d.rho;
    faces.hi.v = h.v + 0.5f * d.v;
    faces.hi.p = h.p + 0.5f * d.p;

    // Fall back to first order where the reconstruction would lose positivity.
    bool valid = min(faces.lo.rho, faces.hi.rho) > u.densityFloor
        && min(faces.lo.p, faces.hi.p) > u.pressureFloor;
    if (!valid) {
        faces.lo = w;
        faces.hi = w;
    }
    return faces;
}

static inline float totalEnergy(Prim w, float gamma) {
    return w.p / (gamma - 1.0f) + 0.5f * w.rho * dot(w.v, w.v);
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
    float el = totalEnergy(l, gamma);
    float er = totalEnergy(r, gamma);
    float cl = sqrt(gamma * l.p / l.rho);
    float cr = sqrt(gamma * r.p / r.rho);

    // Einfeldt wave-speed estimates from Roe averages.
    float sl = sqrt(l.rho);
    float sr = sqrt(r.rho);
    float inv = 1.0f / (sl + sr);
    float3 vRoe = (sl * l.v + sr * r.v) * inv;
    float hRoe = (sl * (el + l.p) / l.rho + sr * (er + r.p) / r.rho) * inv;
    float cRoe = sqrt(max((gamma - 1.0f) * (hRoe - 0.5f * dot(vRoe, vRoe)), 1e-12f));
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

// One-dimensional MUSCL-Hancock sweep along `u.axis`.
kernel void sweep(const device Cell *src [[buffer(0)]],
                  device Cell *dst [[buffer(1)]],
                  const device uchar *mask [[buffer(2)]],
                  device float *peak [[buffer(3)]],
                  device float *impulse [[buffer(4)]],
                  const device StepControl &control [[buffer(5)]],
                  device atomic_uint *maxSpeed [[buffer(6)]],
                  constant SolverUniforms &u [[buffer(7)]],
                  const device float *wallVelocity [[buffer(8)]],
                  uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    int index = int(tid.x + u.nx * (tid.y + u.ny * tid.z));
    if (mask[index] != 0) {
        return;
    }
    int3 cell = int3(tid);

    uint axis = u.axis;
    int n = axis == 0 ? int(u.nx) : (axis == 1 ? int(u.ny) : int(u.nz));
    int i = int(tid[axis]);
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
    float halfLambda = 0.5f * lambda;
    float theta = u.limiterTheta;

    FacePair facesM1 = reconstruct(wM1, slope(wM2, wM1, w0, theta), halfLambda, u);
    FacePair faces0 = reconstruct(w0, slope(wM1, w0, wP1, theta), halfLambda, u);
    FacePair facesP1 = reconstruct(wP1, slope(w0, wP1, wP2, theta), halfLambda, u);

    Flux fluxLow = riemannFlux(facesM1.hi, faces0.lo, u);
    Flux fluxHigh = riemannFlux(faces0.hi, facesP1.lo, u);

    Cell c = src[index];
    float3 momentum = toSweep(float3(c.mx, c.my, c.mz), axis);
    float rho = c.rho - lambda * (fluxHigh.mass - fluxLow.mass);
    momentum -= lambda * (fluxHigh.momentum - fluxLow.momentum);
    float energy = c.energy - lambda * (fluxHigh.energy - fluxLow.energy);

    rho = max(rho, u.densityFloor);
    float kinetic = 0.5f * dot(momentum, momentum) / rho;
    float pressure = (u.gamma - 1.0f) * (energy - kinetic);
    if (pressure < u.pressureFloor) {
        pressure = u.pressureFloor;
        energy = pressure / (u.gamma - 1.0f) + kinetic;
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
        impulse[index] += max(overpressure, 0.0f) * dt;

        float3 speed = fabs(momentum) / rho;
        float fastest = max(speed.x, max(speed.y, speed.z)) + sqrt(u.gamma * pressure / rho);
        recordWaveSpeed(maxSpeed, fastest);
        // The second slot tracks how disturbed the air still is.
        recordWaveSpeed(maxSpeed + 1, fabs(overpressure));
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
                        uint tid [[thread_position_in_grid]]) {
    if (tid != 0) {
        return;
    }
    float fastest = as_type<float>(atomic_exchange_explicit(maxSpeed, 0u, memory_order_relaxed));
    float dt = u.cfl * u.dx / max(fastest, 1e-6f);
    if (u.forcedStep > 0.0f) {
        dt = u.forcedStep;
    } else {
        control.maxOverpressure = as_type<float>(atomic_exchange_explicit(maxSpeed + 1, 0u, memory_order_relaxed));
    }
    float remaining = max(control.timeLimit - control.batchTime, 0.0f);
    dt = min(dt, remaining);

    uint row = control.stepIndex * (u.gaugeCount + 1);
    gaugeLog[row] = control.batchTime;
    for (uint g = 0; g < u.gaugeCount; ++g) {
        Cell c = state[gaugeCells[g]];
        float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, u.densityFloor);
        gaugeLog[row + 1 + g] = (u.gamma - 1.0f) * (c.energy - kinetic);
    }

    control.dt = dt;
    control.batchTime += dt;
    control.stepIndex += 1;
    control.activeSteps += dt > 0.0f ? 1 : 0;
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
    float pressure = max((u.gamma - 1.0f) * (c.energy - 0.5f * rho * dot(velocity, velocity)),
                         u.pressureFloor);
    float3 speed = fabs(velocity);
    recordWaveSpeed(maxSpeed, max(speed.x, max(speed.y, speed.z)) + sqrt(u.gamma * pressure / rho));
    recordWaveSpeed(maxSpeed + 1, fabs(pressure - u.ambientPressure));
}

static inline float cellPressure(const device Cell *state, int index, constant SolverUniforms &u) {
    Cell c = state[index];
    float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, u.densityFloor);
    return (u.gamma - 1.0f) * (c.energy - kinetic);
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
