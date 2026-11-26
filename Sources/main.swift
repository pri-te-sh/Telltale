import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let monitor = Monitor.shared
    private var lastClose = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Telltale")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
        // Testing aid: with --open the panel stays put even when another app takes focus (used by scripts/screenshots.sh).
        popover.behavior = CommandLine.arguments.contains("--open") ? .applicationDefined : .transient
        popover.animates = true
        popover.delegate = self

        monitor.onMenuBarUpdate = { [weak self] text in self?.setTitle(text) }
        monitor.startBackground()
        NotificationCenter.default.addObserver(forName: .telltaleThemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyAppearance()
        }

        if CommandLine.arguments.contains("--open") {   // testing aid: open the panel on launch
            let delay = CommandLine.arguments.first { $0.hasPrefix("--open-after=") }.flatMap { Double($0.dropFirst(13)) } ?? 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.togglePanel(nil) }
        }
    }

    /// Gradient themes are designed for dark glass; the System theme follows light/dark mode.
    private func applyAppearance() {
        popover.appearance = Theme.current.isSystem ? nil : NSAppearance(named: .darkAqua)
    }

    private func setTitle(_ text: String?) {
        guard let button = statusItem.button else { return }
        if let text {
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                .baselineOffset: 0.5,
            ])
        } else {
            button.title = ""
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // A click on the icon while open first closes the transient popover; don't instantly reopen it.
        if Date().timeIntervalSince(lastClose) < 0.25 { return }
        guard let button = statusItem.button else { return }

        // The view tree is created on open and released on close to keep idle memory low.
        // Testing aid: `--panel=memory` opens straight into a detail page.
        let initial = CommandLine.arguments.first { $0.hasPrefix("--panel=") }
            .flatMap { Panel(rawValue: String($0.dropFirst("--panel=".count))) }
        let host = NSHostingController(rootView: RootView(initial: initial).environmentObject(monitor))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        applyAppearance()
        monitor.setPanelOpen(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
        monitor.setPanelOpen(false)
        popover.contentViewController = nil
        ThemeBackground.clearCache()
    }
}

// `Telltale --selftest` prints one full set of readings and exits (used to verify the data sources).
if CommandLine.arguments.contains("--selftest") {
    let m = Monitor.shared
    m.startBackground()
    m.setPanelOpen(true)
    RunLoop.main.run(until: Date().addingTimeInterval(2.5))
    print("cpu", Fmt.pct(m.cpuTotal), "user", Fmt.pct(m.cpuUser), "sys", Fmt.pct(m.cpuSystem), "temp", Fmt.temp(m.temps.cpu))
    print("mem free", Fmt.mem(m.mem.available), "app", Fmt.mem(m.mem.app), "wired", Fmt.mem(m.mem.wired),
          "compressed", Fmt.mem(m.mem.compressed), "pressure", m.mem.pressure, "swap", Fmt.mem(m.mem.swapUsed))
    if let d = m.disk { print("disk", d.name, "avail", Fmt.disk(d.available), "freeNow", Fmt.disk(d.freeNow), "total", Fmt.disk(d.total)) }
    if let b = m.battery {
        print("battery", b.percent, "charging", b.isCharging, "ac", b.onAC, "cycles", b.cycles ?? -1, "/", b.designCycles,
              "health", b.health.map { Fmt.pct($0 * 100) } ?? "-", "adapter", b.adapterWatts ?? 0, "temp", Fmt.temp(m.temps.battery))
    }
    print("fans", m.fans.map { "\($0.id):\(Int($0.rpm))rpm [\(Int($0.minRPM))-\(Int($0.maxRPM))]" }, "soc", Fmt.temp(m.temps.soc), "sensors", m.temps.all.count)
    print("ssd temp", Fmt.temp(m.temps.ssd), "thermal", m.thermal.rawValue, "uptime", Fmt.duration(m.uptime), "load", m.load)
    print("wifi", m.wifi?.ssid ?? "(name hidden)", m.wifi?.rssi ?? 0, m.wifi?.security ?? "-", "ip", m.ipAddress ?? "-",
          "down", Fmt.rate(m.netDown), "up", Fmt.rate(m.netUp), "total", Fmt.disk(m.netTotalDown), Fmt.disk(m.netTotalUp))
    print("top mem:", m.topMemory.map { "\($0.name)=\(Fmt.mem($0.memory))" }.joined(separator: ", "))
    print("top cpu:", m.topCPU.map { "\($0.name)=\(String(format: "%.1f", $0.cpu))%" }.joined(separator: ", "))
    print("bluetooth:", m.bluetooth.map { "\($0.name) [\($0.kind)] \($0.batteries.map { "\($0.label)\($0.percent)%" })" })
    print("drives:", m.drives.map { $0.name }, "quittable apps:", m.quittable.count)
    print("self footprint", Fmt.mem(SysInfo.selfFootprint()))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
