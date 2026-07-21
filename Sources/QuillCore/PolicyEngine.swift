import Foundation

/// Identifies the app + field Quill is looking at. Deliberately carries no
/// text — policy runs *before* any read.
public struct FocusDescriptor: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let isSecureField: Bool
    public let roleIsEditable: Bool

    public init(bundleIdentifier: String?, isSecureField: Bool, roleIsEditable: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.isSecureField = isSecureField
        self.roleIsEditable = roleIsEditable
    }
}

public enum PolicyDecision: Sendable, Equatable {
    case allow
    case denySecureField
    case denyNotEditable
    case denyExcludedApp(String)
    case denyPaused
}

public struct PolicyEngine: Sendable {

    /// Apps where a rewrite is either meaningless or actively dangerous.
    /// Password managers and terminals are never worth the risk.
    public static let defaultExclusions: Set<String> = [
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.lastpassmacdesktop",
        "in.sinew.Enpass-Desktop",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.apple.loginwindow",
    ]

    public var excludedBundleIDs: Set<String>
    public var isPaused: Bool

    public init(excludedBundleIDs: Set<String> = defaultExclusions, isPaused: Bool = false) {
        self.excludedBundleIDs = excludedBundleIDs
        self.isPaused = isPaused
    }

    public func evaluate(_ focus: FocusDescriptor) -> PolicyDecision {
        if isPaused { return .denyPaused }
        if focus.isSecureField { return .denySecureField }
        if !focus.roleIsEditable { return .denyNotEditable }
        if let bundle = focus.bundleIdentifier, excludedBundleIDs.contains(bundle) {
            return .denyExcludedApp(bundle)
        }
        return .allow
    }
}
