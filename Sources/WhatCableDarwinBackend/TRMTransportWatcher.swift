import Foundation
import IOKit
import WhatCableCore

/// Watches `IOPortTransportState*` services for TRM (Trust and Restrict
/// Management) properties and CIO cable capability data. These transport
/// services appear dynamically when a USB-C accessory is connected and
/// disappear on unplug.
///
/// Each transport (USB2, DisplayPort, etc.) can carry its own TRM state,
/// so a single port might have USB2 restricted while DisplayPort is not.
///
/// CIO transports additionally carry cable capability fields
/// (`CableGeneration`, `CableSpeed`, etc.) that represent the TB
/// controller's assessment of the cable, independent of the USB-PD
/// e-marker. These are published separately as `CIOCableCapability`.
@MainActor
public final class TRMTransportWatcher: ObservableObject {
    @Published public private(set) var transports: [TRMTransport] = []
    @Published public private(set) var cioCapabilities: [CIOCableCapability] = []

    // Transport state classes that carry TRM properties. USB2 and
    // DisplayPort are the ones confirmed to have meaningful TRM data.
    // USB3 and CIO may also carry TRM state when those transports are
    // active, so we watch them too.
    nonisolated static let watchedClasses = [
        "IOPortTransportStateUSB2",
        "IOPortTransportStateDisplayPort",
        "IOPortTransportStateUSB3",
        "IOPortTransportStateCIO",
    ]

    private var notifyPort: IONotificationPortRef?
    private var addedIters: [io_iterator_t] = []
    private var removedIters: [io_iterator_t] = []

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<TRMTransportWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in w.handleAdded(iter) }
        }
        let removed: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<TRMTransportWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in w.handleRemoved(iter) }
        }

        for cls in Self.watchedClasses {
            var addIter: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOMatchedNotification,
                                                 IOServiceMatching(cls),
                                                 added, selfPtr, &addIter) == KERN_SUCCESS {
                addedIters.append(addIter)
                handleAdded(addIter)
            }

            var rmIter: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                                 IOServiceMatching(cls),
                                                 removed, selfPtr, &rmIter) == KERN_SUCCESS {
                removedIters.append(rmIter)
                handleRemoved(rmIter)
            }
        }
    }

    public func stop() {
        for iter in addedIters { IOObjectRelease(iter) }
        addedIters.removeAll()
        for iter in removedIters { IOObjectRelease(iter) }
        removedIters.removeAll()
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        transports.removeAll()
        cioCapabilities.removeAll()
    }

    public func refresh() {
        transports.removeAll()
        cioCapabilities.removeAll()
        for cls in Self.watchedClasses {
            var iter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS {
                handleAdded(iter)
                IOObjectRelease(iter)
            }
        }
    }

    private func handleAdded(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }

            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            var classBuf = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(service, &classBuf)
            let className = String(cString: classBuf)
            let transportType = Self.transportType(from: className)

            if let t = makeTRMTransport(entryID: entryID, dict: dict, transportType: transportType),
               !transports.contains(where: { $0.id == t.id }) {
                transports.append(t)
            }

            if transportType == "CIO",
               let c = makeCIOCapability(entryID: entryID, dict: dict),
               !cioCapabilities.contains(where: { $0.id == c.id }) {
                cioCapabilities.append(c)
            }
        }
    }

    private func handleRemoved(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            transports.removeAll { $0.id == entryID }
            cioCapabilities.removeAll { $0.id == entryID }
            IOObjectRelease(service)
        }
    }

    private func makeTRMTransport(entryID: UInt64, dict: [String: Any], transportType: String) -> TRMTransport? {
        let hasTRM = dict.keys.contains { $0.hasPrefix("TRM_") }
        guard hasTRM else { return nil }

        let parent = Self.parentPortIdentity(from: dict)
        let portKey = "\(parent.type)/\(parent.number)"

        return TRMTransport(
            id: entryID,
            portKey: portKey,
            transportType: transportType,
            state: (dict["TRM_State"] as? NSNumber)?.intValue,
            stateDescription: dict["TRM_StateDescription"] as? String,
            transportRestricted: (dict["TRM_TransportRestricted"] as? NSNumber)?.boolValue,
            transportSupervised: (dict["TRM_TransportSupervised"] as? NSNumber)?.boolValue,
            identificationRestricted: (dict["TRM_IdentificationRestricted"] as? NSNumber)?.boolValue,
            deviceLocked: (dict["TRM_DeviceLocked"] as? NSNumber)?.boolValue,
            relaxedPeriod: (dict["TRM_RelaxedPeriod"] as? NSNumber)?.boolValue,
            gracePeriodReason: (dict["TRM_GracePeriodReason"] as? NSNumber)?.intValue,
            gracePeriodReasonDescription: dict["TRM_GracePeriodReasonDescription"] as? String,
            profile: (dict["TRM_Profile"] as? NSNumber)?.intValue,
            profileDescription: dict["TRM_ProfileDescription"] as? String,
            cacheMiss: (dict["TRM_CacheMiss"] as? NSNumber)?.boolValue
        )
    }

    private func makeCIOCapability(entryID: UInt64, dict: [String: Any]) -> CIOCableCapability? {
        let parent = Self.parentPortIdentity(from: dict)
        let portKey = "\(parent.type)/\(parent.number)"

        return CIOCableCapability(
            id: entryID,
            portKey: portKey,
            cableGeneration: (dict["CableGeneration"] as? NSNumber)?.intValue,
            cableSpeed: (dict["CableSpeed"] as? NSNumber)?.intValue,
            generation: (dict["Generation"] as? NSNumber)?.intValue,
            asymmetricModeSupported: (dict["AsymmetricModeSupported"] as? NSNumber)?.boolValue,
            legacyAdapter: (dict["LegacyAdapter"] as? NSNumber)?.boolValue,
            linkTrainingMode: (dict["LinkTrainingMode"] as? NSNumber)?.intValue
        )
    }

    /// Reads the parent port type and number from the service's properties.
    /// Same approach as `USB3TransportWatcher.parentPortIdentity(from:)`.
    nonisolated static func parentPortIdentity(from dict: [String: Any]) -> (type: Int, number: Int) {
        let type = (dict["ParentBuiltInPortType"] as? NSNumber)?.intValue
            ?? (dict["ParentPortType"] as? NSNumber)?.intValue
            ?? 0
        let number = (dict["ParentBuiltInPortNumber"] as? NSNumber)?.intValue
            ?? (dict["ParentPortNumber"] as? NSNumber)?.intValue
            ?? Int(((dict["Priority"] as? NSNumber)?.uint64Value ?? 0) & 0xFF)
        return (type, number)
    }

    /// Extracts a short transport type label from the IOKit class name.
    /// "IOPortTransportStateUSB2" -> "USB2", etc.
    nonisolated static func transportType(from className: String) -> String {
        let prefix = "IOPortTransportState"
        if className.hasPrefix(prefix) {
            return String(className.dropFirst(prefix.count))
        }
        return className
    }
}
