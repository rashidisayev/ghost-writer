import AppKit
import ApplicationServices

public enum AXPermissions {
    /// Non-prompting check. Safe to poll.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts once. Call only from an explicit user action during onboarding —
    /// prompting at launch is how you get denied before you've explained anything.
    @discardableResult
    public static func requestTrust() -> Bool {
        // The literal rather than `kAXTrustedCheckOptionPrompt`: the SDK declares
        // that as a mutable global, which strict concurrency rejects. The key's
        // value is ABI-stable.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
