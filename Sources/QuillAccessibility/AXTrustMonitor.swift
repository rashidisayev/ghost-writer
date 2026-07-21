import Foundation
import Observation

/// Publishes Accessibility trust as observable state.
///
/// TCC gives no notification when a grant is toggled, so polling is the only
/// option. It has to be a real timer owned by the app rather than a SwiftUI
/// `.onReceive` on the MenuBarExtra: with `.menuBarExtraStyle(.menu)` the
/// content closure is only built while the menu is open, so anything driven
/// from there stops updating exactly when the user is in System Settings
/// granting the permission.
///
/// The interval is deliberately short. This is the one moment where the app
/// looks broken to a new user — they flip the switch, come back, and the app
/// still says it has no permission.
@MainActor
@Observable
public final class AXTrustMonitor {
    public static let shared = AXTrustMonitor()

    public private(set) var isTrusted: Bool = AXPermissions.isTrusted

    @ObservationIgnored private var timer: Timer?

    private init() {}

    public func start(interval: TimeInterval = 2) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // .common so the poll keeps running while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func refresh() {
        let current = AXPermissions.isTrusted
        // Assigning unconditionally would wake every observer on each tick.
        if current != isTrusted { isTrusted = current }
    }
}
