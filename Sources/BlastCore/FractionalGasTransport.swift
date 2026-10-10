import CompressibleFlow

/// The released packet operator owns extensive-state transport and supplied gas loads.
/// Geometry, transfer construction, fluxes and time integration remain app-owned.
typealias FractionalGasTransport = CompressibleFlow.PrescribedGasTransport
