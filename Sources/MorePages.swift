import SwiftUI

extension Fmt {
    static func watts(_ w: Double) -> String {
        let a = abs(w)
        if a >= 100 { return String(format: "%.0f W", w) }
        if a >= 10 { return String(format: "%.1f W", w) }
        return String(format: "%.2f W", w)
    }
}

// MARK: - CPU: per-core grid

struct CoreGrid: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            HStack {
                SectionTitle(text: "Cores")
                Spacer()
                if let p = m.pCoreAverage {
                    coreTag("P", Fmt.pct(p), theme.cpu.last ?? .orange)
                }
                if let e = m.eCoreAverage {
                    coreTag("E", Fmt.pct(e), Color(hex: 0x4FACFE))
                }
            }
            if m.cores.isEmpty {
                Text("Measuring…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(m.cores.enumerated()), id: \.offset) { i, load in
                        let efficiency = i < Hardware.efficiencyCores
                        VStack(spacing: 3) {
                            // Fixed-height bars (no GeometryReader) keep per-second updates cheap.
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3).fill(theme.track)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(efficiency ? Color(hex: 0x5B8CFF) : (theme.cpu.last ?? .orange))
                                    .frame(height: max(2, 46 * CGFloat((min(load, 100) / 5).rounded() * 5 / 100)))
                            }
                            .frame(height: 46)
                            Text(efficiency ? "E\(i + 1)" : "P\(i + 1 - Hardware.efficiencyCores)")
                                .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .help(String(format: "%@ core %d: %.0f%%", efficiency ? "Efficiency" : "Performance", i + 1, load))
                    }
                }
            }
        }
    }

    private func coreTag(_ kind: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(kind).font(.system(size: 9, weight: .heavy)).foregroundStyle(color)
            Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - GPU

struct GPUDetail: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme

    var body: some View {
        if let g = m.gpu {
            Card {
                HStack(spacing: 16) {
                    GaugeRing(fraction: g.utilization / 100, colors: theme.gpu, lineWidth: 11) {
                        VStack(spacing: 0) {
                            RollingText(text: Fmt.pct(g.utilization), size: 22, weight: .heavy)
                            Text("busy").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 118, height: 118)
                    VStack(alignment: .leading, spacing: 9) {
                        Stat(label: "Renderer", value: Fmt.pct(g.renderer))
                        Stat(label: "Tiler", value: Fmt.pct(g.tiler))
                        Stat(label: "Memory in use", value: Fmt.mem(g.memoryInUse))
                        Stat(label: "Power", value: m.gpuPowerW.map { Fmt.watts($0) } ?? "—", tint: theme.power.last)
                    }
                }
                Sparkline(values: m.gpuHistory, maxValue: 100, colors: theme.gpu).frame(height: 44)
            }
            Text("GPU memory is shared with the rest of the system on Apple Silicon. Power comes from Apple's energy counters (IOReport).")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        } else {
            Card { Text("GPU statistics aren't available on this Mac.").foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Power & energy

struct PowerDetail: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Whole Mac").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    RollingText(text: m.power?.systemW.map { Fmt.watts($0) } ?? "—", size: 26, weight: .heavy)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(source.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Text(source.value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
            }
            Sparkline(values: m.powerHistory, maxValue: max(20, (m.powerHistory.max() ?? 0) * 1.15), colors: theme.power)
                .frame(height: 52)
            HStack {
                Stat(label: "GPU", value: m.gpuPowerW.map { Fmt.watts($0) } ?? "—", tint: theme.gpu.last)
                Stat(label: "Your apps (CPU+GPU)", value: m.appsPowerW.map { Fmt.watts($0) } ?? "—", tint: theme.cpu.first)
            }
        }
        Card {
            SectionTitle(text: "Battery & charger")
            HStack {
                Stat(label: "Battery", value: batteryFlow)
                Stat(label: "Charger rating", value: m.battery?.adapterWatts.map { "\($0) W" } ?? "—")
            }
            HStack {
                Stat(label: "Voltage", value: m.power?.voltage.map { String(format: "%.2f V", $0) } ?? "—")
                Stat(label: "Current", value: m.power?.amperage.map { String(format: "%.2f A", $0) } ?? "—")
            }
        }
        ProcessList(title: "Top apps by power", items: m.topPower, empty: "Measuring…", colors: theme.power,
                    amount: { $0.power }, value: { Fmt.watts($0.power) })
        Text("Whole-Mac power comes from the battery controller. Per-app power uses the kernel's energy counters; system services aren't included.")
            .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    private var source: (label: String, value: String) {
        if let b = m.battery, !b.onAC { return ("Source", "Battery") }
        if let w = m.power?.adapterInW { return ("From charger", Fmt.watts(w)) }
        return ("Source", "Power adapter")
    }

    private var batteryFlow: String {
        guard let w = m.power?.batteryW else { return "—" }
        if abs(w) < 0.05 { return "Idle" }
        return w > 0 ? "Charging \(Fmt.watts(w))" : "Draining \(Fmt.watts(-w))"
    }
}

// MARK: - Storage: activity

struct DiskActivityCard: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    var body: some View {
        Card {
            HStack(spacing: 14) {
                RateLabel(arrow: "arrow.down.doc", label: "Read", value: Fmt.rate(m.diskRead), color: theme.disk.first ?? .purple)
                RateLabel(arrow: "square.and.pencil", label: "Write", value: Fmt.rate(m.diskWrite), color: theme.upload.last ?? .pink)
                Spacer()
            }
            let top = max(m.diskReadHistory.max() ?? 0, m.diskWriteHistory.max() ?? 0, 100_000) * 1.15
            ZStack {
                Sparkline(values: m.diskReadHistory, maxValue: top, colors: theme.disk)
                Sparkline(values: m.diskWriteHistory, maxValue: top, colors: theme.upload, showDot: false).opacity(0.85)
            }
            .frame(height: 44)
        }
        ProcessList(title: "Top apps by disk activity", items: m.topDisk, empty: "No disk activity right now", colors: theme.disk,
                    amount: { $0.disk }, value: { Fmt.rate($0.disk) })
    }
}

// MARK: - Settings: menu bar

struct MenuBarSettings: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("menuBarItems") private var itemsRaw = ""
    @AppStorage("menuBarCharts") private var charts = true
    @AppStorage("updateInterval") private var interval = 3.0
    @State private var selected: Set<MBItem> = Set(MBItem.load())

    var body: some View {
        Card {
            SectionTitle(text: "Menu bar")
            Text("Pick what to show next to the clock. With nothing selected, Telltale shows just its icon.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 5) {
                ForEach(MBItem.allCases) { item in
                    Toggle(item.title, isOn: Binding(
                        get: { selected.contains(item) },
                        set: { on in
                            if on { selected.insert(item) } else { selected.remove(item) }
                            MBItem.save(MBItem.allCases.filter { selected.contains($0) })
                            m.menuBarSettingsChanged()
                        }))
                    .toggleStyle(.checkbox).font(.system(size: 11.5))
                }
            }
            Toggle("Mini charts", isOn: $charts)
                .toggleStyle(.checkbox).font(.system(size: 11.5))
                .onChange(of: charts) { m.menuBarSettingsChanged() }
            Divider().opacity(0.4)
            Picker("Update every", selection: $interval) {
                Text("1 s").tag(1.0)
                Text("2 s").tag(2.0)
                Text("3 s").tag(3.0)
                Text("5 s").tag(5.0)
            }
            .pickerStyle(.segmented).font(.system(size: 11.5))
            .onChange(of: interval) { m.restartBackgroundTimer() }
            Text("How often the menu bar refreshes while the panel is closed. The open panel always updates every second.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings: alerts

struct AlertSettings: View {
    @EnvironmentObject var m: Monitor
    @State private var on: [Alerts.Kind: Bool] = Dictionary(uniqueKeysWithValues: Alerts.Kind.allCases.map { ($0, Alerts.isOn($0)) })
    @State private var values: [Alerts.Kind: Double] = Dictionary(uniqueKeysWithValues: Alerts.Kind.allCases.map { ($0, Alerts.threshold($0)) })
    @State private var note: String?

    var body: some View {
        Card {
            SectionTitle(text: "Alerts")
            ForEach(Alerts.Kind.allCases) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Notify me when \(kind.title)", isOn: Binding(
                        get: { on[kind] ?? false },
                        set: { newValue in
                            m.setAlert(kind, on: newValue) { granted in
                                on[kind] = newValue && granted
                                note = newValue && !granted ? "Notifications are blocked. Allow Telltale in System Settings → Notifications." : nil
                            }
                        }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11.5))
                    if on[kind] == true {
                        HStack {
                            Text(kind == .disk ? "Below" : "Above").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { values[kind] ?? kind.defaultThreshold },
                                set: { v in values[kind] = v; UserDefaults.standard.set(v, forKey: kind.thresholdKey) }),
                                   in: kind.range, step: 1)
                            .controlSize(.mini)
                            Text(kind.format(values[kind] ?? kind.defaultThreshold))
                                .font(.system(size: 10.5, weight: .semibold)).monospacedDigit().frame(width: 46, alignment: .trailing)
                        }
                    }
                }
            }
            if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0xFB923C)).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
