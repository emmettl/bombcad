#include <metal_stdlib>
using namespace metal;

// The live drag (emmettl/bombcad-work#112; docs/learned-models.md, "The live drag's learned
// response"): each chosen component's sight line from the charge, its features and its predicted
// loads (`liveLoads`), as FacadeLoadSurrogate's `features` and `predict` give them on the CPU, in
// float; and the learned response's small networks (`liveDense`). The CPU's code is the reference
// (`LiveResponse.CPUEngine`); `LiveDragGPUTests` holds them together.

// The district's raster and terrain (`FacadeLoadSurrogate.Raster`, `Terrain`); mirrored by
// `LiveDragGPU.RasterParameters` in Swift.
struct LiveRaster {
    float2 origin;
    float cell;
    int columns;
    int rows;
    int hasTerrain;
    float2 terrainOrigin;
    float terrainSpacing;
    int terrainColumns;
    int terrainRows;
    int itemCount;
    float4 charge;      // xyz; w the charge's open reach, m (`Raster.openReach`)
    float4 masses;      // the yield, kg; the yield times e^`slopeStep`; the cell for the terms, m
};

// The surrogate's coefficients (`FacadeLoadSurrogate.Coefficients`), all floats, mirrored by
// `LiveDragGPU.packed(_:)` in Swift in this order.
struct LiveCoefficients {
    float peak[14];
    float impulse[14];
    float rise[14];
    float structureRise[14];
    float scaledLow;
    float scaledHigh;
    float hasFar;
    float farDepthFrom;
    float farDistanceFrom;
    float farPeakDepth;
    float farPeakAway;
    float hasCloseIn;
    float closePeak[3];
    float closeImpulse[3];
    float closeReferenceCell;
    float closeHeldLow;
    float closeHeldHigh;
    float closeBlendTo;
    float closeInSightOnly;
    float hasShielding;
    float shieldPeak;
    float shieldImpulse;
    float shieldOpenScale;
    float frontCount;
    float frontMinimumMass;
    float frontPoints[16];
};

struct LiveEntry {
    float low;
    float high;
    int owner;
    int unused;
};

constant float edgeSideReachM = 200.0f;
constant float canyonReachM = 25.0f;
constant float canyonWallM = 2.0f;
constant float canyonLongestM = 600.0f;
constant float frontReachM = 200.0f;
constant int liveFeatures = 18;
constant int liveOutputs = 26;

static float terrainHeight(constant LiveRaster &r, device const float *heights, float2 p) {
    if (r.hasTerrain == 0) return 0.0f;
    float2 last = float2(float(r.terrainColumns - 1), float(r.terrainRows - 1));
    float2 position = clamp((p - r.terrainOrigin) / r.terrainSpacing, float2(0.0f), last);
    float2 f0 = floor(position);
    int2 low = min(int2(int(f0.x), int(f0.y)), int2(r.terrainColumns - 2, r.terrainRows - 2));
    float2 f = position - float2(low);
    int base = low.x + r.terrainColumns * low.y;
    float h00 = heights[base];
    float h10 = heights[base + 1];
    float h01 = heights[base + r.terrainColumns];
    float h11 = heights[base + r.terrainColumns + 1];
    float bottom = h00 + f.x * (h10 - h00);
    float top = h01 + f.x * (h11 - h01);
    return bottom + f.y * (top - bottom);
}

static bool cellIndex(constant LiveRaster &r, float2 p, thread int &n) {
    float2 f = floor((p - r.origin) / r.cell);
    int cx = int(f.x);
    int cy = int(f.y);
    if (cx < 0 || cy < 0 || cx >= r.columns || cy >= r.rows) return false;
    n = cx + r.columns * cy;
    return true;
}

static bool isSolid(constant LiveRaster &r, device const float *heights, device const int *starts,
                    device const LiveEntry *entries, float3 p, int excluding) {
    if (r.hasTerrain != 0 && p.z < terrainHeight(r, heights, p.xy)) return true;
    int n;
    if (!cellIndex(r, p.xy, n)) return false;
    for (int e = starts[n]; e < starts[n + 1]; ++e) {
        LiveEntry entry = entries[e];
        if (entry.owner != excluding && p.z >= entry.low && p.z < entry.high) return true;
    }
    return false;
}

// Kingery–Bulmash's fits (Swisdak 1994, Table 1, metric), as `KingeryBulmash.evaluate`.
static float poly(float u, constant float *c, int count) {
    float power = 1.0f;
    float sum = 0.0f;
    for (int k = 0; k < count; ++k) {
        sum += c[k] * power;
        power *= u;
    }
    return exp(sum);
}

constant float incidentA[5] = {7.2106f, -2.1069f, -0.3229f, 0.1117f, 0.0685f};
constant float incidentB[5] = {7.5938f, -3.0523f, 0.40977f, 0.0261f, -0.01267f};
constant float incidentC[2] = {6.0536f, -1.4066f};
constant float reflectedA[7] = {9.006f, -2.6893f, -0.6295f, 0.1011f, 0.29255f, 0.13505f, 0.019736f};
constant float reflectedB[7] = {8.8396f, -1.733f, -2.64f, 2.293f, -0.8232f, 0.14247f, -0.0099f};
constant float impulseA[5] = {5.522f, 1.117f, 0.6f, -0.292f, -0.087f};
constant float impulseB[5] = {5.465f, -0.308f, -1.464f, 1.362f, -0.432f};
constant float impulseC[5] = {5.2749f, -0.4677f, -0.2499f, 0.0588f, -0.00554f};
constant float impulseD[2] = {5.9825f, -1.062f};
constant float reflectedImpulseA[4] = {6.7853f, -1.3466f, 0.101f, -0.01123f};

// The base load (`FacadeLoadSurrogate.base`): peak, Pa, and impulse, Pa s.
static float2 baseLoad(float distance, float cosine, float mass) {
    float root = powr(mass, 1.0f / 3.0f);
    float z = clamp(distance / root, 0.2f, 40.0f);
    float u = log(z);
    float incident = (z <= 2.9f ? poly(u, incidentA, 5) : z <= 23.8f ? poly(u, incidentB, 5) : poly(u, incidentC, 2)) * 1000.0f;
    float reflected = (z <= 2.0f ? poly(u, reflectedA, 7) : poly(u, reflectedB, 7)) * 1000.0f;
    float incidentImpulse = z <= 0.96f ? poly(u, impulseA, 5) : z <= 2.38f ? poly(u, impulseB, 5)
                          : z <= 33.7f ? poly(u, impulseC, 5) : poly(u, impulseD, 2);
    float reflectedImpulse = poly(u, reflectedImpulseA, 4);
    float facing = max(cosine, 0.0f) * max(cosine, 0.0f);
    float peak = incident + facing * (reflected - incident);
    float impulse = (incidentImpulse + facing * (reflectedImpulse - incidentImpulse)) * root;
    float scaled = distance / root;
    float far = scaled > 40.0f ? 40.0f / scaled : 1.0f;
    return float2(peak * far, impulse * far);
}

// The features' indices in `liveLoads`' output, as `FacadeLoadSurrogate.Features`.
enum LiveFeature {
    fDistance, fCos, fCrossed, fBlocked, fRidge, fGroundRise, fHeight, fShadow, fFront, fEdge,
    fEdgeFrom, fEdgeTo, fEdgeTop, fEdgeSide, fEdgeWidth, fLastTop, fCanyon, fCanyonHeight
};

// A prediction (`FacadeLoadSurrogate.predict`): peak, impulse, rise share, the walls' rise share
// (`structureRise`), and the glass's front share (`Coefficients.GlassFront`).
static void predictLoad(thread const float *f, float open, float mass, float cellSize, float learnedFactor,
                        constant LiveCoefficients &c, thread float *out) {
    float root = powr(mass, 1.0f / 3.0f);
    float scaled0 = max(f[fDistance] / root, 0.2f);
    float scaledTerms = clamp(scaled0, c.scaledLow, c.scaledHigh);
    float z = log(scaledTerms);
    // The canyon's terms (`canyonTerms`).
    float canyonPeak = 0.0f;
    float canyonImpulse = 0.0f;
    if (f[fCanyon] > 0.0f && f[fCanyonHeight] > 0.0f) {
        float l = f[fCanyon] / root;
        float h = f[fCanyonHeight] / root;
        float uu = log(max(scaled0, 2.0f) / max(scaled0 - l, 2.0f));
        canyonPeak = uu * exp(-l / (8.0f * h));
        canyonImpulse = h > 0.6f ? uu * exp(-l / (3.0f * h)) * (1.0f - exp(-(h - 0.6f))) : 0.0f;
    }
    float crossed = log(1.0f + f[fCrossed]);
    float x[14] = {
        1.0f, max(f[fCos], 0.0f), max(-f[fCos], 0.0f), crossed, f[fBlocked] / root, z, f[fHeight] / root,
        f[fRidge] / root, f[fGroundRise] / root, z * z, log(cellSize / root), crossed * crossed, canyonPeak,
        canyonImpulse};
    float p = 0.0f, i = 0.0f, r = 0.0f, rs = 0.0f;
    for (int k = 0; k < 14; ++k) {
        p += c.peak[k] * x[k];
        i += c.impulse[k] * x[k];
        r += c.rise[k] * x[k];
        rs += c.structureRise[k] * x[k];
    }
    if (c.hasFar != 0.0f) {
        float depth = max(crossed - log(1.0f + c.farDepthFrom), 0.0f);
        float away = (f[fDistance] > c.farDistanceFrom ? log(f[fDistance] / c.farDistanceFrom) : 0.0f) * max(-f[fCos], 0.0f);
        p += c.farPeakDepth * depth + c.farPeakAway * away;
    }
    float scaled = f[fDistance] / root;
    if (c.hasCloseIn != 0.0f && scaled < c.closeBlendTo && (c.closeInSightOnly == 0.0f || f[fCrossed] == 0.0f)) {
        float start = c.scaledLow;
        float zc = log(clamp(scaled, c.closeHeldLow, c.closeHeldHigh));
        float cell = log(cellSize / root) - log(c.closeReferenceCell);
        float geometryPeak = c.peak[12] * x[12] + c.peak[13] * x[13];
        float geometryImpulse = c.impulse[12] * x[12] + c.impulse[13] * x[13];
        float branchPeak = c.closePeak[0] + c.closePeak[1] * zc + c.closePeak[2] * zc * zc + c.peak[10] * cell + geometryPeak;
        float branchImpulse = c.closeImpulse[0] + c.closeImpulse[1] * zc + c.closeImpulse[2] * zc * zc
                            + c.impulse[10] * cell + geometryImpulse;
        float w = scaled <= start ? 0.0f : min(log(scaled / start) / log(c.closeBlendTo / start), 1.0f);
        float shieldPeak = 0.0f, shieldImpulse = 0.0f;
        if (c.hasShielding != 0.0f && f[fCrossed] > 0.0f && isfinite(open) && c.shieldOpenScale > 0.0f) {
            float share = exp(-open / (c.shieldOpenScale * root));
            shieldPeak = c.shieldPeak * share;
            shieldImpulse = c.shieldImpulse * share;
        }
        p = (1.0f - w) * (branchPeak + shieldPeak) + w * p;
        i = (1.0f - w) * (branchImpulse + shieldImpulse) + w * i;
    }
    float2 base = baseLoad(f[fDistance], f[fCos], mass);
    out[0] = base.x * exp(p) * learnedFactor;
    out[1] = base.y * exp(i);
    out[2] = min(max(r, 0.0f), 0.9f);
    out[3] = min(max(rs, 0.0f), 0.9f);
    // The glass's front (`GlassFront.share(atZ:mass:)`).
    float front = 0.0f;
    int count = int(c.frontCount);
    if (count > 0) {
        float zf = f[fDistance] / root;
        float share;
        if (zf <= c.frontPoints[0]) {
            share = c.frontPoints[1];
        } else if (zf >= c.frontPoints[2 * (count - 1)]) {
            share = c.frontPoints[2 * (count - 1) + 1];
        } else {
            int k = 1;
            while (k < count - 1 && c.frontPoints[2 * k] < zf) ++k;
            float ax = c.frontPoints[2 * (k - 1)], ay = c.frontPoints[2 * (k - 1) + 1];
            float bx = c.frontPoints[2 * k], by = c.frontPoints[2 * k + 1];
            share = ay + log(zf / ax) / log(bx / ax) * (by - ay);
        }
        if (mass < c.frontMinimumMass) {
            float taper = log(mass / (0.1f * c.frontMinimumMass)) / log(10.0f);
            share = taper > 0.0f ? taper * share : 0.0f;
        }
        front = share;
    }
    out[4] = front;
}

// Each item's features (`FacadeLoadSurrogate.features`) and its loads at the yield and at the yield
// times e^`slopeStep`: 26 floats an item, the 18 features then the peak, impulse, rise, walls' rise
// and front share at the yield, then the peak and impulse at the stepped yield, and the walls' rise
// there (unused). An item is its outer face's centre (xyz) and thin axis (w), the facing its cosine
// is taken from (xyz) and its way out (w), and its owner (index in the raster's objects), whether
// it takes the roofs' terms, and its learned peak factor.
kernel void liveLoads(constant LiveRaster &r [[buffer(0)]],
                      device const float *heights [[buffer(1)]],
                      device const int *starts [[buffer(2)]],
                      device const LiveEntry *entries [[buffer(3)]],
                      device const float *tops [[buffer(4)]],
                      device const float4 *centres [[buffer(5)]],
                      device const float4 *facings [[buffer(6)]],
                      device const int2 *owners [[buffer(7)]],
                      device const float *factors [[buffer(8)]],
                      constant LiveCoefficients &walls [[buffer(9)]],
                      constant LiveCoefficients &roofs [[buffer(10)]],
                      device float *output [[buffer(11)]],
                      uint id [[thread_position_in_grid]]) {
    if (int(id) >= r.itemCount) return;
    float4 cw = centres[id];
    float4 fw = facings[id];
    int axis = int(cw.w);
    float outward = fw.w;
    int owner = owners[id].x;
    float3 centre = cw.xyz;
    float3 normal = float3(0.0f);
    normal[axis] = outward;
    float3 charge = r.charge.xyz;
    float3 target = centre + 0.5f * r.cell * normal;
    float3 toCharge = charge - centre;
    float dist = length(toCharge);
    float cosine = dist > 0.0f ? dot(fw.xyz, toCharge) / dist : 1.0f;

    // The sight line (`Raster.sight`), from the charge to the target.
    float3 a = charge;
    float3 b = target;
    float groundA = terrainHeight(r, heights, a.xy);
    float groundB = terrainHeight(r, heights, b.xy);
    float aboveA = a.z - groundA;
    float aboveB = b.z - groundB;
    float lineLength = distance(a, b);
    float2 plan = b.xy - a.xy;
    int steps = max(1, int(ceil(length(plan) / (r.cell / 3.0f))));
    float stepLength = lineLength / float(steps);
    int crossed = 0;
    float blocked = 0.0f;
    int last = -1;
    int lastBlocked = -1;
    float ridge = 0.0f;
    float edgeScore = -INFINITY;
    float edgeM = -INFINITY, edgeFrom = 0.0f, edgeTo = 0.0f, edgeTop = 0.0f, lastTop = 0.0f;
    float3 edgeAt = float3(0.0f);
    bool hasEdge = false;
    for (int s = 0; s < steps; ++s) {
        float t = (float(s) + 0.5f) / float(steps);
        float3 p = a + t * (b - a);
        float ground = terrainHeight(r, heights, p.xy);
        ridge = max(ridge, ground - (groundA + t * (groundB - groundA)));
        p.z = ground + aboveA + t * (aboveB - aboveA);
        int n;
        if (!cellIndex(r, p.xy, n)) continue;
        int inside = -1;
        float top = -FLT_MAX;
        for (int e = starts[n]; e < starts[n + 1]; ++e) {
            LiveEntry entry = entries[e];
            if (entry.owner == owner) continue;
            top = max(top, entry.high);
            if (inside == -1 && p.z >= entry.low && p.z < entry.high) inside = entry.owner;
        }
        if (top > -FLT_MAX) {
            float from = max(t * lineLength, 1.0f);
            float to = max((1.0f - t) * lineLength, 1.0f);
            float over = top - p.z;
            float score = over * sqrt(1.0f / from + 1.0f / to);
            if (score > edgeScore) {
                edgeScore = score;
                edgeM = over;
                edgeFrom = from;
                edgeTo = to;
                edgeTop = top - ground;
                edgeAt = p;
                hasEdge = true;
            }
        }
        if (inside != -1) {
            blocked += stepLength;
            lastBlocked = s;
            lastTop = top - ground;
            if (inside != last) crossed += 1;
        }
        last = inside;
    }
    float shadow = lastBlocked < 0 ? 0.0f : float(steps - 1 - lastBlocked) * stepLength;
    float edgeSide = 0.0f, edgeWidth = 0.0f;
    if (hasEdge && edgeM > 0.0f && length(plan) > 0.0f) {
        float2 side = float2(-plan.y, plan.x) / length(plan);
        float reach[2];
        for (int k = 0; k < 2; ++k) {
            float2 direction = k == 0 ? side : -side;
            float d = 0.0f;
            bool done = false;
            while (d < edgeSideReachM) {
                float2 q = edgeAt.xy + (d + 0.5f * r.cell) * direction;
                int n;
                if (!cellIndex(r, q, n)) { done = true; break; }
                bool higher = false;
                for (int e = starts[n]; e < starts[n + 1]; ++e) {
                    if (entries[e].owner != owner && entries[e].high > edgeAt.z) higher = true;
                }
                if (!higher) { done = true; break; }
                d += r.cell;
            }
            reach[k] = done ? d : edgeSideReachM;
        }
        edgeSide = min(reach[0], reach[1]);
        edgeWidth = reach[0] + reach[1];
    }

    // The street the line runs down (`Raster.canyon`).
    float canyon = 0.0f, canyonHeight = 0.0f;
    float planLength = length(plan);
    if (planLength > 0.0f) {
        float2 along = plan / planLength;
        float2 side = float2(-along.y, along.x);
        float cstep = max(r.cell, 1.0f);
        float length0 = 0.0f;
        float heightSum = 0.0f;
        int count = 0;
        while (length0 < min(planLength, canyonLongestM)) {
            float t = 1.0f - length0 / planLength;
            float2 at = a.xy + t * plan;
            float ground = terrainHeight(r, heights, at);
            if (isSolid(r, heights, starts, entries, float3(at, ground + aboveA + t * (aboveB - aboveA)), -1000000)) break;
            float wallHeight[2];
            bool found[2] = {false, false};
            for (int k = 0; k < 2; ++k) {
                float2 direction = k == 0 ? side : -side;
                float d = 0.5f * r.cell;
                while (d <= canyonReachM) {
                    float2 q = at + d * direction;
                    int n;
                    if (cellIndex(r, q, n)) {
                        float h = tops[n] - terrainHeight(r, heights, q);
                        if (h >= canyonWallM) { wallHeight[k] = h; found[k] = true; break; }
                    }
                    d += r.cell;
                }
            }
            if (!found[0] || !found[1]) break;
            heightSum += min(wallHeight[0], wallHeight[1]);
            count += 1;
            length0 += cstep;
        }
        if (count > 0) {
            canyon = length0;
            canyonHeight = heightSum / float(count);
        }
    }

    // The open air in front of the face (`Raster.reach`).
    float front = frontReachM;
    float travelled = 0.0f;
    float halfCell = r.cell / 2.0f;
    while (travelled < frontReachM) {
        travelled += halfCell;
        if (isSolid(r, heights, starts, entries, target + travelled * normal, -1000000)) { front = travelled; break; }
    }

    float ground = terrainHeight(r, heights, centre.xy);
    float chargeGround = terrainHeight(r, heights, charge.xy);
    float f[18];
    f[fDistance] = dist;
    f[fCos] = cosine;
    f[fCrossed] = float(crossed);
    f[fBlocked] = blocked;
    f[fRidge] = ridge;
    f[fGroundRise] = ground - chargeGround;
    f[fHeight] = centre.z - ground;
    f[fShadow] = shadow;
    f[fFront] = front;
    f[fEdge] = edgeM;
    f[fEdgeFrom] = edgeFrom;
    f[fEdgeTo] = edgeTo;
    f[fEdgeTop] = edgeTop;
    f[fEdgeSide] = edgeSide;
    f[fEdgeWidth] = edgeWidth;
    f[fLastTop] = lastTop;
    f[fCanyon] = canyon;
    f[fCanyonHeight] = canyonHeight;
    device float *o = output + liveOutputs * id;
    for (int k = 0; k < liveFeatures; ++k) o[k] = f[k];
    constant LiveCoefficients &c = owners[id].y != 0 ? roofs : walls;
    float atYield[5];
    float stepped[5];
    predictLoad(f, r.charge.w, r.masses.x, r.masses.z, factors[id], c, atYield);
    predictLoad(f, r.charge.w, r.masses.y, r.masses.z, factors[id], c, stepped);
    for (int k = 0; k < 5; ++k) o[liveFeatures + k] = atYield[k];
    o[liveFeatures + 5] = stepped[0];
    o[liveFeatures + 6] = stepped[1];
    o[liveFeatures + 7] = stepped[3];
}

// After one of the learned response's layers (`LiveResponse.Network`), its matrix product done by
// MPS: each value its output's bias added, then SiLU unless it is the last layer. `shape` is the
// rows, the layer's (padded) outputs, and whether SiLU follows.
kernel void liveBias(device float *values [[buffer(0)]],
                     device const float *biases [[buffer(1)]],
                     constant int4 &shape [[buffer(2)]],
                     uint id [[thread_position_in_grid]]) {
    if (int(id) >= shape.x * shape.y) return;
    float sum = values[id] + biases[int(id) % shape.y];
    values[id] = shape.z != 0 ? sum / (1.0f + exp(-sum)) : sum;
}
