import SwiftUI
import AppKit

// MARK: - Formatting

enum Fmt {
    private static let fileFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false; return f
    }()
    private static let memFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .memory; f.allowsNonnumericFormatting = false; return f
    }()

    static func disk(_ b: UInt64) -> String { fileFmt.string(fromByteCount: Int64(clamping: b)) }
    static func mem(_ b: UInt64) -> String { memFmt.string(fromByteCount: Int64(clamping: b)) }
    /// Compact, fixed-ish width: "512 B/s", "8.4 KB/s", "312 KB/s", "2.1 MB/s".
    static func rate(_ bps: Double) -> String {
        let b = max(0, bps)
        if b < 1_000 { return String(format: "%.0f B/s", b) }
        if b < 10_000 { return String(format: "%.1f KB/s", b / 1_000) }
        if b < 1_000_000 { return String(format: "%.0f KB/s", b / 1_000) }
        if b < 1_000_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        return String(format: "%.2f GB/s", b / 1_000_000_000)
    }
    static func mbps(_ bitsPerSecond: Double) -> String {
        let m = bitsPerSecond / 1_000_000
        return m >= 100 ? String(format: "%.0f Mbps", m) : String(format: "%.1f Mbps", m)
    }
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    static var defaultUnit: String { Locale.current.measurementSystem == .us ? "F" : "C" }
    static func temp(_ c: Double?) -> String {
        guard let c else { return "—" }
        let unit = UserDefaults.standard.string(forKey: "tempUnit") ?? defaultUnit
        return unit == "F" ? String(format: "%.0f°F", c * 9 / 5 + 32) : String(format: "%.0f°C", c)
    }
    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s) / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }
    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
}

// MARK: - Text helpers

/// A number that rolls digit-by-digit when it changes.
struct RollingText: View {
    let text: String
    var size: CGFloat = 17
    var weight: Font.Weight = .bold
    var color: Color? = nil
    var shrink: CGFloat = 1        // < 1 lets it shrink to fit tight spaces (gauge centres)
    var rolling = false            // animate digit changes; only for values that change rarely (keeps CPU low)
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color ?? .primary)
            .contentTransition(rolling ? .numericText() : .identity)
            .animation(rolling ? .snappy(duration: 0.3) : nil, value: text)
            .lineLimit(1)
            .minimumScaleFactor(shrink)
            .fixedSize(horizontal: shrink >= 1, vertical: false)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary).kerning(0.8)
    }
}

struct Stat: View {
    let label: String
    let value: String
    var tint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            RollingText(text: value, size: 13.5, weight: .semibold, color: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    var spacing: CGFloat = 9
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass()
    }
}

/// A tappable glass card with a hover lift.
struct TapCard<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6, content: content)
                .padding(11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .glass(highlighted: hover)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.018 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - Charts

/// Circular gauge with an angular gradient, rounded caps and a soft glow.
struct GaugeRing<Center: View>: View {
    @Environment(\.theme) private var theme
    @State private var shown = false
    var fraction: Double
    var colors: [Color]
    var lineWidth: CGFloat = 8
    @ViewBuilder var center: () -> Center

    var body: some View {
        // Rounded to whole percents so the ring only animates on visible changes.
        let f = shown ? (min(max(fraction, 0), 1) * 100).rounded() / 100 : 0
        let gradient = AngularGradient(colors: colors, center: .center,
                                       startAngle: .degrees(0), endAngle: .degrees(360 * max(f, 0.05)))
        ZStack {
            Circle().stroke(theme.track, lineWidth: lineWidth)
            // Cheap "glow": a wide, faint stroke under the arc instead of a blurred shadow.
            Circle()
                .trim(from: 0, to: max(f, 0.004))
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth * 2.1, lineCap: .round))
                .opacity(0.16)
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: max(f, 0.004))
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .padding(lineWidth / 2)
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { shown = true } }   // sweep in once; live updates snap
    }
}

/// Multi-segment ring (memory breakdown).
struct Ring<Center: View>: View {
    @Environment(\.theme) private var theme
    @State private var shown = false
    var segments: [(Double, Color)]
    var lineWidth: CGFloat = 12
    @ViewBuilder var center: () -> Center

    private var arcs: [(start: Double, end: Double, color: Color)] {
        var acc = 0.0
        return segments.map { seg in
            let s = acc
            acc = min(1, acc + max(0, seg.0))
            return (s * (shown ? 1 : 0), acc * (shown ? 1 : 0), seg.1)
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: lineWidth)
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, a in
                Circle().trim(from: a.start, to: max(a.start, a.end - 0.006))
                    .stroke(a.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            center()
        }
        .padding(lineWidth / 2)
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { shown = true } }
    }
}

/// Smoothed area chart with a gradient stroke and a glowing "now" dot.
struct Sparkline: View {
    @Environment(\.theme) private var theme
    var values: [Double]
    var maxValue: Double? = nil
    var colors: [Color]
    var slots = 60
    var showDot = true

    var body: some View {
        GeometryReader { g in
            let top = max(maxValue ?? (values.max() ?? 1) * 1.15, 0.0001)
            let step = g.size.width / CGFloat(max(slots - 1, 1))
            let start = g.size.width - step * CGFloat(max(values.count - 1, 0))
            let h = g.size.height
            let pts = values.enumerated().map { i, v in
                CGPoint(x: start + step * CGFloat(i), y: 2 + (h - 4) * (1 - CGFloat(min(max(v, 0), top) / top)))
            }
            ZStack(alignment: .topLeading) {
                if pts.count > 1 {
                    let line = Self.smooth(pts)
                    Self.area(line, pts, h).fill(LinearGradient(colors: [(colors.last ?? .clear).opacity(0.35), (colors.first ?? .clear).opacity(0.0)],
                                             startPoint: .top, endPoint: .bottom))
                    line.stroke(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    if showDot, let last = pts.last {
                        Circle().fill((colors.last ?? .white).opacity(0.25)).frame(width: 11, height: 11).position(last)
                        Circle().fill(colors.last ?? .white).frame(width: 5, height: 5).position(last)
                    }
                } else {
                    Capsule().fill(theme.track).frame(height: 2).frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    static func area(_ line: Path, _ pts: [CGPoint], _ h: CGFloat) -> Path {
        var a = line
        a.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: h))
        a.addLine(to: CGPoint(x: pts[0].x, y: h))
        a.closeSubpath()
        return a
    }

    static func smooth(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            p.addQuadCurve(to: mid, control: a)
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }
}

struct Meter: View {
    @Environment(\.theme) private var theme
    @State private var shown = false
    var fraction: Double
    var colors: [Color]
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * CGFloat(shown ? (min(max(fraction, 0), 1) * 100).rounded() / 100 : 0)))
            }
        }
        .frame(height: height)
        .onAppear { withAnimation(.easeOut(duration: 0.8)) { shown = true } }
    }
}

// MARK: - Controls

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 26)
                .glass(radius: 8, highlighted: hover)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hover = $0 }
    }
}

struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var colors: [Color]? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background {
                if let colors {
                    Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .opacity(hover ? 1 : 0.85)
                }
            }
            .glass(radius: 13, highlighted: hover)
            .foregroundStyle(colors == nil ? Color.primary : Color.white)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Process list

struct ProcessList: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.theme) private var theme
    let title: String
    let items: [AppUsage]
    let empty: String
    let colors: [Color]
    let amount: (AppUsage) -> Double
    let value: (AppUsage) -> String

    var body: some View {
        Card {
            SectionTitle(text: title)
            if items.isEmpty {
                Text(empty).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            let top = max(items.map(amount).max() ?? 1, 0.0001)
            ForEach(items) { a in
                HStack(spacing: 9) {
                    Group {
                        if let img = m.icon(for: a) {
                            Image(nsImage: img).resizable()
                        } else {
                            IconBadge(symbol: "terminal", colors: [Color.gray.opacity(0.7), Color.gray.opacity(0.4)], size: 20)
                        }
                    }
                    .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(a.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            if a.processCount > 1 {
                                Text("×\(a.processCount)").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 6)
                            RollingText(text: value(a), size: 11.5, weight: .semibold, color: .secondary)
                        }
                        Meter(fraction: amount(a) / top, colors: colors, height: 3)
                    }
                    if m.canQuit(a) {
                        QuitChip { m.quit(a) }
                    } else {
                        Color.clear.frame(width: 40, height: 1)
                    }
                }
            }
        }
    }
}

struct QuitChip: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text("Quit").font(.system(size: 10, weight: .bold))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(hover ? Color.red.opacity(0.85) : Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                .foregroundStyle(hover ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 40)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - Helpers

func batterySymbol(_ b: BatteryInfo?) -> String {
    guard let b else { return "battery.0percent" }
    if b.isCharging { return "battery.100percent.bolt" }
    switch b.percent {
    case 88...: return "battery.100percent"
    case 63..<88: return "battery.75percent"
    case 38..<63: return "battery.50percent"
    case 13..<38: return "battery.25percent"
    default: return "battery.0percent"
    }
}

func pressureColor(_ p: Int) -> Color { p < 50 ? Color(hex: 0x4ADE80) : (p < 80 ? Color(hex: 0xFACC15) : Color(hex: 0xF87171)) }

func heatColor(_ c: Double?) -> Color {
    guard let c else { return .secondary }
    switch c {
    case ..<60: return Color(hex: 0x4ADE80)
    case ..<80: return Color(hex: 0xFACC15)
    case ..<95: return Color(hex: 0xFB923C)
    default: return Color(hex: 0xF87171)
    }
}
