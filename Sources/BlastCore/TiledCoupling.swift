import BlastModel

extension TiledCoupling {
    /// The pages over `bodies`.
    init(grid: Grid, bodies: [StructuralBody], requestedCapacity: Int) throws {
        try self.init(
            grid: grid,
            footprints: bodies.map {
                Footprint(bounds: $0.model.bounds, reach: max($0.model.elementSize, $0.shellEnvelopeMargin))
            },
            requestedCapacity: requestedCapacity)
    }
}
