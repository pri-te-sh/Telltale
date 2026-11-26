// Prints the window ID of Telltale's popover panel, or nothing if it isn't on screen yet.
import CoreGraphics
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let panels = info.filter {
    guard ($0[kCGWindowOwnerName as String] as? String) == "Telltale",
          let b = $0[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
    return (b["Height"] ?? 0) > 200 && (b["Width"] ?? 0) > 200   // skip the tiny menu bar item window
}
if let id = panels.first?[kCGWindowNumber as String] as? Int { print(id) }
