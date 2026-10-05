// The view is drawn in two passes. The first ray-traces the analytic ground and rigid blocks,
// shaded by the solver's fields, then rasterises the deformable structure's mesh over them
// with a shared depth buffer. The second ray-marches the blast wave in the air, stopping at
// the depth the first pass recorded. Layouts here must match `SceneRenderer.swift`.

#include <metal_stdlib>
using namespace metal;

struct RenderUniforms {
    float4 eye;        // xyz
    float4 right;      // camera basis, pre-scaled by the field of view
    float4 up;
    float4 forward;
    float4 domain;     // xyz = size in metres, w = cell size
    float4 display;    // x = mode (0 now, 1 peak, 2 impulse), y = scale max, z = decades, w = volume opacity
    float4 counts;     // x = boxes, y = gauges, z = charge marker radius (0 hides it), w = volume scale max
    float4 charge;     // xyz = position
    float4 sun;        // xyz = direction towards the light
    float4 clip;       // x = near plane, y = far plane
    float4 highlightLow;   // xyz = low corner of the box to outline, w = 1 to draw it
    float4 highlightHigh;  // xyz = its high corner
};

struct MeshUniforms {
    float4 eye;
    float4 right;       // unit camera basis
    float4 up;
    float4 forward;
    float4 projection;  // x, y = focal scales, z = near, w = far
    float4 lattice;     // xyz = origin, w = element size
    float4 dims;        // xyz = lattice cells, w = floats of state per element
    float4 sun;
};

// Matches `StructureNode` in Structure.metal.
struct MeshNode {
    packed_float3 displacement;
    float mass;
    packed_float3 velocity;
    uint flags;
};

struct BoxData {
    float4 low;
    float4 high;
};

struct VertexOut {
    float4 position [[position]];
    float2 ndc;
};

vertex VertexOut fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 corner = float2((vertexID << 1) & 2, vertexID & 2);
    VertexOut out;
    out.position = float4(corner * 2.0f - 1.0f, 0.0f, 1.0f);
    out.ndc = corner * 2.0f - 1.0f;
    return out;
}

static inline float3 heat(float t) {
    const float3 stops[6] = {
        float3(0.05f, 0.04f, 0.22f), float3(0.30f, 0.07f, 0.50f), float3(0.67f, 0.14f, 0.42f),
        float3(0.92f, 0.33f, 0.16f), float3(0.99f, 0.68f, 0.10f), float3(0.99f, 0.98f, 0.70f),
    };
    float x = clamp(t, 0.0f, 1.0f) * 5.0f;
    int i = min(int(x), 4);
    return mix(stops[i], stops[i + 1], x - float(i));
}

// Maps a value onto [0, 1] logarithmically: `scaleMax` -> 1, `decades` below it -> 0.
static inline float logScale(float value, float scaleMax, float decades) {
    return clamp(1.0f + log10(max(value, 1e-12f) / scaleMax) / decades, 0.0f, 1.0f);
}

static inline bool hitBox(float3 origin, float3 inverseDirection, float3 low, float3 high,
                          thread float &distance, thread float3 &normal) {
    float3 t0 = (low - origin) * inverseDirection;
    float3 t1 = (high - origin) * inverseDirection;
    float3 nearT = min(t0, t1);
    float3 farT = max(t0, t1);
    float enter = max(nearT.x, max(nearT.y, nearT.z));
    float leave = min(farT.x, min(farT.y, farT.z));
    if (enter > leave || enter <= 0.0f) {
        return false;
    }
    distance = enter;
    normal = float3(0.0f);
    if (enter == nearT.x) {
        normal.x = inverseDirection.x > 0.0f ? -1.0f : 1.0f;
    } else if (enter == nearT.y) {
        normal.y = inverseDirection.y > 0.0f ? -1.0f : 1.0f;
    } else {
        normal.z = inverseDirection.z > 0.0f ? -1.0f : 1.0f;
    }
    return true;
}

static inline bool hitSphere(float3 origin, float3 direction, float3 centre, float radius,
                             thread float &distance) {
    float3 offset = origin - centre;
    float b = dot(offset, direction);
    float c = dot(offset, offset) - radius * radius;
    float discriminant = b * b - c;
    if (discriminant < 0.0f) {
        return false;
    }
    float t = -b - sqrt(discriminant);
    if (t <= 0.0f) {
        return false;
    }
    distance = t;
    return true;
}

static inline bool occluded(float3 origin, float3 direction, const device BoxData *boxes, int boxCount) {
    float3 inverseDirection = 1.0f / direction;
    for (int n = 0; n < boxCount; ++n) {
        float distance;
        float3 normal;
        if (hitBox(origin, inverseDirection, boxes[n].low.xyz, boxes[n].high.xyz, distance, normal)) {
            return true;
        }
    }
    return false;
}

// Colour of a lit surface point, tinted by the field channel the display mode selects.
// The tint is only lightly shaded so that shadows do not distort the data.
static inline float3 fieldTint(float3 base, float light, float4 field, constant RenderUniforms &u) {
    int mode = int(u.display.x);
    float value = mode == 0 ? field.r : (mode == 1 ? field.g : field.b);
    float t = logScale(value, u.display.y, u.display.z);
    float dataLight = 0.78f + 0.22f * light;
    float3 colour = mix(base * light, heat(t) * dataLight, smoothstep(0.0f, 0.12f, t) * 0.92f);
    if (mode == 0 && value < 0.0f) {
        // Negative phase (suction) in blue.
        float suction = logScale(-value, u.display.y * 0.3f, u.display.z);
        colour = mix(colour, float3(0.10f, 0.35f, 0.85f) * dataLight, smoothstep(0.0f, 0.3f, suction) * 0.7f);
    }
    return colour;
}

struct SceneOut {
    float4 colour [[color(0)]];
    float depth [[depth(any)]];
};

// Depth-buffer value of a point at view-space distance `z` along the camera axis.
static inline float depthFromView(float z, float near, float far) {
    return far / (far - near) * (1.0f - near / z);
}

static inline float viewFromDepth(float depth, float near, float far) {
    return near / (1.0f - depth * (far - near) / far);
}

fragment SceneOut sceneFragment(VertexOut in [[stage_in]],
                                constant RenderUniforms &u [[buffer(0)]],
                                const device BoxData *boxes [[buffer(1)]],
                                const device float4 *gauges [[buffer(2)]],
                                texture3d<float> field [[texture(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    float3 origin = u.eye.xyz;
    float3 direction = normalize(u.forward.xyz + in.ndc.x * u.right.xyz + in.ndc.y * u.up.xyz);
    float3 inverseDirection = 1.0f / direction;
    float3 domain = u.domain.xyz;
    float cellSize = u.domain.w;
    float3 sun = u.sun.xyz;
    int boxCount = int(u.counts.x);
    int gaugeCount = int(u.counts.y);

    // Background sky.
    float3 colour = mix(float3(0.62f, 0.70f, 0.80f), float3(0.22f, 0.36f, 0.62f),
                        clamp(direction.z * 1.6f, 0.0f, 1.0f));
    float nearest = 1.0e9f;

    // Ground plane z = 0.
    if (direction.z < 0.0f) {
        float t = -origin.z / direction.z;
        if (t > 0.0f) {
            nearest = t;
            float3 p = origin + t * direction;
            bool inside = p.x >= 0.0f && p.y >= 0.0f && p.x <= domain.x && p.y <= domain.y;
            float3 base = inside ? float3(0.46f, 0.47f, 0.49f) : float3(0.33f, 0.34f, 0.36f);
            // 10 m grid, antialiased with screen-space derivatives.
            float2 cell = p.xy / 10.0f;
            float2 line = abs(fract(cell - 0.5f) - 0.5f) / max(fwidth(cell), 1e-5f);
            float grid = 1.0f - clamp(min(line.x, line.y), 0.0f, 1.0f);
            base = mix(base, base * 1.3f, grid * (inside ? 0.6f : 0.3f));
            float light = 0.45f + 0.55f * max(sun.z, 0.0f);
            if (occluded(p + float3(0.0f, 0.0f, 0.01f), sun, boxes, boxCount)) {
                light *= 0.62f;
            }
            colour = base * light;
            if (inside) {
                float3 uvw = float3(p.xy, 0.5f * cellSize) / domain;
                colour = fieldTint(base, light, field.sample(linearSampler, uvw), u);
            }
        }
    }

    // Blocks.
    for (int n = 0; n < boxCount; ++n) {
        float t;
        float3 normal;
        if (hitBox(origin, inverseDirection, boxes[n].low.xyz, boxes[n].high.xyz, t, normal) && t < nearest) {
            nearest = t;
            float3 p = origin + t * direction;
            // Sample half a cell inside the wall, where solid cells hold the adjacent air values.
            float3 uvw = (p - normal * 0.5f * cellSize) / domain;
            float diffuse = max(dot(normal, sun), 0.0f);
            if (diffuse > 0.0f && occluded(p + normal * 0.01f, sun, boxes, boxCount)) {
                diffuse = 0.0f;
            }
            // Faint storey lines give the blocks a sense of scale.
            float storey = normal.z == 0.0f ? smoothstep(0.42f, 0.5f, abs(fract(p.z / 3.0f) - 0.5f)) : 0.0f;
            float light = (0.50f + 0.50f * diffuse) * (1.0f - 0.10f * storey);
            colour = fieldTint(float3(0.80f, 0.79f, 0.76f), light, field.sample(linearSampler, uvw), u);
        }
    }

    // Gauge markers and the charge marker.
    for (int n = 0; n < gaugeCount; ++n) {
        float t;
        if (hitSphere(origin, direction, gauges[n].xyz, gauges[n].w, t) && t < nearest) {
            nearest = t;
            float3 normal = normalize(origin + t * direction - gauges[n].xyz);
            colour = float3(0.10f, 0.80f, 0.90f) * (0.55f + 0.45f * max(dot(normal, sun), 0.0f));
        }
    }
    if (u.counts.z > 0.0f) {
        float t;
        if (hitSphere(origin, direction, u.charge.xyz, u.counts.z, t) && t < nearest) {
            nearest = t;
            float3 normal = normalize(origin + t * direction - u.charge.xyz);
            colour = float3(0.95f, 0.15f, 0.10f) * (0.55f + 0.45f * max(dot(normal, sun), 0.0f));
        }
    }

    SceneOut out;
    out.colour = float4(colour, 1.0f);
    out.depth = nearest < 1.0e8f
        ? depthFromView(nearest * dot(direction, u.forward.xyz), u.clip.x, u.clip.y) : 1.0f;
    return out;
}

struct MeshOut {
    float4 position [[position]];
    float3 world;
    float damage [[flat]];
};

// Which shells a draw takes: all of them, all but the glass, or the glass alone.
constant uint drawAll = 0;
constant uint drawOpaque = 1;
constant uint drawGlass = 2;

// Draws the outer faces of the structure's elements, pulled straight from the solver's buffers:
// 36 vertices per element, with hidden and eroded faces collapsed to nothing.
vertex MeshOut structureVertex(uint vertexID [[vertex_id]],
                               uint instanceID [[instance_id]],
                               const device uint *instances [[buffer(0)]],
                               const device MeshNode *nodes [[buffer(1)]],
                               const device uchar *flags [[buffer(2)]],
                               const device float *states [[buffer(3)]],
                               constant MeshUniforms &u [[buffer(4)]],
                               const device uint *nodeMap [[buffer(5)]]) {
    MeshOut out;
    out.position = float4(0.0f, 0.0f, 0.0f, 1.0f);
    out.world = float3(0.0f);
    out.damage = 0.0f;

    int3 dims = int3(u.dims.xyz);
    int element = int(instances[instanceID]);
    uint flag = flags[element];
    int3 cell = int3(element % dims.x, (element / dims.x) % dims.y, element / (dims.x * dims.y));
    uint face = vertexID / 6;
    uint axis = face >> 1;
    uint side = face & 1u;
    const uint2 quad[6] = {uint2(0, 0), uint2(1, 0), uint2(1, 1), uint2(0, 0), uint2(1, 1), uint2(0, 1)};
    uint2 corner = quad[vertexID % 6];
    int3 offset = int3(0);
    offset[axis] = int(side);
    offset[(axis + 1) % 3] = int(corner.x);
    offset[(axis + 2) % 3] = int(corner.y);
    int nodesX = dims.x + 1;
    int nodesY = dims.y + 1;

    float3 world;
    if (flag == 1) {
        // Intact element: draw only faces that are not shared with another intact element.
        int3 outward = int3(0);
        outward[axis] = side == 0 ? -1 : 1;
        int3 neighbour = cell + outward;
        if (all(neighbour >= 0) && all(neighbour < dims)
            && flags[neighbour.x + dims.x * (neighbour.y + dims.y * neighbour.z)] == 1) {
            return out;
        }
        int3 point = cell + offset;
        MeshNode node = nodes[nodeMap[point.x + nodesX * (point.y + nodesY * point.z)]];
        world = u.lattice.xyz + float3(point) * u.lattice.w + float3(node.displacement);
        out.damage = states[instanceID * uint(u.dims.w) + 7];
    } else if (flag == 2) {
        // Failed element: a small lump of rubble at the middle of its (now free) nodes.
        float3 centre = float3(0.0f);
        for (int a = 0; a < 8; ++a) {
            int3 point = cell + int3(a & 1, (a >> 1) & 1, (a >> 2) & 1);
            MeshNode node = nodes[nodeMap[point.x + nodesX * (point.y + nodesY * point.z)]];
            centre += 0.125f * (u.lattice.xyz + float3(point) * u.lattice.w + float3(node.displacement));
        }
        world = centre + (float3(offset) - 0.5f) * (0.6f * u.lattice.w);
        out.damage = 2.0f;
    } else {
        return out;
    }

    float3 relative = world - u.eye.xyz;
    float3 view = float3(dot(relative, u.right.xyz), dot(relative, u.up.xyz), dot(relative, u.forward.xyz));
    float near = u.projection.z;
    float far = u.projection.w;
    out.position = float4(view.x * u.projection.x, view.y * u.projection.y,
                          far / (far - near) * (view.z - near), view.z);
    out.world = world;
    return out;
}

// Matches `ShellNode` and `ShellElement` in Shell.metal.
struct ShellMeshNode {
    packed_float3 displacement;
    float mass;
    packed_float3 velocity;
    uint flags;
    packed_float3 spin;
    float inertia;
    float4 rotation;
};

struct ShellMeshElement {
    uint node[4];
    uint axis;
    uint material;
    uint barCount;
    float thickness;
    float a;
    float b;
};

// Draws each shell as the slab it stands for: a box between its two faces, which lie half its
// thickness either side of the midsurface along the directors. A failed shell becomes a small
// lump of rubble at the middle of its nodes.
vertex MeshOut shellVertex(uint vertexID [[vertex_id]],
                           uint instanceID [[instance_id]],
                           const device ShellMeshElement *elements [[buffer(0)]],
                           const device ShellMeshNode *nodes [[buffer(1)]],
                           const device uchar *flags [[buffer(2)]],
                           const device float *damage [[buffer(3)]],
                           constant MeshUniforms &u [[buffer(4)]],
                           const device float4 *reference [[buffer(5)]],
                           constant uint &transparentMaterials [[buffer(6)]],
                           constant uint &draw [[buffer(7)]]) {
    MeshOut out;
    out.position = float4(0.0f, 0.0f, 0.0f, 1.0f);
    out.world = float3(0.0f);
    out.damage = 0.0f;
    uint flag = flags[instanceID];
    if (flag == 0) {
        return out;
    }
    ShellMeshElement el = elements[instanceID];
    bool glass = ((transparentMaterials >> min(el.material, 31u)) & 1u) != 0u;
    if ((draw == drawOpaque && glass) || (draw == drawGlass && !glass)) {
        return out;
    }
    // A pane is a sheet: blended, its thin sides and its second face would stack up into
    // grid lines and moiré between neighbouring elements, so only its first face is drawn.
    if (draw == drawGlass && (flag == 1 || flag == 3) && vertexID >= 6) {
        return out;
    }
    float3 normal = float3(0.0f);
    normal[el.axis] = 1.0f;
    // Box corners: the four nodes on the lower face, then on the upper.
    const uint faces[6][4] = {{0, 1, 2, 3}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
    const uint triangle[6] = {0, 1, 2, 0, 2, 3};
    uint corner = faces[vertexID / 6][triangle[vertexID % 6]];
    uint c = corner & 3u;
    float side = corner < 4 ? -1.0f : 1.0f;
    float3 world;
    if (flag == 1 || flag == 3) {
        ShellMeshNode node = nodes[el.node[c]];
        float4 q = node.rotation;
        float3 t = 2.0f * cross(q.xyz, normal);
        float3 director = normal + q.w * t + cross(q.xyz, t);
        world = reference[el.node[c]].xyz + float3(node.displacement) + side * 0.5f * el.thickness * director;
        out.damage = damage[instanceID];
    } else {
        float3 centre = float3(0.0f);
        for (uint n = 0; n < 4; ++n) {
            centre += 0.25f * (reference[el.node[n]].xyz + float3(nodes[el.node[n]].displacement));
        }
        float size = 0.3f * min(min(el.a, el.b), max(el.thickness, 0.05f) * 2.0f);
        float3 offset = float3((c == 1 || c == 2) ? 0.5f : -0.5f, c >= 2 ? 0.5f : -0.5f, 0.5f * side);
        world = centre + offset * size;
        out.damage = 2.0f;
    }
    float3 relative = world - u.eye.xyz;
    float3 view = float3(dot(relative, u.right.xyz), dot(relative, u.up.xyz), dot(relative, u.forward.xyz));
    float near = u.projection.z;
    float far = u.projection.w;
    out.position = float4(view.x * u.projection.x, view.y * u.projection.y,
                          far / (far - near) * (view.z - near), view.z);
    out.world = world;
    return out;
}

// Matches `BeamElement` in Shell.metal.
struct BeamMeshElement {
    uint node[2];
    uint axis;
    uint material;
    float width;
    float depth;
    float length;
    uint barCount;
    float tieRatio;
    float padding0;
    float padding1;
};

// Draws each beam as the bar it stands for: a box around its centreline, its section carried by
// the rotated section axes at each end.
vertex MeshOut beamVertex(uint vertexID [[vertex_id]],
                          uint instanceID [[instance_id]],
                          const device BeamMeshElement *beams [[buffer(0)]],
                          const device ShellMeshNode *nodes [[buffer(1)]],
                          const device uchar *flags [[buffer(2)]],
                          const device float *damage [[buffer(3)]],
                          constant MeshUniforms &u [[buffer(4)]],
                          const device float4 *reference [[buffer(5)]]) {
    MeshOut out;
    out.position = float4(0.0f, 0.0f, 0.0f, 1.0f);
    out.world = float3(0.0f);
    out.damage = 0.0f;
    uint flag = flags[instanceID];
    if (flag != 1 && flag != 3) {
        return out;
    }
    BeamMeshElement beam = beams[instanceID];
    float3 e2 = float3(0.0f);
    float3 e3 = float3(0.0f);
    e2[(beam.axis + 1) % 3] = 1.0f;
    e3[(beam.axis + 2) % 3] = 1.0f;
    // Box corners: bit 0 picks the end, bits 1 and 2 the side of the section.
    const uint faces[6][4] = {{0, 2, 6, 4}, {1, 3, 7, 5}, {0, 1, 3, 2}, {4, 5, 7, 6}, {0, 1, 5, 4}, {2, 3, 7, 6}};
    const uint triangle[6] = {0, 1, 2, 0, 2, 3};
    uint corner = faces[vertexID / 6][triangle[vertexID % 6]];
    uint end = corner & 1u;
    ShellMeshNode node = nodes[beam.node[end]];
    float4 q = node.rotation;
    float3 t2 = 2.0f * cross(q.xyz, e2);
    float3 t3 = 2.0f * cross(q.xyz, e3);
    float3 d2 = e2 + q.w * t2 + cross(q.xyz, t2);
    float3 d3 = e3 + q.w * t3 + cross(q.xyz, t3);
    float s2 = (corner & 2u) != 0 ? 0.5f : -0.5f;
    float s3 = (corner & 4u) != 0 ? 0.5f : -0.5f;
    float3 world = reference[beam.node[end]].xyz + float3(node.displacement) + s2 * beam.width * d2
        + s3 * beam.depth * d3;
    out.damage = damage[instanceID];
    float3 relative = world - u.eye.xyz;
    float3 view = float3(dot(relative, u.right.xyz), dot(relative, u.up.xyz), dot(relative, u.forward.xyz));
    float near = u.projection.z;
    float far = u.projection.w;
    out.position = float4(view.x * u.projection.x, view.y * u.projection.y,
                          far / (far - near) * (view.z - near), view.z);
    out.world = world;
    return out;
}

fragment float4 structureFragment(MeshOut in [[stage_in]], constant MeshUniforms &u [[buffer(0)]]) {
    float3 normal = normalize(cross(dfdx(in.world), dfdy(in.world)));
    if (dot(normal, u.eye.xyz - in.world) < 0.0f) {
        normal = -normal;
    }
    float light = 0.50f + 0.50f * max(dot(normal, u.sun.xyz), 0.0f);
    float dataLight = 0.78f + 0.22f * light;

    // Concrete grey, shading through amber to dark red as plastic strain approaches failure.
    float damage = clamp(in.damage, 0.0f, 1.0f);
    float3 tint = damage < 0.5f
        ? mix(float3(0.98f, 0.82f, 0.25f), float3(0.93f, 0.42f, 0.12f), damage * 2.0f)
        : mix(float3(0.93f, 0.42f, 0.12f), float3(0.55f, 0.06f, 0.08f), damage * 2.0f - 1.0f);
    float3 colour = mix(float3(0.80f, 0.79f, 0.76f) * light, tint * dataLight, smoothstep(0.0f, 0.08f, damage));
    if (in.damage > 1.5f) {
        colour = float3(0.36f, 0.33f, 0.31f) * light;  // rubble
    }
    return float4(colour, 1.0f);
}

// Glass, drawn after everything opaque and blended over it without writing depth. Clear float
// glass is a faint green-blue; it reflects the sky more as the view grazes it (Schlick's
// approximation to the Fresnel term, with 4% reflected head-on) and shows a sharp highlight
// of the sun. Cracking turns it milky and opaque, so damage still reads, and its shards are
// pale, glinting chips.
fragment float4 glassFragment(MeshOut in [[stage_in]], constant MeshUniforms &u [[buffer(0)]]) {
    float3 normal = normalize(cross(dfdx(in.world), dfdy(in.world)));
    float3 view = normalize(u.eye.xyz - in.world);
    if (dot(normal, view) < 0.0f) {
        normal = -normal;
    }
    float facing = saturate(dot(normal, view));
    float fresnel = 0.04f + 0.96f * pow(1.0f - facing, 5.0f);
    float3 reflected = reflect(-view, normal);
    float3 sky = mix(float3(0.36f, 0.37f, 0.38f), mix(float3(0.78f, 0.84f, 0.90f), float3(0.40f, 0.55f, 0.80f),
                                                      saturate(reflected.z)),
                     smoothstep(-0.15f, 0.15f, reflected.z));
    float glint = pow(saturate(dot(reflected, u.sun.xyz)), 300.0f);
    float3 tint = float3(0.55f, 0.74f, 0.74f);

    if (in.damage > 1.5f) {
        float light = 0.6f + 0.4f * saturate(dot(normal, u.sun.xyz));
        float3 colour = mix(float3(0.70f, 0.84f, 0.86f) * light, sky, 0.35f) + 4.0f * glint;
        return float4(colour, 0.85f);
    }
    float3 colour = mix(tint * 0.5f, sky, fresnel) + 3.0f * glint;
    float alpha = 0.16f + 0.75f * fresnel + glint;
    // Cracked: frosted white, from a hairline to fully crazed as the damage index rises.
    float crazed = smoothstep(0.02f, 0.6f, saturate(in.damage));
    float light = 0.65f + 0.35f * saturate(dot(normal, u.sun.xyz));
    colour = mix(colour, float3(0.90f, 0.93f, 0.94f) * light, crazed);
    alpha = mix(alpha, 0.85f, crazed);
    return float4(colour, saturate(alpha));
}

// Second pass: lays the blast wave over the finished scene.
fragment float4 compositeFragment(VertexOut in [[stage_in]],
                                  constant RenderUniforms &u [[buffer(0)]],
                                  texture2d<float> sceneColour [[texture(0)]],
                                  depth2d<float> sceneDepth [[texture(1)]],
                                  texture3d<float> field [[texture(2)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    uint2 pixel = uint2(in.position.xy);
    float3 colour = sceneColour.read(pixel).rgb;
    float depth = sceneDepth.read(pixel);

    float3 origin = u.eye.xyz;
    float3 direction = normalize(u.forward.xyz + in.ndc.x * u.right.xyz + in.ndc.y * u.up.xyz);
    float3 inverseDirection = 1.0f / direction;
    float3 domain = u.domain.xyz;
    float nearest = depth < 1.0f
        ? viewFromDepth(depth, u.clip.x, u.clip.y) / dot(direction, u.forward.xyz) : 1.0e9f;

    // Outline of the box being edited, drawn over whatever surface it coincides with.
    if (u.highlightLow.w > 0.0f) {
        float t;
        float3 normal;
        float3 low = u.highlightLow.xyz - 0.03f;
        float3 high = u.highlightHigh.xyz + 0.03f;
        if (hitBox(origin, inverseDirection, low, high, t, normal) && t < nearest + 0.25f) {
            float3 p = origin + t * direction;
            float3 inset = min(p - low, high - p);
            float edge = fabs(normal.x) > 0.5f ? min(inset.y, inset.z)
                : (fabs(normal.y) > 0.5f ? min(inset.x, inset.z) : min(inset.x, inset.y));
            float thickness = 0.004f * t;  // a few pixels at any distance
            float line = 1.0f - smoothstep(thickness, 2.0f * thickness, edge);
            colour = mix(colour, float3(0.10f, 0.85f, 1.0f), max(line, 0.22f));
        }
    }

    // Blast wave: march the shock indicator between the domain bounds and the first surface.
    float opacity = u.display.w;
    if (opacity > 0.0f) {
        float3 t0 = (float3(0.0f) - origin) * inverseDirection;
        float3 t1 = (domain - origin) * inverseDirection;
        float3 nearT = min(t0, t1);
        float3 farT = max(t0, t1);
        float enter = max(max(nearT.x, max(nearT.y, nearT.z)), 0.0f);
        float leave = min(min(farT.x, min(farT.y, farT.z)), nearest);
        if (leave > enter) {
            const int steps = 192;
            float stepLength = (leave - enter) / float(steps);
            float jitter = fract(sin(dot(in.position.xy, float2(12.9898f, 78.233f))) * 43758.5453f);
            float3 accumulated = float3(0.0f);
            float transmittance = 1.0f;
            float3 inverseDomain = 1.0f / domain;
            for (int s = 0; s < steps; ++s) {
                float3 p = origin + (enter + (float(s) + jitter) * stepLength) * direction;
                float t = logScale(field.sample(linearSampler, p * inverseDomain).a, u.counts.w, u.display.z);
                float alpha = 1.0f - exp(-t * t * t * opacity * stepLength);
                accumulated += transmittance * alpha * heat(0.25f + 0.75f * t);
                transmittance *= 1.0f - alpha;
                if (transmittance < 0.02f) {
                    break;
                }
            }
            colour = colour * transmittance + accumulated;
        }
    }

    return float4(colour, 1.0f);
}
