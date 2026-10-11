// Rubble (`StructureModel.rubbleParticles`): concrete that fails becomes a particle that keeps
// its mass, where without it the failed element's mass stays on its nodes. The particle takes the
// element's mass from its eight nodes, with their momentum, at their centre; the kinetic energy of
// the nodes' motion about that centre, which one particle cannot carry, is kept as its internal
// energy, so that mass, momentum and energy all pass across. From then on it pushes, in contact
// only, on the other particles and on the nodes of what is left of the body, as a sphere: it
// carries compression and friction but no tension. The air pushes it as it pushes loose nodes.
//
// Each element the body started with has a slot, used once it has failed. Contact uses a table of
// its own, built as the nodes' is (`contactClear`, `contactHash`), and the nodes' contact kernel
// reads it, so that a particle and a node push on each other equally and oppositely.
//
// Most slots are never used, so a word of state says which are, a bit each (`rubbleState`): the
// kernels over the slots read their bit before their particle, and a slot not in use costs them a
// bit, not a particle. The state's first word is set once any particle has been made, its second
// while this substep has made one (cleared as the substep's particles move).

// Whether slot `index` holds a particle, from its bit in the rubble's state.
static inline bool rubbleInUse(const device uint *state, uint index) {
    return ((state[rubbleBits + index / 32u] >> (index % 32u)) & 1u) != 0u;
}

// Each substep, after the element pass: an element failing in it (or losing its concrete to
// leave its bars) becomes a particle. Its eight nodes are read before the node pass moves them.
kernel void rubbleConvert(device RubbleParticle *particles [[buffer(0)]],
                          const device StructureNode *nodes [[buffer(1)]],
                          const device uchar *flags [[buffer(2)]],
                          const device uint *elementList [[buffer(3)]],
                          const device uint *nodeMap [[buffer(4)]],
                          const device float2 *rubbleMass [[buffer(5)]],
                          const device StepControl &control [[buffer(6)]],
                          constant StructureUniforms &u [[buffer(7)]],
                          const device uint *failureGate [[buffer(8)]],
                          const device uint *nodeList [[buffer(9)]],
                          device atomic_uint *state [[buffer(10)]],
                          uint compact [[thread_position_in_grid]]) {
    bool active;
    structureStep(u, control, active);
    if (!active || failureGate[0] == 0) {
        return;
    }
    uint element = elementList[compact];
    uchar flag = flags[element];
    if ((flag != elementFailing && flag != elementBaring) || particles[compact].alive != 0) {
        return;
    }
    // The element's mass on its nodes, and the share of it that is steel, which stays with
    // bars left standing.
    float2 held = rubbleMass[compact];
    float mass = flag == elementBaring ? held.x * (1.0f - held.y) : held.x;
    if (mass <= 0.0f) {
        return;
    }
    uint3 tid = uint3(element % u.ex, (element / u.ex) % u.ey, element / (u.ex * u.ey));
    float3 positions[8];
    float3 velocities[8];
    float3 centre = float3(0.0f);
    float3 velocity = float3(0.0f);
    for (uint a = 0; a < 8; ++a) {
        uint3 corner = tid + uint3(a & 1u, (a >> 1) & 1u, (a >> 2) & 1u);
        uint node = nodeMap[corner.x + (u.ex + 1) * (corner.y + (u.ey + 1) * corner.z)];
        positions[a] = nodePosition(node, nodeList, nodes, u);
        velocities[a] = float3(nodes[node].velocity);
        centre += positions[a];
        velocity += velocities[a];
    }
    centre *= 0.125f;
    velocity *= 0.125f;
    float internal = 0.0f;
    float reach = 0.8660254f * u.h;
    for (uint a = 0; a < 8; ++a) {
        float3 about = velocities[a] - velocity;
        internal += 0.0625f * mass * dot(about, about);
        reach = min(reach, length(positions[a] - centre));
    }
    RubbleParticle p;
    p.position = centre;
    p.mass = mass;
    p.velocity = velocity;
    p.reach = reach;
    p.internal = internal;
    p.volume = u.h * u.h * u.h * mass / held.x;
    p.alive = 1;
    p.spare = 0.0f;
    particles[compact] = p;
    atomic_fetch_or_explicit(&state[rubbleBits + compact / 32u], 1u << (compact % 32u), memory_order_relaxed);
    atomic_store_explicit(&state[0], 1u, memory_order_relaxed);
    atomic_store_explicit(&state[1], 1u, memory_order_relaxed);
}

// ...then each node gives up an eighth of each particle made from an element around it. A node
// left with nothing is out of the body: the node pass and contact leave it alone.
kernel void rubbleNodes(device StructureNode *nodes [[buffer(0)]],
                        const device uchar *flags [[buffer(1)]],
                        const device RubbleParticle *particles [[buffer(2)]],
                        const device uint *cellElement [[buffer(3)]],
                        const device uint *nodeList [[buffer(4)]],
                        const device StepControl &control [[buffer(5)]],
                        constant StructureUniforms &u [[buffer(6)]],
                        const device uint *failureGate [[buffer(7)]],
                        const device uint *state [[buffer(8)]],
                        uint threadIndex [[thread_position_in_grid]]) {
    bool active;
    structureStep(u, control, active);
    if (!active || state[1] == 0) {
        return;
    }
    uint3 tid = latticeNode(nodeList[threadIndex], u);
    int3 dims = int3(u.ex, u.ey, u.ez);
    float given = 0.0f;
    for (uint a = 0; a < 8; ++a) {
        int3 cell = int3(tid) - int3(a & 1u, (a >> 1) & 1u, (a >> 2) & 1u);
        if (any(cell < 0) || any(cell >= dims)) {
            continue;
        }
        int element = cell.x + dims.x * (cell.y + dims.y * cell.z);
        uchar flag = flags[element];
        if (flag == elementFailing || flag == elementBaring) {
            given += 0.125f * particles[cellElement[element]].mass;
        }
    }
    if (given > 0.0f) {
        float mass = nodes[threadIndex].mass - given;
        // What rounding leaves of a node whose last element has gone is nothing.
        nodes[threadIndex].mass = mass > 1e-3f * given ? mass : 0.0f;
    }
}

// The particles' contact table, filled as the nodes' is: first each particle marks its cell
// current and empties it...
kernel void rubbleClear(const device RubbleParticle *particles [[buffer(0)]],
                        device uint *heads [[buffer(1)]],
                        device uint *slots [[buffer(2)]],
                        const device uint *failureGate [[buffer(3)]],
                        const device StepControl &control [[buffer(4)]],
                        constant StructureUniforms &u [[buffer(5)]],
                        const device uint *state [[buffer(6)]],
                        uint index [[thread_position_in_grid]]) {
    bool active;
    structureStep(u, control, active);
    if (!active || !rubbleInUse(state, index) || !contactEnabled(u, failureGate)) {
        return;
    }
    uint target = contactBucket(contactCell(float3(particles[index].position), u), u);
    heads[target] = u.stamp;
    for (uint slot = 0; slot < contactSlots; ++slot) {
        slots[target * contactSlots + slot] = emptySlot;
    }
}

// ...then offers its index, and the cell keeps the smallest in ascending order.
kernel void rubbleHash(const device RubbleParticle *particles [[buffer(0)]],
                       device atomic_uint *slots [[buffer(2)]],
                       const device uint *failureGate [[buffer(3)]],
                       const device StepControl &control [[buffer(4)]],
                       constant StructureUniforms &u [[buffer(5)]],
                       const device uint *state [[buffer(6)]],
                       uint index [[thread_position_in_grid]]) {
    bool active;
    structureStep(u, control, active);
    if (!active || !rubbleInUse(state, index) || !contactEnabled(u, failureGate)) {
        return;
    }
    uint target = contactBucket(contactCell(float3(particles[index].position), u), u);
    uint carried = index;
    for (uint slot = 0; slot < contactSlots && carried != emptySlot; ++slot) {
        uint held = atomic_fetch_min_explicit(&slots[target * contactSlots + slot], carried, memory_order_relaxed);
        carried = max(held, carried);
    }
}

// The contact force on each particle from the other particles and the body's nodes, from where
// they all were before this substep moves any of them.
kernel void rubbleForces(const device RubbleParticle *particles [[buffer(0)]],
                         const device uint *heads [[buffer(1)]],
                         const device uint *slots [[buffer(2)]],
                         const device uint *failureGate [[buffer(3)]],
                         const device StepControl &control [[buffer(4)]],
                         constant StructureUniforms &u [[buffer(5)]],
                         device float4 *forces [[buffer(6)]],
                         const device StructureNode *nodes [[buffer(7)]],
                         const device uint *nodeList [[buffer(8)]],
                         const device uint *nodeHeads [[buffer(9)]],
                         const device uint *nodeSlots [[buffer(10)]],
                         const device uint *state [[buffer(11)]],
                         uint index [[thread_position_in_grid]]) {
    bool active;
    float dt = structureStep(u, control, active);
    if (!active || !rubbleInUse(state, index) || !contactEnabled(u, failureGate)) {
        return;
    }
    RubbleParticle p = particles[index];
    if (p.alive == 0) {
        return;
    }
    float3 position = float3(p.position);
    float3 velocity = float3(p.velocity);
    int3 cell = contactCell(position, u);
    if (!rubbleListed(slots, contactBucket(cell, u), index)) {
        forces[index] = float4(0.0f);
        return;
    }
    float3 force = float3(0.0f);
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                int3 c = cell + int3(dx, dy, dz);
                uint target = contactBucket(c, u);
                if (heads[target] == u.stamp) {
                    for (uint slot = 0; slot < contactSlots; ++slot) {
                        uint other = slots[target * contactSlots + slot];
                        if (other == emptySlot) {
                            break;
                        }
                        if (other == index) {
                            continue;
                        }
                        RubbleParticle q = particles[other];
                        float3 at = float3(q.position);
                        if (any(contactCell(at, u) != c)) {
                            continue;
                        }
                        force += rubbleContact(position - at, rubblePairReach(p.reach, q.reach),
                                               velocity - float3(q.velocity), min(p.mass, q.mass), u);
                    }
                }
                if (nodeHeads[target] == u.stamp) {
                    for (uint slot = 0; slot < contactSlots; ++slot) {
                        uint other = nodeSlots[target * contactSlots + slot];
                        if (other == emptySlot) {
                            break;
                        }
                        float3 at = nodePosition(other, nodeList, nodes, u);
                        if (any(contactCell(at, u) != c)) {
                            continue;
                        }
                        StructureNode node = nodes[other];
                        force += rubbleContact(position - at, p.reach, velocity - float3(node.velocity),
                                               min(p.mass, node.mass), u);
                    }
                }
            }
        }
    }
    float largest = p.mass * contactKick / max(dt, 1e-12f);
    float size = length(force);
    if (size > largest) {
        force *= largest / size;
    }
    forces[index] = float4(force, 0.0f);
}

// After the node pass: each particle moves under its contacts, gravity and the air, and lands on
// the ground as loose nodes do.
kernel void rubbleMove(device RubbleParticle *particles [[buffer(0)]],
                       const device float4 *forces [[buffer(1)]],
                       const device uint *failureGate [[buffer(2)]],
                       const device StepControl &control [[buffer(3)]],
                       constant StructureUniforms &u [[buffer(4)]],
                       const device Cell *fluid [[buffer(5)]],
                       const device uchar *fluidMask [[buffer(6)]],
                       device atomic_uint *exchange [[buffer(7)]],
                       const device int *debrisArea [[buffer(8)]],
                       device atomic_uint *couplingMap [[buffer(9)]],
                       device uint *state [[buffer(10)]],
                       uint index [[thread_position_in_grid]]) {
    bool active;
    float dt = structureStep(u, control, active);
    if (!active) {
        return;
    }
    if (index == 0) {
        state[1] = 0;  // read by this substep's node pass, which has run
    }
    if (!rubbleInUse(state, index)) {
        return;
    }
    RubbleParticle p = particles[index];
    if (p.alive == 0) {
        return;
    }
    float3 position = float3(p.position);
    float3 force = contactEnabled(u, failureGate) ? forces[index].xyz : float3(0.0f);
    float3 airForce = float3(0.0f);
    int exchangeCell = -1;
    if (u.coupled != 0 && u.debrisLoading != 0) {
        airForce = debrisAirForce(position, float3(p.velocity), p.volume, fluid, fluidMask, debrisArea, control.dt, u,
                                  couplingMap, exchangeCell);
        force += airForce;
    }
    float3 velocity = float3(p.velocity) + dt * (force / p.mass - gravityPull(u));
    velocity *= max(0.0f, 1.0f - u.damping * dt);
    position += dt * velocity;
    if (position.z < 0.0f && u.groundFriction >= 0.0f) {
        position.z = 0.0f;
        velocity.z = max(velocity.z, 0.0f);
        velocity.xy *= max(0.0f, 1.0f - u.groundFriction * dt);
    }
    if (exchangeCell >= 0) {
        recordExchange(exchange, exchangeCell, airForce, 0.5f * (float3(p.velocity) + velocity), dt, u.fluidCell);
    }
    particles[index].position = position;
    particles[index].velocity = velocity;
}

// Before each air step's substeps, every particle adds its frontal area to its air cell, as loose
// nodes do (`debrisAreas`).
kernel void rubbleAreas(const device RubbleParticle *particles [[buffer(0)]],
                        const device StepControl &control [[buffer(1)]],
                        constant StructureUniforms &u [[buffer(2)]],
                        const device uchar *fluidMask [[buffer(3)]],
                        device atomic_int *area [[buffer(4)]],
                        const device uint *failureGate [[buffer(5)]],
                        device atomic_uint *couplingMap [[buffer(6)]],
                        const device uint *state [[buffer(7)]],
                        uint index [[thread_position_in_grid]]) {
    if (control.dt <= 0.0f || !rubbleInUse(state, index)) {
        return;
    }
    RubbleParticle p = particles[index];
    int exchangeCell = debrisCell(float3(p.position), fluidMask, u, couplingMap);
    if (exchangeCell < 0) {
        return;
    }
    float frontal = pow(p.volume, 2.0f / 3.0f) / (u.fluidCell * u.fluidCell * u.fluidCell);
    atomic_fetch_add_explicit(&area[exchangeCell], int(round(min(frontal * exchangeAreaScale, 1.0e9f))),
                              memory_order_relaxed);
}
