import Foundation
import Metal
import simd

/// A GPU contact solver for the blocks: each block a clump of spheres (a rigid body whose contact
/// is its spheres against other clumps and the heightfield), explicit, spring-dashpot contact
/// with a mass-scaled stiffness, held in place until fired, asleep once still.
/// A block's inertia per unit mass about its own axes, floored at half the largest: flat bedded
/// blocks otherwise spin up without limit under the explicit contact (for the eye, not accuracy).
private func inertiaFloor(_ block: Hillside.Block) -> SIMD3<Float> {
    let d = block.inertiaDiagonalPerMass
    let floor = 0.5 * d.max()
    return SIMD3(max(d.x, floor), max(d.y, floor), max(d.z, floor))
}

final class BlockSimulation {
    /// Layout matches `HillsideBody` in `Hillside.metal`.
    struct GPUBody {
        var posInvMass: SIMD4<Float>
        var quat: SIMD4<Float>
        var velSleep: SIMD4<Float>
        var ang: SIMD4<Float>
        var invInertiaFire: SIMD4<Float>
        var launchSwell: SIMD4<Float>
        var spinRise: SIMD4<Float>
        var swell: SIMD4<Float>
        var first: UInt32
        var count: UInt32
        var state: UInt32
        var pad: UInt32
    }

    /// Layout matches `HillsideUniforms` in `Hillside.metal`.
    struct Uniforms {
        var dt: Float
        var time: Float
        var gravity: Float
        var kc: Float
        var damping: Float
        var friction: Float
        var wakeSpeed: Float
        var cell: Float
        var origin: SIMD4<Float>
        var dims: SIMD4<Int32>
        var terrainOrigin: SIMD4<Float>
        var terrainDims: SIMD4<Int32>
        var sleepSpeed: Float
        var sleepSpin: Float
        var sleepTime: Float
        var frictionGamma: Float
        var bodyCount: UInt32
        var sphereCount: UInt32
        var cellCount: UInt32
        var pad: UInt32
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let bodies: MTLBuffer
    let spheres: MTLBuffer
    let sphereBody: MTLBuffer
    let world: MTLBuffer
    let velocity: MTLBuffer
    let heads: MTLBuffer
    let next: MTLBuffer
    let forces: MTLBuffer
    let torques: MTLBuffer
    let wake: MTLBuffer
    let heights: MTLBuffer
    let pose: MTLBuffer
    let bodyCount: Int
    let sphereCount: Int
    var uniforms: Uniforms
    let pipelines: [String: MTLComputePipelineState]
    var substepCount = 0

    init(
        device: MTLDevice, library: MTLLibrary, hillside: Hillside, launch: Launch, firings: [Firing],
        dt: Float
    ) throws {
        self.device = device
        queue = device.makeCommandQueue()!
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in ["updateSpheres", "clearGrid", "insertSpheres", "forces", "integrate"] {
            pipelines[name] = try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
        self.pipelines = pipelines
        var blocks = hillside.blocks
        let launchState = launch.apply(to: &blocks, firings: firings, hillside: hillside)
        bodyCount = blocks.count
        sphereCount = hillside.spheres.count
        let density: Float = 2500
        var gpuBodies = [GPUBody]()
        gpuBodies.reserveCapacity(blocks.count)
        for (n, b) in blocks.enumerated() {
            let mass = max(density * b.volume, 1)
            gpuBodies.append(
                GPUBody(
                    posInvMass: SIMD4(b.centre, 1 / mass),
                    quat: SIMD4(0, 0, 0, 1),
                    velSleep: .zero,
                    ang: .zero,
                    invInertiaFire: SIMD4(
                        1 / max(mass * inertiaFloor(b).x, 1e-3), 1 / max(mass * inertiaFloor(b).y, 1e-3),
                        1 / max(mass * inertiaFloor(b).z, 1e-3), launchState.fire[n]),
                    launchSwell: SIMD4(launchState.velocity[n], 0),
                    spinRise: SIMD4(launchState.spin[n], launch.rise),
                    swell: launchState.swell[n],
                    first: UInt32(b.firstSphere), count: UInt32(b.sphereCount), state: 0, pad: 0))
        }
        bodies = device.makeBuffer(bytes: gpuBodies, length: MemoryLayout<GPUBody>.stride * bodyCount)!
        var sphereData = [SIMD4<Float>](repeating: .zero, count: sphereCount)
        var bodyIndex = [UInt32](repeating: 0, count: sphereCount)
        for (n, b) in blocks.enumerated() {
            for s in b.firstSphere..<(b.firstSphere + b.sphereCount) {
                let sphere = hillside.spheres[s]
                sphereData[s] = SIMD4(sphere.offset, sphere.radius)
                bodyIndex[s] = UInt32(n)
            }
        }
        spheres = device.makeBuffer(bytes: sphereData, length: 16 * sphereCount)!
        sphereBody = device.makeBuffer(bytes: bodyIndex, length: 4 * sphereCount)!
        world = device.makeBuffer(length: 16 * sphereCount, options: .storageModePrivate)!
        velocity = device.makeBuffer(length: 16 * sphereCount, options: .storageModePrivate)!
        next = device.makeBuffer(length: 4 * sphereCount, options: .storageModePrivate)!
        forces = device.makeBuffer(length: 16 * sphereCount, options: .storageModePrivate)!
        torques = device.makeBuffer(length: 16 * sphereCount, options: .storageModePrivate)!
        wake = device.makeBuffer(length: 4 * bodyCount, options: .storageModeShared)!
        memset(wake.contents(), 0, 4 * bodyCount)
        heights = hillside.terrain.heights.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)!
        }
        pose = device.makeBuffer(length: 32 * bodyCount, options: .storageModeShared)!
        let posePointer = pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodyCount)
        for (n, b) in blocks.enumerated() {
            posePointer[2 * n] = SIMD4(b.centre, 0)
            posePointer[2 * n + 1] = SIMD4(0, 0, 0, 1)
        }
        let cell = max(hillside.maxRadius * 2.05, 0.4)
        let size = hillside.high - hillside.low
        let dims = SIMD3<Int32>(
            Int32(ceil(size.x / cell)), Int32(ceil(size.y / cell)), Int32(ceil(size.z / cell)))
        let cellCount = Int(dims.x) * Int(dims.y) * Int(dims.z)
        heads = device.makeBuffer(length: 4 * cellCount, options: .storageModePrivate)!
        uniforms = Uniforms(
            dt: dt, time: 0, gravity: 9.81, kc: 0.05, damping: 0.25, friction: 0.8, wakeSpeed: 0.6,
            cell: cell, origin: SIMD4(hillside.low, 0), dims: SIMD4(dims, 0),
            terrainOrigin: SIMD4(
                hillside.terrain.origin.x, hillside.terrain.origin.y, hillside.terrain.spacing, 0),
            terrainDims: SIMD4(Int32(hillside.terrain.columns), Int32(hillside.terrain.rows), 0, 0),
            sleepSpeed: 0.2, sleepSpin: 0.5, sleepTime: 0.5, frictionGamma: 0.5,
            bodyCount: UInt32(bodyCount), sphereCount: UInt32(sphereCount), cellCount: UInt32(cellCount),
            pad: 0)
        print(
            "grid: cell \(String(format: "%.2f", cell)) m, \(dims.x)x\(dims.y)x\(dims.z) = \(cellCount), dt \(dt) s"
        )
        // First fill of the spheres' world positions.
        let buffer = queue.makeCommandBuffer()!
        let encoder = buffer.makeComputeCommandEncoder()!
        encodeUpdate(encoder)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    private func encodeUpdate(_ encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(pipelines["updateSpheres"]!)
        encoder.setBuffer(bodies, offset: 0, index: 0)
        encoder.setBuffer(spheres, offset: 0, index: 1)
        encoder.setBuffer(sphereBody, offset: 0, index: 2)
        encoder.setBuffer(world, offset: 0, index: 3)
        encoder.setBuffer(velocity, offset: 0, index: 4)
        dispatch(encoder, sphereCount)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ count: Int) {
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: max(encoder.deviceWidth, 1), height: 1, depth: 1))
    }

    /// Advances `substeps` substeps on one command buffer; returns the GPU time (s).
    @discardableResult
    func advance(substeps: Int) -> Double {
        let buffer = queue.makeCommandBuffer()!
        let encoder = buffer.makeComputeCommandEncoder(dispatchType: .serial)!
        var u = uniforms
        for _ in 0..<substeps {
            u.time += u.dt
            substepCount += 1
            encodeUpdate(encoder)
            // Grid.
            encoder.setComputePipelineState(pipelines["clearGrid"]!)
            encoder.setBuffer(heads, offset: 0, index: 0)
            dispatch(encoder, Int(u.cellCount))
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines["insertSpheres"]!)
            encoder.setBuffer(world, offset: 0, index: 0)
            encoder.setBuffer(heads, offset: 0, index: 1)
            encoder.setBuffer(next, offset: 0, index: 2)
            encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
            dispatch(encoder, sphereCount)
            encoder.memoryBarrier(scope: .buffers)
            // Forces.
            encoder.setComputePipelineState(pipelines["forces"]!)
            encoder.setBuffer(bodies, offset: 0, index: 0)
            encoder.setBuffer(world, offset: 0, index: 1)
            encoder.setBuffer(velocity, offset: 0, index: 2)
            encoder.setBuffer(sphereBody, offset: 0, index: 3)
            encoder.setBuffer(heads, offset: 0, index: 4)
            encoder.setBuffer(next, offset: 0, index: 5)
            encoder.setBuffer(heights, offset: 0, index: 6)
            encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 7)
            encoder.setBuffer(forces, offset: 0, index: 8)
            encoder.setBuffer(torques, offset: 0, index: 9)
            encoder.setBuffer(wake, offset: 0, index: 10)
            dispatch(encoder, sphereCount)
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines["integrate"]!)
            encoder.setBuffer(bodies, offset: 0, index: 0)
            encoder.setBuffer(forces, offset: 0, index: 1)
            encoder.setBuffer(torques, offset: 0, index: 2)
            encoder.setBuffer(wake, offset: 0, index: 3)
            encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 4)
            encoder.setBuffer(pose, offset: 0, index: 5)
            dispatch(encoder, bodyCount)
            encoder.memoryBarrier(scope: .buffers)
        }
        uniforms = u
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer.gpuEndTime - buffer.gpuStartTime
    }

    /// Awake bodies, the fastest speed, and any NaN seen.
    func census() -> (
        awake: Int, held: Int, asleep: Int, maxSpeed: Float, meanSpeed: Float, kineticEnergy: Float, bad: Int
    ) {
        let p = bodies.contents().bindMemory(to: GPUBody.self, capacity: bodyCount)
        var result = (
            awake: 0, held: 0, asleep: 0, maxSpeed: Float(0), meanSpeed: Float(0), kineticEnergy: Float(0),
            bad: 0
        )
        for n in 0..<bodyCount {
            let b = p[n]
            if b.posInvMass.x.isNaN || b.velSleep.x.isNaN {
                result.bad += 1
                continue
            }
            switch b.state {
            case 0: result.held += 1
            case 1:
                result.awake += 1
                let v = simd_length(SIMD3(b.velSleep.x, b.velSleep.y, b.velSleep.z))
                result.maxSpeed = max(result.maxSpeed, v)
                result.meanSpeed += v
                result.kineticEnergy += 0.5 * v * v / b.posInvMass.w
            default: result.asleep += 1
            }
        }
        if result.awake > 0 { result.meanSpeed /= Float(result.awake) }
        return result
    }
}

extension MTLComputeCommandEncoder {
    /// A thread execution width safe for these pipelines: Apple GPUs report 32; a fixed value keeps
    /// the encode simple.
    var deviceWidth: Int { 32 }
}
