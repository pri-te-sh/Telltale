import AppKit

/// Readouts that can be shown in the menu bar.
enum MBItem: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, disk, network, temperature, power, battery
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU load"
        case .gpu: return "GPU load"
        case .memory: return "Memory"
        case .disk: return "Disk activity"
        case .network: return "Network"
        case .temperature: return "CPU temperature"
        case .power: return "Power draw"
        case .battery: return "Battery"
        }
    }
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "MEM"
        case .disk: return "DISK"
        case .network: return "NET"
        case .temperature: return "TEMP"
        case .power: return "POWER"
        case .battery: return "BAT"
        }
    }
    var hasChart: Bool { [.cpu, .gpu, .memory, .temperature, .power].contains(self) }

    /// Saved order is the order of `allCases`; the setting is a comma-separated list of raw values.
    static func load() -> [MBItem] {
        let d = UserDefaults.standard
        if d.object(forKey: "menuBarItems") == nil {
            // Migrate the single-choice setting from 0.1.0.
            switch d.integer(forKey: "menuBarMode") {
            case 1: return [.cpu]
            case 2: return [.cpu, .memory]
            case 3: return [.temperature]
            case 4: return [.cpu, .temperature]
            default: return []
            }
        }
        let set = Set((d.string(forKey: "menuBarItems") ?? "").split(separator: ",").map(String.init))
        return allCases.filter { set.contains($0.rawValue) }
    }

    static func save(_ items: [MBItem]) {
        UserDefaults.standard.set(items.map(\.rawValue).joined(separator: ","), forKey: "menuBarItems")
    }
}

/// Draws the selected readouts into one template image (black; macOS tints it for light/dark menu bars).
enum MenuBarRenderer {
    private struct Block {
        var label: String?
        var lines: [String]          // 1 line = big value, 2 lines = compact pair
        var chart: [Double]?         // normalised 0...1
    }

    private static let labelFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    private static let pairFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
    private static let chartBars = 12
    private static let height: CGFloat = 22

    /// Returns a signature (to skip redundant redraws) and the image. `nil` when nothing is selected.
    static func render(items: [MBItem], charts: Bool, m: Monitor) -> (signature: String, image: NSImage)? {
        guard !items.isEmpty else { return nil }
        let blocks = items.map { block(for: $0, charts: charts, m: m) }
        let signature = blocks.map { b in
            (b.label ?? "") + b.lines.joined(separator: "|") + (b.chart?.map { String(Int($0 * 7)) }.joined() ?? "")
        }.joined(separator: "·")

        let widths = blocks.map(width(of:))
        let total = widths.reduce(0, +) + CGFloat(max(0, blocks.count - 1)) * 9
        let size = NSSize(width: ceil(total), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (i, b) in blocks.enumerated() {
                draw(b, at: x)
                x += widths[i] + 9
            }
            return true
        }
        image.isTemplate = true
        return (signature, image)
    }

    private static func block(for item: MBItem, charts: Bool, m: Monitor) -> Block {
        func last(_ a: [Double], _ lo: Double, _ hi: Double) -> [Double]? {
            guard charts, item.hasChart else { return nil }
            return a.suffix(chartBars).map { min(max(($0 - lo) / max(hi - lo, 0.0001), 0), 1) }
        }
        switch item {
        case .cpu:
            return Block(label: "CPU", lines: [String(format: "%.0f%%", m.cpuTotal)], chart: last(m.cpuHistory, 0, 100))
        case .gpu:
            return Block(label: "GPU", lines: [String(format: "%.0f%%", m.gpu?.utilization ?? 0)], chart: last(m.gpuHistory, 0, 100))
        case .memory:
            return Block(label: "MEM", lines: [String(format: "%.0f%%", m.mem.usedPercent)], chart: last(m.memHistory, 0, 100))
        case .temperature:
            return Block(label: "TEMP", lines: [Fmt.temp(m.temps.cpu)], chart: last(m.tempHistory, 30, 100))
        case .power:
            let w = m.power?.systemW
            let top = max(30, m.powerHistory.max() ?? 0)
            return Block(label: "POWER", lines: [w.map { $0 >= 10 ? String(format: "%.0fW", $0) : String(format: "%.1fW", $0) } ?? "—"],
                         chart: last(m.powerHistory, 0, top))
        case .battery:
            return Block(label: "BAT", lines: [m.battery.map { "\($0.percent)%" } ?? "—"], chart: nil)
        case .network:
            return Block(label: nil, lines: ["↑ " + Fmt.compactRate(m.netUp), "↓ " + Fmt.compactRate(m.netDown)], chart: nil)
        case .disk:
            return Block(label: nil, lines: ["R " + Fmt.compactRate(m.diskRead), "W " + Fmt.compactRate(m.diskWrite)], chart: nil)
        }
    }

    private static func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    private static func width(of b: Block) -> CGFloat {
        let chartW: CGFloat = b.chart == nil ? 0 : CGFloat(chartBars) * 2.5 + 3
        let textW: CGFloat
        if b.lines.count == 2 {
            textW = max(textWidth(b.lines[0], pairFont), textWidth(b.lines[1], pairFont), 44)   // fixed-ish so it doesn't jiggle
        } else {
            textW = max(textWidth(b.label ?? "", labelFont), textWidth(b.lines.first ?? "", valueFont), 26)
        }
        return chartW + textW
    }

    private static func draw(_ b: Block, at x0: CGFloat) {
        var x = x0
        NSColor.black.setFill()
        if let chart = b.chart {
            let barW: CGFloat = 1.8, gap: CGFloat = 0.7, maxH: CGFloat = 14, base: CGFloat = 4
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: NSRect(x: x, y: base - 1, width: CGFloat(chartBars) * (barW + gap), height: 0.6)).fill()
            NSColor.black.setFill()
            let padded = Array(repeating: 0.0, count: max(0, chartBars - chart.count)) + chart
            for (i, v) in padded.enumerated() {
                let h = max(0.8, CGFloat(v) * maxH)
                NSBezierPath(rect: NSRect(x: x + CGFloat(i) * (barW + gap), y: base, width: barW, height: h)).fill()
            }
            x += CGFloat(chartBars) * 2.5 + 3
        }
        let black: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black]
        if b.lines.count == 2 {
            var a = black; a[.font] = pairFont
            (b.lines[0] as NSString).draw(at: NSPoint(x: x, y: 11), withAttributes: a)
            (b.lines[1] as NSString).draw(at: NSPoint(x: x, y: 1), withAttributes: a)
        } else {
            if let label = b.label {
                var a = black; a[.font] = labelFont
                (label as NSString).draw(at: NSPoint(x: x, y: 13.5), withAttributes: a)
            }
            var a = black; a[.font] = valueFont
            ((b.lines.first ?? "") as NSString).draw(at: NSPoint(x: x, y: -0.5), withAttributes: a)
        }
    }
}

extension Fmt {
    /// Very short rate for the menu bar: "512B", "8.4K", "312K", "2.1M".
    static func compactRate(_ bps: Double) -> String {
        let b = max(0, bps)
        if b < 1_000 { return String(format: "%.0fB", b) }
        if b < 10_000 { return String(format: "%.1fK", b / 1_000) }
        if b < 1_000_000 { return String(format: "%.0fK", b / 1_000) }
        if b < 10_000_000 { return String(format: "%.1fM", b / 1_000_000) }
        if b < 1_000_000_000 { return String(format: "%.0fM", b / 1_000_000) }
        return String(format: "%.1fG", b / 1_000_000_000)
    }
}
