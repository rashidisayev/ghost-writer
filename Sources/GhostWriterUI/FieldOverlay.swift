import AppKit
import ApplicationServices
import GhostWriterAccessibility
import GhostWriterCore
import GhostWriterStorage
import SwiftUI

/// The Grammarly-style affordance: a highlight around the focused text field and
/// a button to rewrite it, both following focus across apps.
///
/// Two separate panels rather than one. The highlight must never intercept a
/// click — it sits directly over the text the user is trying to edit — while the
/// button exists only to be clicked. A single panel cannot be both.
@MainActor
public final class FieldOverlay {
    public static let shared = FieldOverlay()

    private let highlight = HighlightPanel()
    private let button = ActionButtonPanel()
    private var timer: Timer?
    private var settings = SettingsStore.shared

    /// Fast enough to feel attached to the caret, slow enough that the AX round
    /// trip stays off the critical path. Each poll is two attribute reads.
    private let interval: TimeInterval = 0.35

    private init() {}

    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func hide() {
        highlight.orderOut(nil)
        button.orderOut(nil)
    }

    private func tick() {
        guard AXPermissions.isTrusted, !settings.isPaused else { return hide() }

        // Never draw over Ghost Writer's own windows.
        guard let app = TargetAppTracker.shared.target,
              let element = TextReader.focusedElement(in: app.processIdentifier) else {
            return hide()
        }

        // Same policy that gates a rewrite. Showing a button that refuses to do
        // anything on click is worse than showing nothing — and the highlight
        // must never appear over a password field.
        let descriptor = TextReader.describe(element, bundleID: app.bundleIdentifier)
        guard settings.policy.evaluate(descriptor) == .allow else { return hide() }

        guard let cgFrame = TextReader.frame(of: element) else { return hide() }
        let frame = TextReader.toAppKit(cgFrame)

        // Tiny fields are search boxes and spinners, not prose.
        guard frame.width >= 80, frame.height >= 20 else { return hide() }

        highlight.show(around: frame)
        button.show(in: frame)
    }
}

// MARK: - Highlight

@MainActor
private final class HighlightPanel: NSPanel {
    private let border = BorderView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // The whole point: clicks pass straight through to the text underneath.
        ignoresMouseEvents = true
        contentView = border
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(around frame: CGRect) {
        let padded = frame.insetBy(dx: -3, dy: -3)
        setFrame(padded, display: true)
        border.needsDisplay = true
        orderFrontRegardless()
    }
}

private final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.stroke()
        NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
        path.fill()
    }
}

// MARK: - Action button

@MainActor
private final class ActionButtonPanel: NSPanel {
    private static let side: CGFloat = 28

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        becomesKeyOnlyIfNeeded = true
        contentView = FirstMouseHostingView(rootView: RewriteButton())
    }

    // If this becomes key the caret stops blinking in the host app and the
    // selection can be lost — the same rule the suggestion panel follows.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(in field: CGRect) {
        // Inside the field's bottom-right corner, where Grammarly puts it —
        // out of the way of the text baseline and the scrollbar.
        var origin = CGPoint(
            x: field.maxX - Self.side - 6,
            y: field.minY + 6
        )
        if let visible = (NSScreen.screens.first { $0.frame.intersects(field) } ?? NSScreen.main)?
            .visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - Self.side - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - Self.side - 4)
        }
        setFrame(CGRect(origin: origin, size: CGSize(width: Self.side, height: Self.side)),
                 display: true)
        orderFrontRegardless()
    }
}

/// A click into an inactive window is swallowed as an activation click unless
/// the view opts in. Without this the button needs two clicks — the first one
/// appearing to do nothing.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct RewriteButton: View {
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
                .opacity(isHovering ? 1 : 0.85)
            Image(systemName: "pencil.tip.crop.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
        .scaleEffect(isHovering ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture { RewriteCoordinator.shared.triggerRewrite() }
        .help("Rewrite this text  ⌥⌘K")
    }
}
