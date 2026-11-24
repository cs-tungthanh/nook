import Foundation
import Combine
import IOKit
import IOKit.ps

/// One reading of the Mac's vital signs. `nil` means unknown or not present
/// (no battery on a desktop, no GPU statistics, or the first sample).
struct SystemStats {
    var cpu: Double?
    var gpu: Double?
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var battery: BatteryStatus?
    var download: Double?
    var upload: Double?
    var diskAvailable: Int64?
    var diskTotal: Int64?
    /// What the whole Mac draws right now, in watts
    var systemPower: Double?
    /// The connected power adapter's rating, in watts
    var adapterWatts: Int?

    var memory: Double? {
        memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : nil
    }

    struct BatteryStatus {
        var level: Double
        var isCharging: Bool
        var isOnAC: Bool
    }
}

/// Samples CPU, GPU, memory, battery, network, disk and power while the
/// System page is open. It reads counters, so rates (CPU, network) appear
/// from the second sample on.
final class SystemMonitor: ObservableObject {
    @Published private(set) var stats = SystemStats()

    var isIslandShown = false { didSet { updateTimer() } }
    /// The System page is the one showing
    var isPageShown = false { didSet { updateTimer() } }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "nook.system-monitor", qos: .utility)
    // Only touched on `queue`
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastNetwork: (received: UInt64, sent: UInt64, at: Date)?

    private func updateTimer() {
        let shouldRun = isIslandShown && isPageShown
        guard shouldRun != (timer != nil) else { return }
        if shouldRun {
            sample()
            let timer = Timer(timeInterval: Constants.System.sampleInterval, repeats: true) { [weak self] _ in
                self?.sample()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            // Rates are measured between samples; the next open must not
            // average over the whole time the page was closed
            queue.async { [weak self] in
                self?.lastCPUTicks = nil
                self?.lastNetwork = nil
            }
        }
    }

    private func sample() {
        queue.async { [weak self] in
            guard let self = self else { return }
            var stats = SystemStats()
            stats.cpu = self.readCPU()
            stats.gpu = Self.readGPU()
            stats.memoryUsed = Self.readMemoryUsed()
            stats.battery = Self.readBattery()
            (stats.download, stats.upload) = self.readNetwork()
            (stats.diskAvailable, stats.diskTotal) = Self.readDisk()
            (stats.systemPower, stats.adapterWatts) = Self.readPower(isOnAC: stats.battery?.isOnAC ?? true)
            DispatchQueue.main.async {
                self.stats = stats
            }
        }
    }

    // MARK: Readers

    /// Busy share of all cores since the last sample
    private func readCPU() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        let ticks = (busy: user + system + nice, total: user + system + nice + idle)
        defer { lastCPUTicks = ticks }
        guard let last = lastCPUTicks, ticks.total > last.total else { return nil }
        return Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
    }

    /// The GPU driver's own utilization figure, as Activity Monitor shows it
    private static func readGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var utilization: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            utilization = max(utilization ?? 0, percent / 100)
        }
        return utilization
    }

    /// App memory, wired and compressed, like "Memory Used" in Activity Monitor
    private static func readMemoryUsed() -> UInt64 {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let appPages = UInt64(info.internal_page_count) - min(UInt64(info.internal_page_count), UInt64(info.purgeable_count))
        let pages = appPages + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    private static func readBattery() -> SystemStats.BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return SystemStats.BatteryStatus(
                level: Double(current) / Double(maximum),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return nil
    }

    /// Bytes per second in and out across all interfaces except loopback
    private func readNetwork() -> (Double?, Double?) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (nil, nil) }
        defer { freeifaddrs(addresses) }
        var received: UInt64 = 0, sent: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date()
        defer { lastNetwork = (received, sent, now) }
        guard let last = lastNetwork else { return (nil, nil) }
        let seconds = now.timeIntervalSince(last.at)
        // Counters are 32-bit per interface and wrap; skip the odd sample where they did
        guard seconds > 0, received >= last.received, sent >= last.sent else { return (nil, nil) }
        return (Double(received - last.received) / seconds, Double(sent - last.sent) / seconds)
    }

    private static func readDisk() -> (Int64?, Int64?) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
        ])
        return (values?.volumeAvailableCapacityForImportantUsage, values?.volumeTotalCapacity.map(Int64.init))
    }

    /// The Mac's power draw and the adapter's rating, from the battery controller.
    /// Macs without a battery don't report either.
    private static func readPower(isOnAC: Bool) -> (Double?, Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let battery = properties?.takeRetainedValue() as? [String: Any] else { return (nil, nil) }

        let adapter = battery["AdapterDetails"] as? [String: Any]
        let adapterWatts = isOnAC ? (adapter?["Watts"] as? NSNumber)?.intValue : nil

        // On power, the telemetry has what the whole system draws (in mW)
        if isOnAC,
           let telemetry = battery["PowerTelemetryData"] as? [String: Any],
           let milliwatts = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue, milliwatts > 0 {
            return (milliwatts / 1000, adapterWatts)
        }
        // On battery, it's what the battery gives out: volts × amps.
        // Amperage is signed but may come back as its unsigned bit pattern.
        guard let millivolts = (battery["Voltage"] as? NSNumber)?.doubleValue,
              let rawAmperage = (battery["InstantAmperage"] as? NSNumber ?? battery["Amperage"] as? NSNumber)?.uint64Value else {
            return (nil, adapterWatts)
        }
        let milliamps = Double(Int64(bitPattern: rawAmperage))
        return (abs(millivolts * milliamps) / 1_000_000, adapterWatts)
    }
}
