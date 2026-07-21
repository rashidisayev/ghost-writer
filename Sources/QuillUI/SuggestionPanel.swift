import AppKit
import QuillAccessibility
import QuillCore
import SwiftUI

@MainActor
public final class SuggestionPanel: NSPanel {
    public static let shared = SuggestionPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 90),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // Follow the user across Spaces and into full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Never steal key focus — the caret must keep blinking in the host app.
        becomesKeyOnlyIfNeeded = true
    }

    // The load-bearing detail: if this panel ever becomes key, the host app
    // loses focus, the caret stops blinking, and the illusion of a system
    // service collapses.
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public func present(
        state: SuggestionView.State,
        anchor: CGRect?,
        onAccept: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let root = SuggestionView(state: state, onAccept: onAccept, onDismiss: onDismiss)
        if let hosting = contentViewController as? NSHostingController<SuggestionView> {
            hosting.rootView = root
        } else {
            contentViewController = NSHostingController(rootView: root)
        }
        layoutIfNeeded()

        let size = contentViewController?.view.fittingSize ?? NSSize(width: 420, height: 90)
        position(size: size, anchor: anchor)
        orderFrontRegardless()   // NOT makeKeyAndOrderFront
    }

    private func position(size: NSSize, anchor: CGRect?) {
        guard let cgCaret = anchor, cgCaret != .zero else {
            positionAtMouse(size: size)
            return
        }
        let caret = TextReader.toAppKit(cgCaret)
        var origin = CGPoint(x: caret.minX, y: caret.minY - size.height - 8)

        let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Flip above the caret if we'd fall off the bottom of the screen.
            if origin.y < visible.minY { origin.y = caret.maxY + 8 }
            // Keep it on-screen horizontally.
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func positionAtMouse(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        var origin = CGPoint(x: mouse.x, y: mouse.y - size.height - 16)
        if let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?
            .visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    public func dismiss() {
        orderOut(nil)
    }
}
