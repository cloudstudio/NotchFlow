import AppKit
import SwiftUI
import NotchFlowCore
import NotchKit

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let bridge = BridgeServer()
    private var panel: NotchPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updateGeometry()
        createPanel()
        model.startPointerTracking()

        model.startLiveServices()
        bridge.start { [weak model] envelope, respond in
            Task { @MainActor in
                model?.receive(envelope, respond: respond)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenParametersChanged() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopLiveServices()
        bridge.stop()
    }

    /// The island lives on the notched (built-in) screen when one exists,
    /// and stays there regardless of where the pointer travels.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func updateGeometry() {
        guard let screen = targetScreen else { return }
        let insetTop = screen.safeAreaInsets.top
        if insetTop > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let notchWidth = right.minX - left.maxX
            model.geometry = NotchGeometry(
                collapsedSize: CGSize(width: notchWidth + 100, height: insetTop),
                hasPhysicalNotch: true,
                notchWidth: notchWidth
            )
        } else {
            model.geometry = .fallback
        }
    }

    private func screenParametersChanged() {
        updateGeometry()
        applyPanelFrame()
    }

    /// The panel always spans the maximum opened size and never resizes.
    /// Every visible size change is SwiftUI-only, which is what makes the
    /// expansion one continuous morph instead of a frame jump.
    private var panelSize: NSSize {
        NSSize(width: 660, height: 720)
    }

    private func createPanel() {
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        let hostingView = NotchHostingView(rootView: NotchIslandView(model: model))
        hostingView.stateProvider = { [weak model] in model?.hitTestState }
        hostingView.safeAreaRegions = []
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.panel = panel

        model.onLayoutChanged = { [weak self] _ in
            self?.refreshKeyStatus()
        }

        applyPanelFrame()
        panel.orderFrontRegardless()
    }

    private func refreshKeyStatus() {
        if !model.pendingInteractions.isEmpty {
            panel?.makeKeyAndOrderFront(nil)
        } else {
            panel?.orderFrontRegardless()
        }
    }

    private func applyPanelFrame() {
        guard let panel, let screen = targetScreen else { return }
        let origin = NSPoint(
            x: screen.frame.midX - (panelSize.width / 2),
            y: screen.frame.maxY - panelSize.height
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true, animate: false)
        model.islandAnchor = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit constrains windows below the menu bar; a notch overlay must be
    /// flush with the physical top edge, so the frame passes through as-is.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Lets clicks fall through everywhere except the island itself, and makes the
/// nonactivating panel key on the first click so buttons never swallow it.
final class NotchHostingView: NSHostingView<NotchIslandView> {
    var stateProvider: (() -> (expanded: Bool, collapsedSize: CGSize)?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let state = stateProvider?() ?? nil else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let interactive: CGRect
        if state.expanded {
            interactive = bounds
        } else {
            interactive = CGRect(
                x: (bounds.width - state.collapsedSize.width) / 2,
                y: 0,
                width: state.collapsedSize.width,
                height: state.collapsedSize.height
            ).insetBy(dx: -6, dy: -6)
        }
        guard interactive.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
