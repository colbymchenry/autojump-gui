import AppKit
import Combine
import SwiftUI

final class LauncherPanel: NSPanel {
    private let viewModel: LauncherViewModel
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: LauncherViewModel) {
        self.viewModel = viewModel

        let hostingController = NSHostingController(rootView: LauncherView(viewModel: viewModel))
        hostingController.sizingOptions = .preferredContentSize

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

        contentViewController = hostingController

        // Belt-and-suspenders: when results change, force a layout/resize on the next runloop.
        viewModel.$results
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncSizeToContent() }
            .store(in: &cancellables)
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

    // Keep the top edge fixed when the panel grows or shrinks.
    override func setContentSize(_ size: NSSize) {
        let topY = frame.maxY
        super.setContentSize(size)
        setFrameOrigin(NSPoint(x: frame.origin.x, y: topY - frame.height))
    }

    private func syncSizeToContent() {
        guard let view = contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        guard fitting.width > 0, fitting.height > 0, fitting != frame.size else { return }
        setContentSize(fitting)
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
                let modifier = LaunchModifier.from(eventFlags: event.modifierFlags)
                self.viewModel.commit(modifier: modifier)
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

private let kVK_Escape = 0x35
private let kVK_Return = 0x24
private let kVK_ANSI_KeypadEnter = 0x4C
private let kVK_DownArrow = 0x7D
private let kVK_UpArrow = 0x7E
