import AppKit
import Combine
import IOBluetooth
import CoreBluetooth
import IOKit

struct BluetoothDeviceInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let isConnected: Bool
    let battery: String?
}

/// Lists paired Bluetooth devices and connects or disconnects them.
/// Uses IOBluetooth for the devices and CoreBluetooth only for the power and
/// permission state. Battery levels rely on undocumented IOBluetoothDevice
/// selectors, so they're checked before use.
final class BluetoothManager: NSObject, ObservableObject {
    enum Availability: Equatable {
        case loading
        case ready
        case poweredOff
        /// macOS hasn't asked yet; `requestAccess()` shows the prompt
        case notAsked
        case unauthorized
    }

    @Published private(set) var availability: Availability = .loading
    @Published private(set) var devices: [BluetoothDeviceInfo] = []
    @Published private(set) var busyDevices: Set<String> = []
    @Published private(set) var errorMessage: String?

    /// Created only once Bluetooth access is allowed or the user asks for it,
    /// since creating it is what shows the permission prompt
    private var central: CBCentralManager?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var isRefreshScheduled = false
    private var refreshGeneration = 0 {
        didSet { latestGeneration.set(refreshGeneration) }
    }
    /// `refreshGeneration` readable off the main thread, so a queued refresh
    /// that a newer one superseded can skip the slow report entirely.
    private let latestGeneration = LockedValue(0)
    private let reportQueue = DispatchQueue(label: "com.nook.bluetooth.report", qos: .userInitiated)

    /// Refreshes on the next main-loop turn, collapsing bursts into one. Callbacks
    /// must use this rather than `refresh()`: registering for connect
    /// notifications calls back synchronously once per connected device, and
    /// refreshing inside that call re-enters `refresh()` and deadlocks the
    /// ObservableObject publisher.
    private func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isRefreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        guard let central = central else {
            guard CBManager.authorization != .notDetermined else {
                setUnavailable(.notAsked)
                return
            }
            // The delegate's state callback triggers the first real refresh
            self.central = CBCentralManager(delegate: self, queue: .main)
            return
        }

        switch central.state {
        case .unauthorized:
            setUnavailable(.unauthorized)
        case .poweredOff:
            setUnavailable(.poweredOff)
        case .poweredOn:
            // Publishing re-renders the whole island, so skip it when nothing changed
            if availability != .ready { availability = .ready }
            watchConnections()
            refreshGeneration += 1
            let generation = refreshGeneration
            // Each IOBluetooth property read is a round trip to bluetoothd; doing
            // them on the main thread held up the island every time it opened
            reportQueue.async { [weak self, latestGeneration] in
                // Opening and closing the island quickly queues several refreshes;
                // only the newest one is worth a system_profiler run
                guard generation == latestGeneration.get() else { return }
                let paired = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).map(Self.info)
                let report = SystemBluetoothReport.load()
                let devices = Self.merge(paired, with: report).sorted {
                    if $0.isConnected != $1.isConnected { return $0.isConnected }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                DispatchQueue.main.async {
                    // A newer refresh (or Bluetooth turning off) supersedes this one
                    guard let self = self, generation == self.refreshGeneration else { return }
                    if self.devices != devices { self.devices = devices }
                }
            }
        default:
            // .unknown / .resetting / .unsupported: keep what we have until it settles
            break
        }
    }

    // MARK: Actions

    /// Shows the Bluetooth permission prompt; the island must be closed first
    /// or it covers the prompt
    func requestAccess() {
        guard central == nil else { return }
        availability = .loading
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func toggleConnection(_ info: BluetoothDeviceInfo) {
        guard !busyDevices.contains(info.id), let device = IOBluetoothDevice(addressString: info.id) else { return }
        errorMessage = nil
        busyDevices.insert(info.id)

        if device.isConnected() {
            let status = device.closeConnection()
            if status != kIOReturnSuccess {
                errorMessage = "Couldn't disconnect \(info.name)"
            }
            // The disconnect notification usually refreshes first; this catches the rest
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Bluetooth.refreshDelay) { [weak self] in
                self?.busyDevices.remove(info.id)
                self?.refresh()
            }
        } else {
            // With a target the call returns at once and reports to connectionComplete(_:status:)
            let status = device.openConnection(self)
            if status != kIOReturnSuccess {
                busyDevices.remove(info.id)
                errorMessage = "Couldn't connect to \(info.name)"
            }
        }
    }

    /// Bluetooth settings, for turning it on or pairing; permission lives on the Permissions page
    func openSettings() {
        if let url = URL(string: Constants.Bluetooth.settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Connection Callbacks

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        let address = device.addressString ?? ""
        busyDevices.remove(address)
        if status != kIOReturnSuccess {
            errorMessage = "Couldn't connect to \(device.name ?? "device") — is it on and nearby?"
        }
        scheduleRefresh()
    }

    private func watchConnections() {
        guard connectNotification == nil else { return }
        // Fires right away for devices that are already connected, too
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString, disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDisconnected(_:device:))
            )
        }
        scheduleRefresh()
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        if let address = device.addressString {
            disconnectNotifications[address] = nil
        }
        scheduleRefresh()
    }

    private func setUnavailable(_ state: Availability) {
        refreshGeneration += 1
        if availability != state { availability = state }
        if !devices.isEmpty { devices = [] }
    }

    // MARK: Device Details

    /// Keeps only devices macOS itself lists (IOBluetooth also returns stale
    /// pairing records, which showed up as duplicates) and prefers the system's
    /// name and battery levels, which include the AirPods case.
    private static func merge(_ paired: [BluetoothDeviceInfo], with report: [String: SystemBluetoothReport.Entry]) -> [BluetoothDeviceInfo] {
        var seen: Set<String> = []
        return paired.compactMap { device in
            let address = SystemBluetoothReport.normalize(device.id)
            guard seen.insert(address).inserted else { return nil }
            // An empty report means system_profiler failed; show everything rather than nothing
            guard !report.isEmpty else { return device }
            guard let entry = report[address] else { return nil }
            return BluetoothDeviceInfo(
                id: device.id,
                name: entry.name,
                icon: device.icon,
                isConnected: device.isConnected,
                battery: device.isConnected ? (entry.batteryText ?? device.battery) : nil
            )
        }
    }

    private static func info(for device: IOBluetoothDevice) -> BluetoothDeviceInfo {
        let isConnected = device.isConnected()
        return BluetoothDeviceInfo(
            id: device.addressString ?? UUID().uuidString,
            name: device.name ?? device.addressString ?? "Unknown device",
            icon: icon(for: device),
            isConnected: isConnected,
            battery: isConnected ? batteryText(for: device) : nil
        )
    }

    /// Reads an undocumented numeric property, or nil if this macOS lacks it.
    private static func number(_ key: String, of device: IOBluetoothDevice) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)) else { return nil }
        return (device.value(forKey: key) as? NSNumber)?.intValue
    }

    private static func batteryText(for device: IOBluetoothDevice) -> String? {
        // 0 means "not reported", so only 1–100 counts as a reading
        func percent(_ key: String) -> Int? {
            guard let value = number(key, of: device), (1...100).contains(value) else { return nil }
            return value
        }

        let parts = [("L", "batteryPercentLeft"), ("R", "batteryPercentRight"), ("Case", "batteryPercentCase")]
            .compactMap { label, key in percent(key).map { "\(label) \($0)%" } }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        return (percent("batteryPercentSingle") ?? percent("batteryPercentCombined")).map { "\($0)%" }
    }

    private static func icon(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods") { return "airpods" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("watch") { return "applewatch" }
        if number("isLowEnergyKeyboard", of: device) == 1 || name.contains("keyboard") { return "keyboard" }
        if number("isLowEnergyPointer", of: device) == 1 || name.contains("mouse") { return "computermouse" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }

        // Bluetooth Class of Device major/minor values
        switch device.deviceClassMajor {
        case 0x01: return "laptopcomputer"
        case 0x02: return "iphone"
        case 0x04:
            return device.deviceClassMinor == 0x05 ? "hifispeaker" : "headphones"
        case 0x05:
            if device.deviceClassMinor & 0x10 != 0 { return "keyboard" }
            if device.deviceClassMinor & 0x20 != 0 { return "computermouse" }
            return "gamecontroller"
        default:
            return "dot.radiowaves.left.and.right"
        }
    }
}

/// The Bluetooth section of `system_profiler`: the same device list and battery
/// levels System Settings shows. Takes well under a second, so it runs on each refresh.
private enum SystemBluetoothReport {
    struct Entry {
        let name: String
        let batteryText: String?
    }

    /// Devices keyed by normalized address, or empty if the report couldn't be read.
    static func load() -> [String: Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("Nook: couldn't run system_profiler: \(error.localizedDescription)")
            return [:]
        }
        // A hung system_profiler must not hold up every later refresh
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
        // Read before waiting so a full pipe can't block the process
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }

        var entries: [String: Entry] = [:]
        for section in sections {
            for group in ["device_connected", "device_not_connected"] {
                for item in section[group] as? [[String: Any]] ?? [] {
                    for (name, value) in item {
                        guard let info = value as? [String: Any],
                              let address = info["device_address"] as? String else { continue }
                        entries[normalize(address)] = Entry(name: name, batteryText: batteryText(info))
                    }
                }
            }
        }
        return entries
    }

    /// IOBluetooth uses "b4-59-76-…", system_profiler "B4:59:76:…".
    static func normalize(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    private static func batteryText(_ info: [String: Any]) -> String? {
        func percent(_ key: String) -> Int? {
            (info[key] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        }
        let parts = [("L", "device_batteryLevelLeft"), ("R", "device_batteryLevelRight"), ("Case", "device_batteryLevelCase")]
            .compactMap { label, key in percent(key).map { "\(label) \($0)%" } }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        return percent("device_batteryLevelMain").map { "\($0)%" }
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Called from inside CoreBluetooth's own state update, so refresh after it returns
        scheduleRefresh()
    }
}
