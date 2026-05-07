import AppKit
import ApplicationServices

@MainActor
final class FinderAXObserver {
    private let pid: pid_t
    private let appElement: AXUIElement
    private var observer: AXObserver?
    private var observedWindow: AXUIElement?
    private let onChange: () -> Void

    private static let appNotifications: [String] = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification,
    ]

    init?(pid: pid_t, onChange: @escaping () -> Void) {
        guard AXIsProcessTrusted() else { return nil }

        self.pid = pid
        self.appElement = AXUIElementCreateApplication(pid)
        self.onChange = onChange

        var ref: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FinderAXObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            Task { @MainActor in
                if name == (kAXFocusedWindowChangedNotification as String) ||
                   name == (kAXMainWindowChangedNotification as String) ||
                   name == (kAXWindowCreatedNotification as String) {
                    me.subscribeFocusedWindow()
                }
                me.onChange()
            }
        }
        guard AXObserverCreate(pid, callback, &ref) == .success, let createdObserver = ref else {
            return nil
        }
        self.observer = createdObserver

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var anySubscribed = false
        for note in Self.appNotifications {
            let result = AXObserverAddNotification(createdObserver, appElement, note as CFString, refcon)
            if result == .success { anySubscribed = true }
        }
        guard anySubscribed else { return nil }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .defaultMode
        )

        subscribeFocusedWindow()
    }

    func invalidate() {
        guard let observer else { return }
        for note in Self.appNotifications {
            AXObserverRemoveNotification(observer, appElement, note as CFString)
        }
        if let observedWindow {
            AXObserverRemoveNotification(observer, observedWindow, kAXTitleChangedNotification as CFString)
            self.observedWindow = nil
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        self.observer = nil
    }

    private func subscribeFocusedWindow() {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        if let observedWindow {
            AXObserverRemoveNotification(observer, observedWindow, kAXTitleChangedNotification as CFString)
            self.observedWindow = nil
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success, let value else { return }
        let cfId = CFGetTypeID(value)
        guard cfId == AXUIElementGetTypeID() else { return }
        let window = value as! AXUIElement

        let addResult = AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, refcon)
        if addResult == .success {
            observedWindow = window
        }
    }
}
