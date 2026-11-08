// The hillside experiment's shaders (docs/hillside-blast.md): compiled at run time from this file,
// which the target copies as a resource. Illustrative; not a blast-design aid.
#include <metal_stdlib>
using namespace metal;

struct HillsideDustUniforms {
    float4 low;
    float4 hdtsteps; // h, dt
    int4 dims;
    float4 wind;
    float4 sun;
    float4 high;
};

constexpr sampler triSampler(filter::linear, address::clamp_to_edge, coord::normalized);

kernel void dustAddSources(texture3d<float, access::read> vIn [[texture(0)]],
                           texture3d<float, access::read> dIn [[texture(1)]],
                           texture3d<float, access::write> vOut [[texture(2)]],
                           texture3d<float, access::write> dOut [[texture(3)]],
                           const device float4 *source [[buffer(1)]],
                           constant HillsideDustUniforms &u [[buffer(0)]],
                           uint3 id [[thread_position_in_grid]]) {
    int n = int(id.x) + u.dims.x * (int(id.y) + u.dims.y * int(id.z));
    float4 s = source[n];
    float dust = dIn.read(id).r;
    float4 v = vIn.read(id);
    if (s.w > 0.0f) {
        dust = min(dust + s.w * u.hdtsteps.y, 40.0f);
        // Velocity toward the source's mean velocity, weighted by what was added.
        float blend = clamp(s.w * 0.25f, 0.0f, 0.95f);
        v.xyz = mix(v.xyz, s.xyz / s.w, blend);
    }
    vOut.write(v, id);
    dOut.write(float4(dust), id);
}

kernel void dustAdvectVelocity(texture3d<float, access::sample> vIn [[texture(0)]],
                               texture3d<float, access::write> vOut [[texture(1)]],
                               constant HillsideDustUniforms &u [[buffer(0)]],
                               uint3 id [[thread_position_in_grid]]) {
    float3 pos = float3(id) + 0.5f;
    float3 v = vIn.read(id).xyz;
    float3 size = float3(u.dims.xyz);
    float3 back = (pos - (v + u.wind.xyz) * u.hdtsteps.y / u.hdtsteps.x) / size;
    float3 s = vIn.sample(triSampler, back).xyz;
    vOut.write(float4(s * 0.995f, 0.0f), id);
}

kernel void dustForces(texture3d<float, access::read> vIn [[texture(0)]],
                       texture3d<float, access::read> dIn [[texture(1)]],
                       texture3d<float, access::write> vOut [[texture(2)]],
                       constant HillsideDustUniforms &u [[buffer(0)]],
                       uint3 id [[thread_position_in_grid]]) {
    int3 p = int3(id);
    float3 v = vIn.read(id).xyz;
    float dust = dIn.read(id).r;
    // Buoyancy of the warm dusty gas, and a touch of vorticity confinement.
    v.z += dust * 0.05f * u.hdtsteps.y;
    if (p.x > 0 && p.y > 0 && p.z > 0 && p.x < u.dims.x - 1 && p.y < u.dims.y - 1 && p.z < u.dims.z - 1) {
        float3 vx0 = vIn.read(uint3(p + int3(-1,0,0))).xyz, vx1 = vIn.read(uint3(p + int3(1,0,0))).xyz;
        float3 vy0 = vIn.read(uint3(p + int3(0,-1,0))).xyz, vy1 = vIn.read(uint3(p + int3(0,1,0))).xyz;
        float3 vz0 = vIn.read(uint3(p + int3(0,0,-1))).xyz, vz1 = vIn.read(uint3(p + int3(0,0,1))).xyz;
        float3 curl = float3((vy1.z - vy0.z) - (vz1.y - vz0.y), (vz1.x - vz0.x) - (vx1.z - vx0.z), (vx1.y - vx0.y) - (vy1.x - vy0.x));
        // A simplified confinement: keep the rotation alive where it is strong.
        float magnitude = length(curl);
        if (magnitude > 0.5f) {
            float3 w = normalize(curl);
            float3 n = normalize(float3(vy1.y - vy0.y, vz1.z - vz0.z, vx1.x - vx0.x) + float3(1e-4f));
            v += cross(n, w) * min(magnitude, 20.0f) * 1.1f * u.hdtsteps.y;
        }
    }
    vOut.write(float4(v, 0.0f), id);
}

kernel void dustDivergence(texture3d<float, access::read> vIn [[texture(0)]],
                           texture3d<float, access::read> sIn [[texture(1)]],
                           texture3d<float, access::write> dOut [[texture(2)]],
                           constant HillsideDustUniforms &u [[buffer(0)]],
                           uint3 id [[thread_position_in_grid]]) {
    int3 p = int3(id);
    int3 m = u.dims.xyz - 1;
    float l = vIn.read(uint3(clamp(p + int3(-1,0,0), int3(0), m))).x;
    float r = vIn.read(uint3(clamp(p + int3(1,0,0), int3(0), m))).x;
    float b = vIn.read(uint3(clamp(p + int3(0,-1,0), int3(0), m))).y;
    float t = vIn.read(uint3(clamp(p + int3(0,1,0), int3(0), m))).y;
    float d = vIn.read(uint3(clamp(p + int3(0,0,-1), int3(0), m))).z;
    float f = vIn.read(uint3(clamp(p + int3(0,0,1), int3(0), m))).z;
    dOut.write(float4(0.5f * ((r - l) + (t - b) + (f - d))), id);
}

kernel void dustJacobi(texture3d<float, access::read> pIn [[texture(0)]],
                       texture3d<float, access::read> dIn [[texture(1)]],
                       texture3d<float, access::read> sIn [[texture(2)]],
                       texture3d<float, access::write> pOut [[texture(3)]],
                       constant HillsideDustUniforms &u [[buffer(0)]],
                       uint3 id [[thread_position_in_grid]]) {
    int3 p = int3(id);
    int3 m = u.dims.xyz - 1;
    float c = pIn.read(id).r;
    float sum = 0.0f;
    int3 offsets[6] = {int3(-1,0,0), int3(1,0,0), int3(0,-1,0), int3(0,1,0), int3(0,0,-1), int3(0,0,1)};
    for (int i = 0; i < 6; ++i) {
        int3 q = p + offsets[i];
        if (any(q < int3(0)) || any(q > m)) { sum += 0.0f; continue; }
        sum += sIn.read(uint3(q)).r > 0.5f ? c : pIn.read(uint3(q)).r;
    }
    pOut.write(float4((sum - dIn.read(id).r) / 6.0f), id);
}

kernel void dustProject(texture3d<float, access::read> vIn [[texture(0)]],
                        texture3d<float, access::read> pIn [[texture(1)]],
                        texture3d<float, access::read> sIn [[texture(2)]],
                        texture3d<float, access::write> vOut [[texture(3)]],
                        constant HillsideDustUniforms &u [[buffer(0)]],
                        uint3 id [[thread_position_in_grid]]) {
    int3 p = int3(id);
    int3 m = u.dims.xyz - 1;
    if (sIn.read(id).r > 0.5f) { vOut.write(float4(0), id); return; }
    float c = pIn.read(id).r;
    float3 v = vIn.read(id).xyz;
    float l = pIn.read(uint3(clamp(p + int3(-1,0,0), int3(0), m))).r;
    float r = pIn.read(uint3(clamp(p + int3(1,0,0), int3(0), m))).r;
    float b = pIn.read(uint3(clamp(p + int3(0,-1,0), int3(0), m))).r;
    float t = pIn.read(uint3(clamp(p + int3(0,1,0), int3(0), m))).r;
    float d = pIn.read(uint3(clamp(p + int3(0,0,-1), int3(0), m))).r;
    float f = pIn.read(uint3(clamp(p + int3(0,0,1), int3(0), m))).r;
    if (sIn.read(uint3(clamp(p + int3(0,0,-1), int3(0), m))).r > 0.5f) d = c;
    v -= 0.5f * float3(r - l, t - b, f - d);
    vOut.write(float4(v, 0.0f), id);
}

kernel void dustAdvectDensity(texture3d<float, access::sample> dIn [[texture(0)]],
                              texture3d<float, access::sample> vIn [[texture(1)]],
                              texture3d<float, access::write> dOut [[texture(2)]],
                              texture3d<float, access::read> sIn [[texture(3)]],
                              constant HillsideDustUniforms &u [[buffer(0)]],
                              uint3 id [[thread_position_in_grid]]) {
    if (sIn.read(id).r > 0.5f) { dOut.write(float4(0), id); return; }
    float3 pos = float3(id) + 0.5f;
    float3 v = vIn.read(id).xyz;
    // Fines settle a little, and thin out.
    v += u.wind.xyz + float3(0.0f, 0.0f, -0.05f);
    float3 size = float3(u.dims.xyz);
    float3 back = (pos - v * u.hdtsteps.y / u.hdtsteps.x) / size;
    float d = dIn.sample(triSampler, back).r * 0.9992f;
    dOut.write(float4(d), id);
}

// MacCormack correction: the backward trace of the semi-Lagrangian result measures its error, and
// half of it goes back, clamped to the corners the trace landed among, so it cannot ring.
kernel void dustBackward(texture3d<float, access::sample> dIn [[texture(0)]],
                         texture3d<float, access::sample> vIn [[texture(1)]],
                         texture3d<float, access::write> dOut [[texture(2)]],
                         constant HillsideDustUniforms &u [[buffer(0)]],
                         uint3 id [[thread_position_in_grid]]) {
    float3 pos = float3(id) + 0.5f;
    float3 v = vIn.read(id).xyz + u.wind.xyz + float3(0.0f, 0.0f, -0.05f);
    float3 size = float3(u.dims.xyz);
    float3 forward = (pos + v * u.hdtsteps.y / u.hdtsteps.x) / size;
    dOut.write(dIn.sample(triSampler, forward), id);
}

kernel void dustCorrect(texture3d<float, access::sample> d0 [[texture(0)]],
                        texture3d<float, access::sample> dSemi [[texture(1)]],
                        texture3d<float, access::sample> dBack [[texture(2)]],
                        texture3d<float, access::sample> vIn [[texture(3)]],
                        texture3d<float, access::read> sIn [[texture(4)]],
                        texture3d<float, access::write> dOut [[texture(5)]],
                        constant HillsideDustUniforms &u [[buffer(0)]],
                        uint3 id [[thread_position_in_grid]]) {
    if (sIn.read(id).r > 0.5f) { dOut.write(float4(0), id); return; }
    float3 pos = float3(id) + 0.5f;
    float3 v = vIn.read(id).xyz + u.wind.xyz + float3(0.0f, 0.0f, -0.05f);
    float3 size = float3(u.dims.xyz);
    float3 back = (pos - v * u.hdtsteps.y / u.hdtsteps.x) / size;
    float semi = dSemi.read(id).r;
    float original = d0.read(id).r;
    float corrected = semi + 0.5f * (original - dBack.read(id).r);
    float3 c = floor(back * size - 0.5f) ;
    float lo = semi, hi = semi;
    for (int z = 0; z < 2; ++z) for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) {
        float3 p = (c + float3(x, y, z) + 0.5f) / size;
        float value = d0.sample(triSampler, p).r;
        lo = min(lo, value);
        hi = max(hi, value);
    }
    dOut.write(float4(clamp(corrected, lo, hi) * 0.9992f), id);
}

// A tileable noise volume for shaping the cloud: inverted Worley at three frequencies.
static inline float worley(float3 p, float period) {
    float3 cell = floor(p);
    float3 f = fract(p);
    float best = 8.0f;
    for (int z = -1; z <= 1; ++z) for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
        float3 g = float3(x, y, z);
        float3 q = fmod(cell + g + period, period);
        float3 h = fract(sin(float3(dot(q, float3(127.1f, 311.7f, 74.7f)), dot(q, float3(269.5f, 183.3f, 246.1f)), dot(q, float3(113.5f, 271.9f, 124.6f)))) * 43758.5453f);
        float3 d = g + h - f;
        best = min(best, dot(d, d));
    }
    return 1.0f - sqrt(best);
}

kernel void dustBakeNoise(texture3d<float, access::write> out [[texture(0)]],
                          uint3 id [[thread_position_in_grid]]) {
    float3 p = float3(id) / float(out.get_width());
    float a = 0.625f * worley(p * 8.0f, 8.0f) + 0.25f * worley(p * 16.0f, 16.0f) + 0.125f * worley(p * 32.0f, 32.0f);
    float b = 0.625f * worley(p * 24.0f, 24.0f) + 0.25f * worley(p * 48.0f, 48.0f) + 0.125f * worley(p * 64.0f, 64.0f);
    out.write(float4(a, b, 0.0f, 0.0f), id);
}

kernel void dustLight(texture3d<float, access::sample> dIn [[texture(0)]],
                      texture3d<float, access::write> lOut [[texture(1)]],
                      constant HillsideDustUniforms &u [[buffer(0)]],
                      uint3 id [[thread_position_in_grid]]) {
    float3 pos = (float3(id) + 0.5f) / float3(u.dims.xyz);
    float3 direction = u.sun.xyz / float3(u.dims.xyz) * 1.6f;
    float tau = 0.0f;
    for (int i = 0; i < 28; ++i) {
        pos += direction;
        if (any(pos < 0.0f) || any(pos > 1.0f)) break;
        tau += max(dIn.sample(triSampler, pos).r - 0.6f, 0.0f);
    }
    lOut.write(float4(tau * u.hdtsteps.x * 1.6f), id);
}

struct FullscreenOut { float4 position [[position]]; float2 uv; };
vertex FullscreenOut fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2(float(vid == 1) * 4.0f - 1.0f, float(vid == 2) * 4.0f - 1.0f);
    FullscreenOut o;
    o.position = float4(p, 0.0f, 1.0f);
    o.uv = p * float2(0.5f, -0.5f) + 0.5f;
    return o;
}

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

static inline float hash31d(float3 p) {
    p = fract(p * 0.3183099f + 0.1f);
    p *= 17.0f;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
static inline float noiseV(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3.0f - 2.0f * f);
    return mix(mix(mix(hash31d(i), hash31d(i + float3(1,0,0)), f.x),
                   mix(hash31d(i + float3(0,1,0)), hash31d(i + float3(1,1,0)), f.x), f.y),
               mix(mix(hash31d(i + float3(0,0,1)), hash31d(i + float3(1,0,1)), f.x),
                   mix(hash31d(i + float3(0,1,1)), hash31d(i + float3(1,1,1)), f.x), f.y), f.z);
}
static inline float noiseFbm(float3 p) {
    return 0.55f * noiseV(p) + 0.3f * noiseV(p * 2.07f + 5.3f) + 0.15f * noiseV(p * 4.3f + 11.1f);
}

fragment float4 dustFragment(FullscreenOut in [[stage_in]],
                             texture3d<float, access::sample> density [[texture(0)]],
                             texture3d<float, access::sample> light [[texture(1)]],
                             depth2d<float, access::sample> depth [[texture(2)]],
                             texture3d<float, access::sample> noise [[texture(3)]],
                             constant HillsideCamera &cam [[buffer(0)]],
                             constant HillsideDustUniforms &u [[buffer(1)]]) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    constexpr sampler wrap(filter::linear, address::repeat);
    float z = depth.sample(nearest, in.uv);
    float2 ndc = float2(in.uv.x * 2.0f - 1.0f, 1.0f - in.uv.y * 2.0f);
    float4 far = cam.inverseViewProjection * float4(ndc, z, 1.0f);
    float3 hit = far.xyz / far.w;
    float3 eye = cam.eye.xyz;
    float maxT = length(hit - eye);
    float3 dir = (hit - eye) / max(maxT, 1e-3f);
    float3 low = u.low.xyz, high = u.high.xyz;
    float3 t0 = (low - eye) / dir, t1 = (high - eye) / dir;
    float3 tmin = min(t0, t1), tmax = max(t0, t1);
    float enter = max(max(tmin.x, tmin.y), max(tmin.z, 0.0f));
    float leave = min(min(tmax.x, tmax.y), min(tmax.z, maxT));
    if (leave <= enter) return float4(0);
    float h = u.hdtsteps.x;
    float jitter = fract(sin(dot(in.position.xy, float2(12.9898f, 78.233f))) * 43758.5453f);
    float coarse = 2.0f;
    float fine = h * 0.6f;
    float t = enter + coarse * jitter;
    float3 size = float3(u.dims.xyz) * h;
    float3 accumulated = float3(0.0f);
    float transmittance = 1.0f;
    float3 albedo = float3(0.5f, 0.41f, 0.31f);
    float mu = dot(dir, cam.sun.xyz);
    float g = 0.45f;
    float hgForward = (1.0f - g * g) / pow(1.0f + g * g - 2.0f * g * mu, 1.5f) * 0.25f;
    float g2 = -0.15f;
    float hgBack = (1.0f - g2 * g2) / pow(1.0f + g2 * g2 - 2.0f * g2 * mu, 1.5f) * 0.25f;
    float phase = 0.75f * hgForward + 0.45f * hgBack;
    float3 sunColor = float3(1.0f, 0.72f, 0.46f) * 5.2f;
    float3 ambientUp = float3(0.42f, 0.5f, 0.68f) * 0.42f;
    float3 ambientDown = float3(0.3f, 0.23f, 0.17f) * 0.3f;
    int quiet = 0;
    bool stepping = false;
    float tt = cam.misc.x;
    for (int steps = 0; steps < 900 && t < leave; ++steps) {
        float step = stepping ? fine : coarse;
        float3 world = eye + dir * t;
        float3 p = (world - low) / size;
        float d = density.sample(triSampler, p).r;
        float shaped = 0.0f;
        if (d > 0.004f) {
            if (!stepping) { stepping = true; t = max(enter, t - coarse * 0.9f); quiet = 0; continue; }
            float dn = 1.0f - exp(-d * 0.42f);
            // Warp the lookup by a few metres so the field's own smooth shape breaks up, then cut
            // the lumps with the noise, more where the field is thin.
            float3 warpSample = noise.sample(wrap, world * 0.05f + float3(0.012f * tt, 0.0f, -0.02f * tt)).rgb;
            float3 warped = (world + (warpSample * 2.0f - 1.0f) * float3(5.5f, 5.5f, 6.5f) - low) / size;
            float dw = density.sample(triSampler, warped).r;
            dn = 1.0f - exp(-dw * 0.42f);
            float3 q = world * 0.022f + float3(0.0085f * tt, -0.004f * tt, -0.018f * tt);
            float big = noise.sample(wrap, q).r;
            float3 q2 = world * 0.05f + float3(-0.012f * tt, 0.02f * tt, 0.007f * tt);
            float small = noise.sample(wrap, q2).g;
            float e1 = (1.0f - big) * mix(0.95f, 0.5f, dn);
            shaped = saturate((dn - e1) / max(1.0f - e1, 0.08f));
            float e2 = (1.0f - small) * (1.0f - shaped * 0.7f) * 0.62f;
            shaped = saturate((shaped - e2) / max(1.0f - e2, 0.08f));
        } else if (stepping) {
            if (++quiet > 3) stepping = false;
        }
        if (shaped > 0.001f) {
            quiet = 0;
            float sigma = shaped * (d * 0.12f + 0.55f);
            float a = 1.0f - exp(-sigma * step);
            float tau = light.sample(triSampler, p).r * 0.11f;
            float direct = exp(-tau) + 0.22f * exp(-tau * 0.3f);
            float heightFrac = saturate(p.z * 2.0f);
            float3 ambient = mix(ambientDown, ambientUp, heightFrac) * (0.45f + 0.55f * exp(-tau * 0.4f));
            float3 lit = albedo * (sunColor * phase * direct + ambient);
            accumulated += transmittance * a * lit;
            transmittance *= 1.0f - a;
            if (transmittance < 0.01f) break;
        }
        t += step;
    }
    return float4(accumulated, 1.0f - transmittance);
}

fragment float4 dustComposite(FullscreenOut in [[stage_in]],
                              texture2d<float> dust [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    return dust.sample(s, in.uv);
}
