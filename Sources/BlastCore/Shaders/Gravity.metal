// Gravity's hydrostatic background (see `stencilFluxesGravity`), appended to Solver.metal at
// compile time.

// The background at rest in a cell, as a cell stores it.
static inline Cell backgroundCell(float z, constant SolverUniforms &u) {
    float2 b = hydrostatic(z, u);
    Cell c;
    c.rho = b.x;
    c.mx = 0.0f;
    c.my = 0.0f;
    c.mz = 0.0f;
    c.energy = gasEnergy(b.x, b.y, u.airModel, u.gamma);
    return c;
}

// One level's table (see `gravityCellOf`): row `tid` is cell `tid - gravityBelow` of size `dz`,
// the background as a cell stores it, then at its lower face.
kernel void gravityTable(device float4 *table [[buffer(0)]],
                         constant uint &rows [[buffer(1)]],
                         constant float &dz [[buffer(2)]],
                         constant SolverUniforms &u [[buffer(3)]],
                         uint tid [[thread_position_in_grid]]) {
    if (tid >= rows) {
        return;
    }
    float k = float(int(tid) - gravityBelow);
    Cell c = backgroundCell((k + 0.5f) * dz, u);
    table[2 * tid] = float4(c.rho, c.energy, 0.0f, 0.0f);
    table[2 * tid + 1] = float4(hydrostatic(k * dz, u), 0.0f, 0.0f);
}

// The air filled at rest in the background, every cell as the coarse grid's table holds it, so
// that the sweeps see no deviation from it; with afterburning, oxygen at `oxygen` of its density.
kernel void fillHydrostatic(device Cell *state [[buffer(0)]],
                            device float2 *species [[buffer(1)]],
                            constant float &oxygen [[buffer(2)]],
                            constant SolverUniforms &u [[buffer(3)]],
                            const device float4 *table [[buffer(4)]],
                            uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    uint index = tid.x + u.nx * (tid.y + u.ny * tid.z);
    float4 b = gravityCellOf(table, int(tid.z));
    Cell c;
    c.rho = b.x;
    c.mx = 0.0f;
    c.my = 0.0f;
    c.mz = 0.0f;
    c.energy = b.y;
    state[index] = c;
    if (oxygen > 0.0f) {
        species[index] = float2(0.0f, oxygen * c.rho);
    }
}
