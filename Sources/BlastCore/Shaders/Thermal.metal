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

// The fireball as a partly transparent volume: see FireballVolume.swift and MetalThermalMarch.swift.
// Each threadgroup is one receiver, its 64 threads sharing out the receiver's sampled directions,
// as CPUThermalMarch draws and follows them; the threads' sums are added in order, so the answer
// is the same from one run to the next.

struct MarchTile {
    packed_float3 centre;
    float radius;
    float compactness;
};

struct MarchReceiver {
    packed_float3 position;
    packed_float3 normal;
};

struct MarchUniforms {
    float lowX;
    float lowY;
    float lowZ;
    float voxelSize;
    uint nx;
    uint ny;
    uint nz;
    uint tileCount;
    uint samples;
    uint occluded;
    float step;
    uint unused;
};

constant uint marchThreads = 64;
constant uint marchMaximumTiles = 16;

// Where the ray enters `box`, if before `limit`, in `t`; zero if it starts inside. As
// CPUThermalMarch.entry.
static bool marchEntry(ThermalBox box, float3 origin, float3 direction, float limit, thread float &t) {
    float low = 0;
    float high = limit;
    for (int axis = 0; axis < 3; axis++) {
        if (direction[axis] == 0) {
            if (origin[axis] < box.lower[axis] || origin[axis] > box.upper[axis]) return false;
            continue;
        }
        float a = (box.lower[axis] - origin[axis]) / direction[axis];
        float b = (box.upper[axis] - origin[axis]) / direction[axis];
        if (a > b) {
            float swapped = a;
            a = b;
            b = swapped;
        }
        low = max(low, a);
        high = min(high, b);
        if (low > high) return false;
    }
    t = low;
    return low < limit;
}

// The gas at `point`, as ThermalMedium.gas: the voxels' share, κ and κB interpolated between their
// centres, and the gas where the share is at least a half: the share in x, and there its κ in y
// and its radiance in z.
static float3 marchGas(device const float4 *medium, constant MarchUniforms &u, float3 point) {
    float3 low = float3(u.lowX, u.lowY, u.lowZ);
    int3 n = int3(u.nx, u.ny, u.nz);
    float3 v = (point - low) / u.voxelSize - 0.5f;
    float3 base = floor(v);
    float3 f = v - base;
    int3 corner = int3(base);
    float share = 0;
    float kappa = 0;
    float emission = 0;
    for (int dz = 0; dz <= 1; dz++) {
        for (int dy = 0; dy <= 1; dy++) {
            for (int dx = 0; dx <= 1; dx++) {
                int3 cell = corner + int3(dx, dy, dz);
                if (any(cell < 0) || any(cell >= n)) continue;
                float w = (dx == 1 ? f.x : 1 - f.x) * (dy == 1 ? f.y : 1 - f.y) * (dz == 1 ? f.z : 1 - f.z);
                float4 voxel = medium[cell.x + n.x * (cell.y + n.y * cell.z)];
                share += w * voxel.x;
                kappa += w * voxel.y;
                emission += w * voxel.z;
            }
        }
    }
    if (!(share >= 0.5f) || !(kappa > 0)) return float3(share, 0, 0);
    return float3(share, kappa / share, emission / kappa);
}

// One step of `length` between two samples, as ThermalMedium.step: what it emits in x, and what it
// lets through in y.
static float2 marchStep(float3 a, float3 b, float length) {
    bool inA = a.y > 0;
    bool inB = b.y > 0;
    if (!inA && !inB) return float2(0, 1);
    float kappa;
    float radiance;
    float span = length;
    if (inA && inB) {
        kappa = 0.5f * (a.y + b.y);
        radiance = (a.y * a.z + b.y * b.z) / (a.y + b.y);
    } else {
        float3 inside = inA ? a : b;
        float3 outside = inA ? b : a;
        kappa = inside.y;
        radiance = inside.z;
        span = length * min(max((inside.x - 0.5f) / max(inside.x - outside.x, 1e-6f), 0.0f), 1.0f);
    }
    float passed = exp(-kappa * span);
    return float2(radiance * (1 - passed), passed);
}

// The radiance reaching `origin` along `direction` from the medium between `enter` and `leave`,
// as ThermalMedium.radiance: through the voxels where gas may be found, steps of at most `u.step`,
// each emitting as marchStep, dimmed by those before.
static float marchRadiance(
    device const float4 *medium, constant MarchUniforms &u, float3 origin, float3 direction, float enter,
    float leave)
{
    float3 low = float3(u.lowX, u.lowY, u.lowZ);
    int3 n = int3(u.nx, u.ny, u.nz);
    float h = u.voxelSize;
    float3 start = (origin + enter * direction - low) / h;
    int3 cell = int3(clamp(floor(start), float3(0), float3(n - 1)));
    int3 stride = int3(0);
    float3 next = float3(INFINITY);
    float3 delta = float3(INFINITY);
    for (int axis = 0; axis < 3; axis++) {
        if (direction[axis] == 0) continue;
        stride[axis] = direction[axis] > 0 ? 1 : -1;
        float boundary = low[axis] + (float(cell[axis]) + (direction[axis] > 0 ? 1.0f : 0.0f)) * h;
        next[axis] = (boundary - origin[axis]) / direction[axis];
        delta[axis] = h / fabs(direction[axis]);
    }
    float distance = enter;
    float radiance = 0;
    float through = 1;
    // The last sample, if it was at `distance`.
    bool hasLast = false;
    float3 last = float3(0);
    while (true) {
        int axis;
        if (next.x < next.y) {
            axis = next.x < next.z ? 0 : 2;
        } else {
            axis = next.y < next.z ? 1 : 2;
        }
        float end = min(next[axis], leave);
        if (medium[cell.x + n.x * (cell.y + n.y * cell.z)].w > 0 && end > distance) {
            int steps = max(1, int(ceil((end - distance) / u.step)));
            float length = (end - distance) / float(steps);
            float3 a = hasLast ? last : marchGas(medium, u, origin + distance * direction);
            for (int s = 1; s <= steps; s++) {
                float3 b = marchGas(medium, u, origin + (distance + float(s) * length) * direction);
                float2 part = marchStep(a, b, length);
                radiance += through * part.x;
                through *= part.y;
                a = b;
            }
            last = a;
            hasLast = true;
            if (through < 1e-4f) break;
        } else {
            hasLast = false;
        }
        if (next[axis] >= leave) break;
        distance = next[axis];
        cell[axis] += stride[axis];
        if (cell[axis] < 0 || cell[axis] >= n[axis]) break;
        next[axis] += delta[axis];
    }
    return radiance;
}

kernel void thermalMarch(
    device const float4 *medium [[buffer(0)]],
    device const MarchTile *tiles [[buffer(1)]],
    device const MarchReceiver *receivers [[buffer(2)]],
    device const packed_float3 *spiral [[buffer(3)]],
    device const ThermalBox *boxes [[buffer(4)]],
    primitive_acceleration_structure structure [[buffer(5)]],
    device float *irradiance [[buffer(6)]],
    constant MarchUniforms &u [[buffer(7)]],
    uint receiver [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]])
{
    threadgroup float partial[marchThreads];
    float3 x = float3(receivers[receiver].position);
    float3 normal = float3(receivers[receiver].normal);
    // The cones, as SamplingCone.cones.
    float3 axes[marchMaximumTiles];
    float cosHalf[marchMaximumTiles];
    float shares[marchMaximumTiles];
    int counts[marchMaximumTiles];
    float densities[marchMaximumTiles];
    int cones = 0;
    float total = 0;
    for (uint t = 0; t < u.tileCount && t < marchMaximumTiles; t++) {
        float3 toCentre = float3(tiles[t].centre) - x;
        float d = length(toCentre);
        float radius = tiles[t].radius;
        float solidAngle;
        if (d <= radius) {
            axes[cones] = normal;
            cosHalf[cones] = 0;
            solidAngle = 2 * M_PI_F;
        } else {
            if (dot(normal, toCentre) < -radius) continue;
            float c = sqrt(max(0.0f, 1 - (radius / d) * (radius / d)));
            axes[cones] = toCentre / d;
            cosHalf[cones] = c;
            solidAngle = 2 * M_PI_F * (1 - c);
        }
        densities[cones] = solidAngle;
        shares[cones] = solidAngle * pow(min(tiles[t].compactness, 1.0f), 2.0f / 3.0f);
        total += shares[cones];
        cones++;
    }
    int rays = 0;
    if (total > 0) {
        for (int c = 0; c < cones; c++) {
            counts[c] = max(4, int(round(float(u.samples) * shares[c] / total)));
            densities[c] = float(counts[c]) / densities[c];
            rays += counts[c];
        }
    }
    float3 low = float3(u.lowX, u.lowY, u.lowZ);
    float3 high = low + float3(u.nx, u.ny, u.nz) * u.voxelSize;
    float sum = 0;
    for (int r = int(lane); r < rays; r += int(marchThreads)) {
        int c = 0;
        int s = r;
        while (s >= counts[c]) {
            s -= counts[c];
            c++;
        }
        float3 axis = axes[c];
        float3 helper = fabs(axis.z) < 0.9f ? float3(0, 0, 1) : float3(1, 0, 0);
        float3 uAxis = normalize(cross(axis, helper));
        float3 vAxis = cross(axis, uAxis);
        float cosine = 1 - (float(s) + 0.5f) / float(counts[c]) * (1 - cosHalf[c]);
        float sine = sqrt(max(0.0f, 1 - cosine * cosine));
        float3 sample = float3(spiral[s]);
        float3 direction = cosine * axis + sine * (sample.y * uAxis + sample.z * vAxis);
        float cosReceiver = dot(normal, direction);
        if (!(cosReceiver > 0)) continue;
        float limit = INFINITY;
        if (direction.z < 0) limit = -x.z / direction.z;
        // Where the ray is within the medium's box, short of the ground.
        float enter = 0;
        float leave = limit;
        bool misses = false;
        for (int a = 0; a < 3; a++) {
            if (direction[a] == 0) {
                if (x[a] < low[a] || x[a] > high[a]) misses = true;
                continue;
            }
            float p = (low[a] - x[a]) / direction[a];
            float q = (high[a] - x[a]) / direction[a];
            if (p > q) {
                float swapped = p;
                p = q;
                q = swapped;
            }
            enter = max(enter, p);
            leave = min(leave, q);
        }
        if (misses || !(enter < leave)) continue;
        if (u.occluded != 0) {
            // The nearest block or structure in the way: the hardware offers the boxes the ray
            // may cross, and the exact test decides, each one found shortening the ray.
            ray query(x, direction, 0.0f, leave);
            intersection_params params;
            params.assume_geometry_type(geometry_type::bounding_box);
            intersection_query<> candidates;
            candidates.reset(query, structure, params);
            while (candidates.next()) {
                float t;
                if (marchEntry(boxes[candidates.get_candidate_primitive_id()], x, direction, leave, t)) {
                    leave = t;
                    candidates.commit_bounding_box_intersection(t);
                }
            }
            if (!(enter < leave)) continue;
        }
        float radiance = marchRadiance(medium, u, x, direction, enter, leave);
        if (!(radiance > 0)) continue;
        float density = densities[c];
        for (int other = 0; other < cones; other++) {
            if (other != c && dot(direction, axes[other]) >= cosHalf[other]) density += densities[other];
        }
        sum += cosReceiver * radiance / density;
    }
    partial[lane] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane == 0) {
        float result = 0;
        for (uint n = 0; n < marchThreads; n++) result += partial[n];
        irradiance[receiver] = result;
    }
}
