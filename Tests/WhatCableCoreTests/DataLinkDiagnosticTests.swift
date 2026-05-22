import Testing
@testable import WhatCableCore

@Suite("Data Link Diagnostic")
struct DataLinkDiagnosticTests {

    // MARK: - Fixtures

    /// Active USB-C port. Same shape as the ChargingDiagnostic fixture
    /// (the proven-compiling AppleHPMInterface init param list).
    private func makePort(active: Bool = true) -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: active,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: [],
            transportsActive: [],
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    /// Cable e-marker (SOP') advertising a given CableSpeed code in the
    /// low 3 bits of VDO[3]. Codes: 0 = USB 2.0 (0.48), 1 = USB 3.2 Gen 1
    /// (5), 2 = Gen 2 (10), 3 = USB4 Gen 3 (40), 4 = Gen 4 (80). Mirrors
    /// the ChargingDiagnostic test's cableIdentity construction.
    private func cableEmarker(speedCode: UInt32) -> USBPDSOP {
        let validLatency: UInt32 = 1 << 13          // ~1m, avoids decode warning
        let cableVDO = speedCode | (1 << 5) | validLatency   // 3A current bits
        let idHeader: UInt32 = 0x1800_0000          // passive cable, UFP type 3
        return USBPDSOP(
            id: 2, endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [idHeader, 0, 0, cableVDO],
            specRevision: 0
        )
    }

    /// USB device with a given "Device Speed" enum value.
    /// 3 = 5 Gbps, 4 = 10 Gbps, 5 = 20 Gbps.
    private func device(speedRaw: UInt8) -> USBDevice {
        USBDevice(
            id: 10, locationID: 0x0100_0000,
            vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Test SSD", serialNumber: nil,
            usbVersion: nil, speedRaw: speedRaw,
            busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    private func cio(cableSpeed: Int) -> CIOCableCapability {
        CIOCableCapability(
            id: 3, portKey: "2/1",
            cableGeneration: nil, cableSpeed: cableSpeed, generation: nil,
            asymmetricModeSupported: nil, legacyAdapter: nil, linkTrainingMode: nil
        )
    }

    private func usb3(signaling: Int) -> USB3Transport {
        USB3Transport(
            id: 4, portKey: "2/1",
            signaling: signaling, signalingDescription: nil, dataRole: nil
        )
    }

    // MARK: - Applicability

    @Test("Returns nil on an inactive port")
    func returnsNilOnInactivePort() {
        let diag = DataLinkDiagnostic(
            port: makePort(active: false),
            identities: [cableEmarker(speedCode: 3)],
            devices: [device(speedRaw: 5)],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil
        )
        #expect(diag == nil)
    }

    @Test("Returns nil when no active link speed is known")
    func returnsNilWithoutActiveSpeed() {
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],
            devices: [device(speedRaw: 5)],
            usb3Transports: [],            // no USB3 signaling
            cio: nil,
            tbActiveGbps: nil              // no TB link
        )
        #expect(diag == nil)
    }

    // MARK: - Bottleneck attribution

    @Test("Cable is the bottleneck")
    func cableIsBottleneck() {
        // Mac port 20, device 20, but a USB 3.2 Gen 1 (5 Gbps) cable.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 1)],   // 5 Gbps
            devices: [device(speedRaw: 5)],              // 20 Gbps
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 20
        )
        guard case .cableLimit(let cable, let capable) = diag?.bottleneck else {
            Issue.record("expected .cableLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(cable == 5)
        #expect(capable == 20)
        #expect(diag!.isWarning)
    }

    @Test("Host port is the bottleneck")
    func hostIsBottleneck() {
        // Fast 40 Gbps cable, 20 Gbps device, but the Mac port only does 5.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [device(speedRaw: 5)],              // 20 Gbps
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 5
        )
        guard case .hostLimit(let host, let capable) = diag?.bottleneck else {
            Issue.record("expected .hostLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(host == 5)
        #expect(capable == 20)
        #expect(diag!.isWarning)
    }

    @Test("Device is the cap, not a fault")
    func deviceIsCapNotFault() {
        // 40 Gbps cable, 40 Gbps port, but a 10 Gbps device.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [device(speedRaw: 4)],              // 10 Gbps
            usb3Transports: [usb3(signaling: 2)],        // active 10 Gbps
            cio: nil,
            hostMaxGbps: 40
        )
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 10)
        #expect(diag!.isWarning == false)   // a slow device is normal, not a warning
    }

    @Test("Degraded link: everyone supports more but it came up slow")
    func degradedLink() {
        // 40 Gbps cable, 40 Gbps port, 20 Gbps device, but the TB link
        // negotiated only 5 Gbps. This is the case the old draft wrongly
        // reported as "full speed".
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [device(speedRaw: 5)],              // 20 Gbps
            usb3Transports: [],
            cio: nil,
            tbActiveGbps: 5,                             // degraded link
            hostMaxGbps: 40
        )
        guard case .degraded(let active, let expected) = diag?.bottleneck else {
            Issue.record("expected .degraded, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 5)
        #expect(expected == 20)
        #expect(diag!.isWarning)
    }

    @Test("No cable signal: honest 'can't tell'")
    func unknownCableWhenNoSignal() {
        // No e-marker, no controller data. Port 40, device 20, link 5.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [device(speedRaw: 5)],              // 20 Gbps
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 40
        )
        guard case .unknownCable(let active) = diag?.bottleneck else {
            Issue.record("expected .unknownCable, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 5)
        #expect(diag!.isWarning == false)
        #expect(diag!.cableSignalConflict == false)
    }

    @Test("Everything matched: fine")
    func everythingFine() {
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [],
            usb3Transports: [],
            cio: nil,
            tbActiveGbps: 40,                            // active 40 Gbps
            hostMaxGbps: 40
        )
        guard case .fine(let active) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(diag!.isWarning == false)
    }

    @Test("Controller overrides a lying e-marker (issue #111)")
    func controllerWinsOverEmarker() {
        // E-marker claims USB 2.0 (passive under-report), but the TB
        // controller reports CableSpeed 3 (40 Gbps). We must NOT blame the
        // cable: report fine at 40 and flag the conflict.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 0)],   // e-marker says 0.48
            devices: [],
            usb3Transports: [],
            cio: cio(cableSpeed: 3),                     // controller says 40
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard case .fine(let active) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(diag!.cableSignalConflict == true)
        #expect(diag!.detail.contains("under-reports"))
    }

    @Test("No capability known at all: unknownCable, not a guess")
    func noCapabilityKnown() {
        // Active 10 Gbps link, but no e-marker, no controller data, host
        // unresolved, no device. Nothing to compare against.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],        // active 10 Gbps
            cio: nil,
            hostMaxGbps: nil
        )
        guard case .unknownCable(let active) = diag?.bottleneck else {
            Issue.record("expected .unknownCable, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 10)
        #expect(diag!.isWarning == false)
    }

    @Test("Facts expose the resolved per-party numbers")
    func factsExposeResolvedNumbers() {
        // E-marker says 0.48 (USB 2.0), controller says 40 (TB4 class),
        // host 40, device 10 (speedRaw 4), link active at 40 (TB).
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 0)],   // 0.48
            devices: [device(speedRaw: 4)],              // 10
            usb3Transports: [],
            cio: cio(cableSpeed: 3),                     // 40
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic with facts, got nil")
            return
        }
        #expect(facts.cableEmarkerGbps == 0.48)
        #expect(facts.cableControllerGbps == 40)
        #expect(facts.cableGbps == 40)        // controller wins
        #expect(facts.deviceGbps == 10)
        #expect(facts.hostGbps == 40)
        #expect(facts.activeGbps == 40)
        #expect(diag!.cableSignalConflict == true)
    }
}
