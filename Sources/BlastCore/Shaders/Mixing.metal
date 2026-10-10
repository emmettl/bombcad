// Sub-grid turbulent mixing, as an option (see `mixingFlux` in Solver.metal), appended to
// Solver.metal at compile time: once each step, before the sweeps, every coarse cell's eddy
// viscosity, after Smagorinsky: nu = (C dx)^2 |S|, |S| = sqrt(2 S_ij S_ij) the resolved rate of
// strain from central differences, times 1 - theta, theta = (div u)^2 / ((div u)^2 + |curl u|^2)
// the sensor of Ducros and others, near 1 in a shock (compression without rotation), where the
// scheme's own dissipation is what is wanted, and near 0 in a shear layer or a vortex. A solid
// neighbour, or one beyond the domain, counts as the cell itself.
//
// As an option, |S| gives way to the sigma model's differential operator (Nicoud, Baya Toda,
// Cabrit, Bose and Lee 2011, Phys. Fluids 23, 085106): sigma3 (sigma1 - sigma2) (sigma2 - sigma3) /
// sigma1^2, from the singular values sigma1 >= sigma2 >= sigma3 of the velocity gradient. It
// vanishes wherever the resolved flow is one- or two-dimensional, axisymmetric, a pure shear or a
// solid rotation, so the laminar flow round a growing flame (a spherical expansion, with its
// irrotational strain ahead) is not taken for turbulence, as Smagorinsky's |S| takes it.

// The sigma model's operator for velocity gradient `g` (column a: d(velocity)/d(x_a)): the
// eigenvalues of g^T g in closed form (Nicoud et al. 2011, appendix), their roots the singular values.
static inline float sigmaOperator(float3x3 g) {
    float3x3 G = transpose(g) * g;
    float i1 = G[0][0] + G[1][1] + G[2][2];
    float3x3 GG = G * G;
    float i2 = 0.5f * (i1 * i1 - (GG[0][0] + GG[1][1] + GG[2][2]));
    float i3 = determinant(G);
    float a1 = i1 * i1 / 9.0f - i2 / 3.0f;
    if (a1 <= 1e-30f) {
        return 0.0f;  // all three equal: an isotropic expansion or none at all
    }
    float a2 = i1 * i1 * i1 / 27.0f - i1 * i2 / 6.0f + i3 / 2.0f;
    float a3 = acos(clamp(a2 / (a1 * sqrt(a1)), -1.0f, 1.0f)) / 3.0f;
    float r = 2.0f * sqrt(a1);
    float s1 = sqrt(max(i1 / 3.0f + r * cos(a3), 0.0f));
    float s2 = sqrt(max(i1 / 3.0f - r * cos(M_PI_F / 3.0f + a3), 0.0f));
    float s3 = sqrt(max(i1 / 3.0f - r * cos(M_PI_F / 3.0f - a3), 0.0f));
    if (s1 <= 0.0f) {
        return 0.0f;
    }
    return max(s3 * (s1 - s2) * (s2 - s3) / (s1 * s1), 0.0f);
}
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
    float rate = u.mixingModel == 1u ? sigmaOperator(gradient) : sqrt(2.0f * strain);
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
