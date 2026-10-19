// Congestion's porous air, appended to Solver.metal at compile time (ShaderLibrary): obstacles'
// drag and the turbulence they make.

// The obstacle turbulence's constants (PDRFoam's PDRkEpsilon and PDRDragModel): k-epsilon's C_mu
// and C_2, the length scale's C_4 and the wall shear's drag and turbulence C_su and C_sk.
constant float obstacleCmu = 0.09f;
constant float obstacleC2 = 1.92f;
constant float obstacleC4 = 0.1f;
constant float obstacleCsu = 0.5f;
constant float obstacleCsk = 0.05f;
// The air's own kinematic viscosity, m^2/s, for the wall shear.
constant float obstacleLaminarViscosity = 1.5e-5f;

// The obstacle turbulence's eddy viscosity, C_mu k^2 / epsilon, m^2/s.
static inline float obstacleEddyViscosity(float2 turbulence) {
    return obstacleCmu * turbulence.x * turbulence.x / max(turbulence.y, 1e-12f);
}

// Congestion's drag (`CongestionField`), as PDRFoam's: the obstacles in a porous cell take
// momentum at (1/2 CR_i |u| + C_su beta_v nu_eff A_w^2) rho u_i per unit of the cell's volume along
// each axis, so (over its open volume, beta_v) at that over beta_v; implicitly over the step, so
// that it never reverses the flow. The kinetic energy it takes stays in the gas as heat.
kernel void congestionDrag(device Cell *state [[buffer(0)]],
                           const device float4 *congestion [[buffer(1)]],
                           const device uchar *mask [[buffer(2)]],
                           const device StepControl &control [[buffer(3)]],
                           constant SolverUniforms &u [[buffer(4)]],
                           const device float4 *parallel [[buffer(5)]],
                           const device float2 *turbulence [[buffer(6)]],
                           uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz || control.dt <= 0.0f) {
        return;
    }
    uint index = tid.x + u.nx * (tid.y + u.ny * tid.z);
    float4 field = congestion[index];
    if (mask[index] != 0 || all(field.yzw == 0.0f)) {
        return;
    }
    Cell c = state[index];
    float rho = max(c.rho, u.densityFloor);
    float3 momentum = float3(c.mx, c.my, c.mz);
    float speed = length(momentum) / rho;
    float wall = parallel[index].w;
    float shear = obstacleCsu * (obstacleLaminarViscosity + obstacleEddyViscosity(turbulence[index])) * wall * wall;
    momentum /= 1.0f + control.dt * (speed * field.yzw / field.x + shear);
    c.mx = momentum.x;
    c.my = momentum.y;
    c.mz = momentum.z;
    state[index] = c;
}

// The turbulence congestion's obstacles make (PDRFoam's PDRkEpsilon, with its obstacle terms and
// without the resolved shear's, which the air resolves or its sub-grid mixing models): k and epsilon
// per mass, carried by the air semi-Lagrangian (from where the cell's gas was a step ago, trilinear,
// a solid neighbour taking the cell's own value), then made and dissipated over the step,
//
//   dk/dt = G_R / beta_v - epsilon,
//   d epsilon/dt = 1.5 C_mu^(3/4) (G_R / beta_v) sqrt(k) / (C_4 L_obs) - C_2 epsilon^2 / k,
//
// G_R = 1/2 |u| u.CT.u + C_sk beta_v nu_eff A_w^2 |u|^2 the obstacles' generation per mass, each
// sink implicitly. Where the generation holds, epsilon = 1.5 C_mu^(3/4) k^(3/2) / (C_2 C_4 L_obs):
// the turbulence's length scale is a tenth of the obstacles'.
kernel void obstacleTurbulence(const device Cell *state [[buffer(0)]],
                               const device float4 *congestion [[buffer(1)]],
                               const device float4 *generation [[buffer(2)]],
                               const device float4 *parallel [[buffer(3)]],
                               const device uchar *mask [[buffer(4)]],
                               const device StepControl &control [[buffer(5)]],
                               constant SolverUniforms &u [[buffer(6)]],
                               const device float2 *turbulenceSrc [[buffer(7)]],
                               device float2 *turbulenceDst [[buffer(8)]],
                               uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    uint index = tid.x + u.nx * (tid.y + u.ny * tid.z);
    float2 own = turbulenceSrc[index];
    float dt = control.dt;
    if (mask[index] != 0 || dt <= 0.0f) {
        turbulenceDst[index] = own;
        return;
    }
    Cell c = state[index];
    float rho = max(c.rho, u.densityFloor);
    float3 velocity = float3(c.mx, c.my, c.mz) / rho;

    // Where the gas was a step ago, in cell units from the first cell's centre.
    int3 size = int3(int(u.nx), int(u.ny), int(u.nz));
    float3 from = clamp(float3(tid) - velocity * dt / u.dx, float3(0.0f), float3(size - 1));
    int3 low = min(int3(floor(from)), size - 1);
    int3 high = min(low + 1, size - 1);
    float3 w = from - float3(low);
    float2 carried = float2(0.0f);
    for (int corner = 0; corner < 8; ++corner) {
        int3 pick = int3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        int3 cell = select(low, high, bool3(pick));
        uint at = uint(cell.x) + u.nx * (uint(cell.y) + u.ny * uint(cell.z));
        float3 share = select(1.0f - w, w, bool3(pick));
        carried += share.x * share.y * share.z * (mask[at] == 0 ? turbulenceSrc[at] : own);
    }
    float k = max(carried.x, 1e-6f);
    float epsilon = max(carried.y, 1e-9f);

    float porosity = congestion[index].x;
    float4 made = generation[index];
    float wall = parallel[index].w;
    float generated = 0.0f;
    if (any(made.xyz != 0.0f) || wall != 0.0f) {
        float speed = length(velocity);
        float nuEffective = obstacleLaminarViscosity + obstacleCmu * k * k / epsilon;
        generated = (0.5f * speed * dot(velocity * velocity, made.xyz)
                     + obstacleCsk * porosity * nuEffective * wall * wall * speed * speed) / porosity;
    }
    float epsilonMade = generated > 0.0f
        ? 1.5f * pow(obstacleCmu, 0.75f) * generated * sqrt(k) / (obstacleC4 * made.w)
        : 0.0f;
    float rate = epsilon / k;
    float kNew = (k + dt * generated) / (1.0f + dt * rate);
    float epsilonNew = (epsilon + dt * epsilonMade) / (1.0f + dt * obstacleC2 * rate);
    turbulenceDst[index] = float2(max(kNew, 1e-6f), max(epsilonNew, 1e-9f));
}
