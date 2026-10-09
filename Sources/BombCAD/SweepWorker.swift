import BlastCore
import DocumentKit
import Foundation
import Metal

/// `BombCAD worker`: runs sweep cases sent to it over standard input, answering on standard
/// output (see `SweepWorkerMessage`), one at a time, until told to stop or its input closes, as
/// when the SSH connection that started it drops. Nothing else may be written to standard output.
@MainActor
enum SweepWorker {
    static func main() async -> Int32 {
        await serve(input: .standardInput, output: .standardOutput)
        return 0
    }

    static func serve(input: FileHandle, output: FileHandle) async {
        let writer = SweepWorkerWriter(output)
        let device = MTLCreateSystemDefaultDevice()?.name ?? "No Metal device"
        guard (try? writer.send(.hello(SweepWorkerHello(device: device)))) != nil else { return }
        let jobs = Jobs()
        do {
            for try await packet in SweepWorkerFrame.packets(from: input) {
                switch packet.message {
                case .run(let job):
                    if let running = jobs.current {
                        try? writer.send(.failed(job.id, "The worker is already running \(running.id)."))
                        continue
                    }
                    jobs.current = (
                        job.id,
                        Task {
                            await run(job, writer: writer)
                            if jobs.current?.id == job.id { jobs.current = nil }
                        }
                    )
                case .cancel(let id):
                    if let running = jobs.current, running.id == id { running.task.cancel() }
                    jobs.sessions[id] = nil
                    jobs.live[id] = nil
                    jobs.thermal[id] = nil
                case .shutdown:
                    await jobs.stop()
                    return
                case .consume(let session):
                    jobs.sessions[session.id] = FragmentConsumer(
                        spec: session.spec, scene: session.scene, keepsFrames: !session.live)
                    if session.live { jobs.live[session.id] = 0 }
                case .air(let id, let header):
                    guard var consumer = jobs.sessions[id] else { continue }
                    do {
                        consumer.consume(try AirSlice(header: header, payload: packet.payload))
                        jobs.sessions[id] = consumer
                        writer.enqueue(.report(id, consumer.report))
                        if let reported = jobs.live[id] {
                            let live = FragmentLive(consumer, time: header.time)
                            let impacts = Array(live.impacts.dropFirst(reported))
                            jobs.live[id] = live.impacts.count
                            writer.enqueue(
                                .live(
                                    id,
                                    LiveFrameHeader(
                                        time: header.time, fragmentCount: live.fragmentCount, impacts: impacts
                                    )),
                                payload: live.payload)
                        }
                    } catch {
                        jobs.sessions[id] = nil
                        writer.enqueue(.failed(id, error.localizedDescription))
                    }
                case .finishConsumer(let id, let interval):
                    guard let consumer = jobs.sessions.removeValue(forKey: id) else {
                        writer.enqueue(.failed(id, "No such fragment session."))
                        continue
                    }
                    do {
                        // The JSON's length, the JSON, then the trajectories.
                        let result = consumer.result(frameInterval: interval)
                        let json = try JSONEncoder().encode(result)
                        var length = UInt32(json.count).bigEndian
                        writer.enqueue(
                            .fragments(id),
                            payload: Data(bytes: &length, count: 4) + json + result.trajectoryData)
                    } catch {
                        writer.enqueue(
                            .failed(
                                id, "The fragments' result could not be sent: \(error.localizedDescription)"))
                    }
                case .thermal(let session):
                    jobs.thermal[session.id] = ThermalExposure(spec: session.spec, scene: session.scene)
                case .fireball(let id, let frame):
                    guard var exposure = jobs.thermal[id] else { continue }
                    exposure.add(frame)
                    jobs.thermal[id] = exposure
                    let live = ThermalLive(exposure)
                    writer.enqueue(
                        .thermalLive(id, ThermalLiveHeader(frames: live.frames, time: live.time)),
                        payload: live.payload)
                case .finishThermal(let id):
                    guard let exposure = jobs.thermal.removeValue(forKey: id) else {
                        writer.enqueue(.failed(id, "No such thermal session."))
                        continue
                    }
                    do {
                        writer.enqueue(.thermalResult(id), payload: try JSONEncoder().encode(exposure.result))
                    } catch {
                        writer.enqueue(
                            .failed(
                                id,
                                "The thermal radiation's result could not be sent: \(error.localizedDescription)"
                            ))
                    }
                default:
                    continue
                }
            }
        } catch {}
        // The input closed: nobody is waiting for the result.
        await jobs.stop()
    }

    /// The job running, if one is.
    private final class Jobs {
        var current: (id: UUID, task: Task<Void, Never>)?
        var sessions: [UUID: FragmentConsumer] = [:]
        /// Live sessions, and the impacts each has been sent.
        var live: [UUID: Int] = [:]
        var thermal: [UUID: ThermalExposure] = [:]

        func stop() async {
            guard let task = current?.task else { return }
            task.cancel()
            await task.value
        }
    }

    private static func run(_ job: SweepWorkerJob, writer: SweepWorkerWriter) async {
        do {
            var document = try ProjectDocument(archive: job.project.archive())
            document.savedRuns = []
            var options = HeadlessRun.Options(project: URL(filePath: "/dev/null"))
            options.name = job.name
            let result = try await HeadlessRun.perform(document, options: options) { fraction in
                try? writer.send(.progress(job.id, fraction))
            }
            try writer.send(.finished(job.id, SweepWorkerArchive(result.document.makeArchive())))
        } catch is CancellationError {
            try? writer.send(.failed(job.id, SweepWorkerMessage.cancelled))
        } catch {
            try? writer.send(.failed(job.id, error.localizedDescription))
        }
    }
}
