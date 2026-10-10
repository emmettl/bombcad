// Sub-grid turbulent mixing, as an option (see `mixingFlux` in Solver.metal), appended to
// Solver.metal at compile time: once each step, before the sweeps, every coarse cell's eddy
// viscosity, after Smagorinsky: nu = (C dx)^2 |S|, |S| = sqrt(2 S_ij S_ij) the resolved rate of
// strain from central differences, times 1 - theta, theta = (div u)^2 / ((div u)^2 + |curl u|^2)
// the sensor of Ducros and others, near 1 in a shock (compression without rotation), where the
// scheme's own dissipation is what is wanted, and near 0 in a shear layer or a vortex. A solid
// neighbour, or one beyond the domain, counts as the cell itself.
kernel void eddyViscosity(const device Cell *state [[buffer(0)]],
                          const device uchar *mask [[buffer(1)]],
                          device float *viscosity [[buffer(2)]],
                          constant SolverUniforms &u [[buffer(3)]],
                          const device StepControl &control [[buffer(4)]],
                          uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz || control.stopped != 0) {
        return;
    }
    int3 cell = int3(tid);
    int3 dims = int3(u.nx, u.ny, u.nz);
    uint index = tid.x + u.nx * (tid.y + u.ny * tid.z);
    if (mask[index] != 0) {
        viscosity[index] = 0.0f;
        return;
    }
    Cell c = state[index];
    float3 own = float3(c.mx, c.my, c.mz) / max(c.rho, u.densityFloor);
    float3x3 gradient;  // column a: d(velocity)/d(x_a)
    for (int a = 0; a < 3; ++a) {
        float3 sides[2];
        for (int s = 0; s < 2; ++s) {
            int3 n = cell;
            n[a] += s == 0 ? -1 : 1;
            sides[s] = own;
            if (all(n >= 0) && all(n < dims)) {
                uint at = uint(n.x) + u.nx * (uint(n.y) + u.ny * uint(n.z));
                if (mask[at] == 0) {
                    Cell m = state[at];
                    sides[s] = float3(m.mx, m.my, m.mz) / max(m.rho, u.densityFloor);
                }
            }
        }
        gradient[a] = (sides[1] - sides[0]) / (2.0f * u.dx);
    }
    // S_ij = (du_i/dx_j + du_j/dx_i) / 2; gradient[j][i] = du_i/dx_j.
    float strain = 0.0f;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            float s = 0.5f * (gradient[j][i] + gradient[i][j]);
            strain += s * s;
        }
    }
    float rate = sqrt(2.0f * strain);
    float divergence = gradient[0][0] + gradient[1][1] + gradient[2][2];
    float3 curl = float3(gradient[1][2] - gradient[2][1], gradient[2][0] - gradient[0][2],
                         gradient[0][1] - gradient[1][0]);
    float compression = divergence * divergence;
    float theta = compression / (compression + dot(curl, curl) + 1e-30f);
    float length = u.mixingCoefficient * u.dx;
    viscosity[index] = length * length * rate * (1.0f - theta);
}

// For benchmarks (`SolverConfiguration.periodicSides`): the grid's two outermost cells on each x
// and y side hold copies of the cells on the far side, refilled before every sweep, so that the
// interior, two cells in from each side, is periodic in x and y.
kernel void periodicHalo(device Cell *state [[buffer(0)]],
                         constant SolverUniforms &u [[buffer(1)]],
                         uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    int i = int(tid.x);
    int j = int(tid.y);
    int nx = int(u.nx) - 4;
    int ny = int(u.ny) - 4;
    int si = i < 2 ? i + nx : (i >= int(u.nx) - 2 ? i - nx : i);
    int sj = j < 2 ? j + ny : (j >= int(u.ny) - 2 ? j - ny : j);
    if (si == i && sj == j) {
        return;
    }
    state[uint(i) + u.nx * (uint(j) + u.ny * tid.z)] = state[uint(si) + u.nx * (uint(sj) + u.ny * tid.z)];
}
