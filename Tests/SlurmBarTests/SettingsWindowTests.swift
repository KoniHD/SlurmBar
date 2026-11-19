import CoreGraphics
import Testing
@testable import SlurmBar

struct SettingsWindowTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func windowCoveringWholeDisplayMeansFullScreen() {
        let windows = [OnScreenWindow(ownerPID: 42, layer: 0, bounds: screen)]
        #expect(FullScreenDetector.isFullScreen(windows: windows, screen: screen, excludingPID: 1))
    }

    @Test func maximisedWindowBelowMenuBarIsNotFullScreen() {
        let windows = [OnScreenWindow(ownerPID: 42, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 949))]
        #expect(!FullScreenDetector.isFullScreen(windows: windows, screen: screen, excludingPID: 1))
    }

    @Test func ownAndOverlayWindowsAreIgnored() {
        let windows = [
            OnScreenWindow(ownerPID: 1, layer: 0, bounds: screen),
            OnScreenWindow(ownerPID: 42, layer: 25, bounds: screen),
        ]
        #expect(!FullScreenDetector.isFullScreen(windows: windows, screen: screen, excludingPID: 1))
    }

    @Test func fullScreenOnSecondDisplayIsMatchedToThatDisplay() {
        let second = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let windows = [OnScreenWindow(ownerPID: 42, layer: 0, bounds: second)]
        #expect(FullScreenDetector.isFullScreen(windows: windows, screen: second, excludingPID: 1))
        #expect(!FullScreenDetector.isFullScreen(windows: windows, screen: screen, excludingPID: 1))
    }
}
