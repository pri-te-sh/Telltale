import Foundation
import AppKit
import CoreLocation
import UserNotifications

struct BTDevice: Identifiable {
    var id: String { name }
    var name: String
    var kind: String
    var batteries: [(label: String, percent: Int)]
}

enum SpeedTestState {
    case idle
    case running
    case done(down: Double, up: Double, responsiveness: Int?)
    case failed(String)
    var isRunning: Bool { if case .running = self { return true }; return false }
}

/// Holds all live readings. Sampling is shared and adaptive:
/// - panel closed: one timer at the user's interval (default 3 s). Always CPU, memory and network counters;
///   anything else only if a menu bar readout or an alert needs it.
/// - panel open: everything every 1 s, processes every 2 s, sensors/battery/disk/Wi-Fi every 5 s.
final class Monitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Monitor()

    // Always sampled
    @Published var cpuUser = 0.0
    @Published var cpuSystem = 0.0
    @Published var cpuHistory: [Double] = []
    @Published var mem = MemoryInfo()
    @Published var memHistory: [Double] = []
    @Published var netDown = 0.0
    @Published var netUp = 0.0
    @Published var netTotalDown: UInt64 = 0
    @Published var netTotalUp: UInt64 = 0
    @Published var downHistory: [Double] = []
    @Published var upHistory: [Double] = []

    // Sampled when shown or when the panel is open
    @Published var cores: [Double] = []
    @Published var gpu: GPUInfo?
    @Published var gpuHistory: [Double] = []
    @Published var gpuPowerW: Double?
    @Published var diskRead = 0.0
    @Published var diskWrite = 0.0
    @Published var diskReadHistory: [Double] = []
    @Published var diskWriteHistory: [Double] = []
    @Published var power: PowerInfo?
    @Published var powerHistory: [Double] = []
    @Published var appsPowerW: Double?

    @Published var disk: DiskInfo?
    @Published var drives: [ExternalDrive] = []
    @Published var battery: BatteryInfo?
    @Published var temps = Temperatures()
    @Published var tempHistory: [Double] = []
    @Published var fans: [FanInfo] = []
    @Published var wifi: WiFiInfo?
    @Published var ipAddress: String?
    @Published var uptime: TimeInterval = 0
    @Published var load: [Double] = [0, 0, 0]
    @Published var thermal: ProcessInfo.ThermalState = .nominal
    @Published var topMemory: [AppUsage] = []
    @Published var topCPU: [AppUsage] = []
    @Published var topPower: [AppUsage] = []
    @Published var topDisk: [AppUsage] = []
    @Published var quittable: Set<String> = []
    @Published var bluetooth: [BTDevice] = []
    @Published var bluetoothLoaded = false
    @Published var speedTest = SpeedTestState.idle
    @Published var locationAuthorized = false
    @Published var selfFootprint: UInt64 = 0

    var cpuTotal: Double { cpuUser + cpuSystem }
    var pCoreAverage: Double? { average(cores.dropFirst(Hardware.efficiencyCores)) }
    var eCoreAverage: Double? { Hardware.efficiencyCores > 0 ? average(cores.prefix(Hardware.efficiencyCores)) : nil }
    var onMenuBarImage: ((NSImage?) -> Void)?

    private var bgTimer: Timer?
    private var fgTimer: Timer?
    private var lastTicks: CPUTicks?
    private var lastCoreTicks: [(busy: UInt64, idle: UInt64)] = []
    private var lastNet: (rx: UInt64, tx: UInt64, t: TimeInterval)?
    private var lastDisk: (r: UInt64, w: UInt64, t: TimeInterval)?
    private var lastHistory: TimeInterval = 0
    private var historyDue = false
    private let historyLength = 60
    private let procs = ProcessSampler()
    private lazy var sensors = Sensors()
    private lazy var smc = SMC()
    private var gpuMeter: GPUPowerMeter?
    private var lastMenuSignature: String?
    private var tick = 0
    private var iconCache: [String: NSImage] = [:]
    private var location: CLLocationManager?
    private var lastSlowBackground: TimeInterval = -10_000
    private var lastTempRead: TimeInterval = -10_000
    private(set) var panelOpen = false
    /// The page currently on screen (set by the UI) so expensive reads run only where they're shown.
    var visiblePanel: Panel? {
        didSet { if panelOpen && visiblePanel != oldValue && (visiblePanel == .thermals || visiblePanel == .storage) { sampleSlow(force: true) } }
    }
    private var slowTick = 0
    private var processSamples = 0

    // MARK: settings

    var updateInterval: Double {
        let v = UserDefaults.standard.double(forKey: "updateInterval")
        return v > 0 ? v : 3
    }
    private var menuItems: [MBItem] { MBItem.load() }
    private var menuCharts: Bool {
        UserDefaults.standard.object(forKey: "menuBarCharts") == nil ? true : UserDefaults.standard.bool(forKey: "menuBarCharts")
    }

    // MARK: lifecycle

    func startBackground() {
        sample(extras: backgroundNeeds)
        restartBackgroundTimer()
        updateMenuBar()
        let status = CLLocationManager().authorizationStatus
        locationAuthorized = status == .authorizedAlways || status == .authorized
    }

    /// Called at launch and whenever the update interval changes.
    func restartBackgroundTimer() {
        bgTimer?.invalidate()
        let t = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in self?.backgroundTick() }
        t.tolerance = min(1, updateInterval * 0.25)
        RunLoop.main.add(t, forMode: .common)
        bgTimer = t
    }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        fgTimer?.invalidate()
        fgTimer = nil
        if open {
            tick = 0
            slowTick = 0
            gpuMeter = GPUPowerMeter()
            _ = gpuMeter?.read()
            sample(extras: .all)
            sampleSlow(force: true)
            procs.reset()
            sampleProcesses()
            refreshBluetooth()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.panelOpen else { return }
                self.sampleProcesses()
            }
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.foregroundTick() }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            fgTimer = t
        } else {
            // Drop everything that is only needed while the panel is visible.
            gpuMeter = nil
            gpuPowerW = nil
            topMemory = []; topCPU = []; topPower = []; topDisk = []
            appsPowerW = nil
            iconCache.removeAll()
            procs.reset()
        }
    }

    private func backgroundTick() {
        guard !panelOpen else { return }
        sample(extras: backgroundNeeds)
        backgroundSlowChecks()
        checkAlerts()
        updateMenuBar()
    }

    private func foregroundTick() {
        tick += 1
        sample(extras: .all)
        gpuPowerW = gpuMeter?.read()
        updateMenuBar()
        if tick % 2 == 0 { sampleProcesses() }
        if tick % 5 == 0 { sampleSlow(); checkAlerts() }
        if tick % 30 == 0 { refreshBluetooth() }
    }

    // MARK: sampling

    struct Extras: OptionSet {
        let rawValue: Int
        static let cores = Extras(rawValue: 1 << 0)
        static let gpu = Extras(rawValue: 1 << 1)
        static let diskIO = Extras(rawValue: 1 << 2)
        static let power = Extras(rawValue: 1 << 3)
        static let temperature = Extras(rawValue: 1 << 4)
        static let all: Extras = [.cores, .gpu, .diskIO, .power, .temperature]
    }

    /// What the closed panel still needs, derived from menu bar readouts and alerts.
    private var backgroundNeeds: Extras {
        var e: Extras = []
        for item in menuItems {
            switch item {
            case .gpu: e.insert(.gpu)
            case .disk: e.insert(.diskIO)
            case .power: e.insert(.power)
            case .temperature: e.insert(.temperature)
            default: break
            }
        }
        if Alerts.isOn(.heat) { e.insert(.temperature) }
        return e
    }

    private func sample(extras: Extras) {
        let now = ProcessInfo.processInfo.systemUptime
        historyDue = now - lastHistory >= 2.9
        if historyDue { lastHistory = now }

        if let t = SysInfo.cpuTicks() {
            if let l = lastTicks {
                let u = Double((t.user &- l.user) &+ (t.nice &- l.nice))
                let s = Double(t.system &- l.system)
                let i = Double(t.idle &- l.idle)
                let total = u + s + i
                if total > 0 { cpuUser = u / total * 100; cpuSystem = s / total * 100 }
            }
            lastTicks = t
        }
        mem = SysInfo.memory()

        let net = SysInfo.networkBytes()
        if let l = lastNet, now > l.t, net.rx >= l.rx, net.tx >= l.tx {
            netDown = Double(net.rx - l.rx) / (now - l.t)
            netUp = Double(net.tx - l.tx) / (now - l.t)
        }
        lastNet = (net.rx, net.tx, now)
        netTotalDown = net.rx
        netTotalUp = net.tx

        if extras.contains(.cores) {
            let ticks = Hardware.coreTicks()
            if ticks.count == lastCoreTicks.count {
                cores = zip(ticks, lastCoreTicks).map { n, o in
                    let busy = Double(n.busy &- o.busy), idle = Double(n.idle &- o.idle)
                    return busy + idle > 0 ? busy / (busy + idle) * 100 : 0
                }
            }
            lastCoreTicks = ticks
        }
        if extras.contains(.gpu) { gpu = Hardware.gpu() }
        if extras.contains(.diskIO) {
            let d = Hardware.diskBytes()
            if let l = lastDisk, now > l.t, d.read >= l.r, d.write >= l.w {
                diskRead = Double(d.read - l.r) / (now - l.t)
                diskWrite = Double(d.write - l.w) / (now - l.t)
            }
            lastDisk = (d.read, d.write, now)
        }
        if extras.contains(.power) { power = Hardware.power() }
        // Temperature moves slowly: refresh it at most every 3 s even when the menu bar updates every second.
        if extras.contains(.temperature) && !panelOpen && now - lastTempRead >= 2.9 {
            lastTempRead = now
            temps.cpu = sensors.hottestCPU()
        }

        if historyDue {
            push(&cpuHistory, cpuTotal)
            push(&memHistory, mem.usedPercent)
            push(&downHistory, netDown)
            push(&upHistory, netUp)
            if extras.contains(.gpu) { push(&gpuHistory, gpu?.utilization ?? 0) }
            if extras.contains(.diskIO) { push(&diskReadHistory, diskRead); push(&diskWriteHistory, diskWrite) }
            if extras.contains(.power), let w = power?.systemW { push(&powerHistory, w) }
            if extras.contains(.temperature), let c = temps.cpu { push(&tempHistory, c) }
        }
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > historyLength { a.removeFirst(a.count - historyLength) }
    }

    private func average<C: Collection>(_ c: C) -> Double? where C.Element == Double {
        c.isEmpty ? nil : c.reduce(0, +) / Double(c.count)
    }

    /// Every 5 s while open. Full sensor sweep only on the Thermals page; disk space (a slow, purgeable-aware
    /// query) every 30 s, or every 5 s on the Storage page.
    private func sampleSlow(force: Bool = false) {
        slowTick += 1
        if force || disk == nil || visiblePanel == .storage || slowTick % 6 == 0 {
            disk = SysInfo.disk()
            drives = SysInfo.externalDrives()
        }
        battery = SysInfo.battery()
        temps = visiblePanel == .thermals ? sensors.read(full: true) : sensors.readSummary()
        fans = smc.fans()
        if force || slowTick % 2 == 0 || visiblePanel == .network {   // CoreWLAN is relatively slow: every 10 s
            wifi = SysInfo.wifi()
            ipAddress = SysInfo.ipv4(for: wifi?.interface ?? "en0")
        }
        uptime = SysInfo.uptime()
        load = SysInfo.loadAverage()
        thermal = ProcessInfo.processInfo.thermalState
        selfFootprint = SysInfo.selfFootprint()
    }

    /// While closed: battery once a minute if shown or alerting; disk space every 5 minutes if alerting.
    private func backgroundSlowChecks() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSlowBackground >= 60 else { return }
        let fiveMin = Int(now / 60) % 5 == 0
        lastSlowBackground = now
        if menuItems.contains(.battery) || Alerts.isOn(.battery) { battery = SysInfo.battery() }
        if Alerts.isOn(.disk) && (fiveMin || disk == nil) { disk = SysInfo.disk() }
        thermal = ProcessInfo.processInfo.thermalState
    }

    private func sampleProcesses() {
        let r = procs.sample(top: 5)
        topMemory = r.memory
        topCPU = r.cpu
        topPower = r.power
        topDisk = r.disk
        appsPowerW = r.totalPower > 0 ? r.totalPower : appsPowerW
        processSamples += 1
        // Which apps can be quit changes rarely, and NSWorkspace's app list is costly: refresh every 10 s.
        guard quittable.isEmpty || processSamples % 5 == 0 else { return }
        refreshQuittable()
    }

    private func refreshQuittable() {
        let mine = Bundle.main.bundleURL.path
        quittable = Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let p = app.bundleURL?.path, p != mine else { return nil }
            return p
        })
    }

    func refreshBluetooth() {
        DispatchQueue.global(qos: .utility).async {
            let devices = Self.readBluetooth()
            DispatchQueue.main.async {
                self.bluetooth = devices
                self.bluetoothLoaded = true
            }
        }
    }

    private static func readBluetooth() -> [BTDevice] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPBluetoothDataType"] as? [[String: Any]],
              let connected = items.first?["device_connected"] as? [[String: Any]] else { return [] }
        var out: [BTDevice] = []
        let hid = SysInfo.hidBatteries()
        for entry in connected {
            for (name, value) in entry {
                guard let d = value as? [String: Any] else { continue }
                var bats: [(String, Int)] = []
                func pct(_ k: String) -> Int? {
                    (d[k] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
                }
                if let v = pct("device_batteryLevelMain") { bats.append(("", v)) }
                if let v = pct("device_batteryLevelLeft") { bats.append(("L", v)) }
                if let v = pct("device_batteryLevelRight") { bats.append(("R", v)) }
                if let v = pct("device_batteryLevelCase") { bats.append(("Case", v)) }
                if bats.isEmpty, let addr = d["device_address"] as? String,
                   let v = hid[addr.lowercased().replacingOccurrences(of: ":", with: "-")] {
                    bats.append(("", v))
                }
                out.append(BTDevice(name: name, kind: d["device_minorType"] as? String ?? "", batteries: bats))
            }
        }
        return out
    }

    // MARK: alerts

    private var streaks: [Alerts.Kind: Int] = [:]
    private var lastFired: [Alerts.Kind: TimeInterval] = [:]

    /// Each alert must hold for two checks in a row, then stays quiet for its cooldown.
    private func checkAlerts() {
        for kind in Alerts.Kind.allCases where Alerts.isOn(kind) {
            let threshold = Alerts.threshold(kind)
            var triggered = false
            var body = ""
            switch kind {
            case .heat:
                if let c = temps.cpu, c >= threshold {
                    triggered = true
                    body = "CPU is at \(Fmt.temp(c)) (alert set at \(Fmt.temp(threshold))). Check what's busy in Telltale → CPU."
                }
            case .memory:
                if Double(mem.pressure) >= threshold {
                    triggered = true
                    body = "Memory pressure is \(mem.pressure)% (alert at \(Int(threshold))%). Telltale → Memory shows what's using it."
                }
            case .disk:
                if let d = disk, Double(d.available) / 1e9 <= threshold {
                    triggered = true
                    body = "Only \(Fmt.disk(d.available)) free on \(d.name) (alert at \(Int(threshold)) GB)."
                }
            case .battery:
                if let b = battery, !b.onAC, Double(b.percent) <= threshold {
                    triggered = true
                    body = "Battery is at \(b.percent)%. Time to plug in."
                }
            }
            streaks[kind] = triggered ? (streaks[kind] ?? 0) + 1 : 0
            let now = ProcessInfo.processInfo.systemUptime
            guard triggered, (streaks[kind] ?? 0) >= 2, now - (lastFired[kind] ?? -100_000) > kind.cooldown else { continue }
            lastFired[kind] = now
            let content = UNMutableNotificationContent()
            content.title = kind.notificationTitle
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil))
        }
    }

    func setAlert(_ kind: Alerts.Kind, on: Bool, completion: @escaping (Bool) -> Void) {
        UserDefaults.standard.set(on, forKey: kind.enabledKey)
        if on && kind == .battery { battery = SysInfo.battery() }
        if on && kind == .disk { disk = SysInfo.disk() }
        guard on else { completion(true); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: menu bar

    func updateMenuBar() {
        let rendered = MenuBarRenderer.render(items: menuItems, charts: menuCharts, m: self)
        let signature = rendered?.signature ?? ""
        guard signature != lastMenuSignature else { return }   // skip redundant redraws
        lastMenuSignature = signature
        onMenuBarImage?(rendered?.image)
    }

    /// Called when menu bar settings change: sample anything newly needed right away.
    func menuBarSettingsChanged() {
        sample(extras: backgroundNeeds.union(panelOpen ? .all : []))
        if menuItems.contains(.battery) && battery == nil { battery = SysInfo.battery() }
        if !panelOpen && backgroundNeeds.contains(.temperature) { temps.cpu = sensors.hottestCPU() }
        lastMenuSignature = nil
        updateMenuBar()
    }

    func refreshTempsNow() {
        temps = sensors.read(full: panelOpen)
        lastMenuSignature = nil
        updateMenuBar()
    }

    // MARK: actions

    func icon(for app: AppUsage) -> NSImage? {
        guard let p = app.appPath else { return nil }
        if let i = iconCache[p] { return i }
        // App icons carry many large representations; drawing them every frame re-decodes them.
        // Flatten once into a single 64×64 bitmap so redraws are a cheap pixel copy.
        let src = NSWorkspace.shared.icon(forFile: p)
        let px = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return src }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let i = NSImage(size: NSSize(width: 32, height: 32))
        i.addRepresentation(rep)
        iconCache[p] = i
        return i
    }

    func canQuit(_ app: AppUsage) -> Bool {
        guard let p = app.appPath else { return false }
        return quittable.contains(p)
    }

    func quit(_ app: AppUsage) {
        guard let p = app.appPath else { return }
        for ra in NSWorkspace.shared.runningApplications where ra.bundleURL?.path == p { ra.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.sampleProcesses(); self?.refreshQuittable() }
    }

    func eject(_ drive: ExternalDrive) {
        DispatchQueue.global(qos: .userInitiated).async {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: drive.url)
            DispatchQueue.main.async { self.drives = SysInfo.externalDrives() }
        }
    }

    func runSpeedTest() {
        guard !speedTest.isRunning else { return }
        speedTest = .running
        DispatchQueue.global(qos: .utility).async {
            var result = SpeedTestState.failed("Couldn't run the test")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            p.arguments = ["-c"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let dl = (j["dl_throughput"] as? NSNumber)?.doubleValue ?? 0
                    let ul = (j["ul_throughput"] as? NSNumber)?.doubleValue ?? 0
                    let rpm = (j["responsiveness"] as? NSNumber)?.intValue ?? (j["dl_responsiveness"] as? NSNumber)?.intValue
                    result = dl > 0 || ul > 0 ? .done(down: dl, up: ul, responsiveness: rpm) : .failed("No results — check your connection")
                }
            }
            DispatchQueue.main.async { self.speedTest = result }
        }
    }

    func requestLocationForWiFiName() {
        let lm = CLLocationManager()
        lm.delegate = self
        location = lm
        if lm.authorizationStatus == .notDetermined {
            lm.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        locationAuthorized = s == .authorizedAlways || s == .authorized
        wifi = SysInfo.wifi()
    }
}

// MARK: - Alert settings

enum Alerts {
    enum Kind: String, CaseIterable, Identifiable {
        case heat, memory, disk, battery
        var id: String { rawValue }

        var enabledKey: String {
            switch self {
            case .heat: return "heatAlerts"          // key kept from 0.1.0
            case .memory: return "memoryAlerts"
            case .disk: return "diskAlerts"
            case .battery: return "batteryAlerts"
            }
        }
        var thresholdKey: String {
            switch self {
            case .heat: return "heatThreshold"
            case .memory: return "memoryThreshold"
            case .disk: return "diskThresholdGB"
            case .battery: return "batteryThreshold"
            }
        }
        var defaultThreshold: Double {
            switch self {
            case .heat: return 90      // °C
            case .memory: return 85    // % pressure
            case .disk: return 10      // GB free
            case .battery: return 15   // %
            }
        }
        var range: ClosedRange<Double> {
            switch self {
            case .heat: return 70...105
            case .memory: return 50...95
            case .disk: return 1...100
            case .battery: return 5...50
            }
        }
        var title: String {
            switch self {
            case .heat: return "the CPU gets hot"
            case .memory: return "memory pressure is high"
            case .disk: return "disk space runs low"
            case .battery: return "the battery runs low"
            }
        }
        var notificationTitle: String {
            switch self {
            case .heat: return "Your Mac is running hot"
            case .memory: return "Memory is tight"
            case .disk: return "Disk space is low"
            case .battery: return "Battery is low"
            }
        }
        var cooldown: TimeInterval { self == .heat ? 600 : 1800 }
        func format(_ v: Double) -> String {
            switch self {
            case .heat: return Fmt.temp(v)
            case .memory, .battery: return "\(Int(v))%"
            case .disk: return "\(Int(v)) GB"
            }
        }
    }

    static func isOn(_ k: Kind) -> Bool { UserDefaults.standard.bool(forKey: k.enabledKey) }
    static func threshold(_ k: Kind) -> Double {
        let v = UserDefaults.standard.double(forKey: k.thresholdKey)
        return v > 0 ? v : k.defaultThreshold
    }
}
