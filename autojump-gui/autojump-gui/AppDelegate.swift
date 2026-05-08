import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = AutojumpStore()
    private lazy var viewModel = LauncherViewModel(store: store)
    private var panel: LauncherPanel?
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private var finderTracker: FinderTracker?
    private var finderTrackingMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        viewModel.onSelect = { [weak self] path, modifier in
            if let modifier {
                let action = LaunchActionsStore.shared.action(for: modifier)
                ActionLauncher.launch(action, path: path)
            } else {
                ActionLauncher.openInFinder(path)
            }
            self?.hidePanel()
        }
        viewModel.onDismiss = { [weak self] in
            self?.hidePanel()
        }

        panel = LauncherPanel(viewModel: viewModel)
        installStatusItem()
        installHotKey()
        installFinderTracker()
    }

    private func installFinderTracker() {
        finderTracker = FinderTracker()
        if FinderTracker.isEnabledByPreference {
            finderTracker?.start()
        }
        updateFinderTrackingMenuItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.uturn.forward.circle",
                                     accessibilityDescription: "Autojump")
        let menu = NSMenu()

        let show = NSMenuItem(title: "Show launcher", action: #selector(togglePanel), keyEquivalent: "j")
        show.keyEquivalentModifierMask = [.command]
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        let install = NSMenuItem(title: "Install CLI integration…", action: #selector(installCLI), keyEquivalent: "")
        install.target = self
        menu.addItem(install)

        let uninstall = NSMenuItem(title: "Uninstall CLI integration", action: #selector(uninstallCLI), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)

        menu.addItem(.separator())

        let finderTracking = NSMenuItem(title: "Track Finder navigation",
                                        action: #selector(toggleFinderTracking),
                                        keyEquivalent: "")
        finderTracking.target = self
        menu.addItem(finderTracking)
        finderTrackingMenuItem = finderTracking

        let accessibility = NSMenuItem(title: "Grant Accessibility access…",
                                       action: #selector(grantAccessibility),
                                       keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)
        accessibilityMenuItem = accessibility

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        finderTracker?.refreshAccessibilityState()
        updateFinderTrackingMenuItem()
        updateAccessibilityMenuItem()
    }

    @objc private func installCLI() {
        guard let shell = Shell.detect() else {
            showAlert(title: "Unsupported shell",
                      message: "$SHELL is not zsh, bash, fish, or tcsh. Set $SHELL or install the integration manually.")
            return
        }
        let alreadyInstalled = CLIIntegration.isInstalled(in: shell)
        let confirm = NSAlert()
        confirm.messageText = alreadyInstalled
            ? "Reinstall autojump CLI integration?"
            : "Install autojump CLI integration?"
        confirm.informativeText = """
        This will copy the autojump scripts to:
            ~/Library/Application Support/autojump-gui/cli/

        And add a block to ~/\(shell.rcFileURL.lastPathComponent) that prepends that directory to PATH and sources the \(shell.rawValue) hook.

        You can undo this from the menu later.
        """
        confirm.addButton(withTitle: alreadyInstalled ? "Reinstall" : "Install")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try CLIIntegration.install(shell: shell)
            showAlert(title: "CLI integration installed",
                      message: "Open a new terminal window and try `j <folder>`.")
        } catch {
            showAlert(title: "Install failed", message: error.localizedDescription)
        }
    }

    @objc private func uninstallCLI() {
        guard let shell = Shell.detect() else { return }
        guard CLIIntegration.isInstalled(in: shell) else {
            showAlert(title: "Nothing to uninstall",
                      message: "No autojump-gui block found in ~/\(shell.rcFileURL.lastPathComponent).")
            return
        }
        do {
            try CLIIntegration.uninstall(shell: shell)
            showAlert(title: "CLI integration removed",
                      message: "The block has been removed from ~/\(shell.rcFileURL.lastPathComponent). Open a new terminal for the change to take effect.")
        } catch {
            showAlert(title: "Uninstall failed", message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func installHotKey() {
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.togglePanel()
        }
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        store.reload()
        viewModel.reset()
        panel?.present()
    }

    private func hidePanel() {
        panel?.dismiss()
    }

    @objc private func toggleFinderTracking() {
        let newValue = !FinderTracker.isEnabledByPreference
        FinderTracker.setEnabledPreference(newValue)
        if newValue {
            finderTracker?.start()
        } else {
            finderTracker?.stop()
        }
        updateFinderTrackingMenuItem()
    }

    private func updateFinderTrackingMenuItem() {
        finderTrackingMenuItem?.state = FinderTracker.isEnabledByPreference ? .on : .off
    }

    @objc private func grantAccessibility() {
        if FinderTracker.hasAccessibilityPermission {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            if let url { NSWorkspace.shared.open(url) }
            return
        }
        FinderTracker.requestAccessibilityPermission()
    }

    private func updateAccessibilityMenuItem() {
        guard let item = accessibilityMenuItem else { return }
        if FinderTracker.hasAccessibilityPermission {
            item.title = "Accessibility access granted"
            item.state = .on
            item.isEnabled = true
        } else {
            item.title = "Grant Accessibility access…"
            item.state = .off
            item.isEnabled = true
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
