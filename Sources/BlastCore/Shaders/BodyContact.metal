// Contact between independent bodies sharing the air (see `BlastSolver`'s lockstep encoding).
//
// As between the two parts of a mixed body (`crossContactSolid`, `crossContactShell`): in each
// substep, after every body has filled its own contact table and found its own contacts, and
// before any of them moves, each node of one body is pushed by the nodes of another within half
// the sum of their spheres' widths, through the other's table. Every pair is worked out the same
// way from both sides, from positions and velocities at the start of the substep and with the
// same spring, damper and friction, so the forces are equal and opposite; each sum runs in table
// order, so runs repeat exactly. Nodes dropped by their own crowded entry take no part, and shell
// nodes tied into a solid (which move with it) are left out. Unlike within a body, no pair is
// excused for having begun close: separate bodies start apart.

struct BodyContact {
    float reach;      // spheres of the two bodies touch closer than this
    float stiffness;  // spring per unit of the pair's mass and of overlap (1/s²)
    float damping;    // fraction of critical
    float friction;
    uint own;         // the bodies' indices in the envelope table
    uint other;
};

// Whether two bodies' envelopes, grown by the reach, overlap; if not, nothing of the one can
// touch the other this substep.
static inline bool bodyContactNear(const device uint *bounds, constant BodyContact &c) {
    for (uint axis = 0; axis < 3; ++axis) {
        uint alo = bounds[6u * c.own + axis], ahi = bounds[6u * c.own + 3u + axis];
        uint blo = bounds[6u * c.other + axis], bhi = bounds[6u * c.other + 3u + axis];
        if (alo > ahi || blo > bhi) { return false; }
        if (min(bodyFloatFromOrder(ahi), bodyFloatFromOrder(bhi)) + c.reach
            < max(bodyFloatFromOrder(alo), bodyFloatFromOrder(blo))) {
            return false;
        }
    }
    return true;
}

// The force on the first of two nodes from the second, `offset` and `relative` being its position
// and velocity relative to the second's: the spring, damper and friction of contact within a body.
static inline float3 bodyPairForce(float3 offset, float3 relative, float mass, float dt,
                                   constant BodyContact &c) {
    float gap = length(offset);
    if (gap >= c.reach || gap < 1e-9f) {
        return float3(0.0f);
    }
    float3 normal = offset / gap;
    float stiffness = c.stiffness * mass;
    float damping = 2.0f * c.damping * sqrt(stiffness * mass);
    float approach = dot(relative, normal);
    float push = approach > separationLimit ? 0.0f : max(stiffness * (c.reach - gap) - damping * approach, 0.0f);
    float3 force = push * normal;
    float3 sliding = relative - approach * normal;
    float speed = length(sliding);
    if (speed > 1e-6f) {
        force -= min(c.friction * push, damping * speed) * (sliding / speed);
    }
    // As within a body, contact may change the lighter node's velocity by at most `contactKick`
    // in a step; the limit is the pair's, so the forces stay equal and opposite.
    float largest = mass * contactKick / max(dt, 1e-12f);
    float size = length(force);
    return size > largest ? force * (largest / size) : force;
}

// Whether a node can touch the other body at all: within the reach of its envelope. Most of a
// body's nodes are far from the other's, and stop here before searching its table.
static inline bool bodyContactWithin(float3 position, const device uint *bounds, constant BodyContact &c) {
    for (uint axis = 0; axis < 3; ++axis) {
        float low = bodyFloatFromOrder(bounds[6u * c.other + axis]) - c.reach;
        float high = bodyFloatFromOrder(bounds[6u * c.other + 3u + axis]) + c.reach;
        if (position[axis] < low || position[axis] > high) { return false; }
    }
    return true;
}

// The force on a node from the nodes of a solid body near it, through that body's table.
static inline float3 forceFromSolidTable(float3 position, float3 velocity, float mass, float dt,
                                         constant BodyContact &c, const device uint *list,
                                         const device StructureNode *nodes, const device uint *heads,
                                         const device uint *slots, constant StructureUniforms &u) {
    int3 low = contactCell(position - c.reach, u);
    int3 high = contactCell(position + c.reach, u);
    float3 force = float3(0.0f);
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                int3 cell = int3(x, y, z);
                uint target = contactBucket(cell, u);
                if (heads[target] != u.stamp) {
                    continue;
                }
                for (uint slot = 0; slot < contactSlots; ++slot) {
                    uint other = slots[target * contactSlots + slot];
                    if (other == emptySlot) {
                        break;
                    }
                    float3 otherPosition = nodePosition(other, list, nodes, u);
                    if (any(contactCell(otherPosition, u) != cell)) {
                        continue;
                    }
                    StructureNode partner = nodes[other];
                    force += bodyPairForce(position - otherPosition, velocity - float3(partner.velocity),
                                           min(mass, partner.mass), dt, c);
                }
            }
        }
    }
    return force;
}

// The force on a node from the nodes of a shell body near it, through that body's table.
static inline float3 forceFromShellTable(float3 position, float3 velocity, float mass, float dt,
                                         constant BodyContact &c, const device ShellNode *nodes,
                                         const device float4 *reference, const device uint *heads,
                                         const device uint *slots, constant ShellUniforms &su) {
    int3 low = shellContactCell(position - c.reach, su);
    int3 high = shellContactCell(position + c.reach, su);
    float3 force = float3(0.0f);
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                int3 cell = int3(x, y, z);
                uint target = shellContactBucket(cell, su);
                if (heads[target] != su.stamp) {
                    continue;
                }
                for (uint slot = 0; slot < shellContactSlots; ++slot) {
                    uint other = slots[target * shellContactSlots + slot];
                    if (other == emptySlot) {
                        break;
                    }
                    ShellNode partner = nodes[other];
                    float3 otherPosition = reference[other].xyz + float3(partner.displacement);
                    if ((partner.flags & shellOnSolid) != 0 || any(shellContactCell(otherPosition, su) != cell)) {
                        continue;
                    }
                    force += bodyPairForce(position - otherPosition, velocity - float3(partner.velocity),
                                           min(mass, partner.mass), dt, c);
                }
            }
        }
    }
    return force;
}

// A solid body's node, listed in its own table, at the start of the substep; false if it takes
// no part.
static inline bool solidContactNode(uint n, const device uint *list, const device StructureNode *nodes,
                                    const device uint *slots, constant StructureUniforms &u,
                                    thread float3 &position, thread StructureNode &node) {
    node = nodes[n];
    if ((node.flags & nodeBuried) != 0) {
        return false;
    }
    position = nodePosition(n, list, nodes, u);
    uint own = contactBucket(contactCell(position, u), u);
    for (uint slot = 0; slot < contactSlots; ++slot) {
        if (slots[own * contactSlots + slot] == n) {
            return true;
        }
    }
    return false;
}

static inline bool shellContactNode(uint n, const device ShellNode *nodes, const device float4 *reference,
                                    const device uint *slots, constant ShellUniforms &su,
                                    thread float3 &position, thread ShellNode &node) {
    node = nodes[n];
    if ((node.flags & shellOnSolid) != 0) {
        return false;
    }
    position = reference[n].xyz + float3(node.displacement);
    uint own = shellContactBucket(shellContactCell(position, su), su);
    for (uint slot = 0; slot < shellContactSlots; ++slot) {
        if (slots[own * shellContactSlots + slot] == n) {
            return true;
        }
    }
    return false;
}

static inline void addBodyContact(device packed_float3 *contact, uint n, float3 force) {
    contact[n] = float3(contact[n]) + force;
}

kernel void bodyContactSolidFromSolid(const device uint *list [[buffer(0)]],
                                      const device StructureNode *nodes [[buffer(1)]],
                                      const device uint *slots [[buffer(2)]],
                                      constant StructureUniforms &u [[buffer(3)]],
                                      const device StepControl &control [[buffer(4)]],
                                      device packed_float3 *contact [[buffer(5)]],
                                      const device uint *otherList [[buffer(6)]],
                                      const device StructureNode *otherNodes [[buffer(7)]],
                                      const device uint *otherHeads [[buffer(8)]],
                                      const device uint *otherSlots [[buffer(9)]],
                                      constant StructureUniforms &ou [[buffer(10)]],
                                      constant BodyContact &c [[buffer(11)]],
                                      const device uint *bounds [[buffer(12)]],
                                      uint n [[thread_position_in_grid]]) {
    bool active;
    float dt = structureStep(u, control, active);
    float3 position;
    StructureNode node;
    if (!active || !bodyContactNear(bounds, c) || !solidContactNode(n, list, nodes, slots, u, position, node)
        || !bodyContactWithin(position, bounds, c)) {
        return;
    }
    float3 force = forceFromSolidTable(position, float3(node.velocity), node.mass, dt, c, otherList, otherNodes,
                                       otherHeads, otherSlots, ou);
    addBodyContact(contact, n, force);
}

kernel void bodyContactSolidFromShell(const device uint *list [[buffer(0)]],
                                      const device StructureNode *nodes [[buffer(1)]],
                                      const device uint *slots [[buffer(2)]],
                                      constant StructureUniforms &u [[buffer(3)]],
                                      const device StepControl &control [[buffer(4)]],
                                      device packed_float3 *contact [[buffer(5)]],
                                      const device ShellNode *otherNodes [[buffer(6)]],
                                      const device float4 *otherReference [[buffer(7)]],
                                      const device uint *otherHeads [[buffer(8)]],
                                      const device uint *otherSlots [[buffer(9)]],
                                      constant ShellUniforms &osu [[buffer(10)]],
                                      constant BodyContact &c [[buffer(11)]],
                                      const device uint *bounds [[buffer(12)]],
                                      uint n [[thread_position_in_grid]]) {
    bool active;
    float dt = structureStep(u, control, active);
    float3 position;
    StructureNode node;
    if (!active || !bodyContactNear(bounds, c) || !solidContactNode(n, list, nodes, slots, u, position, node)
        || !bodyContactWithin(position, bounds, c)) {
        return;
    }
    float3 force = forceFromShellTable(position, float3(node.velocity), node.mass, dt, c, otherNodes,
                                       otherReference, otherHeads, otherSlots, osu);
    addBodyContact(contact, n, force);
}

kernel void bodyContactShellFromSolid(const device ShellNode *nodes [[buffer(0)]],
                                      const device float4 *reference [[buffer(1)]],
                                      const device uint *slots [[buffer(2)]],
                                      constant ShellUniforms &su [[buffer(3)]],
                                      const device StepControl &control [[buffer(4)]],
                                      device packed_float3 *contact [[buffer(5)]],
                                      const device uint *otherList [[buffer(6)]],
                                      const device StructureNode *otherNodes [[buffer(7)]],
                                      const device uint *otherHeads [[buffer(8)]],
                                      const device uint *otherSlots [[buffer(9)]],
                                      constant StructureUniforms &ou [[buffer(10)]],
                                      constant BodyContact &c [[buffer(11)]],
                                      const device uint *bounds [[buffer(12)]],
                                      uint n [[thread_position_in_grid]]) {
    bool active;
    float dt = shellStep(su, control, active);
    float3 position;
    ShellNode node;
    if (!active || n >= su.nodeCount || !bodyContactNear(bounds, c)
        || !shellContactNode(n, nodes, reference, slots, su, position, node)
        || !bodyContactWithin(position, bounds, c)) {
        return;
    }
    float3 force = forceFromSolidTable(position, float3(node.velocity), node.mass, dt, c, otherList, otherNodes,
                                       otherHeads, otherSlots, ou);
    addBodyContact(contact, n, force);
}

kernel void bodyContactShellFromShell(const device ShellNode *nodes [[buffer(0)]],
                                      const device float4 *reference [[buffer(1)]],
                                      const device uint *slots [[buffer(2)]],
                                      constant ShellUniforms &su [[buffer(3)]],
                                      const device StepControl &control [[buffer(4)]],
                                      device packed_float3 *contact [[buffer(5)]],
                                      const device ShellNode *otherNodes [[buffer(6)]],
                                      const device float4 *otherReference [[buffer(7)]],
                                      const device uint *otherHeads [[buffer(8)]],
                                      const device uint *otherSlots [[buffer(9)]],
                                      constant ShellUniforms &osu [[buffer(10)]],
                                      constant BodyContact &c [[buffer(11)]],
                                      const device uint *bounds [[buffer(12)]],
                                      uint n [[thread_position_in_grid]]) {
    bool active;
    float dt = shellStep(su, control, active);
    float3 position;
    ShellNode node;
    if (!active || n >= su.nodeCount || !bodyContactNear(bounds, c)
        || !shellContactNode(n, nodes, reference, slots, su, position, node)
        || !bodyContactWithin(position, bounds, c)) {
        return;
    }
    float3 force = forceFromShellTable(position, float3(node.velocity), node.mass, dt, c, otherNodes,
                                       otherReference, otherHeads, otherSlots, osu);
    addBodyContact(contact, n, force);
}
