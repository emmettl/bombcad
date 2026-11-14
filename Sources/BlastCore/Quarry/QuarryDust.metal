// The quarry face's passive dust field (docs/hillside-blast.md), compiled on its own at run time.
// Illustrative: for the look of a face being blasted; not a blast-design aid.
#include <metal_stdlib>
using namespace metal;

struct QuarryDustUniforms {
    float4 low; // w: the fines' thinning high up, a share a second
    float4 hdtsteps; // h, dt, what velocity and density keep a step
    int4 dims; // w: a face's bench top over the box's floor (m), 0 for a ridge cut
    float4 wind; // xyz: the wind at height; w: the fines' thinning near the ground
    float4 sun; // w: the share of thin dust the renderer's march draws as haze
    float4 high; // w: the event's time
    float4 shape; // x the carry aloft's base over the box's floor, y its share of the wind, z a ridge's low settling, w last firing (stage 3r)
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

// The flow and the dust's thinning, one set of kernels for both scenes since stage 3l
// (emmettl/bombcad-work#146; a ridge cut's own copies from stage 3k, emmettl/bombcad-work#145,
// the face's older ones retired): one plume that drifts and lingers.
// - The wind is in the flow itself (`windAt`), stronger with height over the ground, so it goes
//   over and round the ground rather than through it, and the flow relaxes to it rather than to
//   rest. Gusts from the baked noise (carried with the wind, divergence taken out by the pressure
//   solve) make it a little turbulent.
// - Dust thins mostly while it is thick: its coarse part falls out within seconds, its fines stay
//   for tens of seconds, so the cloud thins, spreads and settles rather than vanishing.
// - Dust near the box's sides fades, so a drifting plume never ends on a box face in view.
// Per scene: `u.wind.xyz` is the wind at height (across each scene's opening view); `u.low.w` and
// `u.wind.w` the fines' thinning high up and near the ground; `u.high.w` the event's time.

// A face's coarse fall-out against a ridge cut's, and its cold dust's settling a second in the
// trench below the bench's top (stage 3l).
constant float faceCoarse = 0.25f;
constant float faceSettle = 0.4f;

static inline float3 windAt(constant QuarryDustUniforms &u, float above) {
    // A light wind that rises from about a third of its strength at the ground to all of it 12 m
    // up (the clearance's reach).
    return u.wind.xyz * (0.35f + 0.65f * smoothstep(0.0f, 12.0f, above));
}

// The wind's carry aloft (stage 3r, emmettl/bombcad-work#152): the dust is carried on downwind,
// outside the flow, by `shape.y` of the wind, from none 4 m under the crest's or the bench's height
// (`shape.x` over the box's floor) to all of it 16 m over it, for a cell `z` metres over the box's
// floor. In the flow itself a wind three times as strong hardly moved the plume: the buoyant
// column's own inflow and spread, which the pressure solve keeps, outweigh a light wind round it,
// so the plume rose nearly straight. Carried outside the flow (as the face's dust drifted along the
// strip before stage 3l), the plume leans more the higher it rises. The renderer's billows ride the
// same carry.
static inline float3 carryAt(constant QuarryDustUniforms &u, float z) {
    return u.wind.xyz * u.shape.y * smoothstep(-4.0f, 16.0f, z - u.shape.x);
}

kernel void dustWindStart(texture3d<float, access::write> vOut [[texture(0)]],
                          texture3d<float, access::read> clearance [[texture(1)]],
                          texture3d<float, access::read> sIn [[texture(2)]],
                          constant QuarryDustUniforms &u [[buffer(0)]],
                          uint3 id [[thread_position_in_grid]]) {
    float3 v = sIn.read(id).r > 0.5f ? float3(0.0f) : windAt(u, clearance.read(id).r * 12.75f);
    vOut.write(float4(v, 0.0f), id);
}

kernel void dustAdvectVelocity(texture3d<float, access::sample> vIn [[texture(0)]],
                                    texture3d<float, access::write> vOut [[texture(1)]],
                                    texture3d<float, access::read> clearance [[texture(2)]],
                                    constant QuarryDustUniforms &u [[buffer(0)]],
                                    uint3 id [[thread_position_in_grid]]) {
    float3 pos = float3(id) + 0.5f;
    float3 v = vIn.read(id).xyz;
    float3 size = float3(u.dims.xyz);
    float3 back = (pos - v * u.hdtsteps.y / u.hdtsteps.x) / size;
    float4 carried = vIn.sample(triSampler, back);
    // The flow relaxes to the wind, as the face's relaxes to rest; across, clear of the ground,
    // faster (by 0.5 a second more, as the plume takes in the air round it), so
    // the plume leans and drifts with the wind within a few seconds of rising.
    float above = clearance.read(id).r * 12.75f;
    float3 wind = windAt(u, above);
    float across = u.hdtsteps.z * exp(-u.hdtsteps.y * 0.5f * smoothstep(4.0f, 12.0f, above));
    float3 s = wind + (carried.xyz - wind) * float3(across, across, u.hdtsteps.z);
    vOut.write(float4(s, carried.w * exp(-u.hdtsteps.y / 1.6f)), id);
}

kernel void dustForces(texture3d<float, access::read> vIn [[texture(0)]],
                            texture3d<float, access::read> dIn [[texture(1)]],
                            texture3d<float, access::write> vOut [[texture(2)]],
                            texture3d<float, access::sample> noise [[texture(3)]],
                            texture3d<float, access::read> clearance [[texture(4)]],
                            constant QuarryDustUniforms &u [[buffer(0)]],
                            uint3 id [[thread_position_in_grid]]) {
    int3 p = int3(id);
    float3 v = vIn.read(id).xyz;
    float dust = dIn.read(id).r;
    float heat = vIn.read(id).w;
    v.z += (heat * 3.2f + min(dust, 4.0f) * 0.01f) * u.hdtsteps.y;
    if (p.x > 0 && p.y > 0 && p.z > 0 && p.x < u.dims.x - 1 && p.y < u.dims.y - 1 && p.z < u.dims.z - 1) {
        float3 vx0 = vIn.read(uint3(p + int3(-1,0,0))).xyz, vx1 = vIn.read(uint3(p + int3(1,0,0))).xyz;
        float3 vy0 = vIn.read(uint3(p + int3(0,-1,0))).xyz, vy1 = vIn.read(uint3(p + int3(0,1,0))).xyz;
        float3 vz0 = vIn.read(uint3(p + int3(0,0,-1))).xyz, vz1 = vIn.read(uint3(p + int3(0,0,1))).xyz;
        float3 curl = float3((vy1.z - vy0.z) - (vz1.y - vz0.y), (vz1.x - vz0.x) - (vx1.z - vx0.z), (vx1.y - vx0.y) - (vy1.x - vy0.x));
        float magnitude = length(curl);
        if (magnitude > 0.5f) {
            float3 w = normalize(curl);
            float3 n = normalize(float3(vy1.y - vy0.y, vz1.z - vz0.z, vx1.x - vx0.x) + float3(1e-4f));
            v += cross(n, w) * min(magnitude, 20.0f) * 1.1f * u.hdtsteps.y;
        }
    }
    // Gusts: the baked noise (features of about 16 m and 8 m here) carried with the wind and
    // turning slowly, pushing the flow about; the pressure solve keeps only its swirl. Stronger
    // with height, as the wind is.
    float3 world = u.low.xyz + (float3(id) + 0.5f) * u.hdtsteps.x;
    float above = clearance.read(id).r * 12.75f;
    float time = u.high.w;
    constexpr sampler gustSampler(filter::linear, mip_filter::linear, address::repeat);
    float3 q = (world - u.wind.xyz * time) / 128.0f + float3(0.0f, 0.0f, 0.004f * time);
    float2 g1 = noise.sample(gustSampler, q, level(2.0f)).rg;
    float2 g2 = noise.sample(gustSampler, q * float3(1.0f, -1.0f, 1.0f) + float3(0.31f, 0.57f, 0.13f), level(2.0f)).rg;
    float3 gust = (float3(g1.x, g2.x, 0.5f * (g1.y + g2.y)) - 0.55f) * float3(1.0f, 1.0f, 0.6f);
    v += gust * 0.6f * (0.4f + 0.6f * smoothstep(0.0f, 12.0f, above)) * u.hdtsteps.y;
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
    float3 v = vIn.read(id).xyz + float3(0.0f, 0.0f, -0.05f) + carryAt(u, pos.z * u.hdtsteps.x);
    float3 size = float3(u.dims.xyz);
    float3 back = (pos - v * u.hdtsteps.y / u.hdtsteps.x) / size;
    dOut.write(float4(dIn.sample(triSampler, back).r * u.hdtsteps.w), id);
}

kernel void dustBackward(texture3d<float, access::sample> dIn [[texture(0)]],
                              texture3d<float, access::sample> vIn [[texture(1)]],
                              texture3d<float, access::write> dOut [[texture(2)]],
                              constant QuarryDustUniforms &u [[buffer(0)]],
                              uint3 id [[thread_position_in_grid]]) {
    float3 pos = float3(id) + 0.5f;
    float3 v = vIn.read(id).xyz + float3(0.0f, 0.0f, -0.05f) + carryAt(u, pos.z * u.hdtsteps.x);
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
    float above = clearance.read(id).r * 12.75f;
    float3 pos = float3(id) + 0.5f;
    float3 v = vIn.read(id).xyz + float3(0.0f, 0.0f, -0.05f) + carryAt(u, pos.z * u.hdtsteps.x);
    float3 size = float3(u.dims.xyz);
    float3 back = (pos - v * u.hdtsteps.y / u.hdtsteps.x) / size;
    float semi = dSemi.read(id).r;
    float original = d0.read(id).r;
    float corrected = semi + 0.5f * (original - dBack.read(id).r);
    float3 c = floor(back * size - 0.5f);
    float lo = semi, hi = semi;
    for (int z = 0; z < 2; ++z) for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) {
        float3 q = (c + float3(x, y, z) + 0.5f) / size;
        float value = d0.sample(triSampler, q).r;
        lo = min(lo, value);
        hi = max(hi, value);
    }
    float kept = clamp(corrected, lo, hi);
    // The coarse part falls out while the dust is thick, fastest near the ground and where it is
    // cold; the fines thin slowly, so a thick puff drops within a few seconds to a haze that
    // lingers, drifts and settles.
    float near = 1.0f - smoothstep(3.0f, 10.0f, above);
    float cold = 1.0f - smoothstep(0.04f, 0.3f, vIn.read(id).w);
    float coarse = smoothstep(0.8f, 3.5f, kept) * (0.45f + 0.45f * near * cold);
    if (u.dims.w > 0) {
        // A face's (`dims.w`, its bench top over the box's floor, is set; stage 3l): its coarse
        // dust falls out more slowly, so the cloud that rose over the bench stands and drifts for
        // longer; but cold dust below the bench's top, in the trench the rock has left, settles,
        // so it does not lie as a flat veil over the new face.
        float bench = float(u.dims.w);
        float z = (float(id.z) + 0.5f) * u.hdtsteps.x;
        coarse = coarse * faceCoarse + faceSettle * cold * (1.0f - smoothstep(0.6f * bench, bench, z));
    } else {
        // A ridge cut's (stage 3r, emmettl/bombcad-work#152): once the firings are done, cold dust
        // low over the cut (up to 6 m over the crest, fading out by 16 m) settles, so the haze
        // left over the crest and the heap clears from about 6 s; the plume above drifts on.
        float z = (float(id.z) + 0.5f) * u.hdtsteps.x;
        float done = smoothstep(u.shape.w + 1.0f, u.shape.w + 2.5f, u.high.w);
        coarse += u.shape.z * done * cold * (1.0f - smoothstep(u.shape.x + 6.0f, u.shape.x + 16.0f, z));
    }
    float fines = mix(u.low.w, u.wind.w, near);
    // Toward the box's sides (not its top or floor) the dust fades over its last 8 m, so it
    // leaves the box as it thins rather than ending on a face.
    float3 edge = min(pos, size - pos) * u.hdtsteps.x;
    float side = 1.0f - smoothstep(0.0f, 8.0f, min(edge.x, edge.y));
    kept *= u.hdtsteps.w * exp(-u.hdtsteps.y * (coarse + fines + 1.5f * side));
    dOut.write(float4(kept), id);
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


// The most dust within `hazeReach` cells of each cell (stage 3l, emmettl/bombcad-work#146), for
// the march: where it is under the least dust the cuts of its noise would keep anything of at a
// step, no lookup its warp can make there would be kept, so the warp is skipped and the dust drawn
// as haze. Haze that has spread was looked up through the warp at every fine step (stage 3k), at
// most of the cost of a frame after the firings. A box filter of maxima, one axis a pass
// (`spread.xyz` the axis, `w` the reach in cells).
kernel void dustSpreadMax(texture3d<float, access::read> dIn [[texture(0)]],
                          texture3d<float, access::write> dOut [[texture(1)]],
                          constant QuarryDustUniforms &u [[buffer(0)]],
                          constant int4 &spread [[buffer(1)]],
                          uint3 id [[thread_position_in_grid]]) {
    int3 p = int3(id);
    int3 axis = spread.xyz;
    int3 top = u.dims.xyz - 1;
    float most = 0.0f;
    for (int k = -spread.w; k <= spread.w; ++k) {
        int3 q = p + axis * k;
        if (any(q < int3(0)) || any(q > top)) continue;
        most = max(most, dIn.read(uint3(q)).r);
    }
    dOut.write(float4(most), id);
}
