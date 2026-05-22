import Foundation

/// Compares what the Mac port, the cable, and the connected device can each
/// do for data, against the speed the link actually negotiated, and names
/// the weakest link. This is the data-speed sibling of `ChargingDiagnostic`
/// (which does the same job for power). Same shape on purpose: a failable
/// init that returns `nil` when there is nothing to judge, a `Bottleneck`
/// enum carrying the numbers, and plain-English `summary` / `detail`.
///
/// Phase 1 wording is deliberately NOT localised yet. The strings are under
/// review; once the verdict wording is approved they move to
/// `String(localized:)` against `_coreLocalizedBundle` in the UI phase,
/// matching `ChargingDiagnostic`.
public struct DataLinkDiagnostic {
    public enum Bottleneck: Hashable {
        /// Link is running at the fastest the parties support. Not a fault.
        case fine(activeGbps: Double)
        /// The cable is the binding constraint; host and device could go faster.
        case cableLimit(cableGbps: Double, capableGbps: Double)
        /// This Mac port is the slowest link.
        case hostLimit(hostGbps: Double, capableGbps: Double)
        /// The connected device itself is the cap (e.g. a USB 2.0 device).
        /// Normal, not actionable: not a cable fault.
        case deviceLimit(deviceGbps: Double)
        /// Everyone supports more than the active speed but no single
        /// culprit can be pinned. The honest answer to the case the old
        /// draft wrongly reported as "full speed".
        case degraded(activeGbps: Double, expectedGbps: Double)
        /// No e-marker and no controller data, so we cannot say whether the
        /// cable is the limit. Stated plainly rather than guessed.
        case unknownCable(activeGbps: Double)
    }

    public let bottleneck: Bottleneck
    public let summary: String
    public let detail: String

    /// True for the cases worth flagging in the inline one-line verdict.
    /// `deviceLimit` and `unknownCable` are informational, not faults, so
    /// they do not warn (a USB 2.0 keyboard or an e-marker-less cable is
    /// normal). This is a deliberate deviation from `ChargingDiagnostic`,
    /// where only `.fine` is non-warning.
    public var isWarning: Bool {
        switch bottleneck {
        case .fine, .deviceLimit, .unknownCable: return false
        case .cableLimit, .hostLimit, .degraded: return true
        }
    }

    /// True when the cable's own e-marker disagrees with the Thunderbolt
    /// controller's view of the cable (issue #111: active TB4 cables that
    /// report "passive" / a low speed in their e-marker while the
    /// controller correctly negotiates the full rate). When true the
    /// controller's higher figure is used and `detail` says so.
    public let cableSignalConflict: Bool

    /// The resolved per-party figures behind the verdict, in Gbps. The
    /// inline one-line verdict uses `summary`; the Pro breakdown renders
    /// these so the user can see the receipts (cable claims X, device does
    /// Y, link negotiated Z). All optional except `activeGbps`, which is
    /// always known (the diagnostic returns nil without it).
    public struct Facts: Hashable {
        /// What this Mac port can do, if the caller resolved it.
        public let hostGbps: Double?
        /// Cable speed as claimed by its own USB-PD e-marker.
        public let cableEmarkerGbps: Double?
        /// Cable speed as the Thunderbolt controller sees it (CIO).
        public let cableControllerGbps: Double?
        /// The cable figure actually used: the higher of the two when both
        /// exist (the controller wins on a conflict).
        public let cableGbps: Double?
        /// The fastest connected device's speed.
        public let deviceGbps: Double?
        /// The speed the link actually negotiated.
        public let activeGbps: Double
    }

    public let facts: Facts
}

extension DataLinkDiagnostic {
    /// - Parameters:
    ///   - port: the physical USB-C / MagSafe port. Used only to gate on
    ///     `connectionActive` (mirrors `ChargingDiagnostic`'s stale-port
    ///     guard: a disconnected port can keep cached state around).
    ///   - identities: USB-PD Discover Identity endpoints for this port.
    ///     The cable e-marker is the SOP' / SOP'' entry; the connected
    ///     device/charger is SOP. We read the cable's claimed speed here.
    ///   - devices: USB devices on this port. The fastest one is taken as
    ///     the representative device cap (the device the link is serving).
    ///   - usb3Transports: USB 3 SuperSpeed transports; the one matching
    ///     this port (by `portKey`) gives the negotiated USB 3 rate.
    ///   - cio: the Thunderbolt controller's own cable assessment for this
    ///     port, if a TB link is active. Ground truth for TB cables and can
    ///     legitimately disagree with the e-marker (issue #111).
    ///   - thunderboltSwitches: the host's TB switch graph. The port's
    ///     active downstream lane link gives the negotiated TB rate. The
    ///     correlation reuses the same `ThunderboltTopology` helpers
    ///     `PortSummary` uses, so the messy switch-tree walk stays in one
    ///     tested place.
    ///   - tbActiveGbps: explicit override for the active TB rate. When
    ///     `nil` it is resolved from `thunderboltSwitches`. Mainly a test
    ///     seam (mirrors `ChargingDiagnostic`'s defaulted `wattageSource`).
    ///   - hostMaxGbps: what this Mac port can do, resolved by the caller.
    ///     This is the one genuinely uncertain input, so it is optional:
    ///     when `nil` the diagnostic never blames the host, it degrades to
    ///     `unknownCable` / `degraded` instead.
    public init?(
        port: AppleHPMInterface,
        identities: [USBPDSOP],
        devices: [USBDevice],
        usb3Transports: [USB3Transport],
        cio: CIOCableCapability?,
        thunderboltSwitches: [IOThunderboltSwitch] = [],
        tbActiveGbps: Double? = nil,
        hostMaxGbps: Double? = nil
    ) {
        // Same guard as ChargingDiagnostic: an inactive port can still
        // expose stale link state. Don't diagnose a port that isn't live.
        guard port.connectionActive == true else { return nil }

        // Pick the port's USB 3 transport (portKey is the correlation key;
        // fall back to the only entry if the caller pre-filtered).
        let usb3 = usb3Transports.first { $0.portKey == port.portKey }
            ?? usb3Transports.first

        // The speed the link actually negotiated: the Thunderbolt link if
        // there is one, otherwise the USB 3 signaling generation.
        let activeGbps = tbActiveGbps
            ?? Self.activeTBGbps(port: port, switches: thunderboltSwitches)
            ?? Self.usb3Gbps(usb3?.signaling)

        // Without a known active speed there is no data-speed verdict to
        // give. Returning nil keeps this off ports that are charge-only or
        // where the link state isn't readable yet.
        guard let active = activeGbps else { return nil }

        // Cable's claimed speed from its e-marker (SOP' / SOP'').
        let emarkerGbps = identities
            .first(where: { $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime })?
            .cableVDO?.speed.maxGbps

        // Cable's speed as the Thunderbolt controller sees it. Only the
        // confirmed codes are mapped; unknown codes stay nil rather than
        // guess (mirrors CIOCableCapability.speedLabel's conservatism).
        let cioGbps = Self.cioCableGbps(cio?.cableSpeed)

        // When both signals exist and disagree, the controller wins
        // (issue #111) and we flag the conflict so the UI can explain it.
        let conflict: Bool
        let cableMaxGbps: Double?
        switch (emarkerGbps, cioGbps) {
        case let (e?, c?):
            conflict = !Self.sameTier(e, c)
            cableMaxGbps = max(e, c)
        case let (e?, nil):
            conflict = false
            cableMaxGbps = e
        case let (nil, c?):
            conflict = false
            cableMaxGbps = c
        case (nil, nil):
            conflict = false
            cableMaxGbps = nil
        }
        self.cableSignalConflict = conflict

        // The device the link is actually serving is the fastest one
        // attached: a slow hub-mate shouldn't mask a fast SSD.
        let fastestDevice = devices
            .filter { $0.speedRaw != nil }
            .max { (Self.deviceGbps($0.speedRaw) ?? 0) < (Self.deviceGbps($1.speedRaw) ?? 0) }
        let deviceMaxGbps = Self.deviceGbps(fastestDevice?.speedRaw)

        // Capture the resolved figures for the Pro breakdown. Every
        // constructed instance flows through here (the only earlier return
        // is the no-active-speed guard, which yields no instance).
        self.facts = Facts(
            hostGbps: hostMaxGbps,
            cableEmarkerGbps: emarkerGbps,
            cableControllerGbps: cioGbps,
            cableGbps: cableMaxGbps,
            deviceGbps: deviceMaxGbps,
            activeGbps: active
        )

        let conflictNote = conflict
            ? " " + String(localized: "The cable's own e-marker under-reports its speed; the Thunderbolt controller confirms it is faster.", bundle: _coreLocalizedBundle)
            : ""

        // Every capability we actually know about, tagged by party. The
        // link can never run faster than the slowest of these.
        var caps: [(party: String, value: Double)] = []
        if let c = cableMaxGbps  { caps.append((party: "cable",  value: c)) }
        if let h = hostMaxGbps   { caps.append((party: "host",   value: h)) }
        if let d = deviceMaxGbps { caps.append((party: "device", value: d)) }

        guard let expected = caps.map(\.value).min() else {
            // We know the active speed but have nothing to compare it to:
            // no e-marker, no controller data, host unresolved, no device.
            // Don't guess a culprit.
            self.bottleneck = .unknownCable(activeGbps: active)
            self.summary = String(localized: "Running at \(Self.label(active))", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "There's no cable e-marker or controller data, and no port or device capability to compare against, so we can't tell whether the cable is the limit.", bundle: _coreLocalizedBundle)
            return
        }

        if Self.meaningfullySlower(active, than: expected) {
            // Slower than even the slowest part we can see. Something
            // unidentified degraded it. If the cable is the unknown, it's
            // the honest suspect; otherwise it's an unattributed degrade.
            // Either way, never claim "full speed" here (the old draft bug).
            if cableMaxGbps == nil {
                self.bottleneck = .unknownCable(activeGbps: active)
                self.summary = String(localized: "Running at \(Self.label(active))", bundle: _coreLocalizedBundle)
                self.detail = String(localized: "This cable has no e-marker and no controller data, so we can't tell whether it is the limit.", bundle: _coreLocalizedBundle)
            } else {
                self.bottleneck = .degraded(activeGbps: active, expectedGbps: expected)
                self.summary = String(localized: "Running slower than expected (\(Self.label(active)))", bundle: _coreLocalizedBundle)
                self.detail = String(localized: "The parts we can see all support \(Self.label(expected)) or more, but the link came up slower. Reseating the cable or trying another port may help.", bundle: _coreLocalizedBundle) + conflictNote
            }
            return
        }

        // The link is running about as fast as the slowest known part
        // allows. If some other known part is faster, that slowest part is
        // holding it back. If everything known is the same tier, nothing is
        // being limited and the link is fine.
        let limiters = caps.filter { Self.sameTier($0.value, expected) }
        let fasterOthers = caps.filter { Self.meaningfullySlower(expected, than: $0.value) }

        guard !fasterOthers.isEmpty else {
            self.bottleneck = .fine(activeGbps: active)
            self.summary = String(localized: "Running at full data speed (\(Self.label(active)))", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "Nothing is being held back: the parts we can see all support this speed.", bundle: _coreLocalizedBundle) + conflictNote
            return
        }

        // Name the binding part. Cable first because it's the actionable
        // one (the user can buy a better cable), then host, then device.
        let capable = fasterOthers.map(\.value).min() ?? expected
        let priority = ["cable", "host", "device"]
        let culprit = priority.first { p in limiters.contains { $0.party == p } } ?? "device"

        switch culprit {
        case "cable":
            self.bottleneck = .cableLimit(cableGbps: expected, capableGbps: capable)
            self.summary = String(localized: "Cable is limiting data speed", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "The Mac and device can do \(Self.label(capable)), but the cable only carries \(Self.label(expected)). A faster cable would unlock full speed.", bundle: _coreLocalizedBundle) + conflictNote
        case "host":
            self.bottleneck = .hostLimit(hostGbps: expected, capableGbps: capable)
            self.summary = String(localized: "This Mac port limits data speed", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "The cable and device can do \(Self.label(capable)), but this port maxes out at \(Self.label(expected)).", bundle: _coreLocalizedBundle) + conflictNote
        default: // device
            self.bottleneck = .deviceLimit(deviceGbps: expected)
            self.summary = String(localized: "Device runs at \(Self.label(expected))", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "This is the fastest the connected device supports. It is not a cable problem.", bundle: _coreLocalizedBundle) + conflictNote
        }
    }

    // MARK: - Speed resolution helpers

    /// The active Thunderbolt link rate for a port, resolved from the host
    /// switch graph. Reuses the same `ThunderboltTopology` correlation
    /// `PortSummary` uses (socket-ID match -> host root -> active
    /// downstream lane port). Returns `nil` when the port isn't on a TB
    /// link or no link is up.
    static func activeTBGbps(
        port: AppleHPMInterface,
        switches: [IOThunderboltSwitch]
    ) -> Double? {
        guard !switches.isEmpty,
              let socketID = ThunderboltTopology.socketID(fromServiceName: port.serviceName),
              let root = ThunderboltTopology.hostRoot(forSocketID: socketID, in: switches),
              let hostPort = ThunderboltTopology.activeDownstreamLanePort(root),
              let gen = hostPort.currentSpeed else {
            return nil
        }
        return gen.totalGbps
    }

    /// USB 3 signaling generation to Gbps. 1 = Gen 1 (5), 2 = Gen 2 (10).
    static func usb3Gbps(_ signaling: Int?) -> Double? {
        switch signaling {
        case 1: return 5
        case 2: return 10
        default: return nil
        }
    }

    /// CIO controller cable-speed code to Gbps. Only the confirmed codes
    /// are mapped (3 = TB4 / 40, 4 = TB5 / 80). TB3 is unsampled, so an
    /// unknown code returns nil rather than a guess.
    static func cioCableGbps(_ code: Int?) -> Double? {
        switch code {
        case 3: return 40
        case 4: return 80
        default: return nil
        }
    }

    /// USB device "Device Speed" enum to Gbps. Mirrors USBDevice.speedLabel.
    static func deviceGbps(_ speedRaw: UInt8?) -> Double? {
        switch speedRaw {
        case 0: return 0.0015   // Low Speed   1.5 Mbps
        case 1: return 0.012    // Full Speed  12 Mbps
        case 2: return 0.48     // High Speed  480 Mbps
        case 3: return 5        // SuperSpeed  5 Gbps
        case 4: return 10       // SuperSpeed+ 10 Gbps
        case 5: return 20       // Gen 2x2     20 Gbps
        default: return nil
        }
    }

    /// Speeds come in well-separated tiers (0.48 / 5 / 10 / 20 / 40 / 80),
    /// so a 10% band is plenty to absorb rounding without merging tiers.
    static func sameTier(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return a == b }
        let ratio = a / b
        return ratio >= 0.9 && ratio <= 1.111
    }

    /// `a` is meaningfully slower than `b` (more than ~10% below it).
    static func meaningfullySlower(_ a: Double, than b: Double) -> Bool {
        a < b * 0.9
    }

    /// Human-readable speed: sub-1-Gbps as Mbps, whole numbers without ".0".
    static func label(_ gbps: Double) -> String {
        if gbps < 1 {
            return "\(Int((gbps * 1000).rounded())) Mbps"
        }
        if gbps.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(gbps)) Gbps"
        }
        return "\(gbps) Gbps"
    }
}
