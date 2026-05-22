import Foundation

// MARK: - Generation / width / adapter enums
//
// These decode the raw IOKit field values into Swift cases. Encoding is
// anchored against Linux's `drivers/thunderbolt/tb_regs.h`, which describes
// the same USB4 lane-adapter registers Apple's IOThunderbolt fields appear
// to mirror. See planning/thunderbolt-fabric.md for the field-by-field
// reasoning and the contributor samples that confirmed the mapping for
// TB3, TB4 / USB4, and TB5. TB5 (raw speed code 0x2) was confirmed against
// an M5 Pro + UGreen JHL9580 dock paste-back on issue #52.

/// Negotiated lane-rate generation for a Thunderbolt link.
/// Decoded from `Current Link Speed` on a TB-protocol port (Adapter Type = 1).
public enum LinkGeneration: Hashable {
    /// Speed code `0x8`. 10 Gb/s per lane.
    case tb3
    /// Speed code `0x4`. 20 Gb/s per lane. Used by both USB4 v1 and TB4.
    /// IOKit doesn't (as far as we've seen) distinguish the two; the
    /// renderer treats them as one bucket.
    case usb4Tb4
    /// Speed code `0x2`. 40 Gb/s per lane. USB4 v2 / TB5.
    /// Confirmed via M5 Pro + UGreen JHL9580 dock paste-back on issue #52
    /// (system_profiler reports "Mode: USB4 v2, Speed: 120 Gb/s" for the
    /// same active link).
    case tb5
    /// Speed code we don't have a mapping for. Forward-compat: future
    /// generations or unexpected encodings won't break the model.
    case unknown(rawSpeedCode: UInt8)

    /// Per-lane Gb/s for the known cases. `nil` for `.unknown`.
    public var perLaneGbps: Int? {
        switch self {
        case .tb3: return 10
        case .usb4Tb4: return 20
        case .tb5: return 40
        case .unknown: return nil
        }
    }

    /// Headline full-link Gb/s for the known cases (TB3 / TB4 / USB4 v1 =
    /// 40, TB5 / USB4 v2 = 80). `nil` for `.unknown`. These are the
    /// published symmetric link speeds, used by `DataLinkDiagnostic` as the
    /// active Thunderbolt data rate. Asymmetric mode (TB5 120/40) and
    /// trained-down lane widths are deliberately not modelled here.
    public var totalGbps: Double? {
        switch self {
        case .tb3: return 40
        case .usb4Tb4: return 40
        case .tb5: return 80
        case .unknown: return nil
        }
    }

    /// Build from a raw `Current Link Speed` register value.
    /// `0` (idle) returns `nil`; the caller treats that as "no link".
    public static func from(rawSpeedCode: UInt8) -> LinkGeneration? {
        switch rawSpeedCode {
        case 0x0: return nil
        case 0x8: return .tb3
        case 0x4: return .usb4Tb4
        case 0x2: return .tb5
        default: return .unknown(rawSpeedCode: rawSpeedCode)
        }
    }
}

/// Bitmask decoding of `Current Link Speed` (a single value) for use as
/// a bitmask on `Supported Link Speed`. Each bit set indicates the
/// controller can negotiate that generation. We keep this as a raw struct
/// so future generations are representable without a model change.
public struct SupportedSpeedMask: Hashable {
    public let supportsTb3: Bool      // bit 0x8
    public let supportsUsb4Tb4: Bool  // bit 0x4
    public let supportsTb5: Bool      // bit 0x2
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
        self.supportsTb3 = (rawValue & 0x8) != 0
        self.supportsUsb4Tb4 = (rawValue & 0x4) != 0
        self.supportsTb5 = (rawValue & 0x2) != 0
    }
}

/// Decode of `Current Link Width`. This is a bitmask in the Linux model
/// (`enum tb_link_width`); preserve it as separate flags so a future TB5
/// asymmetric link is representable without refactoring.
public struct LinkWidth: Hashable {
    public let single: Bool        // bit 0x1
    public let dual: Bool          // bit 0x2
    public let asymmetricTx: Bool  // bit 0x4 (3 TX / 1 RX)
    public let asymmetricRx: Bool  // bit 0x8 (1 TX / 3 RX)
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
        self.single = (rawValue & 0x1) != 0
        self.dual = (rawValue & 0x2) != 0
        self.asymmetricTx = (rawValue & 0x4) != 0
        self.asymmetricRx = (rawValue & 0x8) != 0
    }

    /// Number of active TX lanes.
    /// `1` for single, `2` for dual, `3` for asymmetric TX, `1` for asymmetric RX.
    public var txLanes: Int {
        if asymmetricTx { return 3 }
        if asymmetricRx { return 1 }
        if dual { return 2 }
        if single { return 1 }
        return 0
    }

    /// Number of active RX lanes.
    public var rxLanes: Int {
        if asymmetricRx { return 3 }
        if asymmetricTx { return 1 }
        if dual { return 2 }
        if single { return 1 }
        return 0
    }

    /// Whether any lane is active.
    public var isActive: Bool { rawValue != 0 }
}

/// Decode of `Target Link Width`. Different encoding to Current Link Width:
/// Linux defines `LANE_ADP_CS_1_TARGET_WIDTH_SINGLE = 0x1` and
/// `LANE_ADP_CS_1_TARGET_WIDTH_DUAL = 0x3`. So `0x3` here means "negotiated
/// dual lane", NOT "asymmetric". This was a footgun in the planning phase.
public enum TargetLinkWidth: Hashable {
    case single
    case dual
    case unknown(rawValue: UInt8)

    public static func from(rawValue: UInt8) -> TargetLinkWidth? {
        switch rawValue {
        case 0: return nil
        case 0x1: return .single
        case 0x3: return .dual
        default: return .unknown(rawValue: rawValue)
        }
    }
}

/// Type of adapter on a Thunderbolt port. Each switch has lane adapters
/// (the actual TB ports) plus protocol adapters that tunnel DP, PCIe, and
/// USB3 over the fabric. Encoding 1:1 with Linux `tb_regs.h` adapter types.
///
/// The `down` / `up` distinction is the adapter's role relative to its
/// **local** router, not a global host-side / device-side label. In a
/// daisy-chain, a middle switch has both.
public enum AdapterType: Hashable {
    case inactive       // 0x000000
    case lane           // 0x000001 — physical TB port
    case nhi            // 0x000002 — host interface (only on root switches)
    case dpIn           // 0x0e0101
    case dpOut          // 0x0e0102
    case pcieDown       // 0x100101
    case pcieUp         // 0x100102
    case usb3Down       // 0x200101
    case usb3Up         // 0x200102
    case other(UInt32)

    public static func from(rawValue: UInt32) -> AdapterType {
        switch rawValue {
        case 0x000000: return .inactive
        case 0x000001: return .lane
        case 0x000002: return .nhi
        case 0x0e0101: return .dpIn
        case 0x0e0102: return .dpOut
        case 0x100101: return .pcieDown
        case 0x100102: return .pcieUp
        case 0x200101: return .usb3Down
        case 0x200102: return .usb3Up
        default: return .other(rawValue)
        }
    }

    /// True for the lane (physical TB) adapter. Used to select ports that
    /// actually carry a Thunderbolt link, as opposed to the protocol
    /// tunnels above.
    public var isLane: Bool {
        if case .lane = self { return true }
        return false
    }
}

// MARK: - Switch and port models

/// One Thunderbolt switch in the fabric. Could be a host root (Depth=0)
/// or a downstream device's internal switch (Depth>0).
public struct IOThunderboltSwitch: Identifiable, Hashable {
    public let id: Int64                    // UID (signed Int64; can be negative)
    public let className: String            // raw IOKit class
    public let vendorID: Int
    public let vendorName: String
    public let modelName: String
    public let routerID: Int                // 0 on the first host root
    public let depth: Int                   // hops from host (0 = root)
    public let routeString: Int64           // path encoding (one byte per hop)
    public let upstreamPortNumber: Int
    public let maxPortNumber: Int
    public let supportedSpeed: SupportedSpeedMask
    public let ports: [IOThunderboltPort]
    /// Parent switch UID, populated by the watcher via the IOKit parent
    /// chain. `nil` on host roots. Phase 3 (rendering) uses this to walk
    /// the topology without re-parsing Route String / Hop Table.
    public let parentSwitchUID: Int64?
    /// CIO firmware version string with build date and chip ID.
    public let firmwareVersion: String?
    /// Protocol version (64 = USB4/TB4).
    public let thunderboltVersion: Int?
    /// Controller chip device ID.
    public let deviceID: Int?
    /// Current power state (0 = sleeping, 2 = active).
    public let currentPowerState: Int?
    /// Firmware event counters (binary blob, 348 bytes).
    public let fwCounters: Data?
    /// Lifetime firmware event totals (binary blob, 348 bytes).
    public let fwCountersRunningTotal: Data?
    /// Device ROM topology descriptor.
    public let drom: Data?
    /// Time Management Unit mode requirement.
    public let minRequiredTMUMode: Int?

    public init(
        id: Int64,
        className: String,
        vendorID: Int,
        vendorName: String,
        modelName: String,
        routerID: Int,
        depth: Int,
        routeString: Int64,
        upstreamPortNumber: Int,
        maxPortNumber: Int,
        supportedSpeed: SupportedSpeedMask,
        ports: [IOThunderboltPort],
        parentSwitchUID: Int64?,
        firmwareVersion: String? = nil,
        thunderboltVersion: Int? = nil,
        deviceID: Int? = nil,
        currentPowerState: Int? = nil,
        fwCounters: Data? = nil,
        fwCountersRunningTotal: Data? = nil,
        drom: Data? = nil,
        minRequiredTMUMode: Int? = nil
    ) {
        self.id = id
        self.className = className
        self.vendorID = vendorID
        self.vendorName = vendorName
        self.modelName = modelName
        self.routerID = routerID
        self.depth = depth
        self.routeString = routeString
        self.upstreamPortNumber = upstreamPortNumber
        self.maxPortNumber = maxPortNumber
        self.supportedSpeed = supportedSpeed
        self.ports = ports
        self.parentSwitchUID = parentSwitchUID
        self.firmwareVersion = firmwareVersion
        self.thunderboltVersion = thunderboltVersion
        self.deviceID = deviceID
        self.currentPowerState = currentPowerState
        self.fwCounters = fwCounters
        self.fwCountersRunningTotal = fwCountersRunningTotal
        self.drom = drom
        self.minRequiredTMUMode = minRequiredTMUMode
    }

    /// Build a `IOThunderboltSwitch` from a raw IOKit property dictionary
    /// plus a list of already-parsed child ports. Returns `nil` if the
    /// dictionary is missing the minimum identifying fields (UID + Vendor ID).
    /// Lives here in `WhatCableCore` so it can be exercised against fixture
    /// data without IOKit, mirroring the `AppleHPMInterface.from(...)` pattern.
    public static func from(
        properties: [String: Any],
        className: String,
        ports: [IOThunderboltPort],
        parentSwitchUID: Int64? = nil
    ) -> IOThunderboltSwitch? {
        guard let uidNum = properties["UID"] as? NSNumber else { return nil }
        guard let vendorIDNum = properties["Vendor ID"] as? NSNumber else { return nil }

        let speedMaskRaw = (properties["Supported Link Speed"] as? NSNumber)?.uint8Value ?? 0

        let powerState: Int?
        if let pmDict = properties["IOPowerManagement"] as? [String: Any] {
            powerState = (pmDict["CurrentPowerState"] as? NSNumber)?.intValue
        } else {
            powerState = nil
        }

        return IOThunderboltSwitch(
            id: uidNum.int64Value,
            className: className,
            vendorID: vendorIDNum.intValue,
            vendorName: (properties["Device Vendor Name"] as? String) ?? "",
            modelName: (properties["Device Model Name"] as? String) ?? "",
            routerID: (properties["Router ID"] as? NSNumber)?.intValue ?? 0,
            depth: (properties["Depth"] as? NSNumber)?.intValue ?? 0,
            routeString: (properties["Route String"] as? NSNumber)?.int64Value ?? 0,
            upstreamPortNumber: (properties["Upstream Port Number"] as? NSNumber)?.intValue ?? 0,
            maxPortNumber: (properties["Max Port Number"] as? NSNumber)?.intValue ?? 0,
            supportedSpeed: SupportedSpeedMask(rawValue: speedMaskRaw),
            ports: ports,
            parentSwitchUID: parentSwitchUID,
            firmwareVersion: properties["Firmware Version"] as? String,
            thunderboltVersion: (properties["Thunderbolt Version"] as? NSNumber)?.intValue,
            deviceID: (properties["Device ID"] as? NSNumber)?.intValue,
            currentPowerState: powerState,
            fwCounters: properties["FW Counters"] as? Data,
            fwCountersRunningTotal: properties["FW Counters Running Total"] as? Data,
            drom: properties["DROM"] as? Data,
            minRequiredTMUMode: (properties["Min Required TMU Mode"] as? NSNumber)?.intValue
        )
    }

    /// True for switches the host owns directly (Depth=0).
    public var isHostRoot: Bool { depth == 0 }

    /// True when the controller is in an active power state.
    public var isAwake: Bool { currentPowerState == 2 }
}

/// One adapter on a Thunderbolt switch. Could be a physical TB lane port
/// (with link-state fields) or a protocol-tunnel adapter (DP, PCIe, USB3).
public struct IOThunderboltPort: Hashable {
    public let portNumber: Int
    /// String form of `Socket ID`, present on TB-protocol ports.
    /// Matches the `@N` suffix on a root host's USB-C port for the
    /// host-port-to-switch correlation key.
    public let socketID: String?
    public let adapterType: AdapterType
    /// Human-readable adapter description from IOKit (e.g. "Thunderbolt Port", "DP or HDMI Adapter").
    public let adapterDescription: String?
    /// Decoded `Current Link Speed`. `nil` on idle ports or non-lane adapters.
    public let currentSpeed: LinkGeneration?
    /// Decoded `Current Link Width`. `nil` on non-lane adapters; on idle
    /// lane ports, `LinkWidth.isActive` will be false.
    public let currentWidth: LinkWidth?
    public let targetWidth: TargetLinkWidth?
    /// Hardware-supported maximum link width.
    public let supportedWidth: LinkWidth?
    /// Per-lane Gb/s if we have a known generation, else `nil`. Convenience
    /// derived from `currentSpeed` so renderers don't need to switch on it.
    public let perLaneGbps: Int?
    public let txLanes: Int?
    public let rxLanes: Int?
    /// Raw `Target Link Speed`. Don't interpret this as a bitmask in the
    /// renderer; Linux defines it as a single named value
    /// (e.g. `LANE_ADP_CS_1_TARGET_SPEED_GEN3 = 0xc`). Kept raw for
    /// diagnostics.
    public let rawTargetSpeed: UInt8?
    /// Raw `Link Bandwidth`. Unitless aggregate that scales with active
    /// lanes; useful for diagnostics, not for user-facing labels.
    public let linkBandwidthRaw: Int?
    /// Maximum bandwidth currently allocated to this adapter.
    public let maxBandwidthAllocated: Int?
    /// Minimum bandwidth required by connected devices.
    public let requiredBandwidthAllocated: Int?
    /// Buffer credits reserved per protocol tunnel.
    public let bufferAllocation: BufferAllocation?
    /// Total available buffer credits on this adapter.
    public let maxCredits: Int?
    /// Partner port number for dual-lane operation.
    public let dualLinkPort: Int?
    /// Lane number this adapter uses.
    public let lane: Int?
    /// Power management link state (0 = CL0 active, higher = deeper sleep).
    public let clxState: Int?
    /// Thunderbolt protocol version (64 = USB4/TB4).
    public let thunderboltVersion: Int?
    /// Hardware-supported maximum link speed as a bitmask.
    public let supportedSpeed: SupportedSpeedMask?
    /// TRM policy string (e.g. "Root" for the host switch).
    public let trmPolicy: String?
    /// Controller vendor ID (1452 = Apple).
    public let vendorID: Int?
    /// Controller device ID.
    public let deviceID: Int?

    public struct BufferAllocation: Hashable {
        public let maxUSB3: Int
        public let maxPCIe: Int
        public let maxHI: Int
        public let minDPAux: Int

        public init(maxUSB3: Int, maxPCIe: Int, maxHI: Int, minDPAux: Int) {
            self.maxUSB3 = maxUSB3
            self.maxPCIe = maxPCIe
            self.maxHI = maxHI
            self.minDPAux = minDPAux
        }
    }

    public init(
        portNumber: Int,
        socketID: String?,
        adapterType: AdapterType,
        adapterDescription: String? = nil,
        currentSpeed: LinkGeneration?,
        currentWidth: LinkWidth?,
        targetWidth: TargetLinkWidth?,
        supportedWidth: LinkWidth? = nil,
        rawTargetSpeed: UInt8?,
        linkBandwidthRaw: Int?,
        maxBandwidthAllocated: Int? = nil,
        requiredBandwidthAllocated: Int? = nil,
        bufferAllocation: BufferAllocation? = nil,
        maxCredits: Int? = nil,
        dualLinkPort: Int? = nil,
        lane: Int? = nil,
        clxState: Int? = nil,
        supportedSpeed: SupportedSpeedMask? = nil,
        trmPolicy: String? = nil,
        thunderboltVersion: Int? = nil,
        vendorID: Int? = nil,
        deviceID: Int? = nil
    ) {
        self.portNumber = portNumber
        self.socketID = socketID
        self.adapterType = adapterType
        self.adapterDescription = adapterDescription
        self.currentSpeed = currentSpeed
        self.currentWidth = currentWidth
        self.targetWidth = targetWidth
        self.supportedWidth = supportedWidth
        self.perLaneGbps = currentSpeed?.perLaneGbps
        self.txLanes = currentWidth?.txLanes
        self.rxLanes = currentWidth?.rxLanes
        self.rawTargetSpeed = rawTargetSpeed
        self.linkBandwidthRaw = linkBandwidthRaw
        self.maxBandwidthAllocated = maxBandwidthAllocated
        self.requiredBandwidthAllocated = requiredBandwidthAllocated
        self.bufferAllocation = bufferAllocation
        self.maxCredits = maxCredits
        self.dualLinkPort = dualLinkPort
        self.lane = lane
        self.clxState = clxState
        self.supportedSpeed = supportedSpeed
        self.trmPolicy = trmPolicy
        self.thunderboltVersion = thunderboltVersion
        self.vendorID = vendorID
        self.deviceID = deviceID
    }

    /// Build a port from a raw IOKit property dictionary.
    public static func from(properties: [String: Any]) -> IOThunderboltPort? {
        guard let portNumNum = properties["Port Number"] as? NSNumber else { return nil }
        let adapterRaw = (properties["Adapter Type"] as? NSNumber)?.uint32Value ?? 0
        let adapter = AdapterType.from(rawValue: adapterRaw)

        let socketID = properties["Socket ID"] as? String
        let description = properties["Description"] as? String

        let speedRaw = (properties["Current Link Speed"] as? NSNumber)?.uint8Value ?? 0
        let widthRaw = (properties["Current Link Width"] as? NSNumber)?.uint8Value ?? 0
        let supportedWidthRaw = (properties["Supported Link Width"] as? NSNumber)?.uint8Value ?? 0
        let targetWidthRaw = (properties["Target Link Width"] as? NSNumber)?.uint8Value ?? 0
        let targetSpeedRaw = (properties["Target Link Speed"] as? NSNumber)?.uint8Value

        let currentSpeed: LinkGeneration?
        let currentWidth: LinkWidth?
        let targetWidth: TargetLinkWidth?
        let supportedWidth: LinkWidth?
        if adapter.isLane {
            currentSpeed = LinkGeneration.from(rawSpeedCode: speedRaw)
            currentWidth = LinkWidth(rawValue: widthRaw)
            targetWidth = TargetLinkWidth.from(rawValue: targetWidthRaw)
            supportedWidth = supportedWidthRaw != 0 ? LinkWidth(rawValue: supportedWidthRaw) : nil
        } else {
            currentSpeed = nil
            currentWidth = nil
            targetWidth = nil
            supportedWidth = nil
        }

        let bufferAlloc: BufferAllocation?
        if let bufDict = properties["Buffer Allocation Request"] as? [String: Any] {
            bufferAlloc = BufferAllocation(
                maxUSB3: (bufDict["Max USB3"] as? NSNumber)?.intValue ?? 0,
                maxPCIe: (bufDict["Max PCIe"] as? NSNumber)?.intValue ?? 0,
                maxHI: (bufDict["Max HI"] as? NSNumber)?.intValue ?? 0,
                minDPAux: (bufDict["Min DP Aux"] as? NSNumber)?.intValue ?? 0
            )
        } else {
            bufferAlloc = nil
        }

        return IOThunderboltPort(
            portNumber: portNumNum.intValue,
            socketID: socketID,
            adapterType: adapter,
            adapterDescription: description,
            currentSpeed: currentSpeed,
            currentWidth: currentWidth,
            targetWidth: targetWidth,
            supportedWidth: supportedWidth,
            rawTargetSpeed: targetSpeedRaw,
            linkBandwidthRaw: (properties["Link Bandwidth"] as? NSNumber)?.intValue,
            maxBandwidthAllocated: (properties["Maximum Bandwidth Allocated"] as? NSNumber)?.intValue,
            requiredBandwidthAllocated: (properties["Required Bandwidth Allocated"] as? NSNumber)?.intValue,
            bufferAllocation: bufferAlloc,
            maxCredits: (properties["Max Credits"] as? NSNumber)?.intValue,
            dualLinkPort: (properties["Dual-Link Port"] as? NSNumber)?.intValue,
            lane: (properties["Lane"] as? NSNumber)?.intValue,
            clxState: (properties["CLx State"] as? NSNumber)?.intValue,
            supportedSpeed: {
                let raw = (properties["Supported Link Speed"] as? NSNumber)?.uint8Value ?? 0
                return raw != 0 ? SupportedSpeedMask(rawValue: raw) : nil
            }(),
            trmPolicy: properties["TRM Policy"] as? String,
            thunderboltVersion: (properties["Thunderbolt Version"] as? NSNumber)?.intValue,
            vendorID: (properties["Vendor ID"] as? NSNumber)?.intValue,
            deviceID: (properties["Device ID"] as? NSNumber)?.intValue
        )
    }

    /// True for a TB lane port that has actually negotiated a link.
    /// Useful for the renderer when picking which port to label.
    public var hasActiveLink: Bool {
        guard adapterType.isLane else { return false }
        guard let currentWidth, currentWidth.isActive else { return false }
        return currentSpeed != nil
    }

    /// True when the cable is limiting the link below what hardware supports.
    public var isBandwidthLimited: Bool {
        guard let supported = supportedWidth, let current = currentWidth else { return false }
        return supported.dual && current.single
    }
}
