import AppKit
import ApplicationServices
import Foundation

@MainActor
final class FinderTracker {
    static let preferenceKey = "FinderTrackingEnabled"
    nonisolated static let finderBundleID = "com.apple.finder"

    private var workspaceObservers: [NSObjectProtocol] = []
    private var runningAppObservation: NSKeyValueObservation?
    private var pollTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var axObserver: FinderAXObserver?
    private var axPid: pid_t = 0
    private var lastRecorded: String?
    private let autojumpURL: URL

    private static let script: NSAppleScript? = {
        let source = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return ""
            try
                set theTarget to (target of front Finder window) as alias
                return POSIX path of theTarget
            on error
                return ""
            end try
        end tell
        """
        return NSAppleScript(source: source)
    }()

    init?() {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("autojump")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        self.autojumpURL = url
    }

    static var isEnabledByPreference: Bool {
        if UserDefaults.standard.object(forKey: preferenceKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: preferenceKey)
    }

    static func setEnabledPreference(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    var isUsingAccessibility: Bool { axObserver != nil }

    func start() {
        stop()
        installWorkspaceObservers()
        attachAXObserverIfPossible()
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderTracker.finderBundleID {
            recordCurrentFinderPath()
            if !isUsingAccessibility { startPolling() }
        }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { nc.removeObserver(observer) }
        workspaceObservers.removeAll()
        stopPolling()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        detachAXObserver()
        lastRecorded = nil
    }

    /// Re-evaluate Accessibility permission. Call this after the user grants
    /// or revokes access in System Settings while the app is running.
    func refreshAccessibilityState() {
        if FinderTracker.hasAccessibilityPermission {
            if axObserver == nil { attachAXObserverIfPossible() }
            if isUsingAccessibility { stopPolling() }
        } else {
            detachAXObserver()
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderTracker.finderBundleID {
                startPolling()
            }
        }
    }

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let activate = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == FinderTracker.finderBundleID else { return }
            MainActor.assumeIsolated {
                self.recordCurrentFinderPath()
                if !self.isUsingAccessibility { self.startPolling() }
            }
        }
        let deactivate = nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == FinderTracker.finderBundleID else { return }
            MainActor.assumeIsolated {
                self.stopPolling()
            }
        }
        let launch = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == FinderTracker.finderBundleID else { return }
            MainActor.assumeIsolated {
                self.attachAXObserverIfPossible(for: app)
            }
        }
        let terminate = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == FinderTracker.finderBundleID else { return }
            let terminatedPid = app.processIdentifier
            MainActor.assumeIsolated {
                if self.axPid == terminatedPid {
                    self.detachAXObserver()
                }
            }
        }
        workspaceObservers = [activate, deactivate, launch, terminate]
    }

    private func attachAXObserverIfPossible(for app: NSRunningApplication? = nil) {
        guard FinderTracker.hasAccessibilityPermission else { return }
        let target: NSRunningApplication?
        if let app {
            target = app
        } else {
            target = NSRunningApplication.runningApplications(withBundleIdentifier: FinderTracker.finderBundleID).first
        }
        guard let finder = target, finder.processIdentifier > 0 else { return }
        if axPid == finder.processIdentifier, axObserver != nil { return }

        detachAXObserver()
        let observer = FinderAXObserver(pid: finder.processIdentifier) { [weak self] in
            self?.scheduleDebouncedRecord()
        }
        guard let observer else { return }
        axObserver = observer
        axPid = finder.processIdentifier
        stopPolling()
    }

    private func detachAXObserver() {
        axObserver?.invalidate()
        axObserver = nil
        axPid = 0
    }

    private func scheduleDebouncedRecord() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.recordCurrentFinderPath()
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func startPolling() {
        if isUsingAccessibility { return }
        stopPolling()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordCurrentFinderPath()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func recordCurrentFinderPath() {
        guard let raw = currentFinderPath() else { return }
        let path = normalize(raw)
        guard !path.isEmpty, path != lastRecorded else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        lastRecorded = path
        addToAutojump(path: path)
    }

    private func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private func currentFinderPath() -> String? {
        guard let script = Self.script else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    private func addToAutojump(path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", autojumpURL.path, "--add", path]
        var env = ProcessInfo.processInfo.environment
        env["AUTOJUMP_SOURCED"] = "1"
        task.environment = env
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            // best-effort — silent failure is fine for background tracking
        }
    }
}
