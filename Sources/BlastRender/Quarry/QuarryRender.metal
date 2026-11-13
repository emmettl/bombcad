// The quarry face's renderer (docs/hillside-blast.md), compiled on its own at run time.
// Illustrative: for the look of a face being blasted; not a blast-design aid.
#include <metal_stdlib>
using namespace metal;

static inline float3 rotate(float4 q, float3 v) {
    float3 t = 2.0f * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

static inline float3 unrotate(float4 q, float3 v) {
    float3 t = 2.0f * cross(-q.xyz, v);
    return v + q.w * t + cross(-q.xyz, t);
}

// --- Rendering ---

struct QuarryCamera {
    float4x4 viewProjection;
    float4x4 shadow;
    float4 eye;
    float4 sun;
    float4 fogColor;    // xyz unused; w 2 when the far ground fades into the backdrop's hills (a ridge cut), else 1
    float4 terrainOrigin;
    float4x4 inverseViewProjection;
    float4 dustLow;
    float4 dustHigh;
    float4 misc;
};

struct TerrainVertex { packed_float3 p; packed_float3 n; };

struct QuarryBlockVertex {
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
    float released;
    uint kind [[flat]];
    float weather [[flat]];
    float faceRandom [[flat]];
    float3 centre [[flat]];
    // 1 while the block is unbroken (held, and not yet moved by the swell), easing to 0 as it
    // moves: its own tint and roughness come in only then, so the face reads as one rock first.
    float intact [[flat]];
};

// A vertex's `body` carries the block's index in its low bits and the face's weathering and a
// random value above them (`QuarryRock.faceTag`).
constant uint bodyMask = (1u << 21) - 1u;

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

static inline RasterOut blockRaster(QuarryBlockVertex v, const device float4 *pose, constant QuarryCamera &cam,
                                    const device float4 *rest, bool underSkin, bool dressing = false) {
    uint body = v.body & bodyMask;
    float3 pos = pose[2 * body].xyz;
    float4 q = pose[2 * body + 1];
    float3 local = float3(v.local);
    float3 w = pos + rotate(q, local);
    RasterOut o;
    o.world = w;
    o.normal = rotate(q, unpackNormal(v.normalKind));
    o.local = local + rest[body].xyz;
    o.centre = rest[body].xyz;
    o.bodyTint = fract(float(body) * 0.6180339f);
    o.kind = v.normalKind >> 30;
    o.released = pose[2 * body].w > 0.5f ? 1.0f : 0.0f;
    o.weather = float((v.body >> 21) & 31u) / 31.0f;
    o.faceRandom = float(v.body >> 26) / 63.0f;
    float moved = length(pos - rest[body].xyz) + 2.0f * length(q.xyz) * max(rest[body].w, 0.3f);
    o.intact = (1.0f - o.released) * (1.0f - smoothstep(0.02f, 0.2f, moved));
    // While the held skin is over a block (`skinVertex`), the block is drawn farther along the line
    // of sight (2.5 m, and more far off): where its outer face stands proud of the skin (a hard
    // bed's block over the shale's recess, a thin piece kept from the surface), even seen at a
    // grazing angle, the skin is seen, not the block and its seams. The same pixels, so its outline
    // is unchanged where no skin is.
    // The dressing under a face's held skin past the strip (`QuarryFace.underSkinGrade`) too.
    bool skinned = dressing ? ((v.body >> 21) & 31u) == 30u : underSkin && o.released < 0.5f && moved <= 0.03f;
    float3 view = w - cam.eye.xyz;
    float3 drawn = skinned ? w + view * (2.5f / max(length(view), 1.0f) + 0.04f) : w;
    o.position = cam.viewProjection * float4(drawn, 1.0f);
    return o;
}

vertex RasterOut blockVertex(uint vid [[vertex_id]],
                             const device QuarryBlockVertex *vertices [[buffer(0)]],
                             const device float4 *pose [[buffer(1)]],
                             constant QuarryCamera &cam [[buffer(2)]],
                             const device float4 *rest [[buffer(3)]]) {
    return blockRaster(vertices[vid], pose, cam, rest, true);
}

// The render-only dressing: as the blocks, on one identity pose, with no skin over it.
vertex RasterOut dressingVertex(uint vid [[vertex_id]],
                                const device QuarryBlockVertex *vertices [[buffer(0)]],
                                const device float4 *pose [[buffer(1)]],
                                constant QuarryCamera &cam [[buffer(2)]],
                                const device float4 *rest [[buffer(3)]]) {
    return blockRaster(vertices[vid], pose, cam, rest, false, true);
}

// The held skin (`QuarryFace.heldSkin`, emmettl/bombcad-work#139): one continuous surface a few
// centimetres proud of the blocks' outer faces, in the world's frame, each triangle tagged with the
// block under it, so rock that has not broken shows no seam between its cells. A triangle goes
// (clipped away whole) once its block is released or has moved 3 cm; the block's own outer face is
// under it.
static inline bool skinGone(uint body, const device float4 *pose, const device float4 *rest) {
    float4 p = pose[2 * body];
    float4 q = pose[2 * body + 1];
    float moved = length(p.xyz - rest[body].xyz) + 2.0f * length(q.xyz) * max(rest[body].w, 0.3f);
    return p.w > 0.5f || moved > 0.03f;
}

vertex RasterOut skinVertex(uint vid [[vertex_id]],
                            const device QuarryBlockVertex *vertices [[buffer(0)]],
                            const device float4 *pose [[buffer(1)]],
                            constant QuarryCamera &cam [[buffer(2)]],
                            const device float4 *rest [[buffer(3)]]) {
    QuarryBlockVertex v = vertices[vid];
    uint body = v.body & bodyMask;
    float3 w = float3(v.local);
    RasterOut o;
    o.position = skinGone(body, pose, rest) ? float4(0.0f, 0.0f, 2.0f, 1.0f) : cam.viewProjection * float4(w, 1.0f);
    o.world = w;
    o.normal = unpackNormal(v.normalKind);
    o.local = w;
    o.centre = rest[body].xyz;
    o.bodyTint = fract(float(body) * 0.6180339f);
    o.kind = 1u;
    o.released = 0.0f;
    o.weather = float((v.body >> 21) & 31u) / 31.0f;
    o.faceRandom = float(v.body >> 26) / 63.0f;
    o.intact = 1.0f;
    return o;
}

// The blocks in the shadow map: a block under the held skin is moved 1.2 m away from the sun, as
// it is drawn behind the skin, so the skin casts the rock's shadow (`skinShadowVertex`) and a piece
// standing proud of the skin does not throw a stray shadow onto it.
vertex float4 heldBlockShadowVertex(uint vid [[vertex_id]],
                                    const device QuarryBlockVertex *vertices [[buffer(0)]],
                                    const device float4 *pose [[buffer(1)]],
                                    constant QuarryCamera &cam [[buffer(2)]],
                                    const device float4 *rest [[buffer(3)]]) {
    QuarryBlockVertex v = vertices[vid];
    uint body = v.body & bodyMask;
    float4 p = pose[2 * body];
    float4 q = pose[2 * body + 1];
    float3 w = p.xyz + rotate(q, float3(v.local));
    float moved = length(p.xyz - rest[body].xyz) + 2.0f * length(q.xyz) * max(rest[body].w, 0.3f);
    if (p.w < 0.5f && moved <= 0.03f) w -= cam.sun.xyz * 1.2f;
    return cam.shadow * float4(w, 1.0f);
}

vertex float4 dressingShadowVertex(uint vid [[vertex_id]],
                                   const device QuarryBlockVertex *vertices [[buffer(0)]],
                                   constant QuarryCamera &cam [[buffer(2)]]) {
    QuarryBlockVertex v = vertices[vid];
    float3 w = float3(v.local);
    if (((v.body >> 21) & 31u) == 30u) w -= cam.sun.xyz * 1.2f;
    return cam.shadow * float4(w, 1.0f);
}

vertex float4 skinShadowVertex(uint vid [[vertex_id]],
                               const device QuarryBlockVertex *vertices [[buffer(0)]],
                               const device float4 *pose [[buffer(1)]],
                               constant QuarryCamera &cam [[buffer(2)]],
                               const device float4 *rest [[buffer(3)]]) {
    QuarryBlockVertex v = vertices[vid];
    if (skinGone(v.body & bodyMask, pose, rest)) return float4(0.0f, 0.0f, 2.0f, 1.0f);
    return cam.shadow * float4(float3(v.local), 1.0f);
}

// The top-down height of the scene, for the chips to land on and the fines to fill: the top
// surface's height, and what it is (1 a block of the pile at rest, 0.5 the ground, 0 anything
// else: a block still held, or one moving). `cam.misc.z` is the frame rate between `pose` and
// `previous`. Also which block it is (its index plus one; 0 for the ground), for a chip landing on it
// to ride.
struct HeightOut { float4 position [[position]]; float z; float what; float body [[flat]]; };

vertex HeightOut blockHeightVertex(uint vid [[vertex_id]],
                                   const device QuarryBlockVertex *vertices [[buffer(0)]],
                                   const device float4 *pose [[buffer(1)]],
                                   constant QuarryCamera &cam [[buffer(2)]],
                                   const device float4 *previous [[buffer(4)]]) {
    QuarryBlockVertex v = vertices[vid];
    uint body = v.body & bodyMask;
    float4 p = pose[2 * body];
    float3 w = p.xyz + rotate(pose[2 * body + 1], float3(v.local));
    float speed = length(p.xyz - previous[2 * body].xyz) * cam.misc.z;
    HeightOut o;
    o.position = cam.shadow * float4(w, 1.0f);
    o.z = w.z;
    o.what = (p.w > 0.5f && speed < 1.5f) ? 1.0f : 0.0f;
    o.body = float(body + 1u);
    return o;
}

vertex HeightOut terrainHeightVertex(uint vid [[vertex_id]],
                                     const device TerrainVertex *vertices [[buffer(0)]],
                                     constant QuarryCamera &cam [[buffer(2)]]) {
    float3 w = float3(vertices[vid].p);
    HeightOut o;
    o.position = cam.shadow * float4(w, 1.0f);
    o.z = w.z;
    o.what = 0.5f;
    o.body = 0.0f;
    return o;
}

fragment float4 heightFragment(HeightOut in [[stage_in]]) { return float4(in.z, in.what, in.body, 0.0f); }

struct TerrainOut { float4 position [[position]]; float3 world; float3 normal; };

vertex TerrainOut terrainVertex(uint vid [[vertex_id]],
                                const device TerrainVertex *vertices [[buffer(0)]],
                                constant QuarryCamera &cam [[buffer(2)]]) {
    TerrainOut o;
    o.world = float3(vertices[vid].p);
    o.normal = float3(vertices[vid].n);
    o.position = cam.viewProjection * float4(o.world, 1.0f);
    return o;
}

vertex float4 terrainShadowVertex(uint vid [[vertex_id]],
                                  const device TerrainVertex *vertices [[buffer(0)]],
                                  constant QuarryCamera &cam [[buffer(2)]]) {
    return cam.shadow * float4(float3(vertices[vid].p), 1.0f);
}

static inline float shadowAt(float3 world, float3 normal, constant QuarryCamera &cam, depth2d<float> map, sampler s) {
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

static inline float3 skyColor(float3 dir, constant QuarryCamera &cam) {
    float h = saturate(dir.z * 2.6f + 0.02f);
    float3 horizon = float3(0.98f, 0.72f, 0.46f);
    float3 mid = float3(0.55f, 0.56f, 0.62f);
    float3 zenith = float3(0.16f, 0.27f, 0.47f);
    float3 base = mix(mix(horizon, mid, saturate(h * 2.2f)), zenith, saturate(h * 1.1f));
    float sunGlow = pow(saturate(dot(dir, cam.sun.xyz)), 18.0f);
    return base + float3(1.0f, 0.74f, 0.42f) * sunGlow * 0.8f;
}

// The backdrop: the sky with its distant hills in haze, low on the horizon all round.
static inline float3 backdrop(float3 dir, constant QuarryCamera &cam) {
    float3 color = skyColor(dir, cam);
    float azimuth = atan2(dir.x, dir.y);
    float ridge = 0.045f + 0.03f * fbm3(float3(azimuth * 6.0f, 2.0f, 0.0f), 4) + 0.012f * fbm3(float3(azimuth * 25.0f, 5.0f, 0.0f), 3);
    float near = 0.02f + 0.05f * fbm3(float3(azimuth * 11.0f, 9.0f, 3.0f), 4);
    if (dir.z < ridge) color = mix(float3(0.46f, 0.44f, 0.47f), color, 0.55f);
    if (dir.z < near) color = mix(float3(0.34f, 0.3f, 0.31f), color, 0.4f);
    return color;
}

static inline float dustShadow(float3 world, constant QuarryCamera &cam, texture3d<float> dustLight) {
    if (cam.dustHigh.w < 0.5f) return 1.0f;
    float3 uvw = (world - cam.dustLow.xyz) / (cam.dustHigh.xyz - cam.dustLow.xyz);
    if (any(uvw < 0.0f) || any(uvw > 1.0f)) return 1.0f;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return exp(-dustLight.sample(s, uvw).r * 0.045f);
}

// `wrap` lets light reach a little past the terminator (0: plain Lambert), for the weathered rock's
// small relief under the low sun, which otherwise turned away from it in dark blots.
static inline float3 shade(float3 albedo, float3 world, float3 n, constant QuarryCamera &cam, float shadow, float dust,
                           float wrap = 0.0f) {
    float3 sun = cam.sun.xyz;
    float nl = max((dot(n, sun) + wrap) / (1.0f + wrap), 0.0f);
    float3 sunColor = float3(1.0f, 0.74f, 0.47f) * 3.4f;
    float up = n.z * 0.5f + 0.5f;
    float3 skyLight = mix(float3(0.34f, 0.27f, 0.22f), float3(0.33f, 0.41f, 0.6f), up) * 0.55f;
    float3 bounce = float3(0.5f, 0.38f, 0.26f) * saturate(-n.z * 0.5f + 0.35f) * 0.18f;
    float3 lit = albedo * (sunColor * nl * shadow * dust + skyLight + bounce);
    float distance = length(world - cam.eye.xyz);
    float fog = 1.0f - exp(-distance * distance * 0.7e-6f);
    float3 dir = (world - cam.eye.xyz) / max(distance, 1.0f);
    // A ridge cut's far plain is seen past the ridge, under the backdrop's hills: it fades into
    // them, not into the bare sky's paler horizon, which showed as a pale strip under darker hills
    // (emmettl/bombcad-work#133). A face's view keeps its fog as it was.
    if (cam.fogColor.w > 1.5f) return mix(lit, backdrop(float3(dir.x, dir.y, 0.0f), cam) * 0.95f, fog);
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

// The beds, on the same coordinate as the fracture's (`QuarryFracture.families[0]`), and their
// kinds of rock as `QuarryRock` chooses them: 0 limestone, 1 shale, 2 sandstone, 3 ironstone.
constant float3 beddingNormal = float3(0.0595f, 0.0496f, 0.9970f);
static inline float bedCoordinate(float s) {
    return (s + 0.9f * sin(0.31f * s + 1.2f) + 0.5f * sin(0.97f * s + 2.7f)) / 1.25f;
}
static inline uint bedHash(int k) {
    uint h = as_type<uint>(k) * 0x9E3779B1u;
    h ^= h >> 15; h *= 0x85EBCA77u; h ^= h >> 13; h *= 0xC2B2AE3Du; h ^= h >> 16;
    return h;
}
static inline int rockKind(int k) {
    float u = float(bedHash(k) >> 8) / 16777216.0f;
    return u < 0.42f ? 0 : u < 0.66f ? 1 : u < 0.88f ? 2 : 3;
}

// A bed's colours: fresh (a new break deep in the rock), oxidised (a break in the weathered rock
// near the old surface: buff and brown) and its patina (the old weathered face, darker).
struct RockColour { float3 fresh; float3 oxidised; float3 patina; int kind; float lamination; };

static inline RockColour rockOfKind(int kind) {
    RockColour r;
    r.kind = kind;
    r.lamination = 1.0f;
    if (kind == 0) {
        r.fresh = float3(0.56f, 0.545f, 0.5f);
        r.oxidised = float3(0.57f, 0.51f, 0.42f);
        r.patina = float3(0.42f, 0.4f, 0.36f);
    } else if (kind == 1) {
        r.fresh = float3(0.2f, 0.2f, 0.21f);
        r.oxidised = float3(0.3f, 0.25f, 0.2f);
        r.patina = float3(0.14f, 0.13f, 0.12f);
    } else if (kind == 2) {
        r.fresh = float3(0.57f, 0.5f, 0.38f);
        r.oxidised = float3(0.54f, 0.44f, 0.32f);
        r.patina = float3(0.38f, 0.33f, 0.26f);
    } else {
        // Ironstone: a dark purplish brown, rusty only where it has weathered (it read orange
        // under the warm low sun until 12 November 2026).
        r.fresh = float3(0.31f, 0.24f, 0.21f);
        r.oxidised = float3(0.37f, 0.27f, 0.2f);
        r.patina = float3(0.28f, 0.22f, 0.18f);
    }
    // Weathering brings the beds' faces toward one grey-buff.
    r.patina = mix(r.patina, float3(0.36f, 0.33f, 0.28f), 0.15f);
    return r;
}

/// A kind of rock in the shares the beds have, from a value in 0...1.
static inline int kindFromShare(float u) { return u < 0.42f ? 0 : u < 0.66f ? 1 : u < 0.88f ? 2 : 3; }

// Fine laminations within a bed: wavy, broken and irregular, in three sizes, each faded as it comes
// under a pixel (`footprint`, metres a pixel). A ruled sine, nine lines a bed, read as hatching close
// in and aliased into stripes farther off until 13 November 2026 (emmettl/bombcad-work#142).
static inline float laminae(float c, float3 p, int kind, float h, float footprint) {
    float strength = kind == 0 ? 0.035f : kind == 1 ? 0.1f : kind == 2 ? 0.075f : 0.05f;
    float along = dot(p.xy, float2(0.6f, 0.8f));
    // About 1.4 bed widths a metre at most, across the beds.
    float perPixel = footprint * 1.4f;
    float l = 0.0f;
    const float sizes[3] = {3.0f, 8.0f, 19.0f};
    const float amounts[3] = {0.5f, 0.35f, 0.25f};
    for (int i = 0; i < 3; ++i) {
        float w = 1.0f - smoothstep(0.15f, 0.45f, perPixel * sizes[i]);
        if (w <= 0.0f) break;
        float n = noise3(float3(c * sizes[i], along * 0.1f + float(i) * 5.3f, h * 13.0f + float(i) * 2.1f));
        l += amounts[i] * w * (n - 0.5f) * 2.0f;
    }
    float contrast = 0.4f + 0.9f * noise3(float3(along * 0.07f, c * 0.6f, 4.0f));
    return 1.0f + strength * l * contrast;
}

static inline RockColour rockAt(float3 p, float footprint = 1.0f) {
    float c = bedCoordinate(dot(p, beddingNormal));
    int k = int(floor(c));
    int kind = rockKind(k);
    float h = float(bedHash(k * 7 + 3) & 0xFFFFu) / 65535.0f;
    RockColour r = rockOfKind(kind);
    float tint = 0.88f + 0.24f * h;
    r.fresh *= tint;
    r.oxidised *= tint;
    r.patina *= tint;
    r.lamination = laminae(c, p, kind, h, footprint);
    return r;
}

// The terrain's steep ground behind the rock keeps the beds' weathered colours.
static inline float3 bedColour(float3 p, float footprint) {
    RockColour r = rockAt(p, footprint);
    return mix(r.patina, r.oxidised, 0.35f) * r.lamination;
}

static inline float hash2i(int2 c, uint salt) {
    uint h = as_type<uint>(c.x) * 0x8DA6B343u ^ as_type<uint>(c.y) * 0xD8163841u ^ salt * 0xCB1AB31Fu;
    h ^= h >> 13; h *= 0x4F37F8A5u; h ^= h >> 16;
    return float(h & 0xFFFFFFu) / 16777215.0f;
}

// Nearest and second-nearest stone in a jittered grid: x f1, y f2, z the stone's own value, and the
// way to its middle in `toCentre`.
static inline float3 stones(float2 x, uint salt, thread float2 &toCentre) {
    float2 i = floor(x), f = x - i;
    float f1 = 8.0f, f2 = 8.0f, id = 0.0f;
    for (int y = -1; y <= 1; ++y) for (int xx = -1; xx <= 1; ++xx) {
        int2 cell = int2(i) + int2(xx, y);
        float2 o = float2(hash2i(cell, salt), hash2i(cell, salt + 7u)) * 0.8f + 0.1f;
        float2 r = float2(xx, y) + o - f;
        float d = dot(r, r);
        if (d < f1) { f2 = f1; f1 = d; id = hash2i(cell, salt + 13u); toCentre = r; }
        else if (d < f2) { f2 = d; }
    }
    return float3(sqrt(f1), sqrt(f2), id);
}

// The old joints of the weathered surface (`QuarryJoints.field` in BlastModel, a copy: change them
// together): x how deep in a joint's groove, y how near its open crack, each times how open the
// joint is there. Long irregular traces through several beds, in clusters and gaps
// (emmettl/bombcad-work#142).
static inline float jointHash(int k, uint salt) {
    uint h = (as_type<uint>(k) * 0x8DA6B343u) ^ (salt * 0xCB1AB31Fu);
    h ^= h >> 13; h *= 0x4F37F8A5u; h ^= h >> 16;
    return float(h & 0xFFFFFFu) / 16777216.0f;
}
static inline float jointNoise(float x, uint salt) {
    float i = floor(x);
    float f = x - i;
    float s = f * f * (3.0f - 2.0f * f);
    int k = int(i);
    float a = jointHash(k, salt);
    return a + (jointHash(k + 1, salt) - a) * s;
}
static inline float jointNoise2(float x, float y, uint salt) {
    float i = floor(x), j = floor(y);
    float fx = x - i, fy = y - j;
    float sx = fx * fx * (3.0f - 2.0f * fx), sy = fy * fy * (3.0f - 2.0f * fy);
    int a = int(i), b = int(j) * 7919;
    float h00 = jointHash(a + b, salt), h10 = jointHash(a + 1 + b, salt);
    float h01 = jointHash(a + b + 7919, salt), h11 = jointHash(a + 1 + b + 7919, salt);
    float low = h00 + (h10 - h00) * sx;
    float high = h01 + (h11 - h01) * sx;
    return low + (high - low) * sy;
}
static inline void jointSet(float3 p, int bed, float2 normal, float2 along, float spacing, float lean, float keep,
                            uint salt, float halfWidth, float line, thread float2 &field) {
    float v = dot(p.xy, along);
    float s = float(salt);
    float u = dot(p.xy, normal) + lean * p.z + 1.1f * sin(0.11f * v + s) + 0.35f * sin(0.37f * v + 0.7f * s)
        + 0.12f * sin(1.3f * v + 1.9f * s)
        + 0.7f * (jointNoise(p.z * 0.33f + v * 0.05f, salt + 3u) - 0.5f)
        + 0.06f * (jointNoise(p.z * 2.3f + v * 1.7f, salt + 7u) - 0.5f)
        + (jointHash(bed, salt + 6u) < 0.3f ? (jointHash(bed, salt + 5u) - 0.5f) * 0.8f : 0.0f);
    u += 0.9f * spacing * (jointNoise(u / spacing * 0.45f, salt + 4u) - 0.5f);
    int k0 = int(floor(u / spacing));
    for (int dk = -1; dk <= 1; ++dk) {
        int k = k0 + dk;
        if (jointHash(k, salt) >= keep) continue;
        float centre = (float(k) + 0.5f + 0.8f * (jointHash(k, salt + 1u) - 0.5f)) * spacing;
        float d = abs(u - centre);
        if (d >= max(halfWidth, 1.55f * line)) continue;
        float n = jointNoise2(v * 0.045f + float(k) * 7.31f, p.z * 0.07f + float(k) * 3.7f, salt + 2u);
        float open = saturate((n - 0.38f) / 0.24f);
        float confined = jointHash(bed * 131 + k, salt + 9u) < 0.15f ? 0.0f : 1.0f;
        float openness = open * open * (3.0f - 2.0f * open) * confined;
        if (d < halfWidth) {
            float t = d / halfWidth;
            field.x = max(field.x, openness * (1.0f - t * t) * (1.0f - t * t));
        }
        float width = line * (0.45f + 1.1f * jointNoise(p.z * 1.4f + v * 0.6f + float(k), salt + 8u));
        if (d < width) {
            float t = saturate((d - 0.5f * width) / (0.5f * width));
            field.y = max(field.y, openness * (1.0f - t * t * (3.0f - 2.0f * t)));
        }
    }
}
static inline float2 jointField(float3 p, float halfWidth, float line) {
    float2 field = float2(0.0f);
    int bed = int(floor(bedCoordinate(dot(p, beddingNormal))));
    if (rockKind(bed) == 1) return field;
    jointSet(p, bed, float2(0.9394f, 0.3429f), float2(-0.3429f, 0.9394f), 3.4f, 0.08f, 0.6f, 17u, halfWidth, line, field);
    jointSet(p, bed, float2(-0.3090f, 0.9511f), float2(-0.9511f, -0.3090f), 5.2f, -0.05f, 0.5f, 29u, halfWidth, line, field);
    jointSet(p, bed, float2(0.8090f, -0.5878f), float2(0.5878f, 0.8090f), 9.0f, 0.55f, 0.4f, 43u, halfWidth, line, field);
    return field;
}

// The ground's looks, shared by the ridge's flanks, the face's talus apron and the soil held on the
// weathered rock (defined with the ridge's ground below).
static inline float3 screeGround(float2 q, float3 world, float detail, thread float3 &tilt);
static inline float3 grassGround(float3 world, float detail, thread float3 &tilt);
static inline float3 stoneColour(float id);

// Soil and turf held on the gentler weathered rock (emmettl/bombcad-work#142): in its hollows and
// joints' grooves, on the gentler tops (the steps and steeper fronts stay bare rock), on the
// shale's slopes, and on a ridge cut toward the edge of its dense rock, where it meets the
// flanks' own cover (`cover`, `QuarryFlank`). x how much soil, y how much of that is turf.
static inline float2 heldSoil(float3 p, float3 n, float groove, constant QuarryCamera &cam, texture2d<float> cover) {
    float c = bedCoordinate(dot(p, beddingNormal));
    bool shale = rockKind(int(floor(c))) == 1;
    // On a ridge the shale weathers back to a soil slope; the harder beds hold soil only on their
    // tops. A face's ledges hold a little grit and soil, little turf.
    bool ridge = cam.terrainOrigin.z > 0.0f;
    float gentle = shale && ridge ? smoothstep(0.35f, 0.7f, n.z) : smoothstep(0.6f, 0.85f, n.z);
    if (gentle <= 0.0f) return float2(0.0f);
    float hollow = fbm3(p * 0.45f + 61.0f, 3) - 0.45f;
    float patches = fbm3(p * 0.11f + 5.0f, 3) - 0.45f;
    float edge = 0.0f;
    if (cam.terrainOrigin.z > 0.0f) {
        // How much of the ground a few metres round is outside the dense rock round the cut.
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        float inside = 0.0f;
        for (int k = 0; k < 6; ++k) {
            float a = float(k) * 1.0472f + 0.4f;
            float2 q = p.xy + float2(cos(a), sin(a)) * (k & 1 ? 6.0f : 3.0f);
            inside += cover.sample(linear, saturate((q - cam.terrainOrigin.xy) / cam.terrainOrigin.zw)).b;
        }
        edge = saturate((1.0f - inside / 6.0f) * 1.6f);
    }
    // Soil in broad patches and hollows (held to the laminae's treads it was striped again).
    float hold = 0.5f + 0.9f * hollow + 1.4f * patches + (shale ? 0.15f : 0.0f) + 0.3f * groove
        + 0.9f * edge;
    float soil = smoothstep(0.36f, 0.46f, hold) * gentle * (ridge ? 1.0f : 0.7f);
    float turf = smoothstep(0.3f, 0.55f, fbm3(p * 0.27f + 17.0f, 3) + 0.25f * edge + 0.2f * (hold - 0.45f));
    return float2(soil, turf * (ridge ? 1.0f : 0.25f));
}

fragment float4 blockFragment(RasterOut in [[stage_in]],
                              constant QuarryCamera &cam [[buffer(0)]],
                              depth2d<float> shadowMap [[texture(0)]],
                              texture3d<float> dustLight [[texture(1)]],
                              texture2d<float> cover [[texture(2)]],
                              sampler s [[sampler(0)]]) {
    float3 n = normalize(in.normal);
    float3 rest = in.local;
    float detail = fbm3(rest * 4.0f, 4);
    float grain = fbm3(rest * 19.0f, 3);
    float footprint = length(fwidth(rest));
    // The bed is read a few centimetres inside the block, so a face cut along a bedding plane
    // takes its own block's bed and not the next.
    RockColour rock = rockAt(rest + normalize(in.centre - rest + float3(1e-4f)) * 0.05f, footprint);
    // Each block a little its own: lighter or darker, warmer or greyer.
    float h1 = in.bodyTint;
    float h2 = fract(h1 * 7.31f + 0.17f);
    float h3 = fract(h1 * 13.77f + 0.61f);
    float3 shade1 = mix(mix(float3(0.86f, 0.85f, 0.84f), float3(1.1f, 1.06f, 1.0f), h2), float3(0.97f), in.intact);
    float w = in.weather;
    float3 albedo;
    // The old weathered face: the bed's patina, streaked down the face by water, stained, and a
    // little lichen on the harder beds.
    float3 patina = float3(0.0f);
    float2 soil = float2(0.0f);
    if (in.kind == 1u || in.intact > 0.0f) {
        float streak = fbm3(rest * float3(2.6f, 2.6f, 0.22f) + 7.0f, 3);
        float stain = fbm3(rest * 0.2f, 3);
        patina = rock.patina * (0.72f + 0.6f * streak) * (0.8f + 0.4f * stain);
        float lichen = smoothstep(0.55f, 0.75f, fbm3(rest * 1.3f + 40.0f, 4)) * (rock.kind == 1 ? 0.0f : 1.0f);
        patina = mix(patina, float3(0.25f, 0.28f, 0.13f) * (0.7f + 0.8f * grain), lichen * 0.3f);
        // The weathered surface's small relief, as its geometry (`QuarryFace.weatheredRelief`) is
        // too coarse to carry it (emmettl/bombcad-work#139): the old joints' dark open cracks and
        // stained grooves, small pits, pale lichen rosettes and dark crusts in patches; the finer
        // of them fade as they come under a pixel. The cracks thin and fade, rather than widening
        // into a grid of dark lines far off (emmettl/bombcad-work#142).
        float2 joint = jointField(rest, 0.35f, 0.022f + 0.5f * footprint);
        float crackFade = 1.0f - smoothstep(0.03f, 0.12f, footprint);
        joint.x *= 1.0f - 0.5f * smoothstep(0.08f, 0.3f, footprint);
        patina *= 1.0f - 0.18f * joint.x * joint.x;
        patina = mix(patina, float3(0.06f, 0.053f, 0.047f), joint.y * 0.75f * crackFade);
        float close = 1.0f - smoothstep(0.015f, 0.05f, footprint);
        if (close > 0.0f) {
            float pits = smoothstep(0.68f, 0.8f, fbm3(rest * 6.5f + 3.0f, 2)) * close;
            patina *= 1.0f - 0.15f * pits;
            float2 toRosette;
            float3 rosette = stones(rest.xy * 3.1f + rest.z * 0.7f, 41u, toRosette);
            float rosettes = (rosette.z < 0.18f ? 1.0f - smoothstep(0.18f, 0.3f, rosette.x) : 0.0f) * close
                * (rock.kind == 1 ? 0.0f : 1.0f);
            patina = mix(patina, float3(0.55f, 0.55f, 0.47f) * (0.85f + 0.3f * grain), rosettes * 0.4f);
        }
        float crust = smoothstep(0.58f, 0.78f, fbm3(rest * float3(0.45f, 0.45f, 0.8f) + 23.0f, 3))
            * (rock.kind == 1 ? 0.0f : 1.0f);
        patina = mix(patina, patina * 0.6f + float3(0.012f, 0.01f, 0.008f), crust * 0.35f);
        // Rock thrown by the blast keeps some of its soil and turf on its old top.
        soil = heldSoil(rest, n, joint.x, cam, cover);
        soil.x *= 0.6f + 0.4f * in.intact;
    }
    if (in.kind == 1u) {
        albedo = patina;
    } else if (in.kind == 2u) {
        albedo = float3(0.2f, 0.18f, 0.15f) * (0.7f + 0.6f * detail);
    } else if (in.kind == 3u) {
        // An old joint or parting: stained, more where the rock is weathered, with rusty patches.
        float iron = smoothstep(0.35f, 0.7f, fbm3(rest * 0.9f + 11.0f + in.faceRandom * 20.0f, 4));
        albedo = mix(rock.fresh * 0.82f, rock.oxidised * 0.8f, 0.25f + 0.65f * w);
        albedo = mix(albedo, float3(0.38f, 0.28f, 0.2f) * (0.8f + 0.5f * detail), iron * (0.15f + 0.45f * w));
        albedo *= 0.9f + 0.2f * in.faceRandom;
    } else {
        // A fresh break: pale and cool deep in the rock, buff in the weathered rock near the surface.
        albedo = mix(rock.fresh, rock.oxidised, w * 0.85f) * (0.9f + 0.2f * in.faceRandom) * (0.88f + 0.24f * detail);
        // Percussion marks and crushed edges: paler flecks.
        float fleck = smoothstep(0.62f, 0.7f, fbm3(rest * 9.0f + h2 * 30.0f, 3));
        albedo = mix(albedo, albedo * 1.3f + 0.04f, fleck * 0.45f);
    }
    // Rock that has not broken shows only its weathered skin: what shows of a side face through
    // a seam between unbroken cells is the same rock as the face around it, not a fresh break.
    if (in.kind != 1u) albedo = mix(albedo, patina, in.intact);
    if (h3 > 0.9f) albedo = mix(albedo, albedo * float3(1.03f, 0.9f, 0.8f), 0.5f * (1.0f - in.intact));
    albedo *= shade1 * rock.lamination * (0.84f + 0.32f * grain);
    // Soil and turf in the weathered rock's hollows and on its gentler tops.
    float3 soilTilt = float3(0.0f);
    float near = 1.0f - smoothstep(0.03f, 0.11f, footprint);
    if (soil.x > 0.0f) {
        float3 earth = float3(0.22f, 0.18f, 0.14f) * (0.8f + 0.4f * fbm3(rest * 2.2f + 9.0f, 3));
        float3 gritTilt;
        earth = mix(earth, screeGround(rest.xy, rest, near, gritTilt) * 0.8f, 0.35f);
        // Thin turf on rock: darker and greener than the flanks' dry grass, with the soil showing.
        float3 turf = grassGround(rest, near, soilTilt);
        turf = mix(turf * 0.75f, float3(0.2f, 0.21f, 0.1f), 0.3f);
        albedo = mix(albedo, mix(earth, turf, soil.y), soil.x);
        soilTilt = mix(gritTilt, soilTilt, soil.y);
    }
    // Dust settled on the upper faces of rock that has moved, gathering as the cloud comes down:
    // a pale coat in broad patches.
    if (in.released > 0.5f) {
        float up = smoothstep(0.2f, 0.85f, n.z);
        float patch = smoothstep(0.25f, 0.65f, fbm3(rest * 0.7f + 5.0f, 3));
        float settle = saturate((cam.misc.x - 3.0f) / 6.0f);
        float coat = up * (0.25f + 0.75f * patch) * settle;
        albedo = mix(albedo, float3(0.6f, 0.54f, 0.45f) * (0.9f + 0.2f * grain), coat * 0.45f);
    }
    // Gentle relief on the faces: under the low sun a strong bump turned whole patches of every
    // face away from the light, in spots.
    float roughScale = mix(2.0f, 6.5f, h2);
    float roughness = mix(0.05f, 0.16f, h3) * (rock.kind == 1 ? 0.6f : 1.0f);
    // The old weathered face's bump at 0.45 turned patches of every face that looks up away from
    // a sun 18 degrees high: a ridge's crest and the face's ledges were spotted dark blue (sky
    // light only) all over (until 12 November 2026, emmettl/bombcad-work#136).
    // The weathered faces' bump, 0.2 in four octaves until 13 November 2026: under the low sun its
    // finer octaves still spotted the crest's rock with dark blue blotches (emmettl/bombcad-work#139).
    float3 surface = in.kind == 1u || in.intact > 0.5f ? bumped(n, rest, 1.6f, 0.12f, 2) : bumped(n, rest, roughScale, roughness, 3);
    // The weathered surface's grain close in: a fine, gentle bump, faded with the pixel's footprint.
    if (in.kind == 1u || in.intact > 0.5f) {
        float grainNear = 1.0f - smoothstep(0.02f, 0.08f, footprint);
        if (grainNear > 0.0f) surface = bumped(surface, rest, 7.0f, 0.06f * grainNear, 2);
    }
    // Soil lies smoother than the rock round it.
    if (soil.x > 0.0f) surface = normalize(mix(surface, normalize(n + soilTilt), soil.x));
    float shadow = shadowAt(in.world, n, cam, shadowMap, s);
    float dust = dustShadow(in.world, cam, dustLight);
    // The weathered rock's light wraps a little past the terminator, more on the shale's folded
    // recess: under the low sun its small relief turned away in dark blots (emmettl/bombcad-work#142).
    float wrap = in.kind == 1u || in.intact > 0.5f ? (rock.kind == 1 ? 0.5f : 0.1f) : 0.0f;
    return float4(shade(albedo, in.world, surface, cam, shadow, dust, wrap), 1.0f);
}

// A face's quarry floor (`terrainFragment`, and the toe of the talus apron): its colour, the tilt of
// its gravel close in, and its noises for the rest of the ground's look.
struct FloorLook { float3 ground; float3 gravelTilt; float detail; float fine; float broad; float roads; float footprint; };

static inline FloorLook quarryFloor(float3 world) {
    float detail = fbm3(world * float3(2.2f), 5);
    float fine = fbm3(world * float3(9.0f), 3);
    float broad = fbm3(world * 0.035f, 3);
    float pebbles = smoothstep(0.55f, 0.7f, fbm3(world * 3.7f + 11.0f, 3));
    float3 ground = mix(float3(0.15f, 0.13f, 0.10f), float3(0.34f, 0.29f, 0.22f), detail * 0.7f + fine * 0.3f);
    ground *= 0.55f + 0.95f * broad;
    ground *= 0.85f + 0.3f * smoothstep(0.35f, 0.7f, fbm3(world * 0.012f + 17.0f, 3));
    ground = mix(ground, ground * 1.35f + float3(0.03f), pebbles * 0.6f);
    // A worked quarry floor: broad paler haul-road patches, darker damp hollows, drifts of
    // grit and tracks along the face.
    float roads = smoothstep(0.42f, 0.6f, fbm3(float3(world.x * 0.012f, world.y * 0.03f, 2.0f), 3));
    ground = mix(ground, float3(0.46f, 0.41f, 0.33f) * (0.8f + 0.4f * fine), roads * 0.7f);
    float damp = smoothstep(0.58f, 0.72f, fbm3(world * 0.045f + 31.0f, 4));
    ground *= 1.0f - damp * 0.5f;
    float tracks = smoothstep(0.86f, 0.98f, abs(sin(world.y * 1.9f + 2.5f * fbm3(world * 0.05f, 2))));
    ground *= 1.0f - tracks * roads * 0.18f;
    // Close in, gravel and fines: crushed stones of the beds lying in grit, each domed and leaning
    // its own way, faded with the pixel's footprint; far off their mean, a little paler. Until 13
    // November 2026 the grit was a hash of 14 cm cells, which read as light squares on a grid
    // close in (emmettl/bombcad-work#142).
    float footprint = length(fwidth(world));
    float near = 1.0f - smoothstep(0.015f, 0.08f, footprint);
    ground *= 1.0f + 0.04f * (1.0f - damp);
    float3 gravelTilt = float3(0.0f);
    if (near > 0.0f) {
        float2 q = world.xy;
        float2 toPebble, toGrit;
        float3 pebble = stones(q / 0.09f, 31u, toPebble);
        float3 gritCell = stones(q / 0.03f, 37u, toGrit);
        float gap = pebble.y - pebble.x;
        // Stones scattered in the fines, more off the haul roads, in drifts.
        float drift = fbm3(world * 0.5f + 7.0f, 2);
        bool isPebble = pebble.z < (0.1f + 0.15f * (1.0f - roads)) * (0.4f + 1.4f * drift) && gap > 0.14f;
        float id = isPebble ? pebble.z : gritCell.z;
        float3 stone = stoneColour(id) * (0.85f + 0.3f * fbm3(world * (isPebble ? 30.0f : 70.0f) + id * 40.0f, 2));
        stone = mix(ground, stone, isPebble ? 0.6f : 0.15f);
        float crevice = isPebble ? smoothstep(0.0f, 0.22f, gap) : 0.85f + 0.15f * smoothstep(0.0f, 0.3f, gritCell.y - gritCell.x);
        stone *= 0.7f + 0.3f * crevice;
        ground = mix(ground, stone, near * (1.0f - 0.5f * damp));
        float2 lean = (float2(fract(id * 47.3f), fract(id * 91.7f)) - 0.5f) * (isPebble ? 0.6f : 0.15f);
        gravelTilt = float3((lean - (isPebble ? toPebble * 1.2f : toGrit * 0.25f)) * near * (isPebble ? crevice : 1.0f), 0.0f);
    }
    FloorLook look;
    look.ground = ground;
    look.gravelTilt = gravelTilt;
    look.detail = detail;
    look.fine = fine;
    look.broad = broad;
    look.roads = roads;
    look.footprint = footprint;
    return look;
}

fragment float4 terrainFragment(TerrainOut in [[stage_in]],
                                constant QuarryCamera &cam [[buffer(0)]],
                                depth2d<float> shadowMap [[texture(0)]],
                                texture3d<float> dustLight [[texture(1)]],
                                sampler s [[sampler(0)]]) {
    float3 n = normalize(in.normal);
    float slope = 1.0f - n.z;
    FloorLook look = quarryFloor(in.world);
    float3 ground = look.ground;
    float3 gravelTilt = look.gravelTilt;
    float detail = look.detail, fine = look.fine, broad = look.broad, roads = look.roads, footprint = look.footprint;
    float warp = fbm3(in.world * 0.07f, 3);
    float strata = sin(in.world.z * 1.5f + 9.0f * warp) * 0.5f + 0.5f;
    float3 rock = mix(float3(0.17f, 0.16f, 0.13f), bedColour(in.world, footprint) * 0.95f, smoothstep(0.25f, 0.8f, detail)) * (0.9f + 0.2f * strata);
    float crest = smoothstep(14.0f, 21.0f, in.world.z) * (1.0f - smoothstep(0.08f, 0.25f, slope));
    float3 scrub = mix(float3(0.13f, 0.13f, 0.07f), float3(0.3f, 0.26f, 0.13f), detail * 0.6f + broad * 0.4f);
    scrub = mix(scrub, float3(0.22f, 0.19f, 0.11f), smoothstep(0.45f, 0.7f, fbm3(in.world * 0.11f + 3.0f, 3)));
    // The steep ground stands behind the render-only rock: where it shows between the cells it
    // is the shade of a deep crack, not a smooth wall.
    rock *= mix(1.0f, 0.35f, smoothstep(0.35f, 0.6f, slope));
    float3 albedo = mix(ground, rock, smoothstep(0.12f, 0.45f, slope));
    albedo = mix(albedo, scrub, crest * smoothstep(0.32f, 0.5f, broad + 0.12f * fine));
    float fade = saturate(1.0f - length(in.world - cam.eye.xyz) / 600.0f);
    float3 surface = bumped(normalize(n + gravelTilt * (1.0f - smoothstep(0.12f, 0.45f, slope))), in.world, 1.1f, (0.16f + 0.1f * (1.0f - roads)) * fade, 3);
    float shadow = shadowAt(in.world, n, cam, shadowMap, s);
    float dust = dustShadow(in.world, cam, dustLight);
    return float4(shade(albedo, in.world, surface, cam, shadow, dust), 1.0f);
}

// Fines on the pile: gravel and grit that fill the hollows between the blocks at rest and spread
// in an apron at the pile's foot, as a surface drawn from the top-down height of the scene. A
// picture of fines, not bodies: they come with the pile as it settles.
struct QuarryFinesUniforms {
    float4 low;     // the height map's domain: low x, y; span x, y
    float4 ground;  // the excavated ground's grid: origin x, y, spacing, unused
    float4 misc;    // time, how far the fines have gathered (0...1), the drawn grid's first texel x, y
    float4 grid;    // the drawn grid's step in texels, columns, rows, unused
};

static inline float2 heightTexelWorld(uint2 t, uint2 size, constant QuarryFinesUniforms &u) {
    return float2(u.low.x + (float(t.x) + 0.5f) / float(size.x) * u.low.z,
                  u.low.y + (1.0f - (float(t.y) + 0.5f) / float(size.y)) * u.low.w);
}

kernel void finesBuild(texture2d<float, access::read> height [[texture(0)]],
                       texture2d<float, access::sample> ground [[texture(1)]],
                       texture2d<float, access::write> fines [[texture(2)]],
                       constant QuarryFinesUniforms &u [[buffer(0)]],
                       uint2 id [[thread_position_in_grid]]) {
    uint2 size = uint2(height.get_width(), height.get_height());
    if (id.x >= size.x || id.y >= size.y) return;
    constexpr sampler linear(filter::linear, address::clamp_to_edge, coord::pixel);
    float2 world = heightTexelWorld(id, size, u);
    float g = ground.sample(linear, (world - u.ground.xy) / u.ground.z + 0.5f).r;
    float fill = u.misc.y;
    if (fill <= 0.0f) { fines.write(float4(g - 1.0f), id); return; }
    int2 c = int2(id);
    int2 m = int2(size) - 1;
    // The pile's blocks at rest nearby: how much of the ground they cover, and their mean top.
    float total = 0.0f, pile = 0.0f, top = 0.0f;
    for (int dy = -3; dy <= 3; ++dy) for (int dx = -3; dx <= 3; ++dx) {
        float2 t = height.read(uint2(clamp(c + int2(dx, dy), int2(0), m))).rg;
        float w = exp(-float(dx * dx + dy * dy) / 6.0f);
        total += w;
        if (t.g > 0.75f) { pile += w; top += w * t.r; }
    }
    float cover = pile / total;
    // Farther out, for the apron at the pile's foot.
    float wide = 0.0f;
    for (int k = 0; k < 16; ++k) {
        float a = float(k) * 0.3927f;
        float r = (k & 1) ? 9.0f : 5.0f;
        int2 q = clamp(c + int2(round(cos(a) * r), round(sin(a) * r)), int2(0), m);
        wide += height.read(uint2(q)).g > 0.75f ? 1.0f / 16.0f : 0.0f;
    }
    wide = max(wide, cover);
    // Only in the pile, not round a block on its own: the ring out to 3.4 m must find more.
    float present = smoothstep(0.15f, 0.45f, wide) * fill;
    float apron = g - 0.5f + present * (0.55f + 0.3f * wide);
    float surface = apron;
    if (pile > 1e-3f) {
        // Up to 0.2 m below the blocks' mean top once gathered (0.35 m until 12 November 2026,
        // which left the fines in the blocks' shade under the low sun: dark gaps, not gravel).
        float filled = top / pile - mix(1.1f, 0.2f, fill);
        surface = mix(apron, max(filled, apron), smoothstep(0.3f, 0.6f, cover) * smoothstep(0.3f, 0.6f, wide));
    }
    fines.write(float4(surface), id);
}

// Loose fines stand no steeper than their angle of repose: each pass lowers a texel to no more
// than its lowest neighbour plus that slope, so a heap's sides relax over a few passes.
kernel void finesRelax(texture2d<float, access::read> in [[texture(0)]],
                       texture2d<float, access::write> out [[texture(1)]],
                       constant QuarryFinesUniforms &u [[buffer(0)]],
                       uint2 id [[thread_position_in_grid]]) {
    uint2 size = uint2(in.get_width(), in.get_height());
    if (id.x >= size.x || id.y >= size.y) return;
    float2 texel = u.low.zw / float2(size);
    float slope = 0.8f;
    float z = in.read(id).r;
    int2 m = int2(size) - 1;
    for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
        if (dx == 0 && dy == 0) continue;
        float other = in.read(uint2(clamp(int2(id) + int2(dx, dy), int2(0), m))).r;
        z = min(z, other + slope * length(float2(dx, dy) * texel));
    }
    out.write(float4(z), id);
}

struct FinesOut { float4 position [[position]]; float3 world; float3 normal; };

vertex FinesOut finesVertex(uint vid [[vertex_id]],
                            texture2d<float, access::read> fines [[texture(0)]],
                            constant QuarryCamera &cam [[buffer(2)]],
                            constant QuarryFinesUniforms &u [[buffer(3)]]) {
    uint columns = uint(u.grid.y);
    uint step = uint(u.grid.x);
    uint2 size = uint2(fines.get_width(), fines.get_height());
    uint2 t = min(uint2(u.misc.zw) + uint2(vid % columns, vid / columns) * step, size - 1u);
    uint2 l = uint2(max(int(t.x) - int(step), 0), t.y), r = uint2(min(t.x + step, size.x - 1u), t.y);
    uint2 d = uint2(t.x, max(int(t.y) - int(step), 0)), b = uint2(t.x, min(t.y + step, size.y - 1u));
    float2 texel = u.low.zw / float2(size);
    float z = fines.read(t).r;
    float dzdx = (fines.read(r).r - fines.read(l).r) / (float(r.x - l.x) * texel.x);
    // Rows run down the image, so up the y axis is the row before.
    float dzdy = (fines.read(d).r - fines.read(b).r) / (float(b.y - d.y) * texel.y);
    FinesOut o;
    o.world = float3(heightTexelWorld(t, size, u), z);
    // A lumpy surface, not a plane.
    o.world.z += 0.12f * (fbm3(o.world * float3(1.6f, 1.6f, 0.5f), 2) - 0.45f);
    o.normal = normalize(float3(-dzdx, -dzdy, 1.0f));
    o.position = cam.viewProjection * float4(o.world, 1.0f);
    return o;
}

static inline float3 stoneColour(float id) {
    RockColour rock = rockOfKind(kindFromShare(fract(id * 3.71f)));
    // Crushed shale is paler than its beds: its grit is grey, not black.
    if (rock.kind == 1) rock.fresh = mix(rock.fresh, float3(0.36f, 0.35f, 0.34f), 0.6f);
    float3 c = mix(rock.fresh, rock.oxidised, smoothstep(0.6f, 0.95f, fract(id * 11.3f)));
    return c * (0.78f + 0.3f * fract(id * 29.1f));
}

fragment float4 finesFragment(FinesOut in [[stage_in]],
                              constant QuarryCamera &cam [[buffer(0)]],
                              depth2d<float> shadowMap [[texture(0)]],
                              texture3d<float> dustLight [[texture(1)]],
                              sampler s [[sampler(0)]]) {
    float3 n = normalize(in.normal);
    // Gravel does not lie on a steep face: where the surface stands up between a ledge and the
    // floor, nothing is drawn.
    if (n.z < 0.45f) discard_fragment();
    float2 q = in.world.xy;
    float footprint = length(fwidth(q));
    float detail = 1.0f - smoothstep(0.035f, 0.12f, footprint);
    // Far off, the stones' mean: crushed rock of every bed, about as light as the blocks' faces
    // in shade (until 12 November 2026 it was a dark brown, and from the default camera the
    // fines read only as dark gaps between the blocks). Broad patches of paler and darker grit.
    float patches = fbm3(in.world * 0.35f + 19.0f, 3);
    float3 mean = float3(0.44f, 0.41f, 0.36f) * (0.85f + 0.3f * patches);
    float3 albedo = mean;
    float3 bumpedN = n;
    if (detail > 0.0f) {
        // Crushed rock at three sizes, packed: angular cells of a jittered grid with grit in the
        // gaps between them, each stone domed and tilted its own way, so that it has a lit side
        // and a shaded one under the sky as well as the sun (flat-tinted discs read as terrazzo).
        float2 toCobble, toPebble, toGrit;
        float3 cobble = stones(q / 0.22f, 5u, toCobble);
        float3 pebble = stones(q / 0.08f, 3u, toPebble);
        float3 grain = stones(q / 0.03f, 11u, toGrit);
        float cobbleGap = cobble.y - cobble.x, pebbleGap = pebble.y - pebble.x;
        bool isCobble = cobble.z < 0.3f && cobbleGap > 0.1f;
        bool isPebble = !isCobble && pebble.z < 0.8f && pebbleGap > 0.12f;
        bool isStone = isCobble || isPebble;
        float id = isCobble ? cobble.z : isPebble ? pebble.z : grain.z;
        float2 to = isCobble ? toCobble : isPebble ? toPebble : toGrit;
        float gap = isCobble ? cobbleGap : isPebble ? pebbleGap : grain.y - grain.x;
        // Each stone mottled within, as rock is.
        float mottle = fbm3(in.world * (isCobble ? 22.0f : 50.0f) + id * 40.0f, 2);
        float3 stone = stoneColour(id) * (0.8f + 0.4f * mottle);
        if (!isStone) stone *= 0.8f;
        // Darker into the crevices between stones.
        float crevice = isStone ? smoothstep(0.0f, isCobble ? 0.22f : 0.25f, gap) : 0.7f + 0.3f * smoothstep(0.0f, 0.3f, gap);
        stone *= 0.5f + 0.5f * crevice;
        float2 lean = (float2(fract(id * 47.3f), fract(id * 91.7f)) - 0.5f) * (isStone ? 0.9f : 0.4f);
        float2 dome = -to * (isStone ? 1.7f : 0.7f);
        albedo = mix(mean, stone, detail);
        bumpedN = normalize(n + float3((lean + dome) * detail, 0.0f));
    }
    float3 bumped = bumpedN;
    // Dust settles over the fines as the cloud comes down.
    float settle = saturate((cam.misc.x - 4.0f) / 7.0f);
    float coat = settle * (0.25f + 0.35f * smoothstep(0.3f, 0.7f, fbm3(in.world * 0.5f, 3)));
    albedo = mix(albedo, float3(0.5f, 0.45f, 0.38f), coat * 0.4f);
    float shadow = shadowAt(in.world, n, cam, shadowMap, s);
    float dust = dustShadow(in.world, cam, dustLight);
    return float4(shade(albedo, in.world, bumped, cam, shadow, dust), 1.0f);
}

// Decorative chips and gravel: instanced little polyhedra, not rigid bodies. Attached to their
// block until it has gone, then ballistic over the top-down height of the scene.
struct QuarryChip {
    float4 posSize;
    float4 velAge;
    float4 offsetDelay;
    uint parent;
    uint state;
    float seed;
    float tint;
};

struct QuarryChipUniforms {
    float dt;
    float gravity;
    float time;
    float heightDrawn; // 1 when the top-down height was drawn this step
    float4 low;
    float4 size;
};

// A chip that lands on a block rides it: its place in the block's frame is kept (in `velAge`, which
// a lying chip does not use otherwise: xyz the place, w the block's index plus one), so rubble on
// the moving rock is carried with it, down a flank or along the pile, rather than left hanging
// where the rock was and dropped straight down when the rock has gone. It flies off with the
// block's velocity when the block is thrown, or slides off with it when nothing is under it any
// more. A chip on the ground that the rock runs over stays under it, covered, rather than being
// lifted onto the rock.
kernel void chipUpdate(device QuarryChip *chips [[buffer(0)]],
                       const device float4 *pose [[buffer(1)]],
                       const device float4 *previous [[buffer(2)]],
                       const device float4 *rest [[buffer(4)]],
                       depth2d<float> height [[texture(0)]],
                       texture2d<float, access::read> topBlock [[texture(1)]],
                       constant QuarryChipUniforms &u [[buffer(3)]],
                       uint i [[thread_position_in_grid]]) {
    QuarryChip C = chips[i];
    if (C.state == 3u) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float dt = u.dt;
    if (C.state == 0u) {
        float4 p = pose[2 * C.parent];
        if (p.w < 0.5f) return;
        float age = C.velAge.w + dt;
        if (age < C.offsetDelay.w) { chips[i].velAge.w = age; return; }
        float3 pos = p.xyz + rotate(pose[2 * C.parent + 1], C.offsetDelay.xyz);
        // A chip leaves only from rock open to the air: one from a block still buried under the
        // rest was put up on top of it at once (the height it lands on is the top of the scene),
        // so every block down through the cut shed its chips onto the surface as a carpet of
        // flakes (until 12 November 2026, emmettl/bombcad-work#136). It waits until its block is
        // near the top, and goes with it then, if ever.
        float2 at = float2((pos.x - u.low.x) / u.size.x, 1.0f - (pos.y - u.low.y) / u.size.y);
        if (all(at >= 0.0f) && all(at <= 1.0f)) {
            float top = u.size.z - height.sample(s, at) * (u.size.z - u.size.w);
            if (pos.z < top - 1.0f) { chips[i].velAge.w = age; return; }
        }
        float3 v = (p.xyz - previous[2 * C.parent].xyz) / dt;
        float3 jitter = float3(fract(C.seed * 13.7f), fract(C.seed * 29.3f), fract(C.seed * 7.1f)) * 2.0f - 1.0f;
        v = v * 0.75f + jitter * 2.5f + float3(0, -0.6f, 1.2f);
        C.posSize.xyz = pos;
        C.velAge = float4(v, age);
        C.state = 1u;
    }
    float r = C.posSize.w;
    // Riding a block: where it has gone, and how fast.
    uint carrier = C.state == 2u ? uint(C.velAge.w) : 0u;
    float3 carried = float3(0.0f);
    if (carrier > 0u) {
        uint b = carrier - 1u;
        float4 p = pose[2 * b];
        carried = (p.xyz - previous[2 * b].xyz) / dt;
        C.posSize.xyz = p.xyz + rotate(pose[2 * b + 1], C.velAge.xyz);
        if (length(carried) > 6.0f) {
            // Thrown: off it goes with the block.
            float3 jitter = float3(fract(C.seed * 13.7f), fract(C.seed * 29.3f), fract(C.seed * 7.1f)) * 2.0f - 1.0f;
            C.velAge = float4(carried + jitter * 1.5f, 0.0f);
            C.state = 1u;
            carrier = 0u;
        }
    }
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
    if (any(uv < 0.0f) || any(uv > 1.0f)) { C.state = 0u; C.offsetDelay.w = 1e9f; chips[i] = C; return; }
    float h = u.size.z - height.sample(s, uv) * (u.size.z - u.size.w);
    float onTop = h + r * 0.6f;
    if (C.state == 1u && C.posSize.z <= onTop) {
        // What it lands on: the ground, or a block still close enough to be the one under it (the
        // height may be a few frames old, and the block gone on since: then it falls on through
        // until the height is drawn again, rather than coming to rest in the air where the block
        // was and dropping from there).
        uint2 size = uint2(topBlock.get_width(), topBlock.get_height());
        uint2 texel = min(uint2(uv * float2(size)), size - 1u);
        uint under = uint(topBlock.read(texel).b + 0.5f);
        if (under == 0u) {
            C.posSize.z = onTop;
            C.velAge = float4(0.0f);
            C.state = 2u;
        } else {
            float4 p = pose[2 * (under - 1u)];
            float3 at = float3(C.posSize.xy, onTop);
            if (distance(p.xyz, at) < rest[under - 1u].w + 1.0f) {
                C.posSize.z = onTop;
                C.velAge = float4(unrotate(pose[2 * (under - 1u) + 1], at - p.xyz), float(under));
                C.state = 2u;
            }
        }
    } else if (C.state == 2u && carrier > 0u) {
        // Nothing under it any more where it rides: it slides off with the block's motion.
        if (u.heightDrawn > 0.5f && C.posSize.z > onTop + 0.8f) {
            C.velAge = float4(carried, 0.0f);
            C.state = 1u;
        }
    } else if (C.state == 2u) {
        // On the ground: lifted a little where the surface has risen a little, left covered where
        // the rock has run over it, and falling where what held it has gone.
        if (C.posSize.z < onTop && onTop - C.posSize.z < 0.5f) C.posSize.z = onTop;
        else if (C.posSize.z > onTop + 0.8f) {
            C.state = 1u;
            C.velAge = float4(0.0f);
        }
    }
    chips[i] = C;
}

struct ChipOut {
    float4 position [[position]];
    float3 world;
    float3 albedo [[flat]];
};

// A unit quaternion from three values in 0...1, uniform over rotations.
static inline float4 randomRotation(float3 u) {
    float a = sqrt(1.0f - u.x), b = sqrt(u.x);
    return float4(a * sin(6.2832f * u.y), a * cos(6.2832f * u.y), b * sin(6.2832f * u.z), b * cos(6.2832f * u.z));
}

// Each chip is one of `QuarryDecor.shapeCount` small convex stones (`chipShapes`, 36 vertices of
// up to 12 triangles each), turned its own way: tumbling while it flies, lying with its flat side
// more or less down once it has landed.
static inline float4 chipPosition(QuarryChip c, uint vid, constant QuarryCamera &cam, float4x4 m,
                                  const device float4 *shapes, thread float3 &world) {
    uint shape = uint(fract(c.seed * 61.73f) * 32.0f) & 31u;
    float3 v = shapes[shape * 36u + vid].xyz;
    float3 stretch = float3(0.85f + 0.3f * fract(c.seed * 91.0f), 0.85f + 0.3f * fract(c.seed * 53.0f), 0.85f + 0.3f * fract(c.seed * 37.0f));
    float size = c.state == 0u ? 0.0f : c.posSize.w;
    float3 p = v * stretch * size * 1.15f;
    float yaw = c.seed * 40.0f;
    float tilt = (fract(c.seed * 17.3f) - 0.5f) * 0.6f;
    if (c.state == 1u) {
        // In the air: any way round, and turning.
        float4 q = randomRotation(float3(fract(c.seed * 7.31f), fract(c.seed * 3.17f + cam.misc.x * 0.9f), fract(c.seed * 11.9f + cam.misc.x * 0.6f)));
        p = rotate(q, p);
    } else {
        float ct = cos(tilt), st = sin(tilt);
        p = float3(p.x, ct * p.y - st * p.z, st * p.y + ct * p.z);
    }
    float ca = cos(yaw), sa = sin(yaw);
    p = float3(ca * p.x - sa * p.y, sa * p.x + ca * p.y, p.z);
    world = c.posSize.xyz + p;
    return m * float4(world, 1.0f);
}

vertex ChipOut chipVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                          const device QuarryChip *chips [[buffer(0)]],
                          constant QuarryCamera &cam [[buffer(2)]],
                          const device float4 *rest [[buffer(3)]],
                          const device float4 *shapes [[buffer(5)]]) {
    QuarryChip c = chips[instance];
    ChipOut o;
    o.position = chipPosition(c, vid, cam, cam.viewProjection, shapes, o.world);
    // Broken off its own block, so of its bed: mostly fresh, some from the weathered rock near the
    // surface.
    RockColour rock = rockAt(rest[c.parent].xyz + c.offsetDelay.xyz * 0.8f);
    if (rock.kind == 1) rock.fresh = mix(rock.fresh, float3(0.34f, 0.33f, 0.32f), 0.4f);
    o.albedo = mix(rock.fresh, rock.oxidised, smoothstep(0.55f, 0.95f, c.tint)) * (0.75f + 0.4f * fract(c.seed * 17.0f));
    return o;
}

vertex float4 chipShadowVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                               const device QuarryChip *chips [[buffer(0)]],
                               constant QuarryCamera &cam [[buffer(2)]],
                               const device float4 *shapes [[buffer(5)]]) {
    QuarryChip c = chips[instance];
    float3 w;
    return chipPosition(c, vid, cam, cam.shadow, shapes, w);
}

fragment float4 chipFragment(ChipOut in [[stage_in]],
                             constant QuarryCamera &cam [[buffer(0)]],
                             depth2d<float> shadowMap [[texture(0)]],
                             texture3d<float> dustLight [[texture(1)]],
                             sampler s [[sampler(0)]]) {
    float3 n = normalize(cross(dfdx(in.world), dfdy(in.world)));
    if (dot(n, cam.eye.xyz - in.world) < 0.0f) n = -n;
    float shadow = shadowAt(in.world, n, cam, shadowMap, s);
    return float4(shade(in.albedo, in.world, n, cam, shadow, dustShadow(in.world, cam, dustLight)), 1.0f);
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
static inline float3 aoWorld(float2 uv, depth2d<float> depth, constant QuarryCamera &cam) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float d = depth.sample(s, uv);
    float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
    float4 w = cam.inverseViewProjection * float4(ndc, d, 1.0f);
    return w.xyz / w.w;
}

fragment float4 aoFragment(FullscreenOut in [[stage_in]],
                           depth2d<float> depth [[texture(0)]],
                           constant QuarryCamera &cam [[buffer(0)]]) {
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
fragment float4 skyFragment(SkyOut in [[stage_in]], constant QuarryCamera &cam [[buffer(0)]]) {
    float4 far = cam.inverseViewProjection * float4(in.ndc, 1.0f, 1.0f);
    float3 dir = normalize(far.xyz / far.w - cam.eye.xyz);
    return float4(backdrop(dir, cam), 1.0f);
}

fragment float4 tonemap(FullscreenOut in [[stage_in]],
                        texture2d<float> hdr [[texture(0)]],
                        sampler s [[sampler(0)]],
                        constant QuarryCamera &cam [[buffer(0)]]) {
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

// The play window's presentation: its offscreen frame, scaled to the view.
fragment float4 presentFragment(FullscreenOut in [[stage_in]],
                                texture2d<float> frame [[texture(0)]],
                                sampler s [[sampler(0)]]) {
    return frame.sample(s, in.uv);
}


// The dust ray-marched over the frame.

struct QuarryDustUniforms {
    float4 low;
    float4 hdtsteps; // h, dt
    int4 dims;
    float4 wind;
    float4 sun;
    float4 high;
};

constexpr sampler triSampler(filter::linear, address::clamp_to_edge, coord::normalized);

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
                             constant QuarryCamera &cam [[buffer(0)]],
                             constant QuarryDustUniforms &u [[buffer(1)]]) {
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
    float3 albedo = float3(0.62f, 0.53f, 0.42f);
    float mu = dot(dir, cam.sun.xyz);
    float g = 0.45f;
    float hgForward = (1.0f - g * g) / pow(1.0f + g * g - 2.0f * g * mu, 1.5f) * 0.25f;
    float g2 = -0.15f;
    float hgBack = (1.0f - g2 * g2) / pow(1.0f + g2 * g2 - 2.0f * g2 * mu, 1.5f) * 0.25f;
    float phase = 0.75f * hgForward + 0.45f * hgBack;
    float3 sunColor = float3(1.0f, 0.72f, 0.46f) * 5.2f;
    float3 ambientUp = float3(0.42f, 0.5f, 0.68f) * 0.42f;
    float3 ambientDown = float3(0.62f, 0.5f, 0.38f) * 0.42f;
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
            float tau = light.sample(triSampler, p).r * 0.075f;
            // Light scattered many times in dust is lost slowly: an octave sum of attenuations,
            // each weaker and less extinguished, so the shadowed underside stays pale and glows.
            float direct = exp(-tau) + 0.32f * exp(-tau * 0.25f) + 0.14f * exp(-tau * 0.06f);
            float heightFrac = saturate(p.z * 2.0f);
            float3 ambient = mix(ambientDown, ambientUp, heightFrac) * (0.6f + 0.4f * exp(-tau * 0.4f));
            float3 lit = albedo * (sunColor * phase * direct + ambient);
            accumulated += transmittance * a * lit;
            transmittance *= 1.0f - a;
            if (transmittance < 0.01f) break;
        }
        t += step;
    }
    return float4(accumulated, 1.0f - transmittance);
}

// A ridge cut's dust's phase function (the face's march's, above in it): forward scattering with
// a little back, for the cosine `mu` between the view and the sun.
static inline float ridgeDustPhase(float mu) {
    float g = 0.45f;
    float hgForward = (1.0f - g * g) / pow(1.0f + g * g - 2.0f * g * mu, 1.5f) * 0.25f;
    float g2 = -0.15f;
    float hgBack = (1.0f - g2 * g2) / pow(1.0f + g2 * g2 - 2.0f * g2 * mu, 1.5f) * 0.25f;
    return 0.75f * hgForward + 0.45f * hgBack;
}

// A ridge cut's dust's colour where the sun is `tau` deep in dust (stage 3i, emmettl/bombcad-work#143),
// `heightFrac` up the dust box. Sunlit dust scatters nearly all it takes, so in a thick cloud the
// sun's light is not lost as it goes in but diffuses through, falling off slowly (as a slab's
// diffuse transmission does, 1 / (1 + k tau), rather than as exp(-tau); k chosen by eye). The
// light scattered once keeps its phase (bright rims toward the sun); the diffused light is spread
// evenly. With the face's octave sum of exponentials instead, the cloud's shaded parts went near
// black where the sun was only 3 to 10 deep (most of the cloud's core from 3 s on).
static inline float3 ridgeDustLit(float tau, float phase, float heightFrac) {
    float3 albedo = float3(0.62f, 0.53f, 0.42f);
    float3 sunColor = float3(1.0f, 0.72f, 0.46f) * 5.2f;
    float3 ambientUp = float3(0.42f, 0.5f, 0.68f) * 0.42f;
    float3 ambientDown = float3(0.62f, 0.5f, 0.38f) * 0.42f;
    float single = exp(-tau);
    float diffused = 0.8f / (1.0f + 0.15f * tau);
    float3 ambient = mix(ambientDown, ambientUp, heightFrac) * (0.75f + 0.25f * exp(-tau * 0.3f));
    return albedo * (sunColor * (phase * single + 0.25f * diffused) + ambient);
}

// A ridge cut's billows (stage 3j, emmettl/bombcad-work#144): lobes of the dust's own baked noise
// (inverted Worley in three octaves, lobes of 3.2, 1.6 and 0.8 m here: rounded, bright at their
// middles and creased between), looked up at the mip level a pixel holds (`foot`, metres a pixel
// where they are drawn), so nothing finer than the screen can show is drawn. Looked up once a
// pixel at the place the dust is seen, not in the march, whose 0.9 m steps alias anything finer
// (stage 3i's grain). Carried with the dust's own flow in two phases half a second apart,
// crossfaded, so the lobes rise and roll with the cloud rather than stand while it moves through.
constant float ridgeBillowTile = 25.6f;
// Thin dust's extinction a metre and unit of density, as haze (stage 3k).
constant float ridgeHaze = 0.03f;

static inline float ridgeBillowAt(texture3d<float, access::sample> noise, float3 p, float lod) {
    constexpr sampler mipped(filter::linear, mip_filter::linear, address::repeat);
    // The lobes at two sizes: 3.2 m down to 0.8 m, and three times that, so a puff's outline
    // bulges in big lobes and those break into small ones.
    float small = noise.sample(mipped, p / ridgeBillowTile, level(lod)).r;
    float big = noise.sample(mipped, p / (3.0f * ridgeBillowTile) + 0.37f, level(max(lod - 1.585f, 0.0f))).r;
    return 0.55f * small + 0.45f * big;
}

static inline float ridgeBillow(texture3d<float, access::sample> noise, float3 p, float3 flow, float time, float foot) {
    float lod = max(0.0f, log2(foot * 1.5f / (ridgeBillowTile / 128.0f)));
    float phase = fract(time);
    float a = ridgeBillowAt(noise, p - flow * phase, lod);
    float b = ridgeBillowAt(noise, p - flow * fract(phase + 0.5f) + float3(11.7f, 5.3f, 7.9f), lod);
    float wa = 1.0f - abs(2.0f * phase - 1.0f), wb = 1.0f - wa;
    // Crossfaded so the contrast holds through the blend; the noise's mean is about 0.55.
    float n = 0.55f + (wa * (a - 0.55f) + wb * (b - 0.55f)) / max(sqrt(wa * wa + wb * wb), 1e-3f);
    return saturate((n - 0.3f) / 0.5f);
}

// A ridge cut's march (stage 3f): the face's (`dustFragment`, above) with its lookup warped less,
// 3.3 m rather than 5.5 m: warped further, its thin jets off the heaving rock showed as loose
// patches lying over the rock. A copy rather than a shared function, because the face's march
// compiled through a shared function (or with a branch in it) came out a level different in a
// few pixels, and the face is kept byte for byte as it was.
fragment float4 dustFragmentRidge(FullscreenOut in [[stage_in]],
                                  texture3d<float, access::sample> density [[texture(0)]],
                                  texture3d<float, access::sample> light [[texture(1)]],
                                  depth2d<float, access::sample> depth [[texture(2)]],
                                  texture3d<float, access::sample> noise [[texture(3)]],
                                  texture3d<float, access::sample> flowField [[texture(4)]],
                                  constant QuarryCamera &cam [[buffer(0)]],
                                  constant QuarryDustUniforms &u [[buffer(1)]]) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    constexpr sampler wrap(filter::linear, address::repeat);
    float z = depth.sample(nearest, in.uv);
    float2 ndc = float2(in.uv.x * 2.0f - 1.0f, 1.0f - in.uv.y * 2.0f);
    float4 far = cam.inverseViewProjection * float4(ndc, z, 1.0f);
    float3 hit = far.xyz / far.w;
    float3 eye = cam.eye.xyz;
    float maxT = length(hit - eye);
    float3 dir = (hit - eye) / max(maxT, 1e-3f);
    // The angle a pixel spans, for the billows' finest lobes (before any return: a derivative).
    float3 pixelRay = normalize(far.xyz / far.w - eye);
    float pixelAngle = max(length(dfdx(pixelRay)), length(dfdy(pixelRay)));
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
    float phase = ridgeDustPhase(dot(dir, cam.sun.xyz));
    int quiet = 0;
    bool stepping = false;
    float tt = cam.misc.x;
    // Where the dust is seen: its points weighted by what each gives the pixel.
    float3 seenSum = float3(0.0f);
    float seenWeight = 0.0f;
    for (int steps = 0; steps < 900 && t < leave; ++steps) {
        // The coarse search lands its last probe just short of the surface the ray ends on, so
        // dust lying on the rock (shed by it, or left over the heap) is found by every pixel; it
        // was found only by the pixels whose jittered 2 m probes fell in it, which speckled the
        // dust over the heap with the dark rock behind.
        float step = stepping ? fine : min(coarse, max(leave - 0.05f - t, 0.05f));
        float3 world = eye + dir * t;
        float3 p = (world - low) / size;
        float d = density.sample(triSampler, p).r;
        float shaped = 0.0f;
        float3 lp = p;
        if (d > 0.004f) {
            if (!stepping) { stepping = true; t = max(enter, t - coarse * 0.9f); quiet = 0; continue; }
            float dn = 1.0f - exp(-d * 0.42f);
            // Warp the lookup so the field's own smooth shape breaks up, then cut the lumps with
            // the noise, more where the field is thin. The warp is in two scales (stage 3i): 3.3 m
            // of a slow one (features of 2 m and more), which billows the cloud, and 1.2 m of the
            // fine one. The fine one alone at 3.3 m turned faster than the march's 0.9 m steps
            // sample it, so each pixel drew a random handful of the field within 3 m: the dust
            // thin over the heap came out as a speckle of dust and rock, dark grain in the cloud.
            float3 warpSample = noise.sample(wrap, world * 0.05f + float3(0.012f * tt, 0.0f, -0.02f * tt)).rgb;
            float3 wq = world * 0.016f + float3(0.004f * tt, 0.0f, -0.0065f * tt);
            float3 warpSlow = float3(noise.sample(wrap, wq).r, noise.sample(wrap, wq + float3(0.37f, 0.61f, 0.23f)).r,
                                     noise.sample(wrap, wq * 0.5f + float3(0.71f, 0.13f, 0.47f)).g);
            float3 warped = (world + (warpSlow * 2.0f - 1.0f) * float3(3.3f, 3.3f, 3.9f)
                             + (warpSample * 2.0f - 1.0f) * 1.2f - low) / size;
            float dw = density.sample(triSampler, warped).r;
            lp = warped;
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
        // Haze (stage 3k, emmettl/bombcad-work#145): thin dust, which the noise's cut above leaves
        // out, still dims and lights the ray a little, so a cloud that has thinned and spread
        // stays on view as a haze rather than vanishing.
        float haze = stepping ? ridgeHaze * min(d, 1.5f) * (1.0f - shaped) : 0.0f;
        if (shaped > 0.001f || haze > 1e-4f) {
            quiet = 0;
            float sigma = shaped * (d * 0.12f + 0.55f) + haze;
            float a = 1.0f - exp(-sigma * min(step, leave - t));
            // The sun's optical depth where the dust is drawn: at the warped lookup, the same as
            // its density's, so a puff's sunward side is lit by its own shape and not by the
            // field's unwarped shape a few metres off (which left dark blotches on lit dust).
            float tau = light.sample(triSampler, lp).r * 0.075f;
            float3 lit = ridgeDustLit(tau, phase, saturate(p.z * 2.0f));
            accumulated += transmittance * a * lit;
            seenSum += transmittance * a * world;
            seenWeight += transmittance * a;
            transmittance *= 1.0f - a;
            if (transmittance < 0.01f) break;
        }
        t += step;
    }
    float alpha = 1.0f - transmittance;
    if (alpha < 0.002f) return float4(accumulated, alpha);
    // Billows (stage 3j, emmettl/bombcad-work#144). The march's field is smooth at its 1.5 m
    // cells, so its puffs came out as round cotton-wool balls. Here, once a pixel at the place the
    // dust is seen, lobes of billow noise carried with the dust's flow cut the dust's depth at a
    // puff's edges (they tear into lobes and thin into haze; the core is left), mottle thin dust,
    // and shade thick dust (creases between lobes darker, lobes lit on their sunward side).
    float3 seen = seenSum / max(seenWeight, 1e-5f);
    float foot = pixelAngle * length(seen - eye);
    float3 ps = (seen - low) / size;
    // The wind is in the flow itself (stage 3k).
    float3 flow = flowField.sample(triSampler, ps).xyz;
    // Held to 5 m/s: faster, the flow's change across a puff smeared the lobes within a phase.
    flow *= min(1.0f, 5.0f / max(length(flow), 1e-3f));
    float lobes = ridgeBillow(noise, seen, flow, tt, foot);
    // Across the line of sight (the seen point is only good to a step along it): toward the sun
    // as the screen shows it, and square to that.
    float3 across = cam.sun.xyz - dir * dot(cam.sun.xyz, dir);
    float acrossLength = length(across);
    float3 e1 = acrossLength > 0.05f ? across / acrossLength : normalize(cross(dir, float3(0.0f, 0.0f, 1.0f)));
    float reach = max(0.45f, 2.0f * foot);
    float towardSun = ridgeBillow(noise, seen + e1 * reach, flow, tt, foot);
    // A lobe brighter on its side toward the sun, by how far across the screen the sun stands.
    float lit = (towardSun - lobes) * saturate(acrossLength * 1.5f);
    float opticalDepth = -log(max(transmittance, 1e-4f));
    // The edges of thick dust tear into lobes; thin dust (a veil, or the haze round a puff) is left.
    float cut = 2.4f * (1.0f - lobes) * smoothstep(0.5f, 2.0f, opticalDepth);
    float kept = max(opticalDepth - cut, 0.0f) + 0.3f * min(opticalDepth, cut);
    // Thin dust (a veil running over the rock, the haze round a puff) is mottled by the same lobes,
    // so it rolls rather than lying as an even sheet.
    kept *= mix(1.0f, mix(0.45f, 1.35f, lobes), 1.0f - smoothstep(0.5f, 2.0f, opticalDepth));
    float alphaKept = 1.0f - exp(-kept);
    float body = smoothstep(0.3f, 2.0f, opticalDepth);
    float crease = mix(0.68f, 1.1f, smoothstep(0.15f, 0.85f, lobes));
    float3 shaded = accumulated * (alphaKept / alpha) * mix(1.0f, crease * (1.0f - 1.6f * lit), body);
    return float4(max(shaded, 0.0f), alphaKept);
}


// A ridge cut's crack jets (stage 3i, emmettl/bombcad-work#143): thin spurts finer than the dust
// field's cells, each a streak facing the eye from the crack's top along the jet (`QuarryDustField.Jet`),
// drawn over the scene before the dust's march, so the cloud veils them. Grit in streaks that run
// up the jet, pulsing, thinning and widening toward the tip; lit as the ridge's dust is.
struct QuarryJet {
    float4 base;  // the crack's top; w strength
    float4 axis;  // direction times length; w half-width at the base
    float4 shape; // x a draw, y age (s), z half-width at the tip
};

struct JetOut {
    float4 position [[position]];
    float3 world;
    float2 uv;
    float strength;
    float seed;
    float age;
    float length;
};

vertex JetOut jetVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                        const device QuarryJet *jets [[buffer(0)]],
                        constant QuarryCamera &cam [[buffer(1)]]) {
    QuarryJet j = jets[instance];
    float2 corner = float2(vid == 1 || vid == 2 || vid == 4 ? 1.0f : -1.0f, vid == 2 || vid == 4 || vid == 5 ? 1.0f : 0.0f);
    float reach = max(length(j.axis.xyz), 1e-3f);
    float3 dir = j.axis.xyz / reach;
    // Begun a little inside the crack, so it comes out of the rock rather than off its face.
    float3 p = j.base.xyz - dir * 0.25f + j.axis.xyz * corner.y;
    float3 side = cross(dir, cam.eye.xyz - p);
    float sideLength = length(side);
    side = sideLength > 1e-4f ? side / sideLength : float3(1.0f, 0.0f, 0.0f);
    p += side * mix(j.axis.w, j.shape.z, corner.y) * corner.x;
    JetOut out;
    out.position = cam.viewProjection * float4(p, 1.0f);
    out.world = p;
    out.uv = corner;
    // Seen end on (from above, close in) a jet's streak is foreshortened to a pale fan lying on
    // the rock (stage 3j): faded as it turns toward the eye. Constant over the jet, from its base.
    float3 toEye = cam.eye.xyz - j.base.xyz;
    float sideOn = length(cross(dir, toEye)) / max(length(toEye), 1e-3f);
    out.strength = j.base.w * smoothstep(0.45f, 0.8f, sideOn);
    out.seed = j.shape.x;
    out.age = j.shape.y;
    out.length = reach;
    return out;
}

fragment float4 jetFragment(JetOut in [[stage_in]],
                            texture3d<float> dustLight [[texture(0)]],
                            constant QuarryCamera &cam [[buffer(0)]]) {
    float u = in.uv.x, v = in.uv.y;
    float metres = v * in.length;
    float s = in.seed * 61.0f;
    // Spurts: packets of grit a metre or two apart running up the jet faster than it grows, so
    // it reads as gusts thrown out of the crack rather than a steady rod; streaks along it, and
    // ragged sides.
    float packets = 0.5f + 0.5f * sin(6.2831853f * (metres * 0.55f - in.age * 3.1f + in.seed));
    packets = packets * packets * (3.0f - 2.0f * packets);
    float streak = noise3(float3(u * 2.6f + s, metres * 0.9f - in.age * 9.0f, s));
    float ragged = noise3(float3(u * 1.3f - s, metres * 1.7f - in.age * 6.0f, s + 7.0f));
    // The core wanders across the streak and its width swells and narrows, so its sides are
    // ragged rather than the quad's straight edges.
    float wander = (noise3(float3(metres * 0.6f - in.age * 5.0f, s, 2.0f)) - 0.5f) * 0.7f * v;
    float across = (u - wander) / max(0.25f, 0.2f + 0.8f * ragged);
    float core = exp(-across * across * 4.5f);
    // Thrown in from the crack, breaking into wisps toward the tip.
    float along = smoothstep(0.0f, 0.1f, v) * (1.0f - v) * (1.0f - v);
    float wisps = smoothstep(0.25f * v, 0.25f * v + 0.45f, streak);
    float density = core * along * wisps * (0.25f + 0.75f * packets) * in.strength;
    float alpha = 1.0f - exp(-density * 3.0f);
    if (alpha < 0.003f) discard_fragment();
    float3 uvw = (in.world - cam.dustLow.xyz) / (cam.dustHigh.xyz - cam.dustLow.xyz);
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float tau = dustLight.sample(linear, uvw).r * 0.075f;
    float3 dir = normalize(in.world - cam.eye.xyz);
    float3 lit = ridgeDustLit(tau, ridgeDustPhase(dot(dir, cam.sun.xyz)), saturate(uvw.z * 2.0f));
    return float4(lit * alpha, alpha);
}

fragment float4 dustComposite(FullscreenOut in [[stage_in]],
                              texture2d<float> dust [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    return dust.sample(s, in.uv);
}


// --- A ridge cut's flanks as ground (emmettl/bombcad-work#135) ---
// Illustrative, for the eye: the ground's cover (`QuarryFlank`: scree, grass, rock, the cut, on a
// 1 m grid over the dressing's area in `cam.terrainOrigin`), drawn as stony, grassy or rocky ground
// with detail that fades with the pixel's footprint; and the scree's stones and the scrub as
// render-only instances. A face's ground keeps `terrainFragment`.

// Loose stones packed on the ground: weathered rock of every bed, darker in the crevices, each
// domed and leaning its own way. `detail` is how much of the close detail to draw.
static inline float3 screeGround(float2 q, float3 world, float detail, thread float3 &tilt) {
    // Talus is mostly gravel and grit, streaked paler and darker down the slope, with stones in it.
    float streak = fbm3(world * float3(0.9f, 0.9f, 0.25f) + 3.0f, 3);
    float3 mean = mix(float3(0.3f, 0.28f, 0.25f), float3(0.46f, 0.42f, 0.36f), streak) * (0.85f + 0.3f * fbm3(world * 0.15f + 8.0f, 2));
    tilt = float3(0.0f);
    if (detail <= 0.0f) return mean;
    float2 toCobble, toPebble;
    float3 cobble = stones(q / 0.26f, 21u, toCobble);
    float3 pebble = stones(q / 0.09f, 23u, toPebble);
    float cobbleGap = cobble.y - cobble.x, pebbleGap = pebble.y - pebble.x;
    bool isCobble = cobble.z < 0.16f && cobbleGap > 0.1f;
    bool isPebble = !isCobble && pebble.z < 0.4f && pebbleGap > 0.14f;
    float3 matrixColour = mean * (0.7f + 0.6f * hash31(floor(world * 40.0f))) * (0.85f + 0.3f * fbm3(world * 6.0f, 2));
    if (!isCobble && !isPebble) {
        tilt = float3((float2(hash31(floor(world * 40.0f) + 3.0f), hash31(floor(world * 40.0f) + 9.0f)) - 0.5f) * 0.35f * detail, 0.0f);
        return mix(mean, matrixColour, detail);
    }
    float id = isCobble ? cobble.z : pebble.z;
    float2 to = isCobble ? toCobble : toPebble;
    float gap = isCobble ? cobbleGap : pebbleGap;
    RockColour rock = rockOfKind(kindFromShare(fract(id * 3.71f)));
    if (rock.kind == 1) rock.patina = mix(rock.patina, float3(0.33f, 0.32f, 0.3f), 0.6f);
    float3 stone = mix(rock.patina, rock.oxidised, 0.3f + 0.5f * fract(id * 11.3f)) * (0.85f + 0.35f * fract(id * 29.1f));
    stone *= 0.85f + 0.3f * fbm3(world * (isCobble ? 18.0f : 40.0f) + id * 40.0f, 2);
    float crevice = smoothstep(0.0f, isCobble ? 0.2f : 0.25f, gap);
    stone = mix(matrixColour * 0.6f, stone, crevice);
    float2 lean = (float2(fract(id * 47.3f), fract(id * 91.7f)) - 0.5f) * 0.7f;
    tilt = float3((lean - to * 1.2f) * detail * crevice, 0.0f);
    return mix(mean, stone, detail);
}

// Dry grass in tussocks with soil between, straw and olive in patches, and blades as speckle close
// in.
static inline float3 grassGround(float3 world, float detail, thread float3 &tilt) {
    float patch = fbm3(world * 0.32f + 41.0f, 3);
    float small = fbm3(world * 1.3f + 7.0f, 2);
    float3 straw = float3(0.5f, 0.43f, 0.26f);
    float3 olive = float3(0.27f, 0.28f, 0.13f);
    float3 brown = float3(0.34f, 0.27f, 0.16f);
    float3 colour = mix(mix(straw, olive, smoothstep(0.35f, 0.65f, patch)), brown, smoothstep(0.55f, 0.75f, small) * 0.5f);
    tilt = float3(0.0f);
    float3 mean = colour * 0.85f;
    if (detail <= 0.0f) return mean;
    // Tussocks a few decimetres across, irregular, with bare soil between.
    float3 p = world * 3.4f + 17.0f;
    float clump = fbm3(p, 3);
    float e = 0.12f;
    float2 slope = float2(fbm3(p + float3(e, 0.0f, 0.0f), 3) - clump, fbm3(p + float3(0.0f, e, 0.0f), 3) - clump) / e;
    float tuft = smoothstep(0.32f, 0.55f, clump);
    float blades = noise3(world * float3(42.0f, 42.0f, 42.0f));
    float3 grass = colour * (0.62f + 0.55f * blades) * (0.9f + 0.25f * hash31(floor(world * 70.0f)));
    float3 soil = float3(0.21f, 0.18f, 0.14f) * (0.8f + 0.4f * hash31(floor(world * 30.0f)));
    float3 c = mix(soil, grass, 0.3f + 0.7f * tuft);
    tilt = float3(-slope * 0.35f * detail, 0.0f);
    return mix(mean, c, detail);
}

fragment float4 ridgeTerrainFragment(TerrainOut in [[stage_in]],
                                     constant QuarryCamera &cam [[buffer(0)]],
                                     depth2d<float> shadowMap [[texture(0)]],
                                     texture3d<float> dustLight [[texture(1)]],
                                     texture2d<float> cover [[texture(2)]],
                                     sampler s [[sampler(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float3 world = in.world;
    float3 n = normalize(in.normal);
    float slope = 1.0f - n.z;
    float2 uv = (world.xy - cam.terrainOrigin.xy) / cam.terrainOrigin.zw;
    // The map fades out over its last 15 m into the far ground's own cover.
    float2 edge = min(uv, 1.0f - uv) * cam.terrainOrigin.zw;
    float inside = smoothstep(0.0f, 15.0f, min(edge.x, edge.y));
    float4 c = inside > 0.0f ? cover.sample(linear, saturate(uv)) : float4(0.0f);
    // The grass and scree read a couple of metres off, by noise, so their edges come in lobes and
    // tongues rather than following the 1 m map's lines (emmettl/bombcad-work#138).
    float2 lobes = float2(fbm3(world * 0.13f + 2.0f, 3), fbm3(world * 0.13f + 9.0f, 3)) - 0.44f;
    float2 lobed = (world.xy + lobes * 7.0f - cam.terrainOrigin.xy) / cam.terrainOrigin.zw;
    float4 cl = inside > 0.0f ? cover.sample(linear, saturate(lobed)) : float4(0.0f);
    c.rg = cl.rg;
    float broad = fbm3(world * 0.035f, 3);
    float wander = fbm3(world * 0.45f + 13.0f, 3) - 0.45f;
    // The far ground: dry grass in broad patches, darker scrub, paler bare ground and a little scree on
    // the steeper slopes, so the plain is not one flat colour.
    float far1 = fbm3(world * 0.008f + 3.0f, 4);
    float far2 = fbm3(world * 0.05f + 1.0f, 3);
    float farGrass = smoothstep(0.32f, 0.55f, far1 + 0.25f * far2) * smoothstep(0.55f, 0.25f, slope);
    float farScree = smoothstep(0.3f, 0.5f, slope) * 0.6f;
    float grassAmount = mix(farGrass, c.g, inside);
    float screeAmount = mix(farScree, c.r, inside);
    float rockAmount = c.b * inside;
    float cutAmount = c.a * inside;
    // The cover map is 1 m: its edges are broken up so they never show as squares or blurs.
    grassAmount = smoothstep(0.2f, 0.65f, grassAmount + 0.35f * wander);
    screeAmount = smoothstep(0.12f, 0.6f, screeAmount + 0.45f * (fbm3(world * 0.6f + 5.0f, 4) - 0.45f));
    float2 q = world.xy;
    float footprint = length(fwidth(q));
    float detail = 1.0f - smoothstep(0.03f, 0.11f, footprint);
    float3 screeTilt, grassTilt;
    float3 scree = screeGround(q, world, detail, screeTilt);
    float3 grassy = grassGround(world, detail, grassTilt);
    // Bare soil with grit, and pale bare patches on the far ground.
    float soilDetail = fbm3(world * 2.2f, 4);
    float3 soil = mix(float3(0.2f, 0.17f, 0.13f), float3(0.34f, 0.28f, 0.2f), soilDetail * 0.8f + 0.1f);
    soil *= 0.7f + 0.6f * broad;
    // Mottled at a hand's breadth too, which still shows where the finer detail has faded.
    soil *= 0.82f + 0.36f * fbm3(world * 7.0f + 4.0f, 2);
    float grit = step(0.8f, hash31(floor(world * 9.0f))) * detail;
    soil = mix(soil, float3(0.46f, 0.42f, 0.35f), grit * 0.4f);
    // Close in, the soil's own fine gravel.
    soil = mix(soil, scree * 0.85f, 0.5f * detail);
    float bare = smoothstep(0.6f, 0.75f, fbm3(world * 0.02f + 11.0f, 3)) * (1.0f - inside);
    soil = mix(soil, float3(0.47f, 0.41f, 0.32f), bare * 0.5f);
    // Rock: the beds' weathered colours, dark where the steep ground stands behind the render-only
    // rock.
    float3 rock = mix(float3(0.17f, 0.16f, 0.13f), bedColour(world, footprint) * 0.95f, smoothstep(0.25f, 0.8f, soilDetail));
    rock *= mix(1.0f, 0.35f, smoothstep(0.35f, 0.6f, slope) * max(rockAmount, cutAmount));
    float3 albedo = soil;
    float3 tilt = float3((fbm3(world * 3.0f + 2.0f, 2) - 0.45f) * 0.3f, (fbm3(world * 3.0f + 9.0f, 2) - 0.45f) * 0.3f, 0.0f) * detail;
    albedo = mix(albedo, grassy, grassAmount);
    tilt = mix(tilt, grassTilt, grassAmount);
    albedo = mix(albedo, scree, screeAmount);
    tilt = mix(tilt, screeTilt, screeAmount);
    // Darker scrub far off, where the instances are not.
    float scrub = smoothstep(0.62f, 0.75f, fbm3(world * 0.09f + 7.0f, 3)) * grassAmount * (1.0f - inside);
    albedo = mix(albedo, float3(0.12f, 0.12f, 0.06f), scrub * 0.6f);
    float rocky = max(rockAmount * 0.85f, cutAmount);
    albedo = mix(albedo, mix(rock, scree * 0.8f, 0.35f + 0.4f * detail), rocky);
    tilt *= 1.0f - rocky * 0.6f;
    float fade = saturate(1.0f - length(world - cam.eye.xyz) / 600.0f);
    float3 surface = bumped(normalize(n + tilt), world, 1.1f, 0.12f * fade, 3);
    float shadow = shadowAt(world, n, cam, shadowMap, s);
    float dust = dustShadow(world, cam, dustLight);
    return float4(shade(albedo, world, surface, cam, shadow, dust), 1.0f);
}

// A face's talus apron past the strip's ends (`QuarryFace.footApron`, emmettl/bombcad-work#142):
// grit and stones fallen from the face and banked against its foot, easing into the floor at its
// toe. Render-only.
struct ApronVertex { packed_float3 p; packed_float3 n; float up; };
struct ApronOut { float4 position [[position]]; float3 world; float3 normal; float up; };

vertex ApronOut apronVertex(uint vid [[vertex_id]],
                            const device ApronVertex *vertices [[buffer(0)]],
                            constant QuarryCamera &cam [[buffer(2)]]) {
    ApronOut o;
    o.world = float3(vertices[vid].p);
    o.normal = float3(vertices[vid].n);
    o.up = vertices[vid].up;
    o.position = cam.viewProjection * float4(o.world, 1.0f);
    return o;
}

vertex float4 apronShadowVertex(uint vid [[vertex_id]],
                                const device ApronVertex *vertices [[buffer(0)]],
                                constant QuarryCamera &cam [[buffer(2)]]) {
    return cam.shadow * float4(float3(vertices[vid].p), 1.0f);
}

fragment float4 apronFragment(ApronOut in [[stage_in]],
                              constant QuarryCamera &cam [[buffer(0)]],
                              depth2d<float> shadowMap [[texture(0)]],
                              texture3d<float> dustLight [[texture(1)]],
                              sampler s [[sampler(0)]]) {
    float3 world = in.world;
    float3 n = normalize(in.normal);
    FloorLook floor = quarryFloor(world);
    float detail = 1.0f - smoothstep(0.03f, 0.11f, floor.footprint);
    float3 tilt;
    // Talus: the beds' rock broken small, coarser up the slope, streaked down it; paler than the
    // worked floor, which it runs out into at its toe in lobes.
    float3 talus = screeGround(world.xy + world.z * 0.7f, world, detail, tilt) * float3(0.74f, 0.72f, 0.7f);
    float toe = 1.0f - smoothstep(0.04f, 0.4f, in.up + 0.15f * (fbm3(world * 0.6f + 3.0f, 3) - 0.45f));
    float3 albedo = mix(talus, floor.ground, toe);
    tilt = mix(tilt, floor.gravelTilt, toe);
    float3 surface = bumped(normalize(n + tilt), world, 1.4f, 0.14f, 3);
    float shadow = shadowAt(world, n, cam, shadowMap, s);
    float dust = dustShadow(world, cam, dustLight);
    return float4(shade(albedo, world, surface, cam, shadow, dust), 1.0f);
}

struct FlankStone {
    float4 posSize;
    float4 rotation;
    float4 look;     // x: 0 a stone, 1 scrub; y: a random value; z: its tint; w: a stone's 1 an angular block
};

struct FlankStoneOut {
    float4 position [[position]];
    float3 world;
    // The stone's or lobe's smooth normal: its shape's own, not its facets' (emmettl/bombcad-work#141).
    float3 normal;
    float3 centre [[flat]];
    float3 albedo [[flat]];
    float kind [[flat]];
    float seed [[flat]];
    float size [[flat]];
    float angular [[flat]];
};

// `shapes` is `QuarryFlank.stoneShape()`, an icosahedron: each corner pulled in or out by the
// stone's own hash, so the facets are irregular, and the whole stretched to the stone's own
// proportions (long, middling and short axes), lying on its flattest side. `normal` is the
// stretched shape's smooth normal, before the corners' pull.
static inline float3 flankStonePoint(FlankStone stone, uint vid, const device float4 *shapes, thread float3 &normal) {
    float3 v = shapes[vid].xyz;
    float k = stone.look.y * 53.0f;
    float corner = hash31(floor(v * 4.0f + 0.5f) + k);
    // Turned its own way before it is stretched, so it lies on a face or an edge, not always on
    // a corner with a corner up.
    float3 axis = normalize(float3(fract(k * 0.731f), fract(k * 1.913f), fract(k * 3.17f)) - 0.5f + 1e-3f);
    float angle = fract(k * 0.377f) * 6.2832f;
    v = rotate(float4(axis * sin(angle * 0.5f), cos(angle * 0.5f)), v);
    float3 axes = float3(1.0f, 0.6f + 0.35f * fract(k * 1.37f), 0.34f + 0.26f * fract(k * 2.71f));
    // Corners pulled in hard or left out, and a flatter underside, so no two read as one solid.
    // Pulled in less than they were: 0.5 to 1.25 of the radius made gems of them.
    float3 p = v * (0.72f + 0.4f * corner) * axes;
    p.z = max(p.z, -0.18f - 0.15f * fract(k * 5.3f));
    p += 0.1f * (float3(hash31(v * 7.0f + k), hash31(v * 7.0f + k + 3.1f), hash31(v * 7.0f + k + 6.7f)) - 0.5f);
    normal = rotate(stone.rotation, normalize(v / axes));
    return stone.posSize.xyz + rotate(stone.rotation, p * stone.posSize.w * 0.6f);
}

// A large stone or a fallen block: `shapes` is `QuarryFlank.lobeShape()`, a sphere of 80 triangles
// shaped here as a function of the direction alone, so its smooth normal can be taken from the
// shape itself: rounded and lumpy, squared off for a block, cut by a few flat fracture faces of its
// own and flat underneath (emmettl/bombcad-work#141).
static inline float3 roundStoneShape(float3 v, float k, float angular) {
    float3 axis = normalize(float3(fract(k * 0.731f), fract(k * 1.913f), fract(k * 3.17f)) - 0.5f + 1e-3f);
    float angle = fract(k * 0.377f) * 6.2832f;
    v = rotate(float4(axis * sin(angle * 0.5f), cos(angle * 0.5f)), v);
    float r = 1.0f + 0.16f * (noise3(v * 1.4f + k) - 0.5f) + 0.05f * (noise3(v * 3.3f + k * 1.7f) - 0.5f);
    float3 p = v * r;
    if (angular > 0.5f) p = clamp(p * 1.5f, -1.0f, 1.0f) * 0.82f;
    float3 axes = angular > 0.5f ? float3(1.0f, 0.55f + 0.4f * fract(k * 1.37f), 0.4f + 0.3f * fract(k * 2.71f))
                                 : float3(1.0f, 0.65f + 0.3f * fract(k * 1.37f), 0.42f + 0.25f * fract(k * 2.71f));
    p *= axes;
    for (int i = 0; i < 5; ++i) {
        float3 cutNormal = normalize(float3(fract(k * (3.1f + i)), fract(k * (5.7f + i)), fract(k * (7.3f + i))) - 0.5f + 1e-3f);
        float reach = (angular > 0.5f ? 0.42f : 0.5f) + 0.25f * fract(k * (11.0f + i));
        float beyond = dot(p, cutNormal) - reach;
        if (beyond > 0.0f) p -= cutNormal * beyond;
    }
    p.z = max(p.z, -0.22f - 0.12f * fract(k * 5.3f));
    return p;
}

static inline float3 roundStonePoint(FlankStone stone, uint vid, const device float4 *shapes, thread float3 &normal) {
    float3 v = normalize(shapes[vid].xyz);
    float k = stone.look.y * 53.0f;
    float3 p = roundStoneShape(v, k, stone.look.w);
    float3 t1 = normalize(cross(v, abs(v.z) < 0.9f ? float3(0.0f, 0.0f, 1.0f) : float3(1.0f, 0.0f, 0.0f)));
    float3 t2 = cross(v, t1);
    float3 a = roundStoneShape(normalize(v + t1 * 0.04f), k, stone.look.w) - p;
    float3 b = roundStoneShape(normalize(v + t2 * 0.04f), k, stone.look.w) - p;
    float3 n = cross(a, b);
    // A corner squared off on all three axes has no slope of its own there.
    n = length(n) > 1e-9f ? normalize(n) : normalize(p + 1e-4f);
    if (dot(n, p) < 0.0f) n = -n;
    normal = rotate(stone.rotation, n);
    return stone.posSize.xyz + rotate(stone.rotation, p * stone.posSize.w * 0.6f);
}

static inline FlankStoneOut flankStoneOut(FlankStone stone, float3 world, float3 normal, constant QuarryCamera &cam) {
    FlankStoneOut o;
    o.world = world;
    o.normal = normal;
    o.position = cam.viewProjection * float4(o.world, 1.0f);
    o.centre = stone.posSize.xyz;
    o.kind = stone.look.x;
    o.seed = stone.look.y;
    o.size = stone.posSize.w;
    o.angular = stone.look.w;
    // Weathered rock of the beds, paled toward grey, each stone a little its own.
    RockColour rock = rockOfKind(kindFromShare(fract(stone.look.y * 3.71f)));
    if (rock.kind == 1) rock.patina = mix(rock.patina, float3(0.3f, 0.29f, 0.27f), 0.5f);
    o.albedo = mix(mix(rock.patina, rock.oxidised, 0.25f + 0.6f * stone.look.z), float3(0.36f, 0.35f, 0.32f), 0.25f)
             * (0.62f + 0.4f * fract(stone.look.y * 17.0f));
    return o;
}

vertex FlankStoneOut flankStoneVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                                      const device FlankStone *stones [[buffer(0)]],
                                      constant QuarryCamera &cam [[buffer(2)]],
                                      const device float4 *shapes [[buffer(5)]]) {
    FlankStone stone = stones[instance];
    float3 normal;
    float3 world = flankStonePoint(stone, vid, shapes, normal);
    return flankStoneOut(stone, world, normal, cam);
}

vertex float4 flankStoneShadowVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                                     const device FlankStone *stones [[buffer(0)]],
                                     constant QuarryCamera &cam [[buffer(2)]],
                                     const device float4 *shapes [[buffer(5)]]) {
    float3 normal;
    return cam.shadow * float4(flankStonePoint(stones[instance], vid, shapes, normal), 1.0f);
}

vertex FlankStoneOut roundStoneVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                                      const device FlankStone *stones [[buffer(0)]],
                                      constant QuarryCamera &cam [[buffer(2)]],
                                      const device float4 *shapes [[buffer(5)]]) {
    FlankStone stone = stones[instance];
    float3 normal;
    float3 world = roundStonePoint(stone, vid, shapes, normal);
    return flankStoneOut(stone, world, normal, cam);
}

vertex float4 roundStoneShadowVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                                     const device FlankStone *stones [[buffer(0)]],
                                     constant QuarryCamera &cam [[buffer(2)]],
                                     const device float4 *shapes [[buffer(5)]]) {
    float3 normal;
    return cam.shadow * float4(roundStonePoint(stones[instance], vid, shapes, normal), 1.0f);
}

fragment float4 flankStoneFragment(FlankStoneOut in [[stage_in]],
                                   constant QuarryCamera &cam [[buffer(0)]],
                                   depth2d<float> shadowMap [[texture(0)]],
                                   texture3d<float> dustLight [[texture(1)]],
                                   sampler s [[sampler(0)]]) {
    float3 facet = normalize(cross(dfdx(in.world), dfdy(in.world)));
    if (dot(facet, cam.eye.xyz - in.world) < 0.0f) facet = -facet;
    float footprint = length(fwidth(in.world));
    float near = 1.0f - smoothstep(0.03f, 0.2f, footprint);
    float3 albedo = in.albedo;
    float3 n = facet;
    float3 local = in.world - in.centre;
    if (in.kind > 0.5f) {
        // A lobe of a bush: lit as a ball of small leaves, broken by clusters with dark gaps
        // between, darker underneath and inside. Far off, where a leaf is under a pixel, the
        // leaves and gaps give way to their mean and the lobe is lit as a ball, so a bush still
        // reads as a lit, rounded bush in the wide view, not a dark dot (emmettl/bombcad-work#141).
        float3 round = normalize(local + float3(0.0f, 0.0f, 0.15f * in.size));
        float3 p = in.world * 7.0f + in.seed * 30.0f;
        float3 jitter = float3(noise3(p), noise3(p + 7.1f), noise3(p + 13.3f)) - 0.5f;
        n = normalize(mix(round, facet, 0.25f * near) + jitter * near);
        float leaves = mix(0.5f, fbm3(in.world * 11.0f + in.seed * 30.0f, 3), near);
        float gaps = mix(0.75f, smoothstep(0.28f, 0.5f, fbm3(in.world * 4.0f + 5.0f + in.seed * 9.0f, 2)), near);
        albedo *= (0.6f + 0.85f * leaves) * mix(0.45f, 1.0f, gaps);
        albedo *= mix(0.5f, 1.0f, saturate(round.z * 0.7f + 0.65f));
        // A few paler leaves catching the light, and far off the sunlit crown a little paler too.
        albedo = mix(albedo, albedo * 1.6f + 0.02f, smoothstep(0.62f, 0.7f, fbm3(in.world * 23.0f + in.seed, 2)) * 0.5f * near);
        albedo *= 1.0f + 0.35f * (1.0f - near) * saturate(dot(round, cam.sun.xyz));
    } else {
        // Weathered stone: rounded by its own smooth normal with only a little of its facets,
        // more for a block; grain, pits and lichen on top, soil stain at its foot.
        float3 smooth = normalize(in.normal);
        n = normalize(mix(smooth, facet, in.angular > 0.5f ? 0.45f : 0.2f));
        float grain = fbm3(in.world * 9.0f + in.seed * 30.0f, 3);
        albedo *= 0.8f + 0.4f * mix(0.5f, grain, near);
        float lichen = smoothstep(0.58f, 0.72f, fbm3(in.world * 2.3f + in.seed * 11.0f, 3)) * smoothstep(0.2f, 0.8f, n.z);
        albedo = mix(albedo, float3(0.55f, 0.55f, 0.45f), lichen * 0.4f);
        float dark = smoothstep(0.6f, 0.75f, fbm3(in.world * 4.1f + in.seed * 7.0f, 3)) * smoothstep(0.0f, 0.6f, n.z);
        albedo = mix(albedo, float3(0.13f, 0.12f, 0.1f), dark * 0.35f);
        float foot = 1.0f - smoothstep(-0.12f, 0.05f, local.z / max(in.size, 0.05f));
        albedo = mix(albedo, float3(0.22f, 0.18f, 0.13f), foot * 0.55f);
        n = bumped(n, in.world, 4.0f / max(in.size, 0.3f), 0.12f * near, 3);
    }
    float shadow = shadowAt(in.world, in.kind > 0.5f ? facet : normalize(in.normal), cam, shadowMap, s);
    float dust = dustShadow(in.world, cam, dustLight);
    return float4(shade(albedo, in.world, n, cam, shadow, dust), 1.0f);
}

// A bush's lobe: `shapes` is `QuarryFlank.lobeShape()`, a sphere made lumpy here, a little flattened.
static inline float3 flankBushPoint(FlankStone bush, uint vid, const device float4 *shapes) {
    float3 v = shapes[vid].xyz;
    float3 p = v * 1.9f + bush.look.y * 37.0f;
    float lump = 1.0f + 0.5f * (noise3(p) - 0.5f) + 0.3f * (noise3(p * 2.4f + 5.0f) - 0.5f);
    return bush.posSize.xyz + rotate(bush.rotation, v * lump * float3(1.0f, 1.0f, 0.82f) * bush.posSize.w * 0.5f);
}

vertex FlankStoneOut flankBushVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                                     const device FlankStone *bushes [[buffer(0)]],
                                     constant QuarryCamera &cam [[buffer(2)]],
                                     const device float4 *shapes [[buffer(5)]]) {
    FlankStone bush = bushes[instance];
    FlankStoneOut o;
    o.world = flankBushPoint(bush, vid, shapes);
    o.normal = rotate(bush.rotation, shapes[vid].xyz);
    o.position = cam.viewProjection * float4(o.world, 1.0f);
    o.centre = bush.posSize.xyz;
    o.kind = 1.0f;
    o.seed = bush.look.y;
    o.size = bush.posSize.w;
    o.angular = 0.0f;
    // Each bush its own: dark olive, grey-green, brownish olive, a few turning rusty; each lobe a
    // little lighter or darker.
    float t = bush.look.z;
    float3 c = t < 0.45f ? mix(float3(0.17f, 0.2f, 0.08f), float3(0.25f, 0.28f, 0.12f), t / 0.45f)
             : t < 0.72f ? float3(0.28f, 0.31f, 0.21f)
             : t < 0.93f ? float3(0.29f, 0.26f, 0.14f)
                         : float3(0.32f, 0.22f, 0.12f);
    o.albedo = c * (0.78f + 0.44f * bush.look.w);
    return o;
}

vertex float4 flankBushShadowVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
                                    const device FlankStone *bushes [[buffer(0)]],
                                    constant QuarryCamera &cam [[buffer(2)]],
                                    const device float4 *shapes [[buffer(5)]]) {
    return cam.shadow * float4(flankBushPoint(bushes[instance], vid, shapes), 1.0f);
}

// --- A ridge cut's outcrops and crags (emmettl/bombcad-work#138, #141) ---
// Illustrative: each run of ledges, and each crag, is a stack of weathered layers swept along its
// bed (`QuarryFace.outcropMesh`), shaded and lit here on their own, not by the blocks' shader or
// `shade`: the bed's weathered colour, partings, dark water stains down the fronts, lichen and dark
// crusts on the tops, turf on them in patches, soil and scree banked against the foot, its facets'
// own planes close in so its edges read broken and angular, and its own light: a soft shadow that
// does not speckle under a low sun, and sky light that falls off under overhangs, in partings and
// joints and at the foot. A vertex's `body` carries its height above the ground (cm), its
// outcrop's random value, what part of the profile it is, its layer from the top, how open a joint
// is there and whether it is a crag's (`QuarryFace.outcropTag`).
struct LedgeOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float above;
    float part;
    float layer;
    float crack;
    float random [[flat]];
    float crag [[flat]];
};

vertex LedgeOut ledgeVertex(uint vid [[vertex_id]],
                            const device QuarryBlockVertex *vertices [[buffer(0)]],
                            constant QuarryCamera &cam [[buffer(2)]]) {
    QuarryBlockVertex v = vertices[vid];
    LedgeOut o;
    o.world = float3(v.local);
    o.position = cam.viewProjection * float4(o.world, 1.0f);
    o.normal = unpackNormal(v.normalKind);
    o.above = float(v.body & 1023u) * 0.01f;
    o.random = float((v.body >> 10) & 63u) / 63.0f;
    o.part = float((v.body >> 16) & 7u);
    o.layer = float((v.body >> 19) & 7u);
    o.crack = float((v.body >> 22) & 15u) / 15.0f;
    o.crag = float((v.body >> 26) & 1u);
    return o;
}

vertex float4 ledgeShadowVertex(uint vid [[vertex_id]],
                                const device QuarryBlockVertex *vertices [[buffer(0)]],
                                constant QuarryCamera &cam [[buffer(2)]]) {
    return cam.shadow * float4(float3(vertices[vid].local), 1.0f);
}

// The outcrops' own shadow: pushed out along the normal and toward the sun, and sampled over a
// wider footprint, so a top raked by the low sun is not speckled.
static inline float outcropShadow(float3 world, float3 n, constant QuarryCamera &cam, depth2d<float> map, sampler s) {
    float3 w = world + n * 0.3f + cam.sun.xyz * 0.2f;
    float4 c = cam.shadow * float4(w, 1.0f);
    float3 q = c.xyz / c.w;
    float2 uv = q.xy * float2(0.5f, -0.5f) + 0.5f;
    if (any(uv < 0.0f) || any(uv > 1.0f)) return 1.0f;
    float texel = 1.6f / float(map.get_width());
    float sum = 0.0f;
    for (int y = -1; y <= 2; ++y) for (int x = -1; x <= 2; ++x) {
        sum += map.sample_compare(s, uv + (float2(x, y) - 0.5f) * texel, q.z - 0.0006f);
    }
    return sum / 16.0f;
}

fragment float4 ledgeFragment(LedgeOut in [[stage_in]],
                              constant QuarryCamera &cam [[buffer(0)]],
                              depth2d<float> shadowMap [[texture(0)]],
                              texture3d<float> dustLight [[texture(1)]],
                              sampler s [[sampler(0)]]) {
    float3 world = in.world;
    float3 smooth = normalize(in.normal);
    float3 facet = normalize(cross(dfdx(world), dfdy(world)));
    if (dot(facet, smooth) < 0.0f) facet = -facet;
    float footprint = length(fwidth(world));
    float detail = 1.0f - smoothstep(0.03f, 0.12f, footprint);
    // Close in the facets' own planes, so the edges read broken and angular rather than rounded.
    float3 n = normalize(mix(smooth, facet, 0.6f * (1.0f - smoothstep(0.06f, 0.5f, footprint))));
    RockColour rock = rockAt(world - smooth * 0.1f, footprint);
    float c = bedCoordinate(dot(world, beddingNormal));
    float tone = fract(in.random * 7.31f + in.layer * 0.37f);
    // Weathered rock: the bed's patina, greyed, each outcrop and layer its own tone, mottled broadly.
    float broad = fbm3(world * 0.35f + in.random * 17.0f, 3);
    float3 albedo = mix(mix(rock.patina, rock.oxidised, 0.2f + 0.3f * tone), float3(0.42f, 0.41f, 0.38f), 0.25f);
    albedo *= (0.76f + 0.44f * broad) * (0.9f + 0.2f * fbm3(world * 3.0f, 2)) * (0.86f + 0.24f * tone);
    float front = 1.0f - smoothstep(0.45f, 0.8f, smooth.z);
    float topness = smoothstep(0.6f, 0.85f, smooth.z);
    // Partings within the bed: a few thin darker lines along it on the fronts, wandering and
    // broken, not ruled (evenly ruled lines read as planks).
    float lines = rock.kind == 0 ? 1.0f : 3.0f;
    float parting = smoothstep(0.9f, 0.98f, abs(sin((c + 0.25f * fbm3(world * 0.45f, 3)) * 3.1416f * lines)));
    parting *= smoothstep(0.35f, 0.55f, fbm3(world * float3(0.35f, 0.35f, 1.2f) + 13.0f, 2));
    albedo *= 1.0f - 0.28f * parting * front * detail;
    // Dark stains down the fronts where water runs off the tops, and paler, cleaner rock between.
    float streak = fbm3(world * float3(1.7f, 1.7f, 0.16f) + 5.0f + in.random * 9.0f, 3);
    albedo = mix(albedo, float3(0.13f, 0.12f, 0.11f), front * 0.55f * smoothstep(0.48f, 0.7f, streak));
    albedo *= 1.0f + front * 0.12f * smoothstep(0.45f, 0.25f, streak);
    // On the tops: pale grey-green lichen in rosettes, small yellow ones, dark crusts in patches.
    float2 toCentre;
    float3 cells = stones(world.xy / 0.22f + in.random * 40.0f, 41u, toCentre);
    float rosette = (1.0f - smoothstep(0.25f, 0.42f, cells.x)) * step(0.55f, cells.z);
    float lichenPatch = smoothstep(0.42f, 0.6f, fbm3(world * 0.9f + 31.0f, 3));
    float up = smoothstep(-0.2f, 0.7f, smooth.z);
    float lichen = max(lichenPatch * 0.7f, rosette * lichenPatch * detail) * up;
    float3 lichenColour = cells.z > 0.9f ? float3(0.62f, 0.5f, 0.22f) : float3(0.6f, 0.61f, 0.53f);
    albedo = mix(albedo, lichenColour * (0.85f + 0.3f * fbm3(world * 9.0f, 2)), lichen * 0.55f);
    float crust = smoothstep(0.52f, 0.7f, fbm3(world * 0.4f + 9.0f + in.random * 5.0f, 2)) * (0.4f + 0.6f * topness);
    albedo = mix(albedo, float3(0.11f, 0.1f, 0.09f), crust * 0.5f * (1.0f - lichen));
    // Turf on the tops in patches, more toward the back where they run into the slope, and on a
    // crag's broad top; soil and scree banked against the foot, the line wandering.
    float3 tilt;
    float back = in.part < 0.5f ? 1.0f : 0.0f;
    // A crag's broad top is mostly turf, the hillside running on over it to its edge.
    float turf = smoothstep(0.44f, 0.58f, fbm3(world * 0.8f + 3.0f, 3) + 0.25f * back + 0.3f * in.crag * (in.layer < 0.5f ? 1.0f : 0.3f)) * topness;
    albedo = mix(albedo, grassGround(world, detail, tilt), turf);
    float bank = 0.18f + 0.6f * fbm3(world * float3(0.9f, 0.9f, 0.4f) + 21.0f, 3);
    float banked = 1.0f - smoothstep(bank - 0.12f, bank + 0.04f, in.above);
    float3 screeTilt;
    float3 loose = screeGround(world.xy, world, detail, screeTilt);
    albedo = mix(albedo, mix(loose, float3(0.23f, 0.19f, 0.14f), 0.35f), banked);
    // Joints: dark, narrow cracks; partings between layers dark and dirty.
    float joint = smoothstep(0.35f, 0.85f, in.crack);
    float inParting = 1.0f - saturate(abs(in.part - 3.0f));
    albedo *= (1.0f - 0.45f * joint) * (1.0f - 0.35f * inParting);
    // Pitted and worn, less where it is turf or soil.
    float rough = 1.0f - max(turf, banked) * 0.7f;
    float3 surface = bumped(n, world, 1.6f, 0.07f * rough, 3);
    surface = bumped(surface, world, 8.0f, 0.08f * rough * detail, 2);
    // Its own light: sun through its own soft shadow, sky that falls off under overhangs, in
    // partings and joints and toward the foot, and warm light thrown up from the ground.
    float shadow = outcropShadow(world, smooth, cam, shadowMap, s);
    float dust = dustShadow(world, cam, dustLight);
    float under = saturate(-smooth.z * 1.3f + 0.05f);
    float foot = (1.0f - smoothstep(0.0f, 0.8f, in.above)) * (1.0f - topness);
    float cavity = saturate(1.0f - 0.5f * inParting - 0.4f * under - 0.3f * foot - 0.5f * joint);
    float3 sun = cam.sun.xyz;
    float nl = max(dot(surface, sun), 0.0f);
    float3 sunColor = float3(1.0f, 0.74f, 0.47f) * 3.4f;
    float sky = surface.z * 0.5f + 0.5f;
    float3 skyLight = mix(float3(0.3f, 0.24f, 0.2f), float3(0.3f, 0.39f, 0.6f), sky) * 0.52f * cavity;
    float3 bounce = float3(0.5f, 0.38f, 0.26f) * saturate(-surface.z * 0.5f + 0.35f) * 0.2f * (0.5f + 0.5f * cavity);
    float3 lit = albedo * (sunColor * nl * shadow * dust * mix(0.75f, 1.0f, cavity) + skyLight + bounce);
    float distance = length(world - cam.eye.xyz);
    float fog = 1.0f - exp(-distance * distance * 0.7e-6f);
    float3 dir = (world - cam.eye.xyz) / max(distance, 1.0f);
    float3 haze = cam.fogColor.w > 1.5f ? backdrop(float3(dir.x, dir.y, 0.0f), cam) : skyColor(float3(dir.x, dir.y, 0.03f), cam);
    return float4(mix(lit, haze * 0.95f, fog), 1.0f);
}
