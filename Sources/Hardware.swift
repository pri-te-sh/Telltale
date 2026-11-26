import Foundation
import Darwin
import IOKit

// MARK: - Data types

struct GPUInfo {
    var utilization: Double      // %
    var renderer: Double         // %
    var tiler: Double            // %
    var memoryInUse: UInt64      // bytes of system memory the GPU is using
}

struct PowerInfo {
    var systemW: Double?         // whole-Mac power draw (power telemetry "SystemLoad")
    var adapterInW: Double?      // power arriving from the charger ("SystemPowerIn")
    var batteryW: Double?        // + charging / − discharging (voltage × amperage)
    var voltage: Double?         // battery volts
    var amperage: Double?        // battery amps (signed)
}

// MARK: - Readers (IOKit / Mach; no root, no subprocesses)

enum Hardware {
    private static let host = mach_host_self()

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    /// Efficiency cores come first in the per-core list on Apple Silicon.
    static let efficiencyCores: Int = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    static let performanceCores: Int = sysctlInt("hw.perflevel0.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount

    /// Per-core tick counters: busy (user + system + nice) and idle.
    static func coreTicks() -> [(busy: UInt64, idle: UInt64)] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var out: [(UInt64, UInt64)] = []
        out.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            func t(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            out.append((t(CPU_STATE_USER) &+ t(CPU_STATE_SYSTEM) &+ t(CPU_STATE_NICE), t(CPU_STATE_IDLE)))
        }
        return out
    }

    static func gpu() -> GPUInfo? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: GPUInfo?
        while true {
            let s = IOIteratorNext(iter)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            guard let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            func num(_ k: String) -> Double { (stats[k] as? NSNumber)?.doubleValue ?? 0 }
            let g = GPUInfo(utilization: num("Device Utilization %"), renderer: num("Renderer Utilization %"),
                            tiler: num("Tiler Utilization %"), memoryInUse: UInt64(max(0, num("In use system memory"))))
            if best == nil || g.utilization > best!.utilization { best = g }
        }
        return best
    }

    /// Total bytes read/written by all block storage drivers since boot.
    static func diskBytes() -> (read: UInt64, write: UInt64) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0, w: UInt64 = 0
        while true {
            let s = IOIteratorNext(iter)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            guard let st = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            r &+= (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w &+= (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (r, w)
    }

    private static let batteryService: io_service_t =
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))

    /// Reads only the few properties needed (not the whole battery dictionary).
    static func power() -> PowerInfo? {
        let s = batteryService
        guard s != 0 else { return nil }
        func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        var p = PowerInfo()
        if let t = prop("PowerTelemetryData") as? [String: Any] {
            if let v = (t["SystemLoad"] as? NSNumber)?.doubleValue, v > 0 { p.systemW = v / 1000 }
            if let v = (t["SystemPowerIn"] as? NSNumber)?.doubleValue, v > 0 { p.adapterInW = v / 1000 }
        }
        let mv = (prop("Voltage") as? NSNumber)?.doubleValue
        let ma = (prop("Amperage") as? NSNumber)?.int64Value   // signed; stored as two's complement
        if let mv { p.voltage = mv / 1000 }
        if let ma { p.amperage = Double(ma) / 1000 }
        if let mv, let ma { p.batteryW = mv * Double(ma) / 1_000_000 }
        if p.systemW == nil, let bw = p.batteryW, bw < 0 { p.systemW = -bw }
        return p
    }
}

// MARK: - GPU power via IOReport (Apple Silicon energy counters, no root needed)

@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFMutableDictionary>?
@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(_ a: UnsafeRawPointer?, _ channels: CFMutableDictionary,
                                        _ subscribed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                        _ id: UInt64, _ b: CFTypeRef?) -> Unmanaged<AnyObject>?
@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(_ sub: AnyObject, _ channels: CFMutableDictionary, _ a: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary, _ c: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ ch: CFDictionary, _ err: UnsafeMutablePointer<Int32>?) -> Int64

/// Created only while the panel is open; released when it closes.
final class GPUPowerMeter {
    private var subscription: AnyObject?
    private var channels: CFMutableDictionary?
    private var last: (sample: CFDictionary, time: TimeInterval)?

    init() {
        guard let ch = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let s = IOReportCreateSubscription(nil, ch, &subbed, 0, nil)?.takeRetainedValue(),
              let sc = subbed?.takeRetainedValue() else { return }
        subscription = s
        channels = sc
    }

    /// Average GPU power since the previous call, in watts.
    func read() -> Double? {
        guard let s = subscription, let ch = channels,
              let now = IOReportCreateSamples(s, ch, nil)?.takeRetainedValue() else { return nil }
        let t = ProcessInfo.processInfo.systemUptime
        defer { last = (now, t) }
        guard let prev = last, t > prev.time,
              let delta = IOReportCreateSamplesDelta(prev.sample, now, nil)?.takeRetainedValue() as NSDictionary?,
              let items = delta["IOReportChannels"] as? [NSDictionary] else { return nil }
        var joules = 0.0
        var found = false
        for item in items {
            let c = item as CFDictionary
            guard let name = IOReportChannelGetChannelName(c)?.takeUnretainedValue() as String?, name == "GPU Energy" else { continue }
            let unit = (IOReportChannelGetUnitLabel(c)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces)
            let v = Double(IOReportSimpleGetIntegerValue(c, nil))
            switch unit {
            case "nJ": joules += v / 1e9
            case "uJ", "µJ": joules += v / 1e6
            case "mJ": joules += v / 1e3
            default: joules += v
            }
            found = true
        }
        return found ? joules / (t - prev.time) : nil
    }
}
