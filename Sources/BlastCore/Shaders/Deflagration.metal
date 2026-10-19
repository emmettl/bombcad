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
    uint ignitionCell;             // the cell the ignition point lights, as an index
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
    float wrinklingLimit;          // the radius, in onset radii, beyond which the wrinkling holds
    float turbulenceScale;         // 1.48 a in Bradley's correlation; 0: no sub-grid turbulence
    float velocityPerViscosity;    // u' over the eddy viscosity: sqrt(2/3) / (C_k dx)
    float ignitionX;
    float ignitionY;
    float ignitionZ;
    float densityFloor;
    float ambientPressure;
    float gamma;
    uint airModel;
    uint panelCellCount;
    float unburntDensity;          // the unburnt gas's density and ratio of specific heats, ambient
    float unburntGamma;
    float expansionRatio;          // the burnt gas's volume over the unburnt's, at constant pressure
    float kinematicViscosity;      // the unburnt mixture's, ambient
    float externalFactor;          // multiplies the burning velocity outside the cloud's region
    float regionMinX;
    float regionMinY;
    float regionMinZ;
    float regionMaxX;
    float regionMaxY;
    float regionMaxZ;
    float marksteinNumber;         // the mixture's, for PDRFoam's wrinkling in congestion
    uint speedTableCount;          // a tabulated burning velocity: points (phi, m/s); 0 for Gulder's
    float speedPhi[16];
    float speedValue[16];
};

static inline float laminarBurningSpeed(float fraction, constant DeflagrationUniforms &d) {
    if (fraction < d.lowerLimit || fraction > d.upperLimit) {
        return 0.0f;
    }
    float stoichiometric = d.stoichiometricFraction;
    float phi = (fraction / (1.0f - fraction)) / (stoichiometric / (1.0f - stoichiometric));
    if (d.speedTableCount > 0) {
        // Linear in the equivalence ratio between the table's points, held at its ends.
        uint last = d.speedTableCount - 1;
        if (phi <= d.speedPhi[0]) {
            return d.speedValue[0];
        }
        for (uint n = 0; n < last; ++n) {
            if (phi <= d.speedPhi[n + 1]) {
                float t = (phi - d.speedPhi[n]) / max(d.speedPhi[n + 1] - d.speedPhi[n], 1e-6f);
                return d.speedValue[n] + t * (d.speedValue[n + 1] - d.speedValue[n]);
            }
        }
        return d.speedValue[last];
    }
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
                         const device float *eddyViscosity [[buffer(4)]],
                         const device StepControl &control [[buffer(5)]],
                         constant DeflagrationUniforms &d [[buffer(6)]],
                         const device float4 *congestion [[buffer(7)]],
                         const device float4 *blockage [[buffer(8)]],
                         const device float4 *parallel [[buffer(9)]],
                         const device float2 *obstacleTurbulence [[buffer(10)]],
                         const device float4 *generation [[buffer(11)]],
                         const device float *unitWidth [[buffer(12)]],
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
    // second-order ENO differences (Osher and Fedkiw, Level Set Methods, ch. 3 and 6). A solid
    // neighbour or the domain's edge repeats the nearer value.
    float3 velocity = float3(c.mx, c.my, c.mz) / rho;
    float gradient = 0.0f;
    for (int axis = 0; axis < 3; ++axis) {
        float v[5];
        v[2] = b;
        for (int side = -1; side <= 1; side += 2) {
            float previous = b;
            bool open = true;
            for (int k = 1; k <= 2; ++k) {
                int3 n = cell;
                n[axis] += side * k;
                if (open && fluidAt(n, mask, d)) {
                    previous = regress(species[cellIndex(n, d)]);
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
    // The ignition point lights the cell holding it (chosen on the host, so that a point on a face
    // lights one cell whichever way a float rounds) as a spherical flame kernel: the cell's burnt gas taken as a sphere, the flame its surface, so that it burns
    // at rho_u S_T times that area, (36 pi)^(1/3) sigma^(2/3) (1 - b)^(2/3) / dx per volume for
    // expansion ratio sigma. A seed of a thousandth starts it, and the burning grows from nothing
    // as a real kernel's does, without the pressure pulse a sudden start would send out.
    float3 centreOfCell = (float3(cell) + 0.5f) * dx;
    float3 ignition = float3(d.ignitionX, d.ignitionY, d.ignitionZ);
    if (uint(index) == d.ignitionCell) {
        float burnt = max(1.0f - b, 1e-3f);
        gradient = max(gradient, 4.836f * pow(d.expansionRatio * burnt, 2.0f / 3.0f) / dx);
    }
    if (gradient <= 0.0f) {
        return;
    }

    // The burning velocity, at the fuel fraction the cell's share of cloud gas gives it.
    float cloud = clamp(own.y / rho, 0.0f, 1.0f);
    float laminar = laminarBurningSpeed(cloud * d.cloudFraction, d);
    if (laminar <= 0.0f) {
        return;
    }
    // The unburnt gas's compression: adiabatic from the ambient mixture to the cell's pressure.
    float kinetic = 0.5f * dot(velocity, velocity) * rho;
    float pressure = gasPressure(rho, c.energy - kinetic, d.airModel, d.gamma);
    float compression = pow(max(pressure / d.ambientPressure, 1e-3f), 1.0f / d.unburntGamma);
    float speed = laminar * d.speedFactor;
    float cellular = 1.0f;  // with congestion: the cellular instability's wrinkling, applied below
    if (d.wrinklingRadius > 0.0f) {
        float radius = length(centreOfCell - ignition);
        if (porousAir) {
            cellular = pow(clamp(radius / d.wrinklingRadius, 1.0f, d.wrinklingLimit), d.wrinklingPower);
        } else {
            speed *= pow(clamp(radius / d.wrinklingRadius, 1.0f, d.wrinklingLimit), d.wrinklingPower);
        }
    }
    float resolvedWrinkling = 0.0f;  // with congestion: the sub-grid turbulence's wrinkling and u'
    float subgridVelocity = 0.0f;
    if (d.turbulenceScale > 0.0f) {
        // Wrinkling by sub-grid turbulence (Bauwens et al. 2008, eq. 5, after Bradley, Lau and
        // Lawes 1992): max(1, 1.48 a (u'/S_L)^(1/2) (dx/delta)^(1/6)), u' the sub-grid velocity the
        // air's mixing gives this cell, delta = nu/S_L the laminar flame's thickness, nu the unburnt
        // gas's kinematic viscosity, falling as it is compressed.
        // The sigma-model's viscosity can round a hair below zero, whose square root would be NaN
        // and, under fast math, could pass through the comparisons below to burn a cell whole; and
        // max(NaN, 0) need not give 0 under fast math either. Tested on the bits, as fast math may
        // fold a test for NaN away: every negative, infinity and NaN lie at or above infinity's,
        // and are taken as no turbulence.
        float turbulent = eddyViscosity[index] * d.velocityPerViscosity;
        turbulent = as_type<uint>(turbulent) < 0x7F800000u ? turbulent : 0.0f;
        float thickness = d.kinematicViscosity / (compression * laminar);
        float wrinkling =
            d.turbulenceScale * sqrt(turbulent / laminar) * pow(dx / thickness, 1.0f / 6.0f);
        if (porousAir) {
            subgridVelocity = turbulent;
            resolvedWrinkling = d.turbulenceScale * sqrt(subgridVelocity / laminar) * pow(dx / thickness, 1.0f / 6.0f);
        } else {
            speed *= max(wrinkling, 1.0f);
        }
    }
    if (porousAir) {
        // Congestion (docs/congestion-model.md). The obstacles' turbulence wrinkles the flame as
        // PDRFoam's turbulent wrinkling has it: u' = sqrt(2k/3) and the sub-grid Schelkin term,
        // u'_C sqrt(U.CT.U w) (n^(1/4) - 1), the obstacles' wakes in the lattice's unit cell, w wide; Guelder's
        // 1 + 0.62 sqrt(u'/S_L) u'/(nu epsilon)^(1/4) and SCOPE's 1.6 (K Ma)^(-1/3) u'/S_L, K =
        // 0.157 (u'/S_L) / sqrt(u' l / nu), l = 0.336 sqrt(3/2) u' k / epsilon, blended as
        // (Xi_G^-4 + Xi_S^-4)^(-1/4). The larger of it and the sub-grid turbulence's wrinkling holds;
        // the Markstein number is the unburnt mixture's (PDRFoam's SCOPE fuel data).
        float2 obstacle = obstacleTurbulence[index];
        float k = obstacle.x;
        // Turbulence below the grid is no larger than a cell: epsilon at least C_mu^(3/4) k^(3/2) / dx,
        // as when the obstacles start the flow moving and their turbulence grows ahead of its
        // dissipation.
        float epsilon = max(obstacle.y, 0.1643f * k * sqrt(k) / dx);
        float obstacleVelocity = sqrt(2.0f / 3.0f * k);
        float4 blocked = blockage[index];
        float magnitude = length(velocity);
        float3 along = velocity / (magnitude + 1e-4f);
        along *= along;
        float count = max(blocked.w - dot(along, parallel[index].xyz), 1e-4f);
        float schelkin = sqrt(dot(along * magnitude * magnitude, generation[index].xyz) * unitWidth[index])
            * (max(1.0f, pow(count, 0.25f)) - 1.0f);
        float up = obstacleVelocity + schelkin;
        float viscosity = d.kinematicViscosity / compression;
        float ratio = up / laminar;
        float guelder = 1.0f + 0.62f * sqrt(ratio) * up / pow(viscosity * epsilon, 0.25f);
        float integral = 0.336f * sqrt(1.5f) * up * k / epsilon;
        float karlovitz = 0.157f * ratio / sqrt(max(up * integral / viscosity, 1e-12f));
        // SCOPE holds only for a positive Markstein number; without it, Guelder's alone.
        float blend = guelder;
        if (d.marksteinNumber > 0.01f) {
            float scope = 1.6f * pow(max(karlovitz * d.marksteinNumber, 1e-12f), -1.0f / 3.0f) * ratio;
            blend = pow(pow(guelder, -4.0f) + pow(max(scope, 1e-6f), -4.0f), -0.25f);
        }
        // The cellular instability's wrinkling fades once turbulence wrinkles the flame more (as
        // PDRFoam's instability model, XiEqIn / Xi + Xi, tends to Xi): the larger of the two holds.
        speed *= max(max(resolvedWrinkling, blend), cellular);
        // The flame's folding round the obstacles below the grid (PDRFoam's basicSubGrid XiEq):
        // 1 + max(2.2 sqrt(b), min(0.34 |u| / u' sqrt(b), 1.6)) min(n, 1), n the count of obstacles
        // across the flow and b their blockage across it per square root of that count.
        float folding = sqrt(dot(along, blocked.xyz) / sqrt(count));
        float velocityScale = sqrt(subgridVelocity * subgridVelocity + obstacleVelocity * obstacleVelocity);
        speed *= 1.0f
            + max(2.2f * folding, min(0.34f * magnitude / max(velocityScale, 1e-4f) * folding, 1.6f))
                * min(count, 1.0f);
        // The front's area is the whole cell's, its mixture only the open share's (PDRFoam's b
        // equation): it burns the open volume's faster by 1/beta_v.
        speed /= congestion[index].x;
    }

    if (d.externalFactor != 1.0f) {
        // The external explosion (Molkov and Makarov 2004): outside the cloud's region the vented
        // mixture burns in the vortex it rolls up into, faster than isotropic turbulence gives.
        float3 low = float3(d.regionMinX, d.regionMinY, d.regionMinZ);
        float3 high = float3(d.regionMaxX, d.regionMaxY, d.regionMaxZ);
        if (any(centreOfCell < low) || any(centreOfCell > high)) {
            speed *= d.externalFactor;
        }
    }

    // The unburnt gas's density: the ambient mixture's, compressed, and only the cloud's share of it.
    float unburnt = cloud * d.unburntDensity * compression;
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
// panel records when, on the run's clock (`runClock`).
kernel void ventRelease(device uchar *mask [[buffer(0)]],
                        device uchar *rigidMask [[buffer(1)]],
                        const device uint2 *panelCells [[buffer(2)]],
                        device atomic_uint *panelPeak [[buffer(3)]],
                        const device float *releasePressure [[buffer(4)]],
                        device atomic_uint *panelOpened [[buffer(5)]],
                        device uint *openedAt [[buffer(6)]],
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
        // When, on the run's clock (its ticks), the same however the run is batched.
        openedAt[2 * entry.y] = control.clockLow;
        openedAt[2 * entry.y + 1] = control.clockHigh;
    }
}
