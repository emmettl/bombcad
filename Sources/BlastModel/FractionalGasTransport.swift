import CompressibleFlow

/// The released packet operator owns extensive-state transport and supplied gas loads.
/// Geometry, transfer construction, fluxes and time integration remain app-owned.
package typealias FractionalGasTransport = CompressibleFlow.PrescribedGasTransport
