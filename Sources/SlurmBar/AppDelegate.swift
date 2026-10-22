import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let quitCoordinator = QuitCoordinator()

    override convenience init() {
        self.init(model: AppModel())
    }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Picker menus and the dashboard are transient windows. Closing one
        // must leave this menu bar app running until the user explicitly quits.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitCoordinator.quit(hideUI: {
            // The coordinator also removes the MenuBarExtra via its insertion binding.
            // Hide every window now, including Settings and any hover popover.
            for window in sender.windows { window.orderOut(nil) }
        }, stopMonitoring: { [model] in
            await model.stopMonitoring()
        }, terminate: {
            sender.reply(toApplicationShouldTerminate: true)
        })
        // Acknowledge Quit to macOS while asynchronous cancellation finishes.
        return .terminateLater
    }
}
