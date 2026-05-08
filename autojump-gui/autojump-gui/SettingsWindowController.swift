import AppKit
import SwiftUI

/// Hosts `SettingsView` in a plain NSWindow. Required because `LSUIElement = YES`
/// breaks SwiftUI's `Settings` scene + `showSettingsWindow:` path: there's no main
/// menu bar to register the selector against, and the resulting window often won't
/// come to the front.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 580, height: 560))
            w.contentMinSize = NSSize(width: 460, height: 360)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
