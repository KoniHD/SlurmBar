import AppKit
import SwiftUI
import Testing
@testable import SlurmBar

@MainActor
struct HoverHelpTests {
    @Test func shortHintStaysCompactInsideLargeProposedFrame() {
        let view = NSHostingView(rootView: HoverHelpContent(text: "Refresh when due (minimum 30 seconds)"))
        view.setFrameSize(NSSize(width: 600, height: 1_000))
        let size = view.fittingSize
        #expect(size.width > 100 && size.width <= 296)
        #expect(size.height > 16 && size.height < 65)
    }

    @Test func partitionDetailsWrapWithoutExpandingToWidgetHeight() {
        let text = """
        Idle: 20 nodes (20.0%)
        Mixed: 10 nodes (10.0%)
        Allocated: 65 nodes (65.0%)
        Unavailable: 5 nodes (5.0%)
        240 pending. Visible queue entries; array tasks are grouped. Jobs requesting multiple partitions count in each.
        """
        let view = NSHostingView(rootView: HoverHelpContent(text: text))
        view.setFrameSize(NSSize(width: 600, height: 1_000))
        let size = view.fittingSize
        #expect(size.width > 100 && size.width <= 296)
        #expect(size.height > 65 && size.height < 200)
    }
}
