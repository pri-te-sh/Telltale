import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

enum ThemeName: String, CaseIterable, Identifiable {
    case aurora, sunset, ocean, graphite, system
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Theme {
    let name: ThemeName
    let background: [Color]
    let glowA: Color
    let glowB: Color
    // Two-stop gradients per metric
    let cpu: [Color]
    let memory: [Color]
    let disk: [Color]
    let battery: [Color]
    let network: [Color]
    let upload: [Color]
    let heat: [Color]
    let devices: [Color]
    let brand: [Color]

    var isSystem: Bool { name == .system }
    /// Card fill and border adapt so the System theme still works in light mode.
    var cardFill: Color { isSystem ? Color.primary.opacity(0.055) : Color.white.opacity(0.065) }
    var cardFillHover: Color { isSystem ? Color.primary.opacity(0.09) : Color.white.opacity(0.11) }
    var cardBorder: [Color] { isSystem ? [Color.primary.opacity(0.10), Color.primary.opacity(0.03)]
                                       : [Color.white.opacity(0.20), Color.white.opacity(0.03)] }
    var track: Color { isSystem ? Color.primary.opacity(0.08) : Color.white.opacity(0.09) }

    static var current: Theme {
        make(ThemeName(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .aurora)
    }

    static func make(_ n: ThemeName) -> Theme {
        // Metric colours are shared; each theme mainly changes the backdrop and brand glow.
        let cpu = [Color(hex: 0xFFB347), Color(hex: 0xFF5E62)]
        let mem = [Color(hex: 0x4FACFE), Color(hex: 0x6A5CFF)]
        let disk = [Color(hex: 0xC471F5), Color(hex: 0xFA71CD)]
        let bat = [Color(hex: 0x7EE8A2), Color(hex: 0x1FB86B)]
        let net = [Color(hex: 0x2AF5D2), Color(hex: 0x00B4DB)]
        let up = [Color(hex: 0xFF9A9E), Color(hex: 0xF5576C)]
        let heat = [Color(hex: 0xFFD166), Color(hex: 0xFF4B2B)]
        let dev = [Color(hex: 0xF093FB), Color(hex: 0xF5576C)]
        switch n {
        case .aurora:
            return Theme(name: n, background: [Color(hex: 0x1A1038), Color(hex: 0x14204A), Color(hex: 0x0B3340)],
                         glowA: Color(hex: 0x8B5CF6, opacity: 0.55), glowB: Color(hex: 0x14B8A6, opacity: 0.40),
                         cpu: cpu, memory: mem, disk: disk, battery: bat, network: net, upload: up, heat: heat, devices: dev,
                         brand: [Color(hex: 0x8B5CF6), Color(hex: 0x22D3EE)])
        case .sunset:
            return Theme(name: n, background: [Color(hex: 0x2A0F35), Color(hex: 0x4A1538), Color(hex: 0x3A1A12)],
                         glowA: Color(hex: 0xFF5F6D, opacity: 0.50), glowB: Color(hex: 0xFFC371, opacity: 0.35),
                         cpu: cpu, memory: mem, disk: disk, battery: bat, network: net, upload: up, heat: heat, devices: dev,
                         brand: [Color(hex: 0xFF5F6D), Color(hex: 0xFFC371)])
        case .ocean:
            return Theme(name: n, background: [Color(hex: 0x041527), Color(hex: 0x082A4D), Color(hex: 0x03404A)],
                         glowA: Color(hex: 0x0EA5E9, opacity: 0.50), glowB: Color(hex: 0x2DD4BF, opacity: 0.38),
                         cpu: cpu, memory: mem, disk: disk, battery: bat, network: net, upload: up, heat: heat, devices: dev,
                         brand: [Color(hex: 0x0EA5E9), Color(hex: 0x2DD4BF)])
        case .graphite:
            return Theme(name: n, background: [Color(hex: 0x15171C), Color(hex: 0x1D2129), Color(hex: 0x121418)],
                         glowA: Color(hex: 0x64748B, opacity: 0.35), glowB: Color(hex: 0x94A3B8, opacity: 0.18),
                         cpu: cpu, memory: mem, disk: disk, battery: bat, network: net, upload: up, heat: heat, devices: dev,
                         brand: [Color(hex: 0x94A3B8), Color(hex: 0xE2E8F0)])
        case .system:
            return Theme(name: n, background: [], glowA: .clear, glowB: .clear,
                         cpu: cpu, memory: mem, disk: disk, battery: bat, network: net, upload: up, heat: heat, devices: dev,
                         brand: [Color(hex: 0x6A5CFF), Color(hex: 0x22D3EE)])
        }
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.make(.aurora) }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Static backdrop: gradient plus two soft glows. The blur is expensive, so it is rendered once per theme
/// into a bitmap and reused; redraws then only copy pixels. (Cache is dropped when the panel closes.)
struct ThemeBackground: View {
    let theme: Theme
    private static var cache: [ThemeName: NSImage] = [:]

    static func clearCache() { cache.removeAll() }

    var body: some View {
        if theme.isSystem {
            Color.clear
        } else if let img = Self.image(for: theme) {
            Image(nsImage: img).resizable().allowsHitTesting(false)
        } else {
            LinearGradient(colors: theme.background, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    @MainActor private static func image(for t: Theme) -> NSImage? {
        if let i = cache[t.name] { return i }
        let art = ZStack {
            LinearGradient(colors: t.background, startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(t.glowA).frame(width: 300, height: 300).blur(radius: 90).offset(x: -150, y: -260)
            Circle().fill(t.glowB).frame(width: 280, height: 280).blur(radius: 100).offset(x: 160, y: 260)
        }
        .frame(width: 452, height: 860)
        .clipped()
        let r = ImageRenderer(content: art)
        r.scale = 1   // soft gradients look identical at 1×; keeps the bitmap small (~1.5 MB)
        guard let cg = r.cgImage else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: 452, height: 860))
        cache[t.name] = img
        return img
    }
}

/// Glassy card surface used everywhere.
struct GlassSurface: ViewModifier {
    @Environment(\.theme) private var theme
    var radius: CGFloat = 14
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(highlighted ? theme.cardFillHover : theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: theme.cardBorder, startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
    }
}

extension View {
    func glass(radius: CGFloat = 14, highlighted: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, highlighted: highlighted))
    }
}

/// Gradient rounded-square badge with a white SF Symbol, like an app-icon chip.
struct IconBadge: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 22
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}
