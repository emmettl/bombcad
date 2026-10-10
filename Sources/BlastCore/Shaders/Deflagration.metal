// Premixed gas deflagration, appended to Solver.metal at compile time.
//
// A cloud of flammable gas and air burns behind a flame front, by Weller's regress-variable form
// (Weller 1993; Weller et al. 1998; OpenFOAM's XiFoam): b, the share of the cloud's gas still
// unburnt, obeys
//
//   d(rho b)/dt + div(rho u b) = -rho_u S_T |grad b|,
//
// rho_u being the unburnt gas's density and S_T the burning velocity. Across any profile of b
// the source integrates to rho_u S_T per area of front, so the mixture is consumed at the
// burning velocity however far the grid's own diffusion has spread the front, and a steady
// planar front is a solution whatever its profile: the front's b-levels each move relative to
// the gas at (rho_u / rho) S_T, the mass flux through each being rho_u S_T.
//
// The unburnt mixture (species.x) and all the gas that came from the cloud, burnt or not
// (species.y), are densities carried by the sweeps as afterburning's fuel and oxygen are
// (first-order upwind at the cell's mass fraction); b = x / y. Air the cloud never reached
// counts as unburnt, so a cloud's edge does not light itself; products count as burnt, not as
// air diluting the mixture.
//
// Vent panels are solid cells cleared from the mask once the overpressure beside the panel
// reaches its release pressure.

struct DeflagrationUniforms {
    uint nx;
    uint ny;
    uint nz;
    float dx;
    float ignitionRadius;          // the mixture within this of the ignition point is lit, m
    float heat;                    // J per kg of unburnt mixture burnt
    float cloudFraction;           // fuel volume fraction of the cloud's mixture
    float stoichiometricFraction;
    float lowerLimit;              // flammability limits, volume fractions
    float upperLimit;
    float speedScale;              // Guelder's W (m/s), eta and xi
    float speedPower;
    float speedWidth;
    float speedFactor;             // constant turbulence factor
    float wrinklingRadius;         // 0: no wrinkling with radius
    float wrinklingPower;
    float subgridCoefficient;      // 0: no sub-grid turbulence
    float turbulentSlope;          // b3
    float ignitionX;
    float ignitionY;
    float ignitionZ;
    float reserved;
    float densityFloor;
    float ambientPressure;
    float gamma;
    uint airModel;
    uint panelCellCount;
    float unburntDensity;          // the unburnt gas's density and ratio of specific heats, ambient
    float unburntGamma;
};

static inline float laminarBurningSpeed(float fraction, constant DeflagrationUniforms &d) {
    if (fraction < d.lowerLimit || fraction > d.upperLimit) {
        return 0.0f;
    }
    float stoichiometric = d.stoichiometricFraction;
    float phi = (fraction / (1.0f - fraction)) / (stoichiometric / (1.0f - stoichiometric));
    float offset = phi - 1.075f;
    return d.speedScale * pow(phi, d.speedPower) * exp(-d.speedWidth * offset * offset);
}

static inline float minmodValue(float a, float b) {
    return a * b <= 0.0f ? 0.0f : (fabs(a) < fabs(b) ? a : b);
}

static inline bool fluidAt(int3 cell, const device uchar *mask, constant DeflagrationUniforms &d) {
    return all(cell >= 0) && cell.x < int(d.nx) && cell.y < int(d.ny) && cell.z < int(d.nz)
        && mask[cell.x + int(d.nx) * (cell.y + int(d.ny) * cell.z)] == 0;
}

static inline int cellIndex(int3 cell, constant DeflagrationUniforms &d) {
    return cell.x + int(d.nx) * (cell.y + int(d.ny) * cell.z);
}

// The unburnt share b of the cloud's gas in a cell holding `species`: one where there is none
// (air the cloud never reached is not burnt).
static inline float regress(float2 species) {
    return species.y > 1e-6f ? clamp(species.x / species.y, 0.0f, 1.0f) : 1.0f;
}

// How much of each cell's mixture burns over the step, into `burning` (kg/m^3); the cells are
// left alone until `applyBurning`, so that every cell reads its neighbours' b as the step left it.
kernel void advanceFlame(const device Cell *state [[buffer(0)]],
                         const device float2 *species [[buffer(1)]],
                         const device uchar *mask [[buffer(2)]],
                         device float *burning [[buffer(3)]],
                         const device StepControl &control [[buffer(5)]],
                         constant DeflagrationUniforms &d [[buffer(6)]],
                         uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= d.nx || tid.y >= d.ny || tid.z >= d.nz) {
        return;
    }
    int3 cell = int3(tid);
    int index = cellIndex(cell, d);
    burning[index] = 0.0f;
    float dt = control.dt;
    float2 own = species[index];
    if (dt <= 0.0f || mask[index] != 0 || own.x <= 0.0f) {
        return;
    }
    Cell c = state[index];
    float rho = max(c.rho, d.densityFloor);
    float dx = d.dx;
    float b = regress(own);

    // Godunov's upwind gradient of b for a front moving towards larger b (the unburnt side), from
    // second-order ENO differences (Osher and Fedkiw, Level Set Methods, ch. 3 and 6), and the
    // neighbours' velocities for the vorticity. A solid neighbour or the domain's edge repeats
    // the nearer value.
    float3 velocity = float3(c.mx, c.my, c.mz) / rho;
    float gradient = 0.0f;
    float3 low[3];
    float3 high[3];
    for (int axis = 0; axis < 3; ++axis) {
        float v[5];
        v[2] = b;
        low[axis] = velocity;
        high[axis] = velocity;
        for (int side = -1; side <= 1; side += 2) {
            float previous = b;
            bool open = true;
            for (int k = 1; k <= 2; ++k) {
                int3 n = cell;
                n[axis] += side * k;
                if (open && fluidAt(n, mask, d)) {
                    int other = cellIndex(n, d);
                    previous = regress(species[other]);
                    if (k == 1 && d.subgridCoefficient > 0.0f) {
                        Cell nc = state[other];
                        float3 nv = float3(nc.mx, nc.my, nc.mz) / max(nc.rho, d.densityFloor);
                        if (side < 0) { low[axis] = nv; } else { high[axis] = nv; }
                    }
                } else {
                    open = false;
                }
                v[2 + side * k] = previous;
            }
        }
        float centre = v[3] - 2.0f * v[2] + v[1];
        float below = v[2] - v[1] + 0.5f * minmodValue(v[2] - 2.0f * v[1] + v[0], centre);
        float above = v[3] - v[2] - 0.5f * minmodValue(centre, v[4] - 2.0f * v[3] + v[2]);
        float behind = max(below, 0.0f);
        float ahead = min(above, 0.0f);
        gradient += behind * behind + ahead * ahead;
    }
    gradient = sqrt(gradient) / dx;
    // The ignition point lights the cell holding it (or the cells, on their faces): it burns as a
    // flame kernel growing at about the expansion ratio times the burning velocity would, in a
    // few times dx / S rather than the many a gradient of b / dx gives.
    float3 centreOfCell = (float3(cell) + 0.5f) * dx;
    float3 ignition = float3(d.ignitionX, d.ignitionY, d.ignitionZ);
    if (all(fabs(centreOfCell - ignition) <= 0.5f * dx + d.ignitionRadius)) {
        gradient = max(gradient, 4.0f * b / dx);
    }
    if (gradient <= 0.0f) {
        return;
    }

    // The burning velocity, at the fuel fraction the cell's share of cloud gas gives it.
    float cloud = clamp(own.y / rho, 0.0f, 1.0f);
    float speed = laminarBurningSpeed(cloud * d.cloudFraction, d);
    if (speed <= 0.0f) {
        return;
    }
    if (d.wrinklingRadius > 0.0f) {
        float radius = length(centreOfCell - ignition);
        speed *= max(pow(radius / d.wrinklingRadius, d.wrinklingPower), 1.0f);
    }
    speed *= d.speedFactor;
    if (d.subgridCoefficient > 0.0f) {
        // Central differences of the neighbours' velocities (one-sided where one is solid).
        float3 dUdx = (high[0] - low[0]) / (2.0f * dx);
        float3 dUdy = (high[1] - low[1]) / (2.0f * dx);
        float3 dUdz = (high[2] - low[2]) / (2.0f * dx);
        float3 vorticity = float3(dUdy.z - dUdz.y, dUdz.x - dUdx.z, dUdx.y - dUdy.x);
        speed += d.turbulentSlope * d.subgridCoefficient * dx * length(vorticity);
    }

    // The unburnt gas's density: the ambient mixture's, compressed adiabatically to the cell's
    // pressure, and only the cloud's share of it.
    float kinetic = 0.5f * dot(velocity, velocity) * rho;
    float pressure = gasPressure(rho, c.energy - kinetic, d.airModel, d.gamma);
    float unburnt = cloud * d.unburntDensity * pow(max(pressure / d.ambientPressure, 1e-3f), 1.0f / d.unburntGamma);
    burning[index] = min(unburnt * speed * gradient * dt, own.x);
}

// Burns what `advanceFlame` worked out, releasing its heat.
kernel void applyBurning(device Cell *state [[buffer(0)]],
                         device float2 *species [[buffer(1)]],
                         const device float *burning [[buffer(3)]],
                         constant DeflagrationUniforms &d [[buffer(6)]],
                         uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= d.nx || tid.y >= d.ny || tid.z >= d.nz) {
        return;
    }
    int index = cellIndex(int3(tid), d);
    float burnt = burning[index];
    if (burnt > 0.0f) {
        species[index].x -= burnt;
        state[index].energy += burnt * d.heat;
    }
}

// The largest overpressure in the fluid cells beside each closed panel, as float bits (positive
// floats order as their bits do), kept as a running maximum.
kernel void ventPressure(const device Cell *state [[buffer(0)]],
                         const device uchar *mask [[buffer(1)]],
                         const device uint2 *panelCells [[buffer(2)]],
                         device atomic_uint *panelPeak [[buffer(3)]],
                         const device StepControl &control [[buffer(4)]],
                         constant DeflagrationUniforms &d [[buffer(5)]],
                         uint tid [[thread_position_in_grid]]) {
    if (tid >= d.panelCellCount || control.dt <= 0.0f) {
        return;
    }
    uint2 entry = panelCells[tid];
    int index = int(entry.x);
    if (mask[index] == 0) {
        return;
    }
    int3 cell = int3(index % int(d.nx), (index / int(d.nx)) % int(d.ny), index / int(d.nx * d.ny));
    float peak = 0.0f;
    for (int axis = 0; axis < 3; ++axis) {
        for (int side = -1; side <= 1; side += 2) {
            int3 n = cell;
            n[axis] += side;
            if (!fluidAt(n, mask, d)) {
                continue;
            }
            Cell c = state[cellIndex(n, d)];
            float rho = max(c.rho, d.densityFloor);
            float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / rho;
            float pressure = gasPressure(rho, c.energy - kinetic, d.airModel, d.gamma);
            peak = max(peak, pressure - d.ambientPressure);
        }
    }
    uint bits = as_type<uint>(peak);
    if (bits > atomic_load_explicit(panelPeak + entry.y, memory_order_relaxed)) {
        atomic_fetch_max_explicit(panelPeak + entry.y, bits, memory_order_relaxed);
    }
}

// Clears the cells of every panel whose overpressure has reached its release pressure, from both
// the mask and the rigid mask the structure's remasking starts from. The first cell to clear a
// panel records when, as the batch's time so far.
kernel void ventRelease(device uchar *mask [[buffer(0)]],
                        device uchar *rigidMask [[buffer(1)]],
                        const device uint2 *panelCells [[buffer(2)]],
                        device atomic_uint *panelPeak [[buffer(3)]],
                        const device float *releasePressure [[buffer(4)]],
                        device atomic_uint *panelOpened [[buffer(5)]],
                        device float *openedAt [[buffer(6)]],
                        const device StepControl &control [[buffer(7)]],
                        constant DeflagrationUniforms &d [[buffer(8)]],
                        uint tid [[thread_position_in_grid]]) {
    if (tid >= d.panelCellCount || control.dt <= 0.0f) {
        return;
    }
    uint2 entry = panelCells[tid];
    float peak = as_type<float>(atomic_load_explicit(panelPeak + entry.y, memory_order_relaxed));
    if (peak < releasePressure[entry.y]) {
        return;
    }
    mask[entry.x] = 0;
    rigidMask[entry.x] = 0;
    uint expected = 0u;
    if (atomic_compare_exchange_weak_explicit(panelOpened + entry.y, &expected, 1u, memory_order_relaxed,
                                              memory_order_relaxed)) {
        openedAt[entry.y] = control.batchTime;
    }
}
