import BlastCore
import Foundation
import Testing
import simd

@testable import BombCAD

/// Simulation ▸ Infer Charge: observers read, the posterior sampled off the main thread with
/// progress, cancelled cleanly, and the scene's charge put at its median.
@MainActor @Suite("Infer Charge sheet", .serialized, .hangLimit)
struct ChargeInferenceSheetTests {
    /// 50 t at 120 m east and 80 m south of a point in Beirut, seen by 25 observers 150–700 m out.
    static let reference = SIMD2(35.519042, 33.901425)

    static func observers() -> [ChargeInferenceInputs.ObserverRow] {
        let projection = ChargeInferenceInputs.LocalProjection(centre: reference)
        let places = (0..<25).map { n -> SIMD2<Double> in
            let angle = Double(n) * 2.4
            let range = 150 + 22 * Double(n)
            return SIMD2(120 + range * cos(angle), -80 + range * sin(angle))
        }
        let arrivals = ChargeInference.syntheticArrivals(
            massKg: 5e4, east: 120, north: -80, places: places, spread: 0.03, frame: 1.0 / 30, seed: 7)
        return arrivals.map {
            ChargeInferenceInputs.ObserverRow(
                name: $0.name, lonLat: projection.lonLat(SIMD2($0.east, $0.north)), earliest: $0.earliest,
                latest: $0.latest)
        }
    }

    /// Waits for the inference, with no deadline of its own: the suite's hang limit stops a hang.
    private func finish(_ inference: ChargeInferenceModel) async throws {
        while inference.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func observersReadInEitherForm() throws {
        let plain = try ChargeInferenceInputs.readObservers(
            "name,lat,lon,earliest_s,latest_s\nA,33.9,35.5,1.20,1.25\nB,33.91,35.52,2.0,1.9\n")
        #expect(plain.count == 2 && plain[0].name == "A" && plain[0].lonLat == SIMD2(35.5, 33.9))
        let rigby = try ChargeInferenceInputs.readObservers(
            "video_ref,type,toa_best_s,toa_minus_err_s,lat_deg,lon_deg\n1,Video,2.0,1.95,33.9,35.5\n"
                + "2,Fireball,0.1,0.05,33.9,35.5\n")
        #expect(rigby.count == 1 && rigby[0].name == "Video 1" && rigby[0].earliest == 1.95)
        #expect(throws: ChargeInferenceInputs.ReadError.self) {
            try ChargeInferenceInputs.readObservers("a,b,c\n1,2,3\n")
        }
    }

    @Test func itFindsTheChargeAndPlacesIt() async throws {
        let inference = ChargeInferenceModel()
        #expect(inference.notReady != nil)
        inference.setObservers(Self.observers(), file: "made-up.csv")
        inference.referenceLongitude = String(Self.reference.x)
        inference.referenceLatitude = String(Self.reference.y)
        inference.steps = 600
        #expect(inference.notReady == nil)
        inference.run()
        #expect(inference.isRunning)
        try await finish(inference)
        #expect(inference.error == nil)
        let result = try #require(inference.result)
        #expect(inference.progress > 0.9)
        let kt = try #require(result.kilotonnes)
        #expect(kt.p05 < 0.05 && 0.05 < kt.p95 && abs(kt.median / 0.05 - 1) < 0.25)
        let place = try #require(result.place)
        #expect(simd_distance(place, SIMD2(120, -80)) < 20)
        // The scene's corner 500 m west and 400 m south of the reference point.
        let projection = ChargeInferenceInputs.LocalProjection(centre: Self.reference)
        let placement = try #require(inference.scenePlacement(corner: projection.lonLat(SIMD2(-500, -400))))
        #expect(abs(placement.position.x - 620) < 20 && abs(placement.position.y - 320) < 20)
        #expect(placement.position.z == 0 && abs(placement.massKg / 5e4 - 1) < 0.25)
    }

    @Test func cancellingKeepsNoResult() async throws {
        let inference = ChargeInferenceModel()
        inference.setObservers(Self.observers(), file: "made-up.csv")
        inference.steps = 200_000
        inference.run()
        try await Task.sleep(for: .milliseconds(200))
        inference.cancel()
        try await finish(inference)
        #expect(inference.result == nil && inference.error == nil)
    }
}
