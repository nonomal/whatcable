import Foundation
import IOKit
import WhatCableCore

@MainActor
public final class DisplayPortTransportWatcher: ObservableObject {
    public struct DisplayPortUpdate: Codable, Sendable, Equatable {
        public let portIndex: Int
        public let portType: String
        public let status: IOPortTransportStateDisplayPort
    }

    @Published public private(set) var statuses: [DisplayPortUpdate] = []

    public let updates: AsyncStream<DisplayPortUpdate>

    private var continuation: AsyncStream<DisplayPortUpdate>.Continuation?
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    public init() {
        var continuation: AsyncStream<DisplayPortUpdate>.Continuation?
        updates = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let added: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<DisplayPortTransportWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in watcher.handleAdded(iterator) }
        }
        let removed: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<DisplayPortTransportWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in watcher.handleRemoved(iterator) }
        }

        IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching("IOPortTransportStateDisplayPort"),
            added,
            selfPtr,
            &addedIterator
        )
        handleAdded(addedIterator)

        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOPortTransportStateDisplayPort"),
            removed,
            selfPtr,
            &removedIterator
        )
        handleRemoved(removedIterator)
    }

    public func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        statuses.removeAll()
    }

    public func refresh() {
        statuses.removeAll()
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortTransportStateDisplayPort"), &iter) == KERN_SUCCESS {
            handleAdded(iter)
            IOObjectRelease(iter)
        }
    }

    private func handleAdded(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let update = makeUpdate(from: service) {
                statuses.removeAll {
                    $0.portIndex == update.portIndex && $0.portType == update.portType
                }
                statuses.append(update)
                continuation?.yield(update)
            }
            IOObjectRelease(service)
        }
    }

    private func handleRemoved(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            let portIndex = wcPortIndex(from: [:], service: service)
            let portType = wcPortType(from: [:], service: service)
            statuses.removeAll {
                $0.portIndex == portIndex && $0.portType == portType
            }
            IOObjectRelease(service)
        }
    }

    private func makeUpdate(from service: io_service_t) -> DisplayPortUpdate? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let link = DisplayPortLink(
            active: wcBool(dict["Active"]),
            laneCount: wcInt(dict["LaneCount"]),
            maxLaneCount: wcInt(dict["MaxLaneCount"]),
            linkRate: wcInt(dict["LinkRate"]),
            linkRateDescription: dict["LinkRateDescription"] as? String,
            tunneled: wcBool(dict["Tunneled"]),
            hpdState: wcInt(dict["HPD_State"]),
            hpdStateDescription: dict["HPD_StateDescription"] as? String
        )

        let metadata = dict["Metadata"] as? [String: Any]
        let monitor = MonitorInfo(
            manufacturerName: (dict["ManufacturerName"] as? String)
                ?? (metadata?["ManufacturerName"] as? String),
            productName: (dict["ProductName"] as? String)
                ?? (metadata?["ProductName"] as? String),
            productId: dict["ProductID"].map(wcInt)
                ?? metadata?["ProductID"].map(wcInt),
            serialNumber: dict["SerialNumber"].map(wcInt)
                ?? metadata?["SerialNumber"].map(wcInt),
            yearOfManufacture: dict["YearOfManufacture"].map(wcInt)
                ?? metadata?["Year of Manufacture"].map(wcInt),
            weekOfManufacture: metadata?["Week of Manufacture"].map(wcInt),
            edid: wcData(dict["EDID"]) ?? wcData(metadata?["EDID"])
        )

        let freqs: [Int]
        if let arr = dict["NominalSignalingFrequenciesHz"] as? [Any] {
            freqs = arr.map { wcInt($0) }
        } else {
            freqs = []
        }

        let status = IOPortTransportStateDisplayPort(
            link: link,
            monitor: monitor,
            dfpType: (dict["DFP Type Description"] as? String)
                ?? (metadata?["DFP Type Description"] as? String)
                ?? dict["DFP Type"].map { String(wcInt($0)) },
            branchDeviceId: (dict["BranchDeviceID"] as? String)
                ?? (metadata?["BranchDeviceID"] as? String),
            branchDeviceOUI: wcData(dict["BranchDeviceOUI"])
                ?? wcData(metadata?["BranchDeviceOUI"]),
            sinkCount: wcInt(dict["SinkCount"]),
            role: wcInt(dict["Role"]),
            roleDescription: dict["RoleDescription"] as? String,
            driverStatus: wcInt(dict["DriverStatus"]),
            driverStatusDescription: dict["DriverStatusDescription"] as? String,
            transportType: wcInt(dict["TransportType"]),
            transportTypeDescription: dict["TransportTypeDescription"] as? String,
            transportDescription: dict["TransportDescription"] as? String,
            authorizationRequired: wcBool(dict["AuthorizationRequired"]),
            authorizationStatus: wcInt(dict["AuthorizationStatus"]),
            authorizationStatusDescription: dict["AuthorizationStatusDescription"] as? String,
            authenticationRequired: wcBool(dict["AuthenticationRequired"]),
            authenticationStatus: wcInt(dict["AuthenticationStatus"]),
            authenticationStatusDescription: dict["AuthenticationStatusDescription"] as? String,
            hashStatus: wcInt(dict["HashStatus"]),
            hashStatusDescription: dict["HashStatusDescription"] as? String,
            trmTransportSupervised: wcBool(dict["TRM_TransportSupervised"]),
            parentPortType: wcInt(dict["ParentPortType"]),
            parentPortTypeDescription: dict["ParentPortTypeDescription"] as? String,
            parentPortNumber: wcInt(dict["ParentPortNumber"]),
            parentPortBuiltIn: wcBool(dict["ParentPortBuiltIn"]),
            parentBuiltInPortType: wcInt(dict["ParentBuiltInPortType"]),
            parentBuiltInPortTypeDescription: dict["ParentBuiltInPortTypeDescription"] as? String,
            parentBuiltInPortNumber: wcInt(dict["ParentBuiltInPortNumber"]),
            edidChanged: wcBool(dict["EDIDChanged"]),
            nominalSignalingFrequenciesHz: freqs,
            index: wcInt(dict["Index"])
        )
        return DisplayPortUpdate(
            portIndex: wcPortIndex(from: dict, service: service),
            portType: wcPortType(from: dict, service: service),
            status: status
        )
    }
}
