import AppKit

/// Remembers which application the user was actually working in.
///
/// The system-wide AX element resolves focus against whatever is frontmost, and
/// clicking Ghost Writer's menu bar item makes *Ghost Writer* frontmost — so a rewrite
/// triggered from the menu would inspect Ghost Writer's own menu and correctly report
/// that no text field is focused. The hotkey path doesn't activate Ghost Writer and so
/// never showed this.
///
/// Tracking the last activated app that isn't us makes both paths behave the
/// same. It also gives policy the right bundle identifier: evaluating app
/// exclusions against "com.ghostwriter.app" would silently ignore the user's list.
@MainActor
public final class TargetAppTracker {
    public static let shared = TargetAppTracker()

    private var lastActive: NSRunningApplication?
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self, app.processIdentifier != self.selfPID else { return }
                self.lastActive = app
                // Prime on activation rather than only on trigger. Electron
                // needs time to build its tree after being asked, and the user
                // switching apps is the earliest possible moment to ask — by
                // the time they've typed a paragraph it is ready.
                TextReader.primeLazyAccessibility(
                    for: app.processIdentifier, bundleID: app.bundleIdentifier)
            }
        }
        seed()
    }

    private func seed() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != selfPID {
            lastActive = front
            TextReader.primeLazyAccessibility(
                for: front.processIdentifier, bundleID: front.bundleIdentifier)
        }
    }

    /// The app a rewrite should act on: whatever is frontmost, unless that's us,
    /// in which case the app the user came from.
    public var target: NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != selfPID {
            return front
        }
        return lastActive
    }
}
