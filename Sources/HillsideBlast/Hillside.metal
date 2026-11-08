// The hillside experiment's shaders (docs/hillside-blast.md): compiled at run time from this file,
// which the target copies as a resource. Illustrative; not a blast-design aid.
#include <metal_stdlib>
using namespace metal;

struct HillsideBody {
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

struct HillsideUniforms {
    float dt, time, gravity, kc;
    float damping, friction, wakeSpeed, cell;
    float4 origin;
    int4 dims;
    float4 terrainOrigin;
    int4 terrainDims;
    float sleepSpeed, sleepSpin, sleepTime, frictionGamma;
    uint bodyCount, sphereCount, cellCount, pad;
};

static inline float3 rotate(float4 q, float3 v) {
    float3 t = 2.0f * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

static inline float3 unrotate(float4 q, float3 v) {
    float3 t = 2.0f * cross(-q.xyz, v);
    return v + q.w * t + cross(-q.xyz, t);
}

kernel void updateSpheres(const device HillsideBody *bodies [[buffer(0)]],
                          const device float4 *spheres [[buffer(1)]],
                          const device uint *sphereBody [[buffer(2)]],
                          device float4 *world [[buffer(3)]],
                          device float4 *velocity [[buffer(4)]],
                          uint i [[thread_position_in_grid]]) {
    const device HillsideBody &b = bodies[sphereBody[i]];
    float3 r = rotate(b.quat, spheres[i].xyz);
    world[i] = float4(b.posInvMass.xyz + r, spheres[i].w);
    velocity[i] = float4(b.velSleep.xyz + cross(b.ang.xyz, r), 0.0f);
}

kernel void clearGrid(device uint *heads [[buffer(0)]],
                      uint i [[thread_position_in_grid]]) {
    heads[i] = 0xFFFFFFFFu;
}

static inline int3 gridCell(float3 p, constant HillsideUniforms &u) {
    return clamp(int3(floor((p - u.origin.xyz) / u.cell)), int3(0), u.dims.xyz - 1);
}
static inline uint gridIndex(int3 c, constant HillsideUniforms &u) {
    return uint(c.x + u.dims.x * (c.y + u.dims.y * c.z));
}

kernel void insertSpheres(const device float4 *world [[buffer(0)]],
                          device atomic_uint *heads [[buffer(1)]],
                          device uint *next [[buffer(2)]],
                          constant HillsideUniforms &u [[buffer(3)]],
                          uint i [[thread_position_in_grid]]) {
    uint cell = gridIndex(gridCell(world[i].xyz, u), u);
    uint previous = atomic_exchange_explicit(&heads[cell], i, memory_order_relaxed);
    next[i] = previous;
}

static inline void terrainSample(float2 p, const device float *h, constant HillsideUniforms &u, thread float &height, thread float3 &normal) {
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

kernel void forces(const device HillsideBody *bodies [[buffer(0)]],
                   const device float4 *world [[buffer(1)]],
                   const device float4 *velocity [[buffer(2)]],
                   const device uint *sphereBody [[buffer(3)]],
                   const device uint *heads [[buffer(4)]],
                   const device uint *next [[buffer(5)]],
                   const device float *heights [[buffer(6)]],
                   constant HillsideUniforms &u [[buffer(7)]],
                   device float4 *forceOut [[buffer(8)]],
                   device float4 *torqueOut [[buffer(9)]],
                   device atomic_uint *wake [[buffer(10)]],
                   uint i [[thread_position_in_grid]]) {
    uint bi = sphereBody[i];
    HillsideBody A = bodies[bi];
    if (A.state != 1u) { forceOut[i] = float4(0); torqueOut[i] = float4(0); return; }
    float3 pi = world[i].xyz;
    float ri = world[i].w;
    float3 vi = velocity[i].xyz;
    float invM = A.posInvMass.w;
    float3 apos = A.posInvMass.xyz;
    float3 f = float3(0), t = float3(0);
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
            float pen = min(R - l, ri * 0.35f);
            HillsideBody B = bodies[bj];
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
            t += cross((pi - tn * ri) - apos, F);
        }
    }
    forceOut[i] = float4(f, 0);
    torqueOut[i] = float4(t, 0);
}

kernel void integrate(device HillsideBody *bodies [[buffer(0)]],
                      const device float4 *forceIn [[buffer(1)]],
                      const device float4 *torqueIn [[buffer(2)]],
                      device atomic_uint *wake [[buffer(3)]],
                      constant HillsideUniforms &u [[buffer(4)]],
                      device float4 *pose [[buffer(5)]],
                      uint b [[thread_position_in_grid]]) {
    HillsideBody B = bodies[b];
    float dt = u.dt;
    if (B.state == 0u) {
        float fire = B.invInertiaFire.w;
        float rise = B.swell.w;
        if (u.time < fire) {
            float s = rise > 0.0f ? (u.time - (fire - rise)) / rise : -1.0f;
            if (s > 0.0f) {
                float ease = s * s * (3.0f - 2.0f * s);
                float3 v = B.swell.xyz * ease;
                bodies[b].velSleep = float4(v, 0.0f);
                bodies[b].posInvMass.xyz += v * dt;
                pose[2 * b] = float4(bodies[b].posInvMass.xyz, 0.0f);
            }
            return;
        }
        B.state = 1u;
        B.velSleep = float4(B.launchSwell.xyz, 0.0f);
        B.ang = float4(B.spinRise.xyz, 0.0f);
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
    for (uint s = 0; s < B.count; ++s) {
        F += forceIn[B.first + s].xyz;
        T += torqueIn[B.first + s].xyz;
    }
    float3 v = B.velSleep.xyz + F * B.posInvMass.w * dt;
    float3 w = B.ang.xyz;
    float3 wb = unrotate(B.quat, w);
    float3 tb = unrotate(B.quat, T);
    wb += B.invInertiaFire.xyz * tb * dt;
    w = rotate(B.quat, wb);
    // Explicit rotation is stiff for flat, thin blocks: keep them slower than they could spin.
    float spin = length(w);
    if (spin > 14.0f) w *= 14.0f / spin;
    // A touch of drag keeps flying blocks from spinning for ever.
    w *= 0.9992f;
    float speed = length(v);
    if (speed > 45.0f) { v *= 45.0f / speed; speed = 45.0f; }
    // A body held up by contact, moving slowly, is damped toward rest: explicit contact has no
    // static friction and creeps otherwise.
    float3 contact = F + float3(0, 0, u.gravity / B.posInvMass.w);
    float supported = length(contact) * B.posInvMass.w / u.gravity;
    if (supported > 0.35f && speed < 0.6f) {
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
    if (sleep > u.sleepTime) { B.state = 2u; v = float3(0); w = float3(0); sleep = 0.0f; }
    B.posInvMass.xyz = pos;
    B.quat = q;
    B.velSleep = float4(v, sleep);
    B.ang = float4(w, 0.0f);
    bodies[b] = B;
    pose[2 * b] = float4(pos, float(B.state));
    pose[2 * b + 1] = q;
}

// --- Rendering ---

struct HillsideCamera {
    float4x4 viewProjection;
    float4x4 shadow;
    float4 eye;
    float4 sun;
    float4 fogColor;
    float4 terrainOrigin;
    float4x4 inverseViewProjection;
    float4 dustLow;
    float4 dustHigh;
    float4 misc;
};

struct HillsideBlockVertex {
    packed_float3 local;
    uint normalKind;
    uint body;
};

struct RasterOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 local;
    float bodyTint;
    uint kind [[flat]];
};

static inline float hash31(float3 p) {
    p = fract(p * 0.3183099f + 0.1f);
    p *= 17.0f;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
static inline float noise3(float3 x) {
    float3 i = floor(x); float3 f = fract(x);
    f = f * f * (3.0f - 2.0f * f);
    return mix(mix(mix(hash31(i + float3(0,0,0)), hash31(i + float3(1,0,0)), f.x),
                   mix(hash31(i + float3(0,1,0)), hash31(i + float3(1,1,0)), f.x), f.y),
               mix(mix(hash31(i + float3(0,0,1)), hash31(i + float3(1,0,1)), f.x),
                   mix(hash31(i + float3(0,1,1)), hash31(i + float3(1,1,1)), f.x), f.y), f.z);
}
static inline float fbm3(float3 p, int o) {
    float s = 0.0f, a = 0.5f;
    for (int i = 0; i < o; ++i) { s += a * noise3(p); p = p * 2.03f + 7.1f; a *= 0.5f; }
    return s;
}

static inline float3 unpackNormal(uint packed) {
    return float3(float((packed >> 0) & 1023u), float((packed >> 10) & 1023u), float((packed >> 20) & 1023u)) / 511.5f - 1.0f;
}

vertex RasterOut blockVertex(uint vid [[vertex_id]],
                             const device HillsideBlockVertex *vertices [[buffer(0)]],
                             const device float4 *pose [[buffer(1)]],
                             constant HillsideCamera &cam [[buffer(2)]],
                             const device float4 *rest [[buffer(3)]]) {
    HillsideBlockVertex v = vertices[vid];
    float3 pos = pose[2 * v.body].xyz;
    float4 q = pose[2 * v.body + 1];
    float3 local = float3(v.local);
    float3 w = pos + rotate(q, local);
    RasterOut o;
    o.position = cam.viewProjection * float4(w, 1.0f);
    o.world = w;
    o.normal = rotate(q, unpackNormal(v.normalKind));
    o.local = local + rest[v.body].xyz;
    o.bodyTint = fract(float(v.body) * 0.6180339f);
    o.kind = v.normalKind >> 30;
    return o;
}

vertex float4 blockShadowVertex(uint vid [[vertex_id]],
                                const device HillsideBlockVertex *vertices [[buffer(0)]],
                                const device float4 *pose [[buffer(1)]],
                                constant HillsideCamera &cam [[buffer(2)]]) {
    HillsideBlockVertex v = vertices[vid];
    float3 w = pose[2 * v.body].xyz + rotate(pose[2 * v.body + 1], float3(v.local));
    return cam.shadow * float4(w, 1.0f);
}

struct TerrainVertex { packed_float3 p; packed_float3 n; };
struct TerrainOut { float4 position [[position]]; float3 world; float3 normal; };

vertex TerrainOut terrainVertex(uint vid [[vertex_id]],
                                const device TerrainVertex *vertices [[buffer(0)]],
                                constant HillsideCamera &cam [[buffer(2)]]) {
    TerrainOut o;
    o.world = float3(vertices[vid].p);
    o.normal = float3(vertices[vid].n);
    o.position = cam.viewProjection * float4(o.world, 1.0f);
    return o;
}

vertex float4 terrainShadowVertex(uint vid [[vertex_id]],
                                  const device TerrainVertex *vertices [[buffer(0)]],
                                  constant HillsideCamera &cam [[buffer(2)]]) {
    return cam.shadow * float4(float3(vertices[vid].p), 1.0f);
}

static inline float shadowAt(float3 world, float3 normal, constant HillsideCamera &cam, depth2d<float> map, sampler s) {
    float3 w = world + normal * 0.25f;
    float4 c = cam.shadow * float4(w, 1.0f);
    float3 q = c.xyz / c.w;
    float2 uv = q.xy * float2(0.5f, -0.5f) + 0.5f;
    if (any(uv < 0.0f) || any(uv > 1.0f)) return 1.0f;
    float sum = 0.0f;
    float texel = 1.0f / float(map.get_width());
    for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
        sum += map.sample_compare(s, uv + float2(x, y) * texel, q.z - 0.0006f);
    }
    return sum / 9.0f;
}

static inline float3 skyColor(float3 dir, constant HillsideCamera &cam) {
    float h = saturate(dir.z * 2.6f + 0.02f);
    float3 horizon = float3(0.98f, 0.72f, 0.46f);
    float3 mid = float3(0.55f, 0.56f, 0.62f);
    float3 zenith = float3(0.16f, 0.27f, 0.47f);
    float3 base = mix(mix(horizon, mid, saturate(h * 2.2f)), zenith, saturate(h * 1.1f));
    float sunGlow = pow(saturate(dot(dir, cam.sun.xyz)), 18.0f);
    return base + float3(1.0f, 0.74f, 0.42f) * sunGlow * 0.8f;
}

static inline float dustShadow(float3 world, constant HillsideCamera &cam, texture3d<float> dustLight) {
    if (cam.dustHigh.w < 0.5f) return 1.0f;
    float3 uvw = (world - cam.dustLow.xyz) / (cam.dustHigh.xyz - cam.dustLow.xyz);
    if (any(uvw < 0.0f) || any(uvw > 1.0f)) return 1.0f;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return exp(-dustLight.sample(s, uvw).r * 0.045f);
}

static inline float3 shade(float3 albedo, float3 world, float3 n, constant HillsideCamera &cam, float shadow, float dust) {
    float3 sun = cam.sun.xyz;
    float nl = max(dot(n, sun), 0.0f);
    float3 sunColor = float3(1.0f, 0.74f, 0.47f) * 3.4f;
    float up = n.z * 0.5f + 0.5f;
    float3 skyLight = mix(float3(0.34f, 0.27f, 0.22f), float3(0.33f, 0.41f, 0.6f), up) * 0.55f;
    float3 bounce = float3(0.5f, 0.38f, 0.26f) * saturate(-n.z * 0.5f + 0.35f) * 0.18f;
    float3 lit = albedo * (sunColor * nl * shadow * dust + skyLight + bounce);
    float distance = length(world - cam.eye.xyz);
    float fog = 1.0f - exp(-distance * distance * 0.7e-6f);
    float3 dir = (world - cam.eye.xyz) / max(distance, 1.0f);
    return mix(lit, skyColor(float3(dir.x, dir.y, 0.03f), cam) * 0.95f, fog);
}

static inline float3 bumped(float3 n, float3 p, float scale, float strength, int octaves) {
    float e = 0.04f / scale * 3.0f;
    float h0 = fbm3(p * scale, octaves);
    float3 g = float3(fbm3((p + float3(e, 0, 0)) * scale, octaves) - h0,
                      fbm3((p + float3(0, e, 0)) * scale, octaves) - h0,
                      fbm3((p + float3(0, 0, e)) * scale, octaves) - h0) / e;
    return normalize(n - strength * (g - n * dot(g, n)));
}

fragment float4 blockFragment(RasterOut in [[stage_in]],
                              constant HillsideCamera &cam [[buffer(0)]],
                              depth2d<float> shadowMap [[texture(0)]],
                              texture3d<float> dustLight [[texture(1)]],
                              sampler s [[sampler(0)]]) {
    float3 n = normalize(in.normal);
    float3 rest = in.local;
    float warp = fbm3(rest * 0.07f, 3);
    float band = sin(rest.z * 1.5f + 9.0f * warp + rest.x * 0.12f) * 0.5f + 0.5f;
    float thin = sin(rest.z * 9.0f + 3.0f * fbm3(rest * 0.3f, 2)) * 0.5f + 0.5f;
    float detail = fbm3(rest * 4.0f, 4);
    float grain = fbm3(rest * 19.0f, 3);
    float tintShift = in.bodyTint - 0.5f;
    float3 layer = mix(float3(0.25f, 0.215f, 0.17f), float3(0.46f, 0.38f, 0.27f), band);
    layer *= 0.8f + 0.25f * thin;
    float3 albedo;
    if (in.kind == 1u) {
        float stain = fbm3(in.world * 0.2f, 3);
        float3 weathered = mix(float3(0.2f, 0.18f, 0.145f), float3(0.38f, 0.33f, 0.25f), detail);
        float lichen = smoothstep(0.5f, 0.72f, fbm3(rest * 1.3f + 40.0f, 4));
        albedo = mix(weathered, float3(0.26f, 0.29f, 0.13f) * (0.7f + 0.8f * grain), lichen * 0.3f);
        // Beds show on the weathered face as ledges of colour.
        float beds = smoothstep(0.25f, 0.75f, sin(in.world.z * 1.15f + 4.0f * fbm3(in.world * 0.05f, 3)) * 0.5f + 0.5f);
        albedo *= (0.86f + 0.2f * beds) * (0.75f + 0.6f * stain);
    } else if (in.kind == 2u) {
        albedo = float3(0.22f, 0.2f, 0.17f) * (0.7f + 0.6f * detail);
    } else {
        // Fresh breaks are paler than the weathered skin.
        albedo = (layer + float3(0.12f, 0.1f, 0.07f)) * (0.85f + 0.3f * tintShift) * (0.75f + 0.55f * detail);
    }
    albedo *= 0.82f + 0.36f * grain;
    float3 surface = in.kind == 1u ? bumped(n, rest, 1.6f, 0.7f, 4) : bumped(n, rest, 5.0f, 0.5f, 3);
    float shadow = shadowAt(in.world, n, cam, shadowMap, s);
    float dust = dustShadow(in.world, cam, dustLight);
    return float4(shade(albedo, in.world, surface, cam, shadow, dust), 1.0f);
}

fragment float4 terrainFragment(TerrainOut in [[stage_in]],
                                constant HillsideCamera &cam [[buffer(0)]],
                                depth2d<float> shadowMap [[texture(0)]],
                                texture3d<float> dustLight [[texture(1)]],
                                sampler s [[sampler(0)]]) {
    float3 n = normalize(in.normal);
    float slope = 1.0f - n.z;
    float detail = fbm3(in.world * float3(2.2f), 5);
    float fine = fbm3(in.world * float3(9.0f), 3);
    float broad = fbm3(in.world * 0.035f, 3);
    float pebbles = smoothstep(0.55f, 0.7f, fbm3(in.world * 3.7f + 11.0f, 3));
    float3 ground = mix(float3(0.15f, 0.13f, 0.10f), float3(0.34f, 0.29f, 0.22f), detail * 0.7f + fine * 0.3f);
    ground *= 0.55f + 0.95f * broad;
    ground *= 0.85f + 0.3f * smoothstep(0.35f, 0.7f, fbm3(in.world * 0.012f + 17.0f, 3));
    ground = mix(ground, ground * 1.35f + float3(0.03f), pebbles * 0.6f);
    float warp = fbm3(in.world * 0.07f, 3);
    float strata = sin(in.world.z * 1.5f + 9.0f * warp) * 0.5f + 0.5f;
    float3 rock = mix(float3(0.21f, 0.18f, 0.14f), float3(0.42f, 0.35f, 0.26f), detail) * (0.8f + 0.35f * strata);
    float crest = smoothstep(14.0f, 21.0f, in.world.z) * (1.0f - smoothstep(0.08f, 0.25f, slope));
    float3 scrub = mix(float3(0.13f, 0.13f, 0.07f), float3(0.3f, 0.26f, 0.13f), detail * 0.6f + broad * 0.4f);
    scrub = mix(scrub, float3(0.22f, 0.19f, 0.11f), smoothstep(0.45f, 0.7f, fbm3(in.world * 0.11f + 3.0f, 3)));
    float3 albedo = mix(ground, rock, smoothstep(0.12f, 0.45f, slope));
    albedo = mix(albedo, scrub, crest * smoothstep(0.32f, 0.5f, broad + 0.12f * fine));
    float fade = saturate(1.0f - length(in.world - cam.eye.xyz) / 600.0f);
    float3 surface = bumped(n, in.world, 1.4f, 0.28f * fade, 3);
    float shadow = shadowAt(in.world, n, cam, shadowMap, s);
    float dust = dustShadow(in.world, cam, dustLight);
    return float4(shade(albedo, in.world, surface, cam, shadow, dust), 1.0f);
}

// Decorative chips and gravel: instanced little polyhedra, not rigid bodies. Attached to their
// block until it has gone, then ballistic over the top-down height of the scene.
struct HillsideChip {
    float4 posSize;
    float4 velAge;
    float4 offsetDelay;
    uint parent;
    uint state;
    float seed;
    float tint;
};

struct HillsideChipUniforms {
    float dt;
    float gravity;
    float time;
    float pad;
    float4 low;
    float4 size;
};

kernel void chipUpdate(device HillsideChip *chips [[buffer(0)]],
                       const device float4 *pose [[buffer(1)]],
                       const device float4 *previous [[buffer(2)]],
                       depth2d<float> height [[texture(0)]],
                       constant HillsideChipUniforms &u [[buffer(3)]],
                       uint i [[thread_position_in_grid]]) {
    HillsideChip C = chips[i];
    if (C.state == 3u) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float dt = u.dt;
    if (C.state == 0u) {
        float4 p = pose[2 * C.parent];
        if (p.w < 0.5f) return;
        float age = C.velAge.w + dt;
        if (age < C.offsetDelay.w) { chips[i].velAge.w = age; return; }
        float3 pos = p.xyz + rotate(pose[2 * C.parent + 1], C.offsetDelay.xyz);
        float3 v = (p.xyz - previous[2 * C.parent].xyz) / dt;
        float3 jitter = float3(fract(C.seed * 13.7f), fract(C.seed * 29.3f), fract(C.seed * 7.1f)) * 2.0f - 1.0f;
        v = v * 0.75f + jitter * 2.5f + float3(0, -0.6f, 1.2f);
        C.posSize.xyz = pos;
        C.velAge = float4(v, age);
        C.state = 1u;
    }
    float r = C.posSize.w;
    for (int sub = 0; sub < 2; ++sub) {
        float sdt = dt * 0.5f;
        if (C.state == 1u) {
            float3 v = C.velAge.xyz;
            v.z -= u.gravity * sdt;
            v *= 0.997f;
            C.posSize.xyz += v * sdt;
            C.velAge.xyz = v;
        }
    }
    float2 uv = float2((C.posSize.x - u.low.x) / u.size.x, 1.0f - (C.posSize.y - u.low.y) / u.size.y);
    float h = u.size.z - height.sample(s, uv) * (u.size.z - u.size.w);
    if (C.state == 1u && C.posSize.z <= h + r * 0.6f) {
        C.posSize.z = h + r * 0.6f;
        C.state = 2u;
        C.velAge.xyz = float3(0);
    } else if (C.state == 2u) {
        if (C.posSize.z < h + r * 0.6f) C.posSize.z = h + r * 0.6f;
        else if (C.posSize.z > h + r * 0.6f + 0.8f) C.state = 1u;
    }
    chips[i] = C;
}

constant float3 icoCorners[12] = {
    float3(-0.526f, 0.851f, 0.0f), float3(0.526f, 0.851f, 0.0f), float3(-0.526f, -0.851f, 0.0f), float3(0.526f, -0.851f, 0.0f),
    float3(0.0f, -0.526f, 0.851f), float3(0.0f, 0.526f, 0.851f), float3(0.0f, -0.526f, -0.851f), float3(0.0f, 0.526f, -0.851f),
    float3(0.851f, 0.0f, -0.526f), float3(0.851f, 0.0f, 0.526f), float3(-0.851f, 0.0f, -0.526f), float3(-0.851f, 0.0f, 0.526f)
};
constant uint icoFaces[60] = {
    0,11,5, 0,5,1, 0,1,7, 0,7,10, 0,10,11, 1,5,9, 5,11,4, 11,10,2, 10,7,6, 7,1,8,
    3,9,4, 3,4,2, 3,2,6, 3,6,8, 3,8,9, 4,9,5, 2,4,11, 6,2,10, 8,6,7, 9,8,1
};

struct ChipOut {
    float4 position [[position]];
    float3 world;
    float tint;
    float seed;
};

static inline float4 chipPosition(HillsideChip c, uint vid, uint instance, constant HillsideCamera &cam, float4x4 m, thread float3 &world) {
    uint corner = icoFaces[vid % 60];
    float3 v = icoCorners[corner];
    float h = fract(c.seed * (float(corner) * 3.17f + 1.3f)) * 0.75f + 0.45f;
    float3 stretch = float3(1.0f + 0.7f * fract(c.seed * 91.0f), 1.0f + 0.5f * fract(c.seed * 53.0f), 0.55f + 0.5f * fract(c.seed * 37.0f));
    float size = c.state == 0u ? 0.0f : c.posSize.w;
    float angle = c.seed * 40.0f + c.velAge.w * 6.0f;
    float ca = cos(angle), sa = sin(angle);
    float3 p = v * h * stretch * size;
    p = float3(ca * p.x - sa * p.y, sa * p.x + ca * p.y, p.z);
    world = c.posSize.xyz + p;
    return m * float4(world, 1.0f);
}

vertex ChipOut chipVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                          const device HillsideChip *chips [[buffer(0)]],
                          constant HillsideCamera &cam [[buffer(2)]]) {
    HillsideChip c = chips[instance];
    ChipOut o;
    o.position = chipPosition(c, vid, instance, cam, cam.viewProjection, o.world);
    o.tint = c.tint;
    o.seed = c.seed;
    return o;
}

vertex float4 chipShadowVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                               const device HillsideChip *chips [[buffer(0)]],
                               constant HillsideCamera &cam [[buffer(2)]]) {
    HillsideChip c = chips[instance];
    float3 w;
    return chipPosition(c, vid, instance, cam, cam.shadow, w);
}

fragment float4 chipFragment(ChipOut in [[stage_in]],
                             constant HillsideCamera &cam [[buffer(0)]],
                             depth2d<float> shadowMap [[texture(0)]],
                             texture3d<float> dustLight [[texture(1)]],
                             sampler s [[sampler(0)]]) {
    float3 n = normalize(cross(dfdx(in.world), dfdy(in.world)));
    if (dot(n, cam.eye.xyz - in.world) < 0.0f) n = -n;
    float3 albedo;
    if (in.tint < 0.0f) {
        albedo = float3(0.08f, 0.1f, 0.05f) * (0.6f + 1.2f * fract(in.seed * 11.0f));
    } else {
        albedo = mix(float3(0.21f, 0.18f, 0.14f), float3(0.5f, 0.43f, 0.32f), in.tint) * (0.7f + 0.5f * fract(in.seed * 17.0f));
    }
    float shadow = shadowAt(in.world, n, cam, shadowMap, s);
    return float4(shade(albedo, in.world, n, cam, shadow, dustShadow(in.world, cam, dustLight)), 1.0f);
}

// Dust advection and shading come after the blocks.

struct FullscreenOut { float4 position [[position]]; float2 uv; };
vertex FullscreenOut fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2(float(vid == 1) * 4.0f - 1.0f, float(vid == 2) * 4.0f - 1.0f);
    FullscreenOut o;
    o.position = float4(p, 0.0f, 1.0f);
    o.uv = p * float2(0.5f, -0.5f) + 0.5f;
    return o;
}

static inline float3 aces(float3 x) {
    return clamp((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f), 0.0f, 1.0f);
}

// Screen-space ambient occlusion: multiplied into the frame before the dust goes on it.
static inline float3 aoWorld(float2 uv, depth2d<float> depth, constant HillsideCamera &cam) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float d = depth.sample(s, uv);
    float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
    float4 w = cam.inverseViewProjection * float4(ndc, d, 1.0f);
    return w.xyz / w.w;
}

fragment float4 aoFragment(FullscreenOut in [[stage_in]],
                           depth2d<float> depth [[texture(0)]],
                           constant HillsideCamera &cam [[buffer(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float z = depth.sample(s, in.uv);
    if (z >= 1.0f) return float4(1.0f);
    float2 size = float2(depth.get_width(), depth.get_height());
    float2 texel = 1.0f / size;
    float3 p = aoWorld(in.uv, depth, cam);
    float3 n = normalize(cross(aoWorld(in.uv + float2(texel.x, 0), depth, cam) - p, aoWorld(in.uv + float2(0, texel.y), depth, cam) - p));
    if (dot(n, cam.eye.xyz - p) < 0.0f) n = -n;
    float dist = length(cam.eye.xyz - p);
    float radiusWorld = 2.2f;
    float radiusPixels = radiusWorld * size.y * cam.misc.y / dist;
    float phase = fract(sin(dot(in.position.xy, float2(12.9898f, 78.233f))) * 43758.5453f) * 6.2832f;
    float occlusion = 0.0f;
    int samples = 18;
    for (int i = 0; i < samples; ++i) {
        float f = (float(i) + 0.5f) / float(samples);
        float angle = phase + f * 6.2832f * 5.0f;
        float2 offset = float2(cos(angle), sin(angle)) * sqrt(f) * radiusPixels * texel;
        float3 q = aoWorld(in.uv + offset, depth, cam);
        float3 v = q - p;
        float d = length(v);
        if (d > 0.05f && d < radiusWorld * 2.0f) {
            float h = dot(n, v / d);
            occlusion += max(0.0f, h - 0.12f) * (1.0f - smoothstep(radiusWorld * 0.5f, radiusWorld * 2.0f, d));
        }
    }
    float ao = 1.0f - occlusion / float(samples) * 1.9f;
    ao = clamp(ao, 0.25f, 1.0f);
    return float4(ao, ao, ao, 1.0f);
}

// Sky: a warm low gradient, distant hills in haze, drawn where nothing else is.
struct SkyOut { float4 position [[position]]; float2 ndc; };
vertex SkyOut skyVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float(vid == 1) * 4.0f - 1.0f, float(vid == 2) * 4.0f - 1.0f);
    SkyOut o;
    o.position = float4(p, 1.0f, 1.0f);
    o.ndc = p;
    return o;
}
fragment float4 skyFragment(SkyOut in [[stage_in]], constant HillsideCamera &cam [[buffer(0)]]) {
    float4 far = cam.inverseViewProjection * float4(in.ndc, 1.0f, 1.0f);
    float3 dir = normalize(far.xyz / far.w - cam.eye.xyz);
    float3 color = skyColor(dir, cam);
    float azimuth = atan2(dir.x, dir.y);
    float ridge = 0.045f + 0.03f * fbm3(float3(azimuth * 6.0f, 2.0f, 0.0f), 4) + 0.012f * fbm3(float3(azimuth * 25.0f, 5.0f, 0.0f), 3);
    float near = 0.02f + 0.05f * fbm3(float3(azimuth * 11.0f, 9.0f, 3.0f), 4);
    if (dir.z < ridge) color = mix(float3(0.46f, 0.44f, 0.47f), color, 0.55f);
    if (dir.z < near) color = mix(float3(0.34f, 0.3f, 0.31f), color, 0.4f);
    return float4(color, 1.0f);
}

fragment float4 tonemap(FullscreenOut in [[stage_in]],
                        texture2d<float> hdr [[texture(0)]],
                        sampler s [[sampler(0)]],
                        constant HillsideCamera &cam [[buffer(0)]]) {
    float3 c = hdr.sample(s, in.uv).rgb;
    c *= 0.62f;
    float2 centre = in.uv - 0.5f;
    float vignette = 1.0f - 0.42f * smoothstep(0.25f, 0.85f, length(centre * float2(1.15f, 1.0f)));
    c *= vignette;
    c = aces(c);
    c = pow(c, float3(1.0f / 2.2f));
    // A small warm grade, and shadows held a little cool.
    float luminance = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    c = mix(float3(luminance), c, 1.08f);
    c *= mix(float3(0.96f, 0.99f, 1.06f), float3(1.04f, 1.0f, 0.94f), smoothstep(0.1f, 0.75f, luminance));
    float grain = fract(sin(dot(in.position.xy + cam.misc.x * 37.0f, float2(12.9898f, 78.233f))) * 43758.5453f) - 0.5f;
    c += grain * 0.012f;
    return float4(c, 1.0f);
}
