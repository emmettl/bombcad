// The view of the air, appended to Solver.metal at compile time (ShaderLibrary).

static inline float cellPressure(const device Cell *state, int index, constant SolverUniforms &u) {
    Cell c = state[index];
    float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, u.densityFloor);
    return gasPressure(max(c.rho, u.densityFloor), c.energy - kinetic, u.airModel, u.gamma);
}

// Packs the fields the renderer needs into a filterable 3D texture:
//   r = overpressure / ambient, g = peak overpressure / ambient, b = impulse (Pa s),
//   a = pressure jump across one cell / ambient (a shock indicator for the volume view).
// Solid cells carry the largest value among their fluid face neighbours so that
// building surfaces can be shaded by sampling just inside the wall.
kernel void updateVisualization(const device Cell *state [[buffer(0)]],
                                const device uchar *mask [[buffer(1)]],
                                const device float *peak [[buffer(2)]],
                                const device float *impulse [[buffer(3)]],
                                constant SolverUniforms &u [[buffer(4)]],
                                texture3d<float, access::write> visualization [[texture(0)]],
                                uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    int3 dims = int3(u.nx, u.ny, u.nz);
    int3 position = int3(tid);
    int index = position.x + dims.x * (position.y + dims.y * position.z);
    float inverseAmbient = 1.0f / u.ambientPressure;
    bool solid = mask[index] != 0;
    float pressure = solid ? u.ambientPressure : cellPressure(state, index, u);

    const int3 offsets[6] = {
        int3(-1, 0, 0), int3(1, 0, 0), int3(0, -1, 0), int3(0, 1, 0), int3(0, 0, -1), int3(0, 0, 1),
    };
    float neighbours[6];
    float3 best = float3(0.0f);
    for (int n = 0; n < 6; ++n) {
        int3 q = position + offsets[n];
        neighbours[n] = pressure;
        if (any(q < 0) || any(q >= dims)) {
            continue;
        }
        int neighbour = q.x + dims.x * (q.y + dims.y * q.z);
        if (mask[neighbour] != 0) {
            continue;
        }
        neighbours[n] = cellPressure(state, neighbour, u);
        if (solid) {
            best = max(best, float3((neighbours[n] - u.ambientPressure) * inverseAmbient,
                                    peak[neighbour] * inverseAmbient, impulse[neighbour]));
        }
    }

    if (solid) {
        visualization.write(float4(clamp(best, 0.0f, 6.0e4f), 0.0f), tid);
        return;
    }
    float3 gradient = 0.5f * float3(neighbours[1] - neighbours[0], neighbours[3] - neighbours[2],
                                    neighbours[5] - neighbours[4]);
    float4 value = float4((pressure - u.ambientPressure) * inverseAmbient, peak[index] * inverseAmbient,
                          impulse[index], length(gradient) * inverseAmbient);
    visualization.write(clamp(value, -6.0e4f, 6.0e4f), tid);
}
