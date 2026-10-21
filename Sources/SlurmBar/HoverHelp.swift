import SwiftUI

private struct InstantHelp: ViewModifier {
    let text: String
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovered = $0 }
            .popover(isPresented: $isHovered, arrowEdge: .trailing) {
                HoverHelpContent(text: text)
            }
            .onDisappear { isHovered = false }
    }
}

/// Keep the popover's root at its content size. A flexible root can inherit the
/// menu widget's proposed height, turning a short hint into a window-sized bubble.
struct HoverHelpContent: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .frame(width: 280, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .fixedSize()
            .allowsHitTesting(false)
    }
}

extension View {
    func instantHelp(_ text: String) -> some View {
        modifier(InstantHelp(text: text))
    }
}
