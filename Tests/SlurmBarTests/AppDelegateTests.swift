import AppKit
import Foundation
import Testing
@testable import SlurmBar

@MainActor
struct AppDelegateTests {
    @Test func closingLastWindowKeepsMenuBarAppRunning() throws {
        let suite = "SlurmBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate(model: AppModel(defaults: defaults, startMonitoring: false))
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        #expect(!delegate.quitCoordinator.isQuitting)
    }
}
