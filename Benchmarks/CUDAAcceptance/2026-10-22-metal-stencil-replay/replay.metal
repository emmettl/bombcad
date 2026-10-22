// Appended to the frozen Solver.metal. No production source replacement.
kernel void replayStencil(const device Cell *cells [[buffer(0)]],
                          const device int *signs [[buffer(1)]],
                          const device float *lambdas [[buffer(2)]],
                          constant SolverUniforms &u [[buffer(3)]],
                          device float *output [[buffer(4)]],
                          constant uint &count [[buffer(5)]],
                          uint tid [[thread_position_in_grid]]) {
    if (tid >= count) return;
    Prim w[5];
    for (uint i = 0; i < 5; ++i) {
        w[i] = primOfCell(cells[tid * 5 + i], u);
        if (signs[tid * 5 + i] < 0) w[i] = mirrored(w[i], 0.0f);
    }
    Flux low;
    Flux high;
    stencilFluxes(w[0], w[1], w[2], w[3], w[4], lambdas[tid], u, low, high);
    output[tid * 10 + 0] = low.mass;
    output[tid * 10 + 1] = low.momentum.x;
    output[tid * 10 + 2] = low.momentum.y;
    output[tid * 10 + 3] = low.momentum.z;
    output[tid * 10 + 4] = low.energy;
    output[tid * 10 + 5] = high.mass;
    output[tid * 10 + 6] = high.momentum.x;
    output[tid * 10 + 7] = high.momentum.y;
    output[tid * 10 + 8] = high.momentum.z;
    output[tid * 10 + 9] = high.energy;
}
