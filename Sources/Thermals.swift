import SwiftUI

struct ThermalsDetail: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    @AppStorage("heatAlerts") private var alertsOn = false
    @AppStorage("heatThreshold") private var threshold = 90.0
    @State private var showAll = false
    @State private var note: String?

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                GaugeRing(fraction: ((m.temps.cpu ?? 30) - 25) / 80, colors: theme.heat, lineWidth: 10) {
                    VStack(spacing: 0) {
                        RollingText(text: Fmt.temp(m.temps.cpu), size: 20, weight: .heavy, color: heatColor(m.temps.cpu), shrink: 0.6, rolling: true)
                        Text("hottest core").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 8) {
                    Stat(label: "Average across cores", value: Fmt.temp(m.temps.cpuAvg), tint: heatColor(m.temps.cpuAvg))
                    HStack {
                        Stat(label: "SoC", value: Fmt.temp(m.temps.soc), tint: heatColor(m.temps.soc))
                        Stat(label: "SSD", value: Fmt.temp(m.temps.ssd), tint: heatColor(m.temps.ssd))
                    }
                    Stat(label: "Battery", value: Fmt.temp(m.temps.battery), tint: heatColor(m.temps.battery))
                }
            }
            if m.tempHistory.count >= 3 {
                Sparkline(values: m.tempHistory, maxValue: max(100, m.tempHistory.max() ?? 0), colors: theme.heat).frame(height: 40)
            } else {
                Text("Temperature history builds up while this panel is open (or when temperature is shown in the menu bar).")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }

        Card {
            SectionTitle(text: "Fans")
            if m.fans.isEmpty {
                Text("This Mac has no fans, or they can't be read.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(m.fans) { f in
                HStack(spacing: 10) {
                    SpinningFan(rpm: f.rpm, colors: theme.network)
                    Text(m.fans.count == 2 ? (f.id == 0 ? "Left" : "Right") : "Fan \(f.id + 1)")
                        .font(.system(size: 12, weight: .medium)).frame(width: 38, alignment: .leading)
                    Meter(fraction: f.fraction, colors: theme.network, height: 5)
                    RollingText(text: f.rpm < 1 ? "Off" : String(format: "%.0f rpm", f.rpm), size: 11.5, weight: .semibold)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            if !m.fans.isEmpty {
                Text(m.fans.allSatisfy({ $0.rpm < 1 })
                     ? "Fans are off — normal for Apple Silicon at light load. Range \(rangeText)."
                     : "Fans are controlled automatically by macOS. Range \(rangeText).")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }

        Card {
            Toggle("Notify me when the CPU gets hot", isOn: Binding(get: { alertsOn }, set: { on in
                m.setHeatAlerts(on) { granted in
                    alertsOn = on && granted
                    note = on && !granted ? "Notifications are blocked. Allow Telltale in System Settings → Notifications." : nil
                }
            }))
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            if alertsOn {
                HStack {
                    Text("Alert above").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Slider(value: $threshold, in: 70...105, step: 1).controlSize(.small).tint(theme.heat.last)
                    Text(Fmt.temp(threshold)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0xFB923C)).fixedSize(horizontal: false, vertical: true) }
        }

        Card {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showAll.toggle() }
            } label: {
                HStack {
                    SectionTitle(text: "All sensors (\(m.temps.all.count))")
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAll ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showAll {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 5) {
                        ForEach(Array(m.temps.all.enumerated()), id: \.offset) { _, s in
                            HStack(spacing: 6) {
                                Circle().fill(heatColor(s.value)).frame(width: 5, height: 5)
                                Text(s.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Fmt.temp(s.value)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            }
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
        }
    }

    private var rangeText: String {
        guard let lo = m.fans.map(\.minRPM).min(), let hi = m.fans.map(\.maxRPM).max() else { return "—" }
        return String(format: "%.0f–%.0f rpm", lo, hi)
    }
}

/// Fan badge: coloured while running, grey when off. (No perpetual spin: it would redraw 120×/s.)
struct SpinningFan: View {
    let rpm: Double
    let colors: [Color]
    var body: some View {
        IconBadge(symbol: "fan.fill", colors: rpm < 1 ? [Color.gray.opacity(0.7), Color.gray.opacity(0.45)] : colors, size: 24)
            .rotationEffect(.degrees(rpm < 1 ? 0 : 22))
    }
}
