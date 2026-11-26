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

/// Holds all live readings. Sampling is cheap and adaptive:
/// - panel closed: CPU, memory and network counters every 3 s (feeds history + optional menu bar text)
/// - panel open: fast readings every 1 s, processes every 2 s, sensors/battery/disk every 5 s
final class Monitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Monitor()

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
    @Published var quittable: Set<String> = []
    @Published var bluetooth: [BTDevice] = []
    @Published var bluetoothLoaded = false
    @Published var speedTest = SpeedTestState.idle
    @Published var locationAuthorized = false
    @Published var selfFootprint: UInt64 = 0

    var cpuTotal: Double { cpuUser + cpuSystem }
    var onMenuBarUpdate: ((String?) -> Void)?

    private var bgTimer: Timer?
    private var fgTimer: Timer?
    private var lastTicks: CPUTicks?
    private var lastNet: (rx: UInt64, tx: UInt64, t: TimeInterval)?
    private var lastHistory: TimeInterval = 0
    private let historyLength = 60
    private let procs = ProcessSampler()
    private lazy var sensors = Sensors()
    private lazy var smc = SMC()
    private var lastTempHistory: TimeInterval = 0
    private var lastAlert: TimeInterval = -10_000
    private var hotStreak = 0
    private var lastMenuText: String?? = .none
    private var tick = 0
    private var iconCache: [String: NSImage] = [:]
    private var location: CLLocationManager?
    private(set) var panelOpen = false

    // MARK: lifecycle

    func startBackground() {
        sampleFast()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, !self.panelOpen else { return }
            self.sampleFast()
            if self.needsBackgroundTemps {
                let cpu = self.sensors.read(full: false).cpu
                self.temps.cpu = cpu
                self.pushTemp(cpu)
                self.checkHeat()
            }
            self.updateMenuBar()
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        bgTimer = t
        updateMenuBar()
        let status = CLLocationManager().authorizationStatus
        locationAuthorized = status == .authorizedAlways || status == .authorized
    }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        fgTimer?.invalidate()
        fgTimer = nil
        if open {
            tick = 0
            sampleFast()
            sampleSlow()
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
            topMemory = []
            topCPU = []
            iconCache.removeAll()
            procs.reset()
        }
    }

    private func foregroundTick() {
        tick += 1
        sampleFast()
        updateMenuBar()
        if tick % 2 == 0 { sampleProcesses() }
        if tick % 5 == 0 { sampleSlow() }
        if tick % 30 == 0 { refreshBluetooth() }
    }

    // MARK: sampling

    private func sampleFast() {
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

        let now = ProcessInfo.processInfo.systemUptime
        let net = SysInfo.networkBytes()
        if let l = lastNet, now > l.t, net.rx >= l.rx, net.tx >= l.tx {
            netDown = Double(net.rx - l.rx) / (now - l.t)
            netUp = Double(net.tx - l.tx) / (now - l.t)
        }
        lastNet = (net.rx, net.tx, now)
        netTotalDown = net.rx
        netTotalUp = net.tx

        if now - lastHistory >= 2.9 {
            lastHistory = now
            push(&cpuHistory, cpuTotal)
            push(&memHistory, mem.usedPercent)
            push(&downHistory, netDown)
            push(&upHistory, netUp)
        }
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > historyLength { a.removeFirst(a.count - historyLength) }
    }

    private func sampleSlow() {
        disk = SysInfo.disk()
        drives = SysInfo.externalDrives()
        battery = SysInfo.battery()
        temps = sensors.read(full: true)
        pushTemp(temps.cpu)
        fans = smc.fans()
        checkHeat()
        wifi = SysInfo.wifi()
        ipAddress = SysInfo.ipv4(for: wifi?.interface ?? "en0")
        uptime = SysInfo.uptime()
        load = SysInfo.loadAverage()
        thermal = ProcessInfo.processInfo.thermalState
        selfFootprint = SysInfo.selfFootprint()
    }

    private func sampleProcesses() {
        let r = procs.sample(top: 5)
        topMemory = r.byMemory
        topCPU = r.byCPU
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

    // MARK: temperatures & alerts

    private var menuBarMode: Int { UserDefaults.standard.integer(forKey: "menuBarMode") }
    var heatAlertsOn: Bool { UserDefaults.standard.bool(forKey: "heatAlerts") }
    var heatThreshold: Double {
        let v = UserDefaults.standard.double(forKey: "heatThreshold")
        return v > 0 ? v : 90
    }
    private var needsBackgroundTemps: Bool { menuBarMode >= 3 || heatAlertsOn }

    private func pushTemp(_ c: Double?) {
        guard let c else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTempHistory >= 2.9 else { return }
        lastTempHistory = now
        push(&tempHistory, c)
    }

    /// Notifies once (then at most every 10 min) when the hottest CPU sensor stays above the threshold.
    private func checkHeat() {
        guard heatAlertsOn, let c = temps.cpu else { hotStreak = 0; return }
        hotStreak = c >= heatThreshold ? hotStreak + 1 : 0
        let now = ProcessInfo.processInfo.systemUptime
        guard hotStreak >= 2, now - lastAlert > 600 else { return }
        lastAlert = now
        let content = UNMutableNotificationContent()
        content.title = "Your Mac is running hot"
        content.body = "CPU is at \(Fmt.temp(c)) (alert set at \(Fmt.temp(heatThreshold))). Check what's busy in Telltale → CPU."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "heat", content: content, trigger: nil))
    }

    func setHeatAlerts(_ on: Bool, completion: @escaping (Bool) -> Void) {
        UserDefaults.standard.set(on, forKey: "heatAlerts")
        guard on else { completion(true); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: menu bar

    func updateMenuBar() {
        let text: String?
        switch menuBarMode {
        case 1: text = String(format: "%.0f%%", cpuTotal)
        case 2: text = String(format: "%.0f%%  %.0f%%", cpuTotal, mem.usedPercent)
        case 3: text = temps.cpu == nil ? nil : Fmt.temp(temps.cpu)
        case 4: text = String(format: "%.0f%%  ", cpuTotal) + (temps.cpu == nil ? "" : Fmt.temp(temps.cpu))
        default: text = nil
        }
        if case .some(let last) = lastMenuText, last == text { return }   // skip redundant redraws
        lastMenuText = .some(text)
        onMenuBarUpdate?(text)
    }

    func refreshTempsNow() {
        temps = sensors.read(full: panelOpen)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.sampleProcesses() }
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
