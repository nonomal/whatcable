import Foundation

/// Cable capability data from Apple's CIO (Thunderbolt) transport controller.
///
/// These properties come from `IOPortTransportStateCIO`, which appears
/// dynamically when a Thunderbolt link is active. They represent the TB
/// controller's own assessment of the cable, independent of the USB-PD
/// e-marker. This matters because some active TB4 cables (e.g. CalDigit
/// 2M) report "passive" in their e-marker while the CIO controller
/// correctly identifies their TB capability.
///
/// Value mappings are based on limited data (one TB4 cable so far) and
/// need confirmation with more cables before driving user-facing labels.
public struct CIOCableCapability: Identifiable, Hashable, Sendable {
    public let id: UInt64
    /// Port correlation key matching `PowerSource.portKey`.
    public let portKey: String

    /// Cable's Thunderbolt generation as reported by the CIO controller.
    /// Observed: 2 on a TB4 cable. Needs more data points.
    public let cableGeneration: Int?
    /// Cable speed capability from the CIO controller.
    /// Observed: 3 on a TB4 cable (likely Gen 3 / 40 Gbps).
    public let cableSpeed: Int?
    /// Active link generation on the CIO transport.
    /// Observed: 3 = USB4 Gen 3.
    public let generation: Int?
    /// Whether the cable/link supports asymmetric mode (120/40 Gbps).
    public let asymmetricModeSupported: Bool?
    /// True for TB3 legacy adapter connections, false for native USB4/TB4+.
    public let legacyAdapter: Bool?
    /// Link training mode reported by CIO. Meaning TBD.
    public let linkTrainingMode: Int?

    public init(
        id: UInt64,
        portKey: String,
        cableGeneration: Int?,
        cableSpeed: Int?,
        generation: Int?,
        asymmetricModeSupported: Bool?,
        legacyAdapter: Bool?,
        linkTrainingMode: Int?
    ) {
        self.id = id
        self.portKey = portKey
        self.cableGeneration = cableGeneration
        self.cableSpeed = cableSpeed
        self.generation = generation
        self.asymmetricModeSupported = asymmetricModeSupported
        self.legacyAdapter = legacyAdapter
        self.linkTrainingMode = linkTrainingMode
    }
}
