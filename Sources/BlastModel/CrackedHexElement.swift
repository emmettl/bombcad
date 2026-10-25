// The element of the cracked-hex reference (CrackedHexReference.swift): bars, histories and the
// four formulations' forces and tangents.

extension CrackedHex {
    /// A line of bars along local axis `axis`, at natural coordinates `position` in the other two
    /// (its entry along `axis` is ignored), or spread over the element's width across
    /// `spreadAcross`, as a mat is. `area` is the steel area the line carries through the element.
    public struct Bar: Sendable, Equatable {
        public var axis: Int
        public var area: Double
        public var position: SIMD3<Double>
        public var spreadAcross: Int?

        public init(axis: Int, area: Double, position: SIMD3<Double>, spreadAcross: Int? = nil) {
            self.axis = axis
            self.area = area
            self.position = position
            self.spreadAcross = spreadAcross
        }
    }

    /// An element's history. The centre's (and the hourglass forces') serve the one-point element;
    /// once switched, the eight points' and the bars' points' take over.
    public struct ElementHistory: Sendable, Equatable {
        public var switched = false
        public var centre = PointHistory()
        public var points = Array(repeating: PointHistory(), count: 8)
        public var hourglassForce = Array(repeating: SIMD3<Double>.zero, count: 4)
        public var hourglassAmplitude = Array(repeating: SIMD3<Double>.zero, count: 4)
        public var barCentre: [Steel.State]
        public var barPoints: [[Steel.State]]

        public init(element: Element) {
            barCentre = Array(repeating: Steel.State(), count: element.bars.count)
            barPoints = element.barPointRows.map { Array(repeating: Steel.State(), count: $0.count) }
        }
    }

    public struct Response: Sendable {
        /// Internal nodal forces (24) and their tangent (24 × 24, row-major).
        public var force: [Double]
        public var tangent: [Double]
        public var state: ElementHistory
    }

    public struct Element: Sendable {
        public let geometry: Geometry
        public let law: Law
        public let steel: Steel?
        public let bars: [Bar]
        public let formulation: Formulation
        /// What of the bars' strength the one-point element's hourglass cap counts (today's: all
        /// of it, `.smeared`).
        public var hourglassSteel = HourglassSteel.smeared
        /// With true (the reference as built for emmettl/bombcad-work#20), an element whose centre
        /// has not cracked caps its hourglass forces at the full tensile strength; the shader caps
        /// it at the tension its centre has reached, E times its largest tensile strain so far
        /// (`tensionEnvelope` below the onset), so an element squeezed from the start bends no
        /// more strongly than its bars and its squeeze allow. False matches the shader.
        public var uncrackedCapAtStrength = true
        /// Each bar's strain along its axis as a row over the 24 displacements: at the centre, and
        /// at its own points (two along it, two across a mat), with their weights (steel volume).
        let barCentreRows: [[Double]]
        let barPointRows: [[[Double]]]
        let barPointWeights: [[Double]]

        public init(
            geometry: Geometry, law: Law, formulation: Formulation, steel: Steel? = nil, bars: [Bar] = []
        ) {
            precondition(bars.isEmpty || steel != nil, "bars need a steel")
            self.geometry = geometry
            self.law = law
            self.formulation = formulation
            self.steel = steel
            self.bars = bars
            func row(_ b: [[Double]], axis: Int) -> [Double] {
                let r = geometry.axis(axis)
                let c = [r.x * r.x, r.y * r.y, r.z * r.z, r.x * r.y, r.y * r.z, r.z * r.x]
                return (0..<24).map { column in (0..<6).reduce(0.0) { $0 + c[$1] * b[$1][column] } }
            }
            barCentreRows = bars.map { row(geometry.centre, axis: $0.axis) }
            var pointRows: [[[Double]]] = []
            var weights: [[Double]] = []
            for bar in bars {
                var points: [SIMD3<Double>] = []
                for along in [-CrackedHex.gauss, CrackedHex.gauss] {
                    var p = bar.position
                    p[bar.axis] = along
                    if let across = bar.spreadAcross {
                        for side in [-CrackedHex.gauss, CrackedHex.gauss] {
                            var q = p
                            q[across] = side
                            points.append(q)
                        }
                    } else {
                        points.append(p)
                    }
                }
                pointRows.append(points.map { row(geometry.assumedOperator(at: $0), axis: bar.axis) })
                let volume = bar.area * geometry.length(along: bar.axis)
                weights.append(Array(repeating: volume / Double(points.count), count: points.count))
            }
            barPointRows = pointRows
            barPointWeights = weights
        }

        public var initialState: ElementHistory { ElementHistory(element: self) }

        /// Internal forces, tangent and trial history at displacements `u` (24), from the
        /// committed history. `switchNow` makes a switching element switch whatever its strain
        /// (a solver keeps a switch made earlier in the same step).
        public func evaluate(_ u: [Double], from committed: ElementHistory, switchNow: Bool = false)
            -> Response
        {
            var response = Response(
                force: Array(repeating: 0, count: 24), tangent: Array(repeating: 0, count: 576),
                state: committed)
            var sums = Sums()
            switch formulation {
            case .onePointHourglass(let coefficient):
                onePoint(
                    u, coefficient: coefficient, barsAtPoints: false, state: &response.state, into: &sums)
            case .fullIntegration:
                points(u, operators: geometry.full, state: &response.state, into: &sums)
            case .assumedStrain:
                points(u, operators: geometry.assumed, state: &response.state, into: &sums)
            case .switching(let coefficient):
                var switches = committed.switched || switchNow
                if !switches {
                    for b in geometry.assumed where CrackedHex.leavesElasticRange(law, strain: multiply(b, u))
                    {
                        switches = true
                        break
                    }
                }
                if switches {
                    if !committed.switched {
                        // Each point starts from the centre's history (its bars have been at
                        // their own points throughout); the hourglass control goes.
                        response.state.points = Array(repeating: committed.centre, count: 8)
                        response.state.hourglassForce = Array(repeating: .zero, count: 4)
                        response.state.hourglassAmplitude = Array(repeating: .zero, count: 4)
                    }
                    response.state.switched = true
                    points(u, operators: geometry.assumed, state: &response.state, into: &sums)
                } else {
                    onePoint(
                        u, coefficient: coefficient, barsAtPoints: true, state: &response.state, into: &sums)
                }
            }
            response.force = sums.force
            response.tangent = sums.tangent
            return response
        }

        /// Forces and tangent being summed.
        struct Sums {
            var force = Array(repeating: 0.0, count: 24)
            var tangent = Array(repeating: 0.0, count: 576)
        }

        func multiply(_ b: [[Double]], _ u: [Double]) -> [Double] {
            b.map { row in zip(row, u).reduce(0.0) { $0 + $1.0 * $1.1 } }
        }

        /// One point of concrete (or the elastic solid), weighted by `weight` (its volume).
        func addPoint(
            _ b: [[Double]], weight: Double, _ u: [Double], state: inout PointHistory,
            into response: inout Sums
        ) -> [Double] {
            let (stress, d) = CrackedHex.evaluate(law, strain: multiply(b, u), state: &state)
            var db = Array(repeating: Array(repeating: 0.0, count: 24), count: 6)
            for v in 0..<6 {
                for w in 0..<6 where d[6 * v + w] != 0 {
                    let dvw = d[6 * v + w]
                    for column in 0..<24 where b[w][column] != 0 { db[v][column] += dvw * b[w][column] }
                }
            }
            for v in 0..<6 {
                for row in 0..<24 where b[v][row] != 0 {
                    let bv = weight * b[v][row]
                    response.force[row] += bv * stress[v]
                    for column in 0..<24 where db[v][column] != 0 {
                        response.tangent[24 * row + column] += bv * db[v][column]
                    }
                }
            }
            return stress
        }

        func addBar(
            _ row: [Double], weight: Double, _ u: [Double], state: inout Steel.State,
            into response: inout Sums
        ) {
            guard let steel else { return }
            let strain = zip(row, u).reduce(0.0) { $0 + $1.0 * $1.1 }
            let (stress, tangent) = steel.stress(strain, state: &state)
            for i in 0..<24 where row[i] != 0 {
                response.force[i] += weight * stress * row[i]
                for j in 0..<24 where row[j] != 0 {
                    response.tangent[24 * i + j] += weight * tangent * row[i] * row[j]
                }
            }
        }

        func points(
            _ u: [Double], operators: [[[Double]]], state: inout ElementHistory, into response: inout Sums
        ) {
            let weight = geometry.volume / 8
            for g in 0..<8 {
                _ = addPoint(operators[g], weight: weight, u, state: &state.points[g], into: &response)
            }
            addBarPoints(u, state: &state, into: &response)
        }

        /// The bars strained at their own points.
        func addBarPoints(_ u: [Double], state: inout ElementHistory, into response: inout Sums) {
            for (i, rows) in barPointRows.enumerated() {
                for (p, row) in rows.enumerated() {
                    addBar(
                        row, weight: barPointWeights[i][p], u, state: &state.barPoints[i][p], into: &response)
                }
            }
        }

        /// Today's element: the centre's stress over the whole volume, bars strained with the
        /// centre (or, for the switching element, at their own points), and the shader's stiffness hourglass control (`Structure.metal`): its γ eight
        /// times these, E h / 48 per unit amplitude, incremental, each mode's force capped for
        /// concrete at its bending capacity × h² / 8, that capacity the larger of the tension the
        /// centre can still carry plus the bars' yield over the element, and s (1 − s / f_c) for
        /// a centre squeezed at s.
        func onePoint(
            _ u: [Double], coefficient: Double, barsAtPoints: Bool, state: inout ElementHistory,
            into response: inout Sums
        ) {
            let concreteStress = addPoint(
                geometry.centre, weight: geometry.volume, u, state: &state.centre, into: &response)
            if barsAtPoints {
                addBarPoints(u, state: &state, into: &response)
            } else {
                for (i, row) in barCentreRows.enumerated() {
                    addBar(
                        row, weight: bars[i].area * geometry.length(along: bars[i].axis), u,
                        state: &state.barCentre[i], into: &response)
                }
            }
            let h = geometry.size
            let k = coefficient * law.youngsModulus * h / 48
            var limit = Double.infinity
            if case .concrete(let c) = law {
                let most = state.centre.tension.max()
                let remaining =
                    most > c.crackingStrain || !uncrackedCapAtStrength
                    ? c.tension(most).stress : c.tensileStrength
                var steelCapacity = 0.0
                if let steel, hourglassSteel != .none {
                    for (i, bar) in bars.enumerated() {
                        let ratio = bar.area * geometry.length(along: bar.axis) / geometry.volume
                        var share = 1.0
                        if hourglassSteel == .remaining, !barsAtPoints {
                            // A layer of steel spread through the element carrying a membrane
                            // stress s bends no more than M_p (1 - (s / f_y)^2): what its axial
                            // force uses is not there to bend it as well.
                            var probe = state.barCentre[i]
                            let strain = zip(barCentreRows[i], u).reduce(0.0) { $0 + $1.0 * $1.1 }
                            let s = steel.stress(strain, state: &probe).stress / steel.yieldStress
                            share = max(1 - s * s, 0)
                        }
                        steelCapacity += ratio * steel.yieldStress * share
                    }
                }
                let squeezed = max(-min(concreteStress[0], min(concreteStress[1], concreteStress[2])), 0)
                let bending = squeezed * max(1 - squeezed / c.compressiveStrength, 0)
                let capacity = max(max(remaining + steelCapacity, bending), 0.02 * c.tensileStrength)
                limit = 0.125 * capacity * h * h
            }
            let amplitudes = geometry.hourglassAmplitudes(u).map { 8 * $0 }
            for mode in 0..<4 {
                let committedForce = state.hourglassForce[mode]
                let committedAmplitude = state.hourglassAmplitude[mode]
                var force = committedForce + k * (amplitudes[mode] - committedAmplitude)
                // At the cap the tangent stays elastic: a static solve then creeps onto the cap
                // instead of meeting a near-singular stiffness.
                let stiffness = k
                let magnitude = CrackedHex.length(force)
                if magnitude > limit { force *= limit / magnitude }
                state.hourglassForce[mode] = force
                state.hourglassAmplitude[mode] = amplitudes[mode]
                let gamma = geometry.gamma[mode].map { 8 * $0 }
                for a in 0..<8 {
                    for i in 0..<3 {
                        response.force[3 * a + i] += gamma[a] * force[i]
                        for b in 0..<8 {
                            response.tangent[24 * (3 * a + i) + 3 * b + i] += stiffness * gamma[a] * gamma[b]
                        }
                    }
                }
            }
        }
    }
}
