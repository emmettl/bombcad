#include <metal_stdlib>
using namespace metal;

// Layout matches SceneGeometry.Vertex: position with the pick number in w, normal, colour.
struct SceneVertex {
    float4 position;
    float4 normal;
    float4 colour;
};

// Layout matches SceneUniforms in MeshRenderer.swift.
struct SceneUniforms {
    float4x4 viewProjection;
    float4 eye;
    // x: the pick number to highlight, or -1; y: depth bias for lines, in clip units.
    float4 options;
    float4 highlight;
};

struct Fragment {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float4 colour;
    float pick;
};

static Fragment transform(SceneVertex v, constant SceneUniforms &uniforms) {
    Fragment out;
    out.position = uniforms.viewProjection * float4(v.position.xyz, 1);
    out.world = v.position.xyz;
    out.normal = v.normal.xyz;
    out.colour = v.colour;
    out.pick = v.position.w;
    return out;
}

vertex Fragment sceneVertex(
    uint id [[vertex_id]], const device SceneVertex *vertices [[buffer(0)]],
    constant SceneUniforms &uniforms [[buffer(1)]])
{
    return transform(vertices[id], uniforms);
}

vertex Fragment lineVertex(
    uint id [[vertex_id]], const device SceneVertex *vertices [[buffer(0)]],
    constant SceneUniforms &uniforms [[buffer(1)]])
{
    Fragment out = transform(vertices[id], uniforms);
    // Drawn a little in front of the faces they outline.
    out.position.z -= uniforms.options.y * out.position.w;
    return out;
}

// Lit by a light at the eye, so whatever faces the viewer is brightest, with an ambient floor.
fragment float4 litFragment(Fragment in [[stage_in]], constant SceneUniforms &uniforms [[buffer(1)]]) {
    float3 toEye = normalize(uniforms.eye.xyz - in.world);
    float diffuse = abs(dot(normalize(in.normal), toEye));
    float3 colour = in.colour.rgb * (0.55 + 0.45 * diffuse);
    if (uniforms.options.x >= 0 && abs(in.pick - uniforms.options.x) < 0.5) {
        colour = mix(colour, uniforms.highlight.rgb, uniforms.highlight.a);
    }
    return float4(colour, in.colour.a);
}

fragment float4 flatFragment(Fragment in [[stage_in]]) {
    return in.colour;
}
