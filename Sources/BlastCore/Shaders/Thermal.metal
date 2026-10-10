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

// The terrain's cells, as TerrainSight reads them: see ThermalTerrain.swift. Cells come after the
// boxes in the acceleration structure, from primitive `firstCell`, (columns + 1) × (rows + 1) of
// them, the outer ring reaching `reach` beyond the nodes. `present` is 0 with no terrain.
struct ThermalTerrain {
    float originX;
    float originY;
    float spacing;
    float reach;
    uint columns;
    uint rows;
    uint firstCell;
    uint present;
};

struct TerrainPatch {
    float x0, y0, x1, y1;
    float h00, h10, h01, h11;
    float top;
    float sx, sy;
};

static void terrainNodes(int a, int count, thread int &low, thread int &high) {
    low = min(max(a - 1, 0), count - 1);
    high = min(max(a, 0), count - 1);
}

static void terrainSpan(int a, int count, float origin, float spacing, float reach, thread float &low,
    thread float &high)
{
    low = a == 0 ? origin - reach : origin + float(a - 1) * spacing;
    high = a == count ? origin + float(count - 1) * spacing + reach : origin + float(a) * spacing;
}

// As TerrainSight.patch.
static TerrainPatch terrainPatch(constant ThermalTerrain &t, device const float *heights, uint cell) {
    int columns = int(t.columns);
    int rows = int(t.rows);
    int a = int(cell % (t.columns + 1));
    int b = int(cell / (t.columns + 1));
    int i0, i1, j0, j1;
    terrainNodes(a, columns, i0, i1);
    terrainNodes(b, rows, j0, j1);
    TerrainPatch p;
    terrainSpan(a, columns, t.originX, t.spacing, t.reach, p.x0, p.x1);
    terrainSpan(b, rows, t.originY, t.spacing, t.reach, p.y0, p.y1);
    p.h00 = heights[i0 + columns * j0];
    p.h10 = heights[i1 + columns * j0];
    p.h01 = heights[i0 + columns * j1];
    p.h11 = heights[i1 + columns * j1];
    p.top = max(max(p.h00, p.h10), max(p.h01, p.h11));
    float inverse = 1 / t.spacing;
    p.sx = i0 == i1 ? 0 : inverse;
    p.sy = j0 == j1 ? 0 : inverse;
    return p;
}

// As TerrainSight.margin.
static float terrainMargin(float top) { return fma(1e-5f, fabs(top), 0.001f); }

// As TerrainSight.clearance: the height of `point` above the patch.
static float terrainClearance(TerrainPatch p, float3 point) {
    float fx = (point.x - p.x0) * p.sx;
    float fy = (point.y - p.y0) * p.sy;
    float bottom = fma(fx, p.h10 - p.h00, p.h00);
    float top = fma(fx, p.h11 - p.h01, p.h01);
    return point.z - fma(fy, top - bottom, bottom);
}

static bool terrainClipAxis(float lower, float upper, float s, float d, thread float &low, thread float &high) {
    if (fabs(d) < 1e-12f) return s >= lower && s <= upper;
    float a = (lower - s) / d;
    float b = (upper - s) / d;
    if (a > b) {
        float swapped = a;
        a = b;
        b = swapped;
    }
    low = max(low, a);
    high = min(high, b);
    return low <= high;
}

static bool terrainClip(TerrainPatch p, float3 start, float3 delta, thread float &low, thread float &high) {
    return terrainClipAxis(p.x0, p.x1, start.x, delta.x, low, high)
        && terrainClipAxis(p.y0, p.y1, start.y, delta.y, low, high);
}

static float3 terrainPoint(float3 start, float3 delta, float t) {
    return float3(fma(t, delta.x, start.x), fma(t, delta.y, start.y), fma(t, delta.z, start.z));
}

// As TerrainSight.slope: the clearance's rate of change, and half its second derivative.
static float2 terrainSlope(TerrainPatch p, float3 point, float3 delta) {
    float fx = (point.x - p.x0) * p.sx;
    float fy = (point.y - p.y0) * p.sy;
    float bx = delta.x * p.sx;
    float by = delta.y * p.sy;
    float twist = (p.h11 - p.h01) - (p.h10 - p.h00);
    float alongX = fma(fy, twist, p.h10 - p.h00);
    float alongY = fma(fx, twist, p.h01 - p.h00);
    float rate = delta.z - fma(bx, alongX, by * alongY);
    return float2(rate, -(bx * by) * twist);
}

// As TerrainSight.blocks.
static bool terrainBlocks(TerrainPatch p, float3 start, float3 delta) {
    float low = 0;
    float high = 1;
    if (!terrainClip(p, start, delta, low, high)) return false;
    float3 first = terrainPoint(start, delta, low);
    float3 last = terrainPoint(start, delta, high);
    // Above the patch's highest node throughout: nothing to find.
    if (min(first.z, last.z) > p.top + terrainMargin(p.top)) return false;
    if (terrainClearance(p, first) < 0 || terrainClearance(p, last) < 0) return true;
    float2 slope = terrainSlope(p, first, delta);
    if (!(slope.y > 0)) return false;
    float turn = low + -slope.x / (2 * slope.y);
    return turn > low && turn < high && terrainClearance(p, terrainPoint(start, delta, turn)) < 0;
}

// As TerrainSight.entry: where the ray first goes below the patch, if before `limit`.
static bool terrainEntry(TerrainPatch p, float3 origin, float3 direction, float limit, thread float &t) {
    float low = 0;
    float high = limit;
    if (!terrainClip(p, origin, direction, low, high)) return false;
    float3 first = terrainPoint(origin, direction, low);
    if (min(first.z, terrainPoint(origin, direction, high).z) > p.top + terrainMargin(p.top)) return false;
    float c0 = terrainClearance(p, first);
    if (c0 <= 0) {
        t = low;
        return low < limit;
    }
    float2 slope = terrainSlope(p, first, direction);
    float c1 = slope.x;
    float c2 = slope.y;
    float u = INFINITY;
    if (c2 == 0) {
        if (c1 < 0) u = -c0 / c1;
    } else {
        float disc = fma(c1, c1, -4 * c2 * c0);
        if (disc >= 0) {
            float q = -0.5f * (c1 + (c1 < 0 ? -sqrt(disc) : sqrt(disc)));
            float r1 = q / c2;
            float r2 = c0 / q;
            if (r1 > 0) u = min(u, r1);
            if (r2 > 0) u = min(u, r2);
        }
    }
    t = low + u;
    return isfinite(u) && t <= high && t < limit;
}

// One thread a ray: 1 in `visible` if it reaches its end above the ground with no box across it
// and without passing under the terrain. The acceleration structure holds the boxes, a little
// enlarged, and then the terrain's cells, as bounding-box primitives; the hardware finds the
// candidates and the exact tests above decide, so no intersection function is needed. The floor is
// the plane z = 0, tested directly.
kernel void thermalVisibility(
    device const ThermalRay *rays [[buffer(0)]],
    device const ThermalBox *boxes [[buffer(1)]],
    primitive_acceleration_structure structure [[buffer(2)]],
    device uchar *visible [[buffer(3)]],
    constant uint &count [[buffer(4)]],
    constant ThermalTerrain &terrain [[buffer(5)]],
    device const float *heights [[buffer(6)]],
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
    float3 delta = end - origin;
    while (candidates.next()) {
        uint primitive = candidates.get_candidate_primitive_id();
        bool blocks = primitive < terrain.firstCell
            ? thermalBlocks(boxes[primitive], origin, end)
            : terrainBlocks(terrainPatch(terrain, heights, primitive - terrain.firstCell), origin, delta);
        if (blocks) {
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
    constant ThermalTerrain &terrain [[buffer(8)]],
    device const float *heights [[buffer(9)]],
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
            // The nearest block, structure or terrain in the way: the hardware offers the boxes and
            // cells the ray may cross, and the exact tests decide, each one found shortening it.
            ray query(x, direction, 0.0f, leave);
            intersection_params params;
            params.assume_geometry_type(geometry_type::bounding_box);
            intersection_query<> candidates;
            candidates.reset(query, structure, params);
            while (candidates.next()) {
                float t;
                uint primitive = candidates.get_candidate_primitive_id();
                bool enters = primitive < terrain.firstCell
                    ? marchEntry(boxes[primitive], x, direction, leave, t)
                    : terrainEntry(
                        terrainPatch(terrain, heights, primitive - terrain.firstCell), x, direction, leave, t);
                if (enters) {
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
