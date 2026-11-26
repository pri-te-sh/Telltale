// Prints the window ID of Telltale's popover panel, or with --menubar its menu bar item.
// Prints nothing if the window isn't on screen yet.
import CoreGraphics
let wantMenuBar = CommandLine.arguments.contains("--menubar")
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let match = info.filter {
    guard ($0[kCGWindowOwnerName as String] as? String) == "Telltale",
          let b = $0[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
    let h = b["Height"] ?? 0, w = b["Width"] ?? 0
    return wantMenuBar ? (h > 10 && h < 50 && w > 20) : (h > 200 && w > 200)
}
if let id = match.first?[kCGWindowNumber as String] as? Int { print(id) }
