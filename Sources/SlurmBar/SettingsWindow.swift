import AppKit
import SwiftUI

/// A visible window from another app, in Quartz coordinates (origin at the top-left of the main display).
struct OnScreenWindow: Equatable {
    var ownerPID: pid_t
    var layer: Int
    var bounds: CGRect
}

enum FullScreenDetector {
    /// A full-screen Space shows a normal-layer window covering the whole display, menu bar area included.
    /// Maximised windows stop below the menu bar, so they do not match.
    static func isFullScreen(windows: [OnScreenWindow], screen: CGRect, excludingPID pid: pid_t) -> Bool {
        windows.contains { window in
            window.ownerPID != pid && window.layer == 0
                && abs(window.bounds.minX - screen.minX) < 1 && abs(window.bounds.minY - screen.minY) < 1
                && abs(window.bounds.width - screen.width) < 1 && abs(window.bounds.height - screen.height) < 1
        }
    }

    /// Reads window bounds and owners only, which needs no screen-recording permission.
    @MainActor static func activeSpaceIsFullScreen() -> Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let mainHeight = NSScreen.screens.first?.frame.maxY,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let frame = screen.frame
        let quartzFrame = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        let windows = info.compactMap { entry -> OnScreenWindow? in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { return nil }
            return OnScreenWindow(ownerPID: pid, layer: layer, bounds: bounds)
        }
        return isFullScreen(windows: windows, screen: quartzFrame, excludingPID: ProcessInfo.processInfo.processIdentifier)
    }
}

/// Keeps Settings on the current Space, including above a full-screen app, and closes it
/// when focus moves to another app while it is shown over a full-screen app.
@MainActor
final class SettingsWindowController {
    private weak var window: NSWindow?
    private var closesOnFocusLoss = false
    private var observers: [NSObjectProtocol] = []

    func open(_ openWindow: OpenWindowAction) {
        closesOnFocusLoss = FullScreenDetector.activeSpaceIsFullScreen()
        if let window { configure(window) }
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    func attach(_ window: NSWindow) {
        configure(window)
        guard window !== self.window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        self.window = window
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusMayHaveLeft() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusMayHaveLeft() }
            },
        ]
    }

    private func configure(_ window: NSWindow) {
        window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenNone, .canJoinAllSpaces])
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
    }

    private func focusMayHaveLeft() {
        // Wait one turn so the new key window is known; the socket picker and the dashboard keep Settings open.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.closesOnFocusLoss, let window = self.window, window.isVisible,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !NSApp.isActive || NSApp.keyWindow == nil else { return }
            window.close()
        }
    }
}

/// Hands the hosting NSWindow to the controller as soon as SwiftUI places the view in it.
struct SettingsWindowAccessor: NSViewRepresentable {
    let controller: SettingsWindowController

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {
        view.controller = controller
        if let window = view.window { controller.attach(window) }
    }

    final class AccessorView: NSView {
        var controller: SettingsWindowController?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { controller?.attach(window) }
        }
    }
}
