// The quarry face's contact solver (docs/hillside-blast.md), compiled on its own at run time.
// Illustrative: for the look of a face being blasted; not a blast-design aid.
#include <metal_stdlib>
using namespace metal;

struct QuarryBody {
    float4 posInvMass;
    float4 quat;
    float4 velSleep;
    float4 ang;
    float4 invInertiaFire;
    float4 launchSwell;
    float4 spinRise;
    float4 swell;
    uint first, count, state, pad;
};

struct QuarryUniforms {
    float dt, time, gravity, kc;
    float damping, friction, wakeSpeed, cell;
    float4 origin;
    int4 dims;
    float4 terrainOrigin;
    int4 terrainDims;
    float sleepSpeed, sleepSpin, sleepTime, frictionGamma;
    uint bodyCount, sphereCount, cellCount;
    // Below this speed a supported body is damped toward rest (m/s).
    float creepSpeed;
};

static inline float3 rotate(float4 q, float3 v) {
    float3 t = 2.0f * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

static inline float3 unrotate(float4 q, float3 v) {
    float3 t = 2.0f * cross(-q.xyz, v);
    return v + q.w * t + cross(-q.xyz, t);
}

kernel void updateSpheres(const device QuarryBody *bodies [[buffer(0)]],
                          const device float4 *spheres [[buffer(1)]],
                          const device uint *sphereBody [[buffer(2)]],
                          device float4 *world [[buffer(3)]],
                          device float4 *velocity [[buffer(4)]],
                          uint i [[thread_position_in_grid]]) {
    const device QuarryBody &b = bodies[sphereBody[i]];
    float3 r = rotate(b.quat, spheres[i].xyz);
    world[i] = float4(b.posInvMass.xyz + r, spheres[i].w);
    velocity[i] = float4(b.velSleep.xyz + cross(b.ang.xyz, r), 0.0f);
}

kernel void clearGrid(device uint *heads [[buffer(0)]],
                      uint i [[thread_position_in_grid]]) {
    heads[i] = 0xFFFFFFFFu;
}

static inline int3 gridCell(float3 p, constant QuarryUniforms &u) {
    return clamp(int3(floor((p - u.origin.xyz) / u.cell)), int3(0), u.dims.xyz - 1);
}
static inline uint gridIndex(int3 c, constant QuarryUniforms &u) {
    return uint(c.x + u.dims.x * (c.y + u.dims.y * c.z));
}

kernel void insertSpheres(const device float4 *world [[buffer(0)]],
                          device atomic_uint *heads [[buffer(1)]],
                          device uint *next [[buffer(2)]],
                          constant QuarryUniforms &u [[buffer(3)]],
                          uint i [[thread_position_in_grid]]) {
    uint cell = gridIndex(gridCell(world[i].xyz, u), u);
    uint previous = atomic_exchange_explicit(&heads[cell], i, memory_order_relaxed);
    next[i] = previous;
}

static inline void terrainSample(float2 p, const device float *h, constant QuarryUniforms &u, thread float &height, thread float3 &normal) {
    float2 g = (p - u.terrainOrigin.xy) / u.terrainOrigin.z;
    int ci = u.terrainDims.x, cj = u.terrainDims.y;
    int i = clamp(int(floor(g.x)), 0, ci - 2);
    int j = clamp(int(floor(g.y)), 0, cj - 2);
    float fx = g.x - float(i), fy = g.y - float(j);
    float h00 = h[i + ci * j], h10 = h[i + 1 + ci * j], h01 = h[i + ci * (j + 1)], h11 = h[i + 1 + ci * (j + 1)];
    height = mix(mix(h00, h10, fx), mix(h01, h11, fx), fy);
    float sx = mix(h10 - h00, h11 - h01, fy) / u.terrainOrigin.z;
    float sy = mix(h01 - h00, h11 - h10, fx) / u.terrainOrigin.z;
    normal = normalize(float3(-sx, -sy, 1.0f));
}

kernel void forces(const device QuarryBody *bodies [[buffer(0)]],
                   const device float4 *world [[buffer(1)]],
                   const device float4 *velocity [[buffer(2)]],
                   const device uint *sphereBody [[buffer(3)]],
                   const device uint *heads [[buffer(4)]],
                   const device uint *next [[buffer(5)]],
                   const device float *heights [[buffer(6)]],
                   constant QuarryUniforms &u [[buffer(7)]],
                   device float4 *forceOut [[buffer(8)]],
                   device float4 *torqueOut [[buffer(9)]],
                   device atomic_uint *wake [[buffer(10)]],
                   uint i [[thread_position_in_grid]]) {
    uint bi = sphereBody[i];
    QuarryBody A = bodies[bi];
    if (A.state != 1u) { forceOut[i] = float4(0); torqueOut[i] = float4(0); return; }
    float3 pi = world[i].xyz;
    float ri = world[i].w;
    float3 vi = velocity[i].xyz;
    float invM = A.posInvMass.w;
    float3 apos = A.posInvMass.xyz;
    float3 f = float3(0), t = float3(0);
    // The contacts' summed stiffness and damping on this sphere, for the body's implicit update.
    float kSum = 0.0f, cSum = 0.0f;
    int3 c = gridCell(pi, u);
    float dt2 = u.dt * u.dt;
    for (int dz = -1; dz <= 1; ++dz) {
    for (int dy = -1; dy <= 1; ++dy) {
    for (int dx = -1; dx <= 1; ++dx) {
        int3 n = c + int3(dx, dy, dz);
        if (any(n < int3(0)) || any(n >= u.dims.xyz)) continue;
        uint j = heads[gridIndex(n, u)];
        for (int guard = 0; guard < 80 && j != 0xFFFFFFFFu; ++guard, j = next[j]) {
            uint bj = sphereBody[j];
            if (bj == bi) continue;
            float3 d = pi - world[j].xyz;
            float R = ri + world[j].w;
            float l2 = dot(d, d);
            if (l2 >= R * R || l2 < 1e-10f) continue;
            float l = sqrt(l2);
            float3 nrm = d / l;
            float pen = R - l;
            QuarryBody B = bodies[bj];
            float invMb = (B.state == 1u) ? B.posInvMass.w : 0.0f;
            float mEff = 1.0f / (invM + invMb);
            float k = u.kc * mEff / dt2;
            float3 rel = vi - velocity[j].xyz;
            float vn = dot(rel, nrm);
            float fn = k * pen - 2.0f * u.damping * sqrt(k * mEff) * vn;
            if (fn <= 0.0f) continue;
            float3 vt = rel - vn * nrm;
            float vtl = length(vt);
            float gamma = u.frictionGamma * sqrt(k * mEff);
            float ft = min(u.friction * fn, gamma * vtl);
            float3 F = fn * nrm - (vtl > 1e-5f ? ft * vt / vtl : float3(0));
            f += F;
            kSum += k;
            cSum += 2.0f * u.damping * sqrt(k * mEff) + gamma;
            float3 arm = (pi - nrm * ri) - apos;
            t += cross(arm, F);
            if (B.state == 2u && length_squared(rel) > u.wakeSpeed * u.wakeSpeed) {
                atomic_store_explicit(&wake[bj], 1u, memory_order_relaxed);
            }
        }
    }}}
    // Terrain.
    float h; float3 tn;
    terrainSample(pi.xy, heights, u, h, tn);
    float gap = (pi.z - h) * tn.z - ri;
    if (gap < 0.0f) {
        float pen = -gap;
        float mEff = 1.0f / invM;
        float k = u.kc * mEff / dt2;
        float vn = dot(vi, tn);
        float fn = k * pen - 2.0f * u.damping * sqrt(k * mEff) * vn;
        if (fn > 0.0f) {
            float3 vt = vi - vn * tn;
            float vtl = length(vt);
            float gamma = u.frictionGamma * sqrt(k * mEff);
            float ft = min(u.friction * fn, gamma * vtl);
            float3 F = fn * tn - (vtl > 1e-5f ? ft * vt / vtl : float3(0));
            f += F;
            kSum += k;
            cSum += 2.0f * u.damping * sqrt(k * mEff) + gamma;
            t += cross((pi - tn * ri) - apos, F);
        }
    }
    forceOut[i] = float4(f, kSum);
    torqueOut[i] = float4(t, cSum);
}

kernel void integrate(device QuarryBody *bodies [[buffer(0)]],
                      const device float4 *forceIn [[buffer(1)]],
                      const device float4 *torqueIn [[buffer(2)]],
                      device atomic_uint *wake [[buffer(3)]],
                      constant QuarryUniforms &u [[buffer(4)]],
                      device float4 *pose [[buffer(5)]],
                      uint b [[thread_position_in_grid]]) {
    QuarryBody B = bodies[b];
    float dt = u.dt;
    // The swell is dynamic: a block wakes when its swell begins and is pushed along it, so that
    // contact keeps swelling neighbours apart. (Moved kinematically while held, as before, blocks
    // whose swells converged ran deep into one another and burst apart when released.)
    float fire = B.invInertiaFire.w;
    float rise = B.swell.w;
    if (B.state == 0u) {
        if (rise <= 0.0f || u.time < fire - rise) { return; }
        B.state = 1u;
        B.velSleep = float4(0.0f);
    }
    // The swell's push this substep: the change of its velocity profile, eased.
    float3 swellPush = float3(0.0f);
    if (B.pad == 0u && rise > 0.0f) {
        float s1 = saturate((u.time - (fire - rise)) / rise);
        float s0 = saturate((u.time - dt - (fire - rise)) / rise);
        swellPush = B.swell.xyz * (s1 * s1 * (3.0f - 2.0f * s1) - s0 * s0 * (3.0f - 2.0f * s0));
    }
    if (B.pad == 0u && u.time >= fire) {
        // Let go: the launch, less the swell the block was given.
        B.pad = 1u;
        B.state = 1u;
        B.velSleep.xyz += B.launchSwell.xyz - B.swell.xyz;
        B.ang.xyz += B.spinRise.xyz;
    }
    if (B.state == 2u) {
        if (atomic_exchange_explicit(&wake[b], 0u, memory_order_relaxed) != 0u) {
            B.state = 1u;
            B.velSleep.w = 0.0f;
        } else {
            return;
        }
    }
    atomic_store_explicit(&wake[b], 0u, memory_order_relaxed);
    float3 F = float3(0, 0, -u.gravity / B.posInvMass.w), T = float3(0);
    float K = 0.0f, C = 0.0f;
    for (uint s = 0; s < B.count; ++s) {
        F += forceIn[B.first + s].xyz;
        T += torqueIn[B.first + s].xyz;
        K += forceIn[B.first + s].w;
        C += torqueIn[B.first + s].w;
    }
    // Linearly implicit in the body's own contacts: each contact's spring and dashpot is explicit
    // and stable alone, but a block of six spheres touches its neighbours at twenty to fifty
    // sphere pairs at once, and their sum is past the explicit limit: blocks at rest in the pile
    // rang at about a metre a second and crept. Backward Euler on the summed stiffness and
    // damping keeps them still, and leaves free flight (no contacts) as it was.
    float implicitShare = 1.0f / (1.0f + B.posInvMass.w * (dt * C + dt * dt * K));
    float3 v = B.velSleep.xyz + F * B.posInvMass.w * dt * implicitShare + swellPush;
    float3 w = B.ang.xyz;
    float3 wb = unrotate(B.quat, w);
    float3 tb = unrotate(B.quat, T);
    wb += B.invInertiaFire.xyz * tb * dt * implicitShare;
    w = rotate(B.quat, wb);
    // Explicit rotation is stiff for flat, thin blocks: keep them slower than they could spin.
    float spin = length(w);
    if (spin > 14.0f) w *= 14.0f / spin;
    // A touch of drag keeps flying blocks from spinning for ever.
    w *= 0.9992f;
    float speed = length(v);
    if (speed > 45.0f) { v *= 45.0f / speed; speed = 45.0f; }
    // A body held up by contact, moving slowly, is damped toward rest: explicit contact has no
    // static friction and creeps otherwise, and a clump of spheres has no rolling resistance (on
    // a ridge's flanks, rounded blocks rolled on at a metre a second, so its threshold is higher).
    float3 contact = F + float3(0, 0, u.gravity / B.posInvMass.w);
    float supported = length(contact) * B.posInvMass.w / u.gravity;
    if (supported > 0.35f && speed < u.creepSpeed) {
        float keep = exp(-dt * 14.0f);
        v *= keep;
        w *= keep;
    }
    float3 pos = B.posInvMass.xyz + v * dt;
    float4 q = B.quat;
    float4 omega = float4(w, 0.0f);
    float4 dq = 0.5f * float4(
        omega.w * q.x + omega.x * q.w + omega.y * q.z - omega.z * q.y,
        omega.w * q.y - omega.x * q.z + omega.y * q.w + omega.z * q.x,
        omega.w * q.z + omega.x * q.y - omega.y * q.x + omega.z * q.w,
        omega.w * q.w - omega.x * q.x - omega.y * q.y - omega.z * q.z);
    q = normalize(q + dq * dt);
    float sleep = B.velSleep.w;
    if (speed < u.sleepSpeed && length(w) < u.sleepSpin) sleep += dt; else sleep = 0.0f;
    if (B.pad == 0u) sleep = 0.0f;
    if (sleep > u.sleepTime) { B.state = 2u; v = float3(0); w = float3(0); sleep = 0.0f; }
    B.posInvMass.xyz = pos;
    B.quat = q;
    B.velSleep = float4(v, sleep);
    B.ang = float4(w, 0.0f);
    bodies[b] = B;
    pose[2 * b] = float4(pos, float(B.state));
    pose[2 * b + 1] = q;
}

