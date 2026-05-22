import Foundation

public struct PowerSample: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let systemVoltageIn: Int
    public let systemCurrentIn: Int
    public let systemPowerIn: Int

    public init(timestamp: Date, systemVoltageIn: Int, systemCurrentIn: Int, systemPowerIn: Int) {
        self.timestamp = timestamp
        self.systemVoltageIn = systemVoltageIn
        self.systemCurrentIn = systemCurrentIn
        self.systemPowerIn = systemPowerIn
    }
}

public struct PortPowerSample: Codable, Sendable, Equatable {
    public let portIndex: Int
    public let portKey: String
    public let current: Int
    public let watts: Int
    public let configuredVoltage: Int
    public let configuredCurrent: Int
    public let adapterVoltage: Int
    public let vconnCurrent: Int
    public let vconnPower: Int
    /// Smoothed power reading (centiwatts).
    public let filteredPower: Int
    /// PD contract negotiated power (mW).
    public let pdPowerMW: Int
    /// Maximum VConn current the cable claimed (mA).
    public let vconnMaxCurrent: Int
    /// Lifetime accumulated energy through this port.
    public let accumulatedPower: Int
    /// Number of energy measurement samples taken.
    public let accumulatorCount: Int
    /// Number of energy measurement errors.
    public let accumulatorErrorCount: Int
    /// Lifetime VConn energy accumulated.
    public let vconnAccumulatedPower: Int
    /// VConn energy sample count.
    public let vconnAccumulatorCount: Int
    /// VConn energy measurement errors.
    public let vconnAccumulatorErrorCount: Int
    /// Number of liquid detection collision events on this port.
    public let numLDCMCollisions: Int
    /// Reserved sleep power for USB devices (mW).
    public let usbSleepPoolPowerMW: Int
    /// Reserved wake power for USB devices (mW).
    public let usbWakePoolPowerMW: Int
    /// Power delivery state.
    public let powerState: Int
    /// Port type identifier.
    public let portType: Int
    // True when the sample came from PortControllerInfo (contracted/port-max
    // only, no live per-port metering). Voltage is unrecoverable in this
    // path, so configuredVoltage stays 0 and the UI shows the honest
    // contracted-max card instead of a synthesized live reading.
    public let isContractedFallback: Bool

    public init(
        portIndex: Int,
        portKey: String = "",
        current: Int,
        watts: Int,
        configuredVoltage: Int,
        configuredCurrent: Int,
        adapterVoltage: Int,
        vconnCurrent: Int,
        vconnPower: Int,
        filteredPower: Int = 0,
        pdPowerMW: Int = 0,
        vconnMaxCurrent: Int = 0,
        accumulatedPower: Int = 0,
        accumulatorCount: Int = 0,
        accumulatorErrorCount: Int = 0,
        vconnAccumulatedPower: Int = 0,
        vconnAccumulatorCount: Int = 0,
        vconnAccumulatorErrorCount: Int = 0,
        numLDCMCollisions: Int = 0,
        usbSleepPoolPowerMW: Int = 0,
        usbWakePoolPowerMW: Int = 0,
        powerState: Int = 0,
        portType: Int = 0,
        isContractedFallback: Bool = false
    ) {
        self.portIndex = portIndex
        self.portKey = portKey
        self.current = current
        self.watts = watts
        self.configuredVoltage = configuredVoltage
        self.configuredCurrent = configuredCurrent
        self.adapterVoltage = adapterVoltage
        self.vconnCurrent = vconnCurrent
        self.vconnPower = vconnPower
        self.filteredPower = filteredPower
        self.pdPowerMW = pdPowerMW
        self.vconnMaxCurrent = vconnMaxCurrent
        self.accumulatedPower = accumulatedPower
        self.accumulatorCount = accumulatorCount
        self.accumulatorErrorCount = accumulatorErrorCount
        self.vconnAccumulatedPower = vconnAccumulatedPower
        self.vconnAccumulatorCount = vconnAccumulatorCount
        self.vconnAccumulatorErrorCount = vconnAccumulatorErrorCount
        self.numLDCMCollisions = numLDCMCollisions
        self.usbSleepPoolPowerMW = usbSleepPoolPowerMW
        self.usbWakePoolPowerMW = usbWakePoolPowerMW
        self.powerState = powerState
        self.portType = portType
        self.isContractedFallback = isContractedFallback
    }

    private enum CodingKeys: String, CodingKey {
        case portIndex, portKey, current, watts, configuredVoltage
        case configuredCurrent, adapterVoltage, vconnCurrent, vconnPower
        case filteredPower, pdPowerMW, vconnMaxCurrent
        case accumulatedPower, accumulatorCount, accumulatorErrorCount
        case vconnAccumulatedPower, vconnAccumulatorCount, vconnAccumulatorErrorCount
        case numLDCMCollisions, usbSleepPoolPowerMW, usbWakePoolPowerMW
        case powerState, portType
        case isContractedFallback
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        portIndex = try c.decode(Int.self, forKey: .portIndex)
        portKey = try c.decode(String.self, forKey: .portKey)
        current = try c.decode(Int.self, forKey: .current)
        watts = try c.decode(Int.self, forKey: .watts)
        configuredVoltage = try c.decode(Int.self, forKey: .configuredVoltage)
        configuredCurrent = try c.decode(Int.self, forKey: .configuredCurrent)
        adapterVoltage = try c.decode(Int.self, forKey: .adapterVoltage)
        vconnCurrent = try c.decode(Int.self, forKey: .vconnCurrent)
        vconnPower = try c.decode(Int.self, forKey: .vconnPower)
        filteredPower = try c.decodeIfPresent(Int.self, forKey: .filteredPower) ?? 0
        pdPowerMW = try c.decodeIfPresent(Int.self, forKey: .pdPowerMW) ?? 0
        vconnMaxCurrent = try c.decodeIfPresent(Int.self, forKey: .vconnMaxCurrent) ?? 0
        accumulatedPower = try c.decodeIfPresent(Int.self, forKey: .accumulatedPower) ?? 0
        accumulatorCount = try c.decodeIfPresent(Int.self, forKey: .accumulatorCount) ?? 0
        accumulatorErrorCount = try c.decodeIfPresent(Int.self, forKey: .accumulatorErrorCount) ?? 0
        vconnAccumulatedPower = try c.decodeIfPresent(Int.self, forKey: .vconnAccumulatedPower) ?? 0
        vconnAccumulatorCount = try c.decodeIfPresent(Int.self, forKey: .vconnAccumulatorCount) ?? 0
        vconnAccumulatorErrorCount = try c.decodeIfPresent(Int.self, forKey: .vconnAccumulatorErrorCount) ?? 0
        numLDCMCollisions = try c.decodeIfPresent(Int.self, forKey: .numLDCMCollisions) ?? 0
        usbSleepPoolPowerMW = try c.decodeIfPresent(Int.self, forKey: .usbSleepPoolPowerMW) ?? 0
        usbWakePoolPowerMW = try c.decodeIfPresent(Int.self, forKey: .usbWakePoolPowerMW) ?? 0
        powerState = try c.decodeIfPresent(Int.self, forKey: .powerState) ?? 0
        portType = try c.decodeIfPresent(Int.self, forKey: .portType) ?? 0
        isContractedFallback = try c.decodeIfPresent(Bool.self, forKey: .isContractedFallback) ?? false
    }
}

public struct CableResistanceEstimate: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case insufficient
        case converging
        case stable
        case unreliable
    }

    public let milliohms: Double
    public let sampleCount: Int
    public let rSquared: Double
    public let status: Status

    public init(milliohms: Double, sampleCount: Int, rSquared: Double, status: Status) {
        self.milliohms = milliohms
        self.sampleCount = sampleCount
        self.rSquared = rSquared
        self.status = status
    }
}

public struct PowerMonitorSnapshot: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let systemSample: PowerSample
    public let portSamples: [PortPowerSample]
    public let resistanceEstimate: CableResistanceEstimate?

    public init(
        timestamp: Date,
        systemSample: PowerSample,
        portSamples: [PortPowerSample],
        resistanceEstimate: CableResistanceEstimate?
    ) {
        self.timestamp = timestamp
        self.systemSample = systemSample
        self.portSamples = portSamples
        self.resistanceEstimate = resistanceEstimate
    }
}
