#include <metal_stdlib>
using namespace metal;

// One texel of a field `stride` times coarser along each axis than the solver's visualisation
// (updateVisualization in Solver.metal: r overpressure, g peak and a shock indicator, all over
// ambient, b impulse), for a view sent elsewhere. Each channel keeps the block's extreme rather
// than its mean, so a front one cell thick still shows: the largest peak, impulse and shock
// indicator, and the overpressure of the largest magnitude, its sign kept.
kernel void coarsenField(texture3d<float, access::read> fine [[texture(0)]],
                         texture3d<float, access::write> coarse [[texture(1)]],
                         constant uint &stride [[buffer(0)]],
                         uint3 tid [[thread_position_in_grid]]) {
    uint3 coarseSize = uint3(coarse.get_width(), coarse.get_height(), coarse.get_depth());
    if (any(tid >= coarseSize)) {
        return;
    }
    uint3 fineSize = uint3(fine.get_width(), fine.get_height(), fine.get_depth());
    float4 best = float4(0.0f);
    float strongest = -1.0f;
    for (uint z = 0; z < stride; ++z) {
        for (uint y = 0; y < stride; ++y) {
            for (uint x = 0; x < stride; ++x) {
                uint3 p = tid * stride + uint3(x, y, z);
                if (any(p >= fineSize)) {
                    continue;
                }
                float4 value = fine.read(p);
                if (abs(value.r) > strongest) {
                    strongest = abs(value.r);
                    best.r = value.r;
                }
                best.gba = max(best.gba, value.gba);
            }
        }
    }
    coarse.write(best, tid);
}
