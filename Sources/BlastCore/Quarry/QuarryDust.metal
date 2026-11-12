// The quarry face's passive dust field (docs/hillside-blast.md), compiled on its own at run time.
// Illustrative: for the look of a face being blasted; not a blast-design aid.
#include <metal_stdlib>
using namespace metal;

struct QuarryDustUniforms {
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
                           const device float *heatSource [[buffer(2)]],
                           constant QuarryDustUniforms &u [[buffer(0)]],
                           uint3 id [[thread_position_in_grid]]) {
    int n = int(id.x) + u.dims.x * (int(id.y) + u.dims.y * int(id.z));
    float4 s = source[n];
    float dust = dIn.read(id).r;
    float4 v = vIn.read(id);
    if (s.w > 0.0f) {
        float added = s.w * u.hdtsteps.y;
        // New dust carries the velocity and heat it was born with, as its share of the cell.
        float blend = clamp(added / (dust + added + 1e-3f), 0.0f, 0.92f);
        v.xyz = mix(v.xyz, s.xyz / s.w, blend);
        v.w = mix(v.w, heatSource[n] / s.w, blend);
        dust = min(dust + added, 40.0f);
    }
    vOut.write(v, id);
    dOut.write(float4(dust), id);
}

kernel void dustAdvectVelocity(texture3d<float, access::sample> vIn [[texture(0)]],
                               texture3d<float, access::write> vOut [[texture(1)]],
                               constant QuarryDustUniforms &u [[buffer(0)]],
                               uint3 id [[thread_position_in_grid]]) {
    float3 pos = float3(id) + 0.5f;
    float3 v = vIn.read(id).xyz;
    float3 size = float3(u.dims.xyz);
    float3 back = (pos - (v + u.wind.xyz) * u.hdtsteps.y / u.hdtsteps.x) / size;
    float3 s = vIn.sample(triSampler, back).xyz;
    float4 carried = vIn.sample(triSampler, back);
    // Heat cools with an e-folding time of about three seconds.
    vOut.write(float4(s * 0.995f, carried.w * exp(-u.hdtsteps.y / 1.6f)), id);
}

kernel void dustForces(texture3d<float, access::read> vIn [[texture(0)]],
                       texture3d<float, access::read> dIn [[texture(1)]],
                       texture3d<float, access::write> vOut [[texture(2)]],
                       constant QuarryDustUniforms &u [[buffer(0)]],
                       uint3 id [[thread_position_in_grid]]) {
    int3 p = int3(id);
    float3 v = vIn.read(id).xyz;
    float dust = dIn.read(id).r;
    // Buoyancy of the warm dusty gas, and a touch of vorticity confinement.
    // Hot, dusty gas rises; cold dust only drifts.
    float heat = vIn.read(id).w;
    v.z += (heat * 3.2f + min(dust, 4.0f) * 0.01f) * u.hdtsteps.y;
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
    vOut.write(float4(v, vIn.read(id).w), id);
}

kernel void dustDivergence(texture3d<float, access::read> vIn [[texture(0)]],
                           texture3d<float, access::read> sIn [[texture(1)]],
                           texture3d<float, access::write> dOut [[texture(2)]],
                           constant QuarryDustUniforms &u [[buffer(0)]],
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
                       constant QuarryDustUniforms &u [[buffer(0)]],
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
                        constant QuarryDustUniforms &u [[buffer(0)]],
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
    vOut.write(float4(v, vIn.read(id).w), id);
}

kernel void dustAdvectDensity(texture3d<float, access::sample> dIn [[texture(0)]],
                              texture3d<float, access::sample> vIn [[texture(1)]],
                              texture3d<float, access::write> dOut [[texture(2)]],
                              texture3d<float, access::read> sIn [[texture(3)]],
                              constant QuarryDustUniforms &u [[buffer(0)]],
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
                         constant QuarryDustUniforms &u [[buffer(0)]],
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
                        texture3d<float, access::read> clearance [[texture(6)]],
                        constant QuarryDustUniforms &u [[buffer(0)]],
                        uint3 id [[thread_position_in_grid]]) {
    if (sIn.read(id).r > 0.5f) { dOut.write(float4(0), id); return; }
    // Cold dust low over the ground and the pile falls out: within a few metres of the ground it
    // thins in about two seconds, so what the impacts throw up comes down again rather than
    // lying in a flat sheet. Warm dust rises first; the plumes high up are left alone.
    float above = clearance.read(id).r * 12.75f;
    float cold = 1.0f - smoothstep(0.04f, 0.3f, vIn.read(id).w);
    float deposit = exp(-u.hdtsteps.y * 0.55f * cold * (1.0f - smoothstep(3.0f, 9.0f, above)));
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
    dOut.write(float4(clamp(corrected, lo, hi) * 0.9992f * deposit), id);
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
                      constant QuarryDustUniforms &u [[buffer(0)]],
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

