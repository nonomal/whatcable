import Foundation

/// Where the "charger wattage" number came from for a given port.
///
/// Most ports get their wattage from the per-port USB-PD negotiation
/// (`portNegotiated`). Some setups (e.g. Thunderbolt docks that deliver
/// power without registering a USB-PD source) only expose a system-wide
/// adapter reading. Under strict conditions we fall back to that value.
public enum ChargerWattageSource: Hashable {
    case portNegotiated(watts: Int)
    case systemAdapterFallback(watts: Int)
    case unknown

    public var watts: Int? {
        switch self {
        case .portNegotiated(let w): return w
        case .systemAdapterFallback(let w): return w
        case .unknown: return nil
        }
    }

    /// Resolve the charger wattage for a single port.
    ///
    /// - Parameters:
    ///   - portSources: Power sources belonging to this port only.
    ///   - activePortCount: Number of ports with `connectionActive == true`
    ///     across the whole machine. Used to guard against multi-charger
    ///     cross-contamination (see issue #46).
    ///   - adapter: System-wide adapter info from `IOPSCopyExternalPowerAdapterDetails`.
    public static func resolve(
        portSources: [PowerSource],
        activePortCount: Int,
        adapter: AdapterInfo?
    ) -> ChargerWattageSource {
        let source = PowerSource.preferredChargingSource(in: portSources)

        // "Brick ID" is a low-fidelity analog identifier, not a USB-PD
        // contract. On MagSafe with a third-party PD brick the port only
        // exposes Brick ID (often ~3W) while the real negotiated wattage
        // sits in the system adapter reading. Same situation as the
        // TB-dock case in #141, extended to a Brick ID that does carry a
        // tiny wattage (so the check below would otherwise accept it as
        // authoritative). When Brick ID is the only source, one port is
        // active, and the system adapter reports a higher wattage, trust
        // the adapter. The single-active-port guard preserves the #46
        // multi-charger protection. See issue #154.
        if let source, source.name == "Brick ID",
           activePortCount == 1,
           let adapterW = adapter?.watts, adapterW > 0 {
            let brickW = Int((Double(source.maxPowerMW) / 1000).rounded())
            if adapterW > brickW {
                return .systemAdapterFallback(watts: adapterW)
            }
        }

        if let source, source.maxPowerMW > 0 {
            let watts = Int((Double(source.maxPowerMW) / 1000).rounded())
            return .portNegotiated(watts: watts)
        }

        // If a USB-PD source exists on this port (even with 0W), PD
        // negotiation owns the wattage. Don't substitute the system
        // adapter, because on a multi-charger Mac the adapter value
        // might belong to a different port. See issue #46.
        let hasUSBPD = portSources.contains { $0.name == "USB-PD" }
        if hasUSBPD { return .unknown }

        // Brick ID is the sole source type (no USB-PD). The charger is
        // delivering power through a path that bypasses per-port PD
        // negotiation (e.g. a Thunderbolt dock, see issue #141).
        // Fall back to the system adapter under two conditions:
        //
        // (a) Only one port is active. If two ports are active, we
        //     can't tell which one the system adapter reading belongs
        //     to. This guards against a hypothetical where two TB
        //     docks both deliver power on separate chains.
        //
        // (b) The system adapter reports a positive wattage.
        if activePortCount == 1,
           let adapterW = adapter?.watts,
           adapterW > 0 {
            return .systemAdapterFallback(watts: adapterW)
        }

        return .unknown
    }
}
