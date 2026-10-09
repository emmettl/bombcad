// What blocks a receiver's view of the fireball, on the GPU's ray-tracing hardware: see
// MetalThermalVisibility.swift. Compiled on its own, in safe math mode, so that each test is the
// same arithmetic as CPUThermalVisibility's.

#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace raytracing;

// Seven floats, as ThermalRay stores them.
struct ThermalRay {
    packed_float3 origin;
    packed_float3 direction;
    float length;
};

struct ThermalBox {
    float3 lower;
    float3 upper;
};

// Whether `box` lies across the segment from `start` to `end`; an end inside it counts. As
// CPUThermalVisibility.blocks, operation for operation.
static bool thermalBlocks(ThermalBox box, float3 start, float3 end) {
    float3 delta = end - start;
    float low = 0;
    float high = 1;
    for (int axis = 0; axis < 3; axis++) {
        if (fabs(delta[axis]) < 1e-12f) {
            if (start[axis] < box.lower[axis] || start[axis] > box.upper[axis]) return false;
            continue;
        }
        float a = (box.lower[axis] - start[axis]) / delta[axis];
        float b = (box.upper[axis] - start[axis]) / delta[axis];
        if (a > b) {
            float swapped = a;
            a = b;
            b = swapped;
        }
        low = max(low, a);
        high = min(high, b);
        if (low > high) return false;
    }
    return true;
}

// One thread a ray: 1 in `visible` if it reaches its end above the ground with no box across it.
// The acceleration structure holds the boxes, a little enlarged, as bounding-box primitives; the
// hardware finds the candidates and the exact test above decides, so no intersection function is
// needed. The ground is the plane z = 0, tested directly.
kernel void thermalVisibility(
    device const ThermalRay *rays [[buffer(0)]],
    device const ThermalBox *boxes [[buffer(1)]],
    primitive_acceleration_structure structure [[buffer(2)]],
    device uchar *visible [[buffer(3)]],
    constant uint &count [[buffer(4)]],
    uint id [[thread_position_in_grid]])
{
    if (id >= count) return;
    ThermalRay r = rays[id];
    float3 origin = r.origin;
    float3 direction = r.direction;
    float3 end = origin + r.length * direction;
    if (!(end.z >= 0)) {
        visible[id] = 0;
        return;
    }
    ray query(origin, direction, 0.0f, r.length * 1.001f + 0.01f);
    intersection_params params;
    params.accept_any_intersection(true);
    params.assume_geometry_type(geometry_type::bounding_box);
    intersection_query<> candidates;
    candidates.reset(query, structure, params);
    bool blocked = false;
    while (candidates.next()) {
        if (thermalBlocks(boxes[candidates.get_candidate_primitive_id()], origin, end)) {
            blocked = true;
            candidates.abort();
        }
    }
    visible[id] = blocked ? 0 : 1;
}
