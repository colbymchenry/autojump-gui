import AppKit
import SwiftUI

final class LauncherPanel: NSPanel {
    private let viewModel: LauncherViewModel
    private var keyMonitor: Any?

    init(viewModel: LauncherViewModel) {
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: LauncherView(viewModel: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        visualEffect.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            host.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        contentView = visualEffect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present() {
        positionAtSpotlightLocation()
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        removeKeyMonitor()
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    private func positionAtSpotlightLocation() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - visible.height * 0.22
        )
        setFrameOrigin(origin)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.viewModel.dismiss()
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.viewModel.commit()
                return nil
            case kVK_DownArrow:
                self.viewModel.moveDown()
                return nil
            case kVK_UpArrow:
                self.viewModel.moveUp()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

// kVK_* constants live in Carbon; bridge the ones we use.
private let kVK_Escape = 0x35
private let kVK_Return = 0x24
private let kVK_ANSI_KeypadEnter = 0x4C
private let kVK_DownArrow = 0x7D
private let kVK_UpArrow = 0x7E
