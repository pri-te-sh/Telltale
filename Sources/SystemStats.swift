import Foundation
import Darwin
import IOKit
import IOKit.ps
import CoreWLAN

// MARK: - Plain data types

struct CPUTicks { var user, system, idle, nice: UInt64 }

struct MemoryInfo {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Int = 0          // 0-100, higher = more pressure
    var used: UInt64 { app + wired + compressed }
    var available: UInt64 { total > used ? total - used : 0 }
    var usedPercent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
}

struct DiskInfo {
    var name: String
    var total: UInt64
    var available: UInt64          // includes purgeable space (what Finder shows)
    var freeNow: UInt64            // immediately free, excluding purgeable
    var usedFraction: Double { total == 0 ? 0 : 1 - Double(available) / Double(total) }
}

struct BatteryInfo {
    var percent: Int
    var isCharging: Bool
    var isCharged: Bool
    var onAC: Bool
    var minutesRemaining: Int?     // to empty (on battery) or to full (charging)
    var cycles: Int?
    var designCycles: Int
    var health: Double?            // 0-1, current max capacity vs design
    var adapterWatts: Int?
    var condition: String?
}

struct Temperatures {
    var cpu: Double?        // hottest CPU die sensor
    var cpuAvg: Double?
    var soc: Double?        // other SoC sensors (average)
    var battery: Double?
    var ssd: Double?
    var all: [(name: String, value: Double)] = []   // only filled on full reads
}

struct WiFiInfo {
    var ssid: String?
    var rssi: Int
    var txRate: Double
    var security: String
    var interface: String
}

struct ExternalDrive: Identifiable {
    var id: String { url.path }
    var url: URL
    var name: String
    var total: UInt64
    var available: UInt64
}

// MARK: - Readers (all cheap syscalls, no subprocesses)

enum SysInfo {
    private static let host = mach_host_self()   // cached: each call to mach_host_self() takes a port right
    static let pageSize = UInt64(vm_kernel_page_size)
    static let totalMemory = ProcessInfo.processInfo.physicalMemory
    static let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    static func memory() -> MemoryInfo {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var m = MemoryInfo()
        m.total = totalMemory
        if kr == KERN_SUCCESS {
            let anon = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            m.app = (anon > purgeable ? anon - purgeable : 0) * pageSize
            m.wired = UInt64(stats.wire_count) * pageSize
            m.compressed = UInt64(stats.compressor_page_count) * pageSize
            m.cached = (UInt64(stats.external_page_count) + purgeable) * pageSize
        }
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 { m.swapUsed = xsw.xsu_used }
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 {
            m.pressure = max(0, min(100, 100 - Int(level)))
        }
        return m
    }

    static func disk() -> DiskInfo? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                                        .volumeAvailableCapacityKey,
                                                        .volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        let total = UInt64(v.volumeTotalCapacity ?? 0)
        let now = UInt64(v.volumeAvailableCapacity ?? 0)
        let important = UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? Int64(now)))
        return DiskInfo(name: v.volumeName ?? "Macintosh HD", total: total, available: max(important, now), freeNow: now)
    }

    static func externalDrives() -> [ExternalDrive] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            let external = (v.volumeIsInternal == false) || (v.volumeIsEjectable == true) || (v.volumeIsRemovable == true)
            guard external, u.path != "/" else { return nil }
            return ExternalDrive(url: u, name: v.volumeName ?? u.lastPathComponent,
                                 total: UInt64(v.volumeTotalCapacity ?? 0), available: UInt64(v.volumeAvailableCapacity ?? 0))
        }
    }

    static func uptime() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - (Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : [0, 0, 0]
    }

    /// Total bytes received/sent on physical interfaces (en*) since boot, using 64-bit counters.
    /// (NET_RT_IFLIST2 truncates these to 32 bits for normal apps, so read the ifmib counters instead, like netstat.)
    private static var enIndexes: [UInt32] = []
    private static var enIndexesRefreshed: TimeInterval = 0

    static func networkBytes() -> (rx: UInt64, tx: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        if enIndexes.isEmpty || now - enIndexesRefreshed > 30 {   // interfaces rarely change; re-list every 30 s
            enIndexesRefreshed = now
            enIndexes = []
            if let list = if_nameindex() {
                var p = list
                while p.pointee.if_index != 0 {
                    if let n = p.pointee.if_name, String(cString: n).hasPrefix("en") { enIndexes.append(p.pointee.if_index) }
                    p += 1
                }
                if_freenameindex(list)
            }
        }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for idx in enIndexes {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(idx), IFDATA_GENERAL]
            var d = ifmibdata()
            var len = MemoryLayout<ifmibdata>.size
            if sysctl(&mib, 6, &d, &len, nil, 0) == 0 {
                rx &+= d.ifmd_data.ifi_ibytes
                tx &+= d.ifmd_data.ifi_obytes
            }
        }
        return (rx, tx)
    }

    static func ipv4(for iface: String) -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let i = p {
            let e = i.pointee
            if let addr = e.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: e.ifa_name) == iface {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            p = e.ifa_next
        }
        return nil
    }

    static func wifi() -> WiFiInfo? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return nil }
        let sec: String
        switch i.security() {
        case .none: sec = "Open"
        case .WEP, .dynamicWEP: sec = "WEP"
        case .wpaPersonal, .wpaPersonalMixed: sec = "WPA Personal"
        case .wpa2Personal: sec = "WPA2 Personal"
        case .personal: sec = "WPA/WPA2 Personal"
        case .wpa3Personal: sec = "WPA3 Personal"
        case .wpa3Transition: sec = "WPA2/WPA3 Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise: sec = "Enterprise"
        case .wpa3Enterprise: sec = "WPA3 Enterprise"
        default: sec = "—"
        }
        return WiFiInfo(ssid: i.ssid(), rssi: i.rssiValue(), txRate: i.transmitRate(), security: sec,
                        interface: i.interfaceName ?? "en0")
    }

    static func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var info: BatteryInfo?
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = max(1, d[kIOPSMaxCapacityKey] as? Int ?? 100)
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charged = d[kIOPSIsChargedKey] as? Bool ?? false
            var mins: Int?
            if charging, let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0 { mins = t }
            if !onAC, let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0 { mins = t }
            info = BatteryInfo(percent: Int(Double(cur) / Double(mx) * 100 + 0.5), isCharging: charging, isCharged: charged,
                               onAC: onAC, minutesRemaining: mins, cycles: nil, designCycles: 1000, health: nil,
                               adapterWatts: nil, condition: d[kIOPSBatteryHealthKey] as? String)
        }
        guard var b = info else { return nil }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let p = props?.takeRetainedValue() as? [String: Any] {
                let bd = p["BatteryData"] as? [String: Any] ?? [:]
                b.cycles = p["CycleCount"] as? Int ?? bd["CycleCount"] as? Int
                if let dc = p["DesignCycleCount9C"] as? Int, dc > 0 { b.designCycles = dc }
                let rawMax = p["AppleRawMaxCapacity"] as? Int ?? bd["AppleRawMaxCapacity"] as? Int
                let design = p["DesignCapacity"] as? Int ?? bd["DesignCapacity"] as? Int
                if let r = rawMax, let d = design, d > 0 { b.health = min(1, Double(r) / Double(d)) }
                b.adapterWatts = (p["AdapterDetails"] as? [String: Any])?["Watts"] as? Int
                if !b.onAC { b.adapterWatts = nil }
            }
            IOObjectRelease(svc)
        }
        return b
    }

    /// Battery % of Bluetooth HID accessories (Magic Mouse/Keyboard/Trackpad), keyed by "aa-bb-cc-dd-ee-ff".
    static func hidBatteries() -> [String: Int] {
        var out: [String: Int] = [:]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iter) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iter) }
        while true {
            let s = IOIteratorNext(iter)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            guard let pct = IORegistryEntryCreateCFProperty(s, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
                  let addr = IORegistryEntryCreateCFProperty(s, "DeviceAddress" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            else { continue }
            out[addr.lowercased().replacingOccurrences(of: ":", with: "-")] = pct
        }
        return out
    }

    /// Telltale's own memory footprint (what Activity Monitor shows as "Memory").
    static func selfFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

// MARK: - Temperature sensors (Apple Silicon HID sensors)

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

final class Sensors {
    private let kTemperatureEvent: Int64 = 15
    private var services: [(name: String, service: AnyObject)] = []
    private var cpuServices: [AnyObject] = []   // one CPU-die sensor per name: the cheap background subset
    private var summaryServices: [(name: String, service: AnyObject)] = []   // one per name: CPU dies, SSD, battery
    private var client: AnyObject?   // must outlive the service references, or reads crash

    init() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let arr = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return }
        for s in arr {
            guard let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  !name.contains("tcal") else { continue }   // tcal is a calibration value, not a temperature
            services.append((name, s))
        }
        services.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var seen = Set<String>()
        cpuServices = services.filter { $0.name.hasPrefix("PMU tdie") && seen.insert($0.name).inserted }.map(\.service)
        var seen2 = Set<String>()
        summaryServices = services.filter {
            ($0.name.hasPrefix("PMU tdie") || $0.name.hasPrefix("NAND") || $0.name.contains("gas gauge")) && seen2.insert($0.name).inserted
        }
    }

    /// CPU, SSD and battery temperatures from one sensor of each — what every page except Thermals shows.
    func readSummary() -> Temperatures {
        var cpu: [Double] = [], ssd: [Double] = [], bat: [Double] = []
        for (name, s) in summaryServices {
            guard let e = IOHIDServiceClientCopyEvent(s, kTemperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let v = IOHIDEventGetFloatValue(e, Int32(kTemperatureEvent << 16))
            guard v > 0, v < 130 else { continue }
            if name.hasPrefix("PMU tdie") { cpu.append(v) } else if name.hasPrefix("NAND") { ssd.append(v) } else { bat.append(v) }
        }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        return Temperatures(cpu: cpu.max(), cpuAvg: avg(cpu), soc: nil, battery: avg(bat), ssd: avg(ssd))
    }

    /// Hottest CPU die temperature from one sensor per core. Each read is an IPC round-trip, so this is
    /// what runs while the panel is closed; the full read (both PMUs, all sensors) is for the open panel.
    func hottestCPU() -> Double? {
        var hottest: Double?
        for s in cpuServices {
            guard let e = IOHIDServiceClientCopyEvent(s, kTemperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let v = IOHIDEventGetFloatValue(e, Int32(kTemperatureEvent << 16))
            if v > 0, v < 130 { hottest = max(hottest ?? v, v) }
        }
        return hottest
    }

    /// `full: false` reads only the CPU die sensors (used for the menu bar and heat alerts while the panel is closed).
    func read(full: Bool = true) -> Temperatures {
        var byName: [String: Double] = [:]
        for (name, s) in services {
            if !full && !name.hasPrefix("PMU tdie") { continue }
            guard let e = IOHIDServiceClientCopyEvent(s, kTemperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let v = IOHIDEventGetFloatValue(e, Int32(kTemperatureEvent << 16))
            guard v > 0, v < 130 else { continue }
            byName[name] = max(byName[name] ?? -1, v)   // each sensor is exposed twice; keep one value
        }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        let cpu = byName.filter { $0.key.hasPrefix("PMU tdie") }.map(\.value)
        let soc = byName.filter { $0.key.hasPrefix("PMU tdev") || $0.key.hasPrefix("PMU TP") }.map(\.value)
        let bat = byName.filter { $0.key.contains("gas gauge") }.map(\.value)
        let ssd = byName.filter { $0.key.hasPrefix("NAND") }.map(\.value)
        var t = Temperatures(cpu: cpu.max(), cpuAvg: avg(cpu), soc: avg(soc), battery: avg(bat), ssd: avg(ssd))
        if full {
            t.all = byName.map { (Self.friendly($0.key), $0.value) }
                .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        }
        return t
    }

    static func friendly(_ raw: String) -> String {
        if raw.hasPrefix("PMU tdie") { return "CPU die " + raw.dropFirst("PMU tdie".count) }
        if raw.hasPrefix("PMU tdev") { return "SoC sensor " + raw.dropFirst("PMU tdev".count) }
        if raw.hasPrefix("PMU TP") { return "SoC " + raw.dropFirst("PMU ".count) }
        if raw.hasPrefix("NAND") { return "SSD" }
        if raw.contains("gas gauge") { return "Battery" }
        return raw
    }
}
