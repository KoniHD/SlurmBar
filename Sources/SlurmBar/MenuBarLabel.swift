import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let title: String
    let runningJobCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if runningJobCount > 0 {
            Image(nsImage: MenuBarIcon.image(runningJobCount: runningJobCount, dark: colorScheme == .dark))
                .renderingMode(.original)
                .accessibilityLabel("\(title), \(runningJobCount) running jobs")
        } else {
            Image(systemName: "server.rack")
                .accessibilityLabel(title)
        }
    }
}

@MainActor
enum MenuBarIcon {
    static func image(runningJobCount: Int, dark: Bool) -> NSImage {
        let count = (runningJobCount > 99 ? "99+" : String(runningJobCount)) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let countSize = count.size(withAttributes: attributes)
        let badge = NSRect(x: 11, y: 5, width: max(13, ceil(countSize.width) + 6), height: 13)
        let symbol = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(paletteColors: [dark ? .white : .black]))!
        // Bake the number into an original-color image so template rendering
        // doesn't discard the green color.
        let image = NSImage(size: NSSize(width: badge.maxX, height: 18), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
            NSColor(srgbRed: 0, green: 0.48, blue: 0.16, alpha: 1).setFill()
            NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
            count.draw(at: NSPoint(x: badge.midX - countSize.width / 2,
                                   y: badge.midY - countSize.height / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }
}
