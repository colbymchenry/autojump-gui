import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AutojumpStore()
    private lazy var viewModel = LauncherViewModel(store: store)
    private var panel: LauncherPanel?
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        viewModel.onSelect = { [weak self] path in
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            self?.hidePanel()
        }
        viewModel.onDismiss = { [weak self] in
            self?.hidePanel()
        }

        panel = LauncherPanel(viewModel: viewModel)
        installStatusItem()
        installHotKey()
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
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
