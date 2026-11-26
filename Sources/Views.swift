import SwiftUI
import AppKit
import ServiceManagement

enum Panel: String, Hashable { case storage, memory, cpu, gpu, power, battery, network, devices, thermals, settings }

extension Notification.Name { static let telltaleThemeChanged = Notification.Name("TelltaleThemeChanged") }

extension Fmt {
    /// Compact disk size for tight spaces: "379 GB", "1.2 TB".
    static func short(_ b: UInt64) -> String {
        let d = Double(b)
        if d >= 1e12 { return String(format: "%.1f TB", d / 1e12) }
        if d >= 1e11 { return String(format: "%.0f GB", d / 1e9) }
        return String(format: "%.1f GB", d / 1e9)
    }
}

struct RootView: View {
    @AppStorage("theme") private var themeName = ThemeName.aurora.rawValue
    @State private var panel: Panel?
    private let onSize: (CGSize) -> Void

    init(initial: Panel? = nil, onSize: @escaping (CGSize) -> Void = { _ in }) {
        _panel = State(initialValue: initial)
        self.onSize = onSize
    }

    var body: some View {
        let theme = Theme.make(ThemeName(rawValue: themeName) ?? .aurora)
        ZStack(alignment: .top) {
            if let p = panel {
                DetailView(panel: p) { go(nil) }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            } else {
                OverviewView { go($0) }
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .padding(14)
        .frame(width: 392)
        .background(ThemeBackground(theme: theme).padding(-30))
        .environment(\.theme, theme)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { proxy in
            // Round so sub-point jitter from live numbers never triggers a resize.
            CGSize(width: proxy.size.width.rounded(), height: proxy.size.height.rounded())
        } action: { onSize($0) }
        .onAppear { Monitor.shared.visiblePanel = panel }
        .onChange(of: panel) { Monitor.shared.visiblePanel = panel }
    }

    private func go(_ p: Panel?) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { panel = p }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    let open: (Panel) -> Void
    private let halfWidth: CGFloat = 177   // fixed so live numbers can never resize the cards

    var body: some View {
        VStack(spacing: 10) {
            header
            gauges
            HStack(spacing: 10) {
                networkCard.frame(width: halfWidth)
                thermalsCard.frame(width: halfWidth)
            }
            .frame(height: 132)
            HStack(spacing: 10) {
                powerCard.frame(width: halfWidth)
                diskActivityCard.frame(width: halfWidth)
            }
            .frame(height: 112)
            HStack(spacing: 10) {
                busiestCard.frame(width: halfWidth)
                devicesCard.frame(width: halfWidth)
            }
            .frame(height: 104)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            IconBadge(symbol: "gauge.with.dots.needle.50percent", colors: theme.brand, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Telltale").font(.system(size: 15.5, weight: .heavy, design: .rounded))
                Text("Up \(Fmt.duration(m.uptime)) · \(ProcessInfo.processInfo.activeProcessorCount) cores")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            HealthPill()
        }
    }

    private var gauges: some View {
        HStack(spacing: 0) {
            GaugeCell(title: "CPU", value: Fmt.pct(m.cpuTotal), fraction: m.cpuTotal / 100,
                      sub: Fmt.temp(m.temps.cpu), colors: theme.cpu, rolling: false) { open(.cpu) }
            GaugeCell(title: "GPU", value: Fmt.pct(m.gpu?.utilization ?? 0), fraction: (m.gpu?.utilization ?? 0) / 100,
                      sub: m.gpuPowerW.map { Fmt.watts($0) } ?? "—", colors: theme.gpu, rolling: false) { open(.gpu) }
            GaugeCell(title: "Memory", value: Fmt.pct(m.mem.usedPercent), fraction: m.mem.usedPercent / 100,
                      sub: "\(Fmt.short(m.mem.available)) free", colors: theme.memory) { open(.memory) }
            GaugeCell(title: "Disk", value: Fmt.pct((m.disk?.usedFraction ?? 0) * 100), fraction: m.disk?.usedFraction ?? 0,
                      sub: m.disk.map { "\(Fmt.short($0.available)) free" } ?? "—", colors: theme.disk) { open(.storage) }
            GaugeCell(title: "Battery", value: m.battery.map { "\($0.percent)%" } ?? "—",
                      fraction: Double(m.battery?.percent ?? 0) / 100,
                      sub: batteryShort, colors: (m.battery?.percent ?? 100) <= 20 ? [Color(hex: 0xFF9A9E), Color(hex: 0xF5576C)] : theme.battery) {
                open(.battery)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
        .glass()
    }

    private var batteryShort: String {
        guard let b = m.battery else { return "" }
        if b.isCharging { return "Charging" }
        if b.onAC { return b.percent >= 99 ? "Charged" : "Plugged in" }
        return b.minutesRemaining.map { Fmt.minutes($0) + " left" } ?? "On battery"
    }

    private var powerCard: some View {
        TapCard(action: { open(.power) }) {
            CardHeader(symbol: "bolt.fill", title: "Power", colors: theme.power)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                RollingText(text: m.power?.systemW.map { Fmt.watts($0) } ?? "—", size: 20, weight: .heavy)
                Text(powerSource).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            Sparkline(values: m.powerHistory, maxValue: max(20, (m.powerHistory.max() ?? 0) * 1.15), colors: theme.power)
                .frame(maxHeight: .infinity)
        }
    }

    private var powerSource: String {
        guard let b = m.battery else { return "whole Mac" }
        if !b.onAC { return m.power?.batteryW.map { "battery \(Fmt.watts(abs($0)))" } ?? "on battery" }
        return "from charger"
    }

    private var diskActivityCard: some View {
        TapCard(action: { open(.storage) }) {
            CardHeader(symbol: "internaldrive.fill", title: "Disk activity", colors: theme.disk)
            HStack(spacing: 12) {
                RateLabel(arrow: "arrow.down.doc", label: "Read", value: Fmt.rate(m.diskRead), color: theme.disk.first ?? .purple)
                RateLabel(arrow: "square.and.pencil", label: "Write", value: Fmt.rate(m.diskWrite), color: theme.disk.last ?? .pink)
            }
            let top = max(m.diskReadHistory.max() ?? 0, m.diskWriteHistory.max() ?? 0, 100_000) * 1.15
            ZStack {
                Sparkline(values: m.diskReadHistory, maxValue: top, colors: theme.disk)
                Sparkline(values: m.diskWriteHistory, maxValue: top, colors: theme.upload, showDot: false).opacity(0.85)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var networkCard: some View {
        TapCard(action: { open(.network) }) {
            CardHeader(symbol: "wifi", title: m.wifi?.ssid ?? "Network", colors: theme.network)
            HStack(spacing: 12) {
                RateLabel(arrow: "arrow.down", label: "Down", value: Fmt.rate(m.netDown), color: theme.network.last ?? .teal)
                RateLabel(arrow: "arrow.up", label: "Up", value: Fmt.rate(m.netUp), color: theme.upload.last ?? .pink)
            }
            let top = max(m.downHistory.max() ?? 0, m.upHistory.max() ?? 0, 1024) * 1.15
            ZStack {
                Sparkline(values: m.downHistory, maxValue: top, colors: theme.network)
                Sparkline(values: m.upHistory, maxValue: top, colors: theme.upload, showDot: false).opacity(0.85)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var thermalsCard: some View {
        TapCard(action: { open(.thermals) }) {
            CardHeader(symbol: "flame.fill", title: "Thermals", colors: theme.heat)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                RollingText(text: Fmt.temp(m.temps.cpu), size: 24, weight: .heavy, color: heatColor(m.temps.cpu), rolling: true)
                Text("CPU").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            TempScale(celsius: m.temps.cpu)
            HStack(spacing: 5) {
                Image(systemName: "fan").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(fanSummary).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 2)
                Text("SSD \(Fmt.temp(m.temps.ssd))").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var fanSummary: String {
        if m.fans.isEmpty { return "No fans" }
        if m.fans.allSatisfy({ $0.rpm < 1 }) { return "Fans off" }
        return m.fans.map { String(format: "%.0f", $0.rpm) }.joined(separator: " · ") + " rpm"
    }

    private var busiestCard: some View {
        TapCard(action: { open(.cpu) }) {
            CardHeader(symbol: "bolt.fill", title: "Busiest now", colors: theme.cpu)
            if let a = m.topCPU.first {
                HStack(spacing: 8) {
                    AppIcon(app: a, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        RollingText(text: String(format: "%.0f%% CPU", a.cpu), size: 11, weight: .medium, color: .secondary)
                    }
                }
            } else {
                Text("All quiet").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let top = m.topMemory.first {
                Text("Most memory: \(top.name) · \(Fmt.mem(top.memory))")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var devicesCard: some View {
        TapCard(action: { open(.devices) }) {
            CardHeader(symbol: "dot.radiowaves.left.and.right", title: "Devices", colors: theme.devices)
            if !m.bluetoothLoaded {
                Text("Scanning…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if m.bluetooth.isEmpty && m.drives.isEmpty {
                Text("Nothing connected").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            ForEach(m.bluetooth.prefix(2)) { d in
                HStack(spacing: 8) {
                    GaugeRing(fraction: Double(d.batteries.first?.percent ?? 0) / 100, colors: theme.battery, lineWidth: 3) {
                        Image(systemName: deviceSymbol(d.kind)).font(.system(size: 9, weight: .semibold))
                    }
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(shortName(d.name)).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        Text(d.batteries.first.map { "\($0.percent)%" } ?? "Connected")
                            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if m.bluetooth.isEmpty, let d = m.drives.first {
                Label(d.name, systemImage: "externaldrive").font(.system(size: 11.5))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            PillButton(title: "Activity Monitor", symbol: "chart.bar.xaxis") {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                   configuration: NSWorkspace.OpenConfiguration())
            }
            Spacer()
            IconButton(symbol: "gearshape.fill", help: "Settings") { open(.settings) }
            IconButton(symbol: "power", help: "Quit Telltale") { NSApp.terminate(nil) }
        }
    }

    private func shortName(_ n: String) -> String {
        n.replacingOccurrences(of: "’s ", with: " ").components(separatedBy: " ").suffix(2).joined(separator: " ")
    }
}

// MARK: - Overview pieces

struct CardHeader: View {
    let symbol: String
    let title: String
    let colors: [Color]
    var body: some View {
        HStack(spacing: 7) {
            IconBadge(symbol: symbol, colors: colors, size: 20)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
        }
    }
}

struct GaugeCell: View {
    let title: String
    let value: String
    let fraction: Double
    let sub: String
    let colors: [Color]
    var rolling = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                GaugeRing(fraction: fraction, colors: colors, lineWidth: 6) {
                    RollingText(text: value, size: 13, weight: .heavy, shrink: 0.6, rolling: rolling)
                }
                .frame(width: 58, height: 58)
                .scaleEffect(hover ? 1.06 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: hover)
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(sub).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct RateLabel: View {
    let arrow: String
    let label: String
    let value: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Image(systemName: arrow).font(.system(size: 8, weight: .heavy)).foregroundStyle(color)
                Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            RollingText(text: value, size: 13.5, weight: .bold, shrink: 0.7)
                .frame(width: 72, alignment: .leading)
        }
    }
}

/// Green→red bar from 30 °C to 100 °C with a glowing marker for the current reading.
struct TempScale: View {
    let celsius: Double?
    var body: some View {
        GeometryReader { g in
            let f = CGFloat(min(max(((celsius ?? 30) - 30) / 70, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [Color(hex: 0x4ADE80), Color(hex: 0xFACC15), Color(hex: 0xFB923C), Color(hex: 0xF87171)],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(height: 5).opacity(0.9)
                Circle().fill(.white).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(heatColor(celsius), lineWidth: 2))
                    .offset(x: f * (g.size.width - 9))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 10)
    }
}

struct AppIcon: View {
    @EnvironmentObject var m: Monitor
    let app: AppUsage
    var size: CGFloat = 20
    var body: some View {
        if let img = m.icon(for: app) {
            Image(nsImage: img).resizable().frame(width: size, height: size)
        } else {
            IconBadge(symbol: "terminal", colors: [Color.gray.opacity(0.75), Color.gray.opacity(0.4)], size: size)
        }
    }
}

struct HealthPill: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        let s = status
        HStack(spacing: 5) {
            Circle().fill(s.color).frame(width: 6, height: 6)
            Text(s.text).font(.system(size: 10.5, weight: .bold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(s.color.opacity(0.15)))
        .overlay(Capsule().strokeBorder(s.color.opacity(0.35)))
        .foregroundStyle(s.color)
        .animation(.easeInOut(duration: 0.3), value: s.text)
    }

    private var status: (text: String, color: Color) {
        let red = Color(hex: 0xF87171), orange = Color(hex: 0xFB923C), yellow = Color(hex: 0xFACC15), green = Color(hex: 0x4ADE80)
        if m.thermal == .serious || m.thermal == .critical || (m.temps.cpu ?? 0) >= 95 { return ("Running hot", red) }
        if m.mem.pressure >= 80 { return ("Memory tight", orange) }
        if let b = m.battery, !b.onAC, b.percent <= 15 { return ("Battery low", orange) }
        if let d = m.disk, d.total > 0, Double(d.available) / Double(d.total) < 0.08 { return ("Disk nearly full", orange) }
        if m.cpuTotal >= 85 { return ("Working hard", yellow) }
        return ("All good", green)
    }
}

func deviceSymbol(_ kind: String) -> String {
    let k = kind.lowercased()
    if k.contains("mouse") { return "magicmouse.fill" }
    if k.contains("keyboard") { return "keyboard.fill" }
    if k.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
    if k.contains("headphone") || k.contains("headset") { return "headphones" }
    if k.contains("speaker") { return "hifispeaker.fill" }
    if k.contains("gamepad") || k.contains("controller") { return "gamecontroller.fill" }
    return "dot.radiowaves.left.and.right"
}

// MARK: - Detail container

struct DetailView: View {
    @Environment(\.theme) private var theme
    let panel: Panel
    let back: () -> Void
    @State private var hoverBack = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 26)
                        .glass(radius: 8, highlighted: hoverBack)
                }
                .buttonStyle(.plain)
                .onHover { hoverBack = $0 }
                .help("Back to overview")
                IconBadge(symbol: meta.symbol, colors: meta.colors, size: 24)
                Text(meta.title).font(.system(size: 15.5, weight: .heavy, design: .rounded))
                Spacer()
            }
            switch panel {
            case .storage: StorageDetail()
            case .memory: MemoryDetail()
            case .cpu: CPUDetail()
            case .gpu: GPUDetail()
            case .power: PowerDetail()
            case .battery: BatteryDetail()
            case .network: NetworkDetail()
            case .devices: DevicesDetail()
            case .thermals: ThermalsDetail()      // has a toggle + slider (AppKit controls can't be GPU-rasterised)
            case .settings: SettingsDetail()      // has toggle + pickers
            }
        }
    }

    private var meta: (title: String, symbol: String, colors: [Color]) {
        switch panel {
        case .storage: return ("Storage", "internaldrive.fill", theme.disk)
        case .memory: return ("Memory", "memorychip.fill", theme.memory)
        case .cpu: return ("CPU", "cpu.fill", theme.cpu)
        case .gpu: return ("GPU", "cube.transparent.fill", theme.gpu)
        case .power: return ("Power & Energy", "bolt.fill", theme.power)
        case .battery: return ("Battery", "battery.100percent.bolt", theme.battery)
        case .network: return ("Network", "wifi", theme.network)
        case .devices: return ("Devices", "dot.radiowaves.left.and.right", theme.devices)
        case .thermals: return ("Thermals & Fans", "flame.fill", theme.heat)
        case .settings: return ("Settings", "gearshape.fill", theme.brand)
        }
    }
}

// MARK: - Panels

struct StorageDetail: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    var body: some View {
        if let d = m.disk {
            Card {
                HStack(spacing: 16) {
                    GaugeRing(fraction: d.usedFraction, colors: theme.disk, lineWidth: 11) {
                        VStack(spacing: 0) {
                            RollingText(text: Fmt.short(d.available), size: 18, weight: .heavy, shrink: 0.6, rolling: true)
                            Text("available").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 128, height: 128)
                    VStack(alignment: .leading, spacing: 10) {
                        Stat(label: "Volume", value: d.name)
                        Stat(label: "Used", value: "\(Fmt.short(d.total - min(d.total, d.available))) of \(Fmt.short(d.total))")
                        Stat(label: "Free right now", value: Fmt.disk(d.freeNow))
                        Stat(label: "Purgeable (macOS can clear)", value: Fmt.disk(d.available > d.freeNow ? d.available - d.freeNow : 0))
                    }
                }
            }
        }
        DiskActivityCard()
        DrivesCard()
        PillButton(title: "Storage Settings", symbol: "gearshape") {
            if let u = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(u) }
        }
    }
}

struct DrivesCard: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    var body: some View {
        Card {
            SectionTitle(text: "External drives")
            if m.drives.isEmpty {
                Text("None connected").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(m.drives) { d in
                HStack(spacing: 9) {
                    IconBadge(symbol: "externaldrive.fill", colors: theme.disk, size: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.name).font(.system(size: 12, weight: .medium))
                        Meter(fraction: d.total == 0 ? 0 : 1 - Double(d.available) / Double(d.total), colors: theme.disk, height: 4)
                        Text("\(Fmt.disk(d.available)) free of \(Fmt.disk(d.total))").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    IconButton(symbol: "eject.fill", help: "Eject") { m.eject(d) }
                }
            }
        }
    }
}

struct MemoryDetail: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    private let appC = Color(hex: 0x4FACFE), wiredC = Color(hex: 0x6A5CFF), compC = Color(hex: 0xC471F5)

    var body: some View {
        let t = Double(max(m.mem.total, 1))
        Card {
            HStack(spacing: 16) {
                Ring(segments: [(Double(m.mem.app) / t, appC), (Double(m.mem.wired) / t, wiredC),
                                (Double(m.mem.compressed) / t, compC)], lineWidth: 11) {
                    VStack(spacing: 0) {
                        RollingText(text: Fmt.mem(m.mem.available), size: 18, weight: .heavy, shrink: 0.6)
                        Text("of \(Fmt.mem(m.mem.total)) free").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 9) {
                    legend("App memory", m.mem.app, appC)
                    legend("Wired", m.mem.wired, wiredC)
                    legend("Compressed", m.mem.compressed, compC)
                    legend("Cached files", m.mem.cached, Color.gray.opacity(0.6))
                }
            }
            Divider().opacity(0.4)
            HStack {
                Stat(label: "Pressure", value: "\(m.mem.pressure)%", tint: pressureColor(m.mem.pressure))
                Stat(label: "Swap used", value: Fmt.mem(m.mem.swapUsed))
                Stat(label: "Used", value: Fmt.pct(m.mem.usedPercent))
            }
            Sparkline(values: m.memHistory, maxValue: 100, colors: theme.memory).frame(height: 34)
        }
        ProcessList(title: "Top memory users", items: m.topMemory, empty: "Measuring…", colors: theme.memory,
                    amount: { Double($0.memory) }, value: { Fmt.mem($0.memory) })
    }

    private func legend(_ label: String, _ v: UInt64, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            RollingText(text: Fmt.mem(v), size: 11.5, weight: .semibold)
        }
    }
}

struct CPUDetail: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Load · last 3 min")
                Spacer()
                RollingText(text: Fmt.pct(m.cpuTotal), size: 20, weight: .heavy)
            }
            Sparkline(values: m.cpuHistory, maxValue: 100, colors: theme.cpu).frame(height: 70)
            HStack {
                Stat(label: "User", value: Fmt.pct(m.cpuUser), tint: theme.cpu.first)
                Stat(label: "System", value: Fmt.pct(m.cpuSystem), tint: theme.cpu.last)
                Stat(label: "Idle", value: Fmt.pct(max(0, 100 - m.cpuTotal)))
            }
        }
        Card {
            HStack {
                Stat(label: "Temperature", value: Fmt.temp(m.temps.cpu), tint: heatColor(m.temps.cpu))
                Stat(label: "Load average", value: m.load.map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
            HStack {
                Stat(label: "Cores", value: "\(ProcessInfo.processInfo.activeProcessorCount)")
                Stat(label: "Uptime", value: Fmt.duration(m.uptime))
            }
        }
        CoreGrid()
        ProcessList(title: "Top CPU users (% of one core)", items: m.topCPU, empty: "Nothing busy right now",
                    colors: theme.cpu, amount: { $0.cpu }, value: { String(format: "%.1f%%", $0.cpu) })
    }
}

struct BatteryDetail: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    var body: some View {
        if let b = m.battery {
            Card {
                HStack(spacing: 16) {
                    GaugeRing(fraction: Double(b.percent) / 100,
                              colors: b.percent <= 20 ? [Color(hex: 0xFF9A9E), Color(hex: 0xF5576C)] : theme.battery, lineWidth: 11) {
                        VStack(spacing: 1) {
                            RollingText(text: "\(b.percent)%", size: 24, weight: .heavy, rolling: true)
                            Image(systemName: b.isCharging ? "bolt.fill" : (b.onAC ? "powerplug.fill" : "battery.75percent"))
                                .font(.system(size: 11)).foregroundStyle(theme.battery.last ?? .green)
                        }
                    }
                    .frame(width: 128, height: 128)
                    VStack(alignment: .leading, spacing: 10) {
                        Stat(label: "Status", value: status(b))
                        Stat(label: "Cycle count", value: b.cycles.map { "\($0) / \(b.designCycles)" } ?? "—")
                        Stat(label: "Health (capacity vs new)", value: b.health.map { Fmt.pct($0 * 100) } ?? "—",
                             tint: (b.health ?? 1) < 0.8 ? Color(hex: 0xFACC15) : nil)
                    }
                }
                if let h = b.health {
                    VStack(alignment: .leading, spacing: 4) {
                        Meter(fraction: h, colors: h < 0.8 ? [Color(hex: 0xFACC15), Color(hex: 0xFB923C)] : theme.battery, height: 5)
                        Text(h < 0.8 ? "Below 80% of original capacity — Apple considers this worn."
                                     : "Battery capacity is in good shape.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            Card {
                HStack {
                    Stat(label: "Temperature", value: Fmt.temp(m.temps.battery), tint: heatColor(m.temps.battery))
                    Stat(label: "Power adapter", value: b.adapterWatts.map { "\($0) W" } ?? (b.onAC ? "Connected" : "—"))
                }
                if let c = b.condition { Stat(label: "Condition", value: c) }
            }
            PillButton(title: "Battery Settings", symbol: "gearshape") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(u) }
            }
        } else {
            Card { Text("This Mac has no internal battery.").foregroundStyle(.secondary) }
        }
    }

    private func status(_ b: BatteryInfo) -> String {
        if b.isCharging { return b.minutesRemaining.map { "Charging, \(Fmt.minutes($0)) left" } ?? "Charging" }
        if b.onAC { return b.isCharged || b.percent >= 99 ? "Fully charged" : "Plugged in, not charging" }
        return b.minutesRemaining.map { "\(Fmt.minutes($0)) remaining" } ?? "On battery"
    }
}

struct NetworkDetail: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    var body: some View {
        Card {
            HStack(spacing: 8) {
                Text(m.wifi?.ssid ?? (m.wifi == nil ? "Wi-Fi off" : "Wi-Fi")).font(.system(size: 14, weight: .bold, design: .rounded))
                if let w = m.wifi { SignalBars(rssi: w.rssi, colors: theme.network) }
                Spacer()
                if let w = m.wifi, w.ssid == nil {
                    PillButton(title: "Show name", symbol: "location.fill") { m.requestLocationForWiFiName() }
                        .help("macOS only reveals Wi-Fi names to apps with Location access")
                }
            }
            if let w = m.wifi {
                HStack {
                    Stat(label: "Signal", value: "\(w.rssi) dBm · \(signalWord(w.rssi))")
                    Stat(label: "Link speed", value: String(format: "%.0f Mbps", w.txRate))
                }
                HStack {
                    Stat(label: "Security", value: w.security)
                    Stat(label: "IP address", value: m.ipAddress ?? "—")
                }
            }
        }
        Card {
            let top = max(m.downHistory.max() ?? 0, m.upHistory.max() ?? 0, 1024) * 1.15
            HStack(spacing: 14) {
                RateLabel(arrow: "arrow.down", label: "Download", value: Fmt.rate(m.netDown), color: theme.network.last ?? .teal)
                RateLabel(arrow: "arrow.up", label: "Upload", value: Fmt.rate(m.netUp), color: theme.upload.last ?? .pink)
                Spacer()
            }
            ZStack {
                Sparkline(values: m.downHistory, maxValue: top, colors: theme.network)
                Sparkline(values: m.upHistory, maxValue: top, colors: theme.upload, showDot: false).opacity(0.85)
            }
            .frame(height: 56)
            HStack {
                Text("↓ \(Fmt.disk(m.netTotalDown)) · ↑ \(Fmt.disk(m.netTotalUp)) since startup")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        Card {
            HStack {
                SectionTitle(text: "Speed test")
                Spacer()
                PillButton(title: m.speedTest.isRunning ? "Testing…" : "Run test", symbol: "speedometer",
                           colors: theme.network) { m.runSpeedTest() }
                    .disabled(m.speedTest.isRunning)
            }
            switch m.speedTest {
            case .idle:
                Text("Uses Apple's built-in networkQuality tool. Takes about 15–20 seconds.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .running:
                Text("Measuring download and upload…").font(.system(size: 10.5)).foregroundStyle(.secondary)
            case .done(let down, let up, let rpm):
                HStack {
                    Stat(label: "Download", value: Fmt.mbps(down), tint: theme.network.last)
                    Stat(label: "Upload", value: Fmt.mbps(up), tint: theme.upload.last)
                    Stat(label: "Responsiveness", value: rpm.map { "\($0) RPM" } ?? "—")
                }
            case .failed(let msg):
                Text(msg).font(.system(size: 11)).foregroundStyle(Color(hex: 0xF87171))
            }
        }
    }

    private func signalWord(_ rssi: Int) -> String {
        switch rssi {
        case (-55)...: return "Excellent"
        case (-67)..<(-55): return "Good"
        case (-75)..<(-67): return "Fair"
        default: return "Weak"
        }
    }
}

struct SignalBars: View {
    let rssi: Int
    let colors: [Color]
    var body: some View {
        let level = rssi >= -55 ? 4 : rssi >= -67 ? 3 : rssi >= -75 ? 2 : 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                Capsule()
                    .fill(i <= level ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
                                     : AnyShapeStyle(Color.white.opacity(0.15)))
                    .frame(width: 3.5, height: CGFloat(3 + i * 3))
            }
        }
    }
}

struct DevicesDetail: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    var body: some View {
        Card {
            HStack {
                SectionTitle(text: "Bluetooth")
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { m.refreshBluetooth() }
            }
            if !m.bluetoothLoaded {
                Text("Scanning…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if m.bluetooth.isEmpty {
                Text("No devices connected").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(m.bluetooth) { d in
                HStack(spacing: 11) {
                    GaugeRing(fraction: Double(d.batteries.first?.percent ?? 0) / 100,
                              colors: (d.batteries.first?.percent ?? 100) <= 20 ? [Color(hex: 0xFF9A9E), Color(hex: 0xF5576C)] : theme.battery,
                              lineWidth: 4) {
                        Image(systemName: deviceSymbol(d.kind)).font(.system(size: 12, weight: .semibold))
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if d.batteries.isEmpty {
                            Text(d.kind.isEmpty ? "Connected" : d.kind).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        ForEach(Array(d.batteries.enumerated()), id: \.offset) { _, b in
                            HStack(spacing: 6) {
                                if !b.label.isEmpty { Text(b.label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading) }
                                Meter(fraction: Double(b.percent) / 100, colors: theme.battery, height: 4)
                                RollingText(text: "\(b.percent)%", size: 11, weight: .semibold).frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        DrivesCard()
        Text("iPhone battery isn't available to third-party Mac apps, so only Bluetooth accessories are shown.")
            .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsDetail: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    @AppStorage("tempUnit") private var unit = Fmt.defaultUnit
    @AppStorage("theme") private var themeName = ThemeName.aurora.rawValue
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) { content }
        }
        .frame(height: 560)
    }

    @ViewBuilder private var content: some View {
        Card {
            SectionTitle(text: "Theme")
            HStack(spacing: 0) {
                ForEach(ThemeName.allCases) { n in
                    ThemeSwatch(name: n, selected: themeName == n.rawValue) {
                        withAnimation(.easeInOut(duration: 0.35)) { themeName = n.rawValue }
                        NotificationCenter.default.post(name: .telltaleThemeChanged, object: nil)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        Card {
            Toggle("Open Telltale at login", isOn: Binding(get: { loginOn }, set: setLogin))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            if let n = loginNote {
                Text(n).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.4)
            Picker("Temperature unit", selection: $unit) {
                Text("°F").tag("F")
                Text("°C").tag("C")
            }
            .pickerStyle(.segmented).font(.system(size: 12)).frame(maxWidth: 240)
            .onChange(of: unit) { m.refreshTempsNow() }
        }
        MenuBarSettings()
        AlertSettings()
        Card {
            HStack(spacing: 8) {
                IconBadge(symbol: "leaf.fill", colors: theme.battery, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    RollingText(text: "Using \(Fmt.mem(m.selfFootprint))", size: 13, weight: .bold, rolling: true)
                    Text("Detailed stats are collected only while this panel is open.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        HStack(spacing: 6) {
            Text("Telltale \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            Spacer()
            PillButton(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right") {
                if let u = URL(string: "https://github.com/pri-te-sh/Telltale") { NSWorkspace.shared.open(u) }
            }
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginNote = nil
        } catch {
            loginNote = "Couldn't change it: \(error.localizedDescription)"
        }
        let s = SMAppService.mainApp.status
        loginOn = s == .enabled
        if s == .requiresApproval {
            loginNote = "Approve Telltale in System Settings → General → Login Items."
        }
    }
}

struct ThemeSwatch: View {
    let name: ThemeName
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        let t = Theme.make(name)
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    if name == .system {
                        Circle().fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        Circle().fill(LinearGradient(colors: t.background, startPoint: .topLeading, endPoint: .bottomTrailing))
                        Circle().fill(LinearGradient(colors: [t.glowA, .clear, t.glowB], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(selected ? Color.white : Color.white.opacity(hover ? 0.35 : 0.15), lineWidth: selected ? 2 : 1))
                .shadow(color: (t.brand.first ?? .clear).opacity(selected ? 0.6 : 0), radius: 6)
                .scaleEffect(hover ? 1.08 : 1)
                Text(name.title).font(.system(size: 10, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: hover)
    }
}
