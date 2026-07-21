import AppKit
import ApplicationServices

/// Answers "why did that say no text field focused?" with facts instead of
/// guesses. Every AX failure looks identical from the UI — nil is nil whether
/// the tree is missing, the role is unexpected, or the app never built one —
/// so the only way to tell them apart is to dump each step separately.
@MainActor
public enum Diagnostics {

    public static func report() -> String {
        var out: [String] = []
        out.append("Ghost Writer diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        out.append("AX trusted: \(AXPermissions.isTrusted)")

        guard let app = TargetAppTracker.shared.target else {
            out.append("Target app: NONE — the tracker has no app to act on.")
            return out.joined(separator: "\n")
        }

        let bundleID = app.bundleIdentifier
        out.append("Target app: \(app.localizedName ?? "?") (\(bundleID ?? "no bundle id"))")
        out.append("PID: \(app.processIdentifier)")

        let quirks = AXCompat.quirks(for: bundleID)
        out.append("Quirks: manualAccessibility=\(quirks.needsManualAccessibility) "
            + "enhancedUI=\(quirks.needsEnhancedUI) paste=\(quirks.preferPasteStrategy)")

        // Re-prime, then report both focus paths independently.
        TextReader.primeLazyAccessibility(for: app.processIdentifier, bundleID: bundleID)

        let perProcess = TextReader.focusedElement(in: app.processIdentifier)
        let systemWide = TextReader.focusedElement()
        out.append("Focus (per-process): \(perProcess == nil ? "nil" : "found")")
        out.append("Focus (system-wide): \(systemWide == nil ? "nil" : "found")")

        guard let element = perProcess ?? systemWide else {
            out.append("")
            out.append("No focused element. The app exposes no AX focus at all —")
            out.append("either its tree is unavailable, or focus is inside web")
            out.append("content that did not respond to priming.")
            out.append(windowSurvey(pid: app.processIdentifier))
            return out.joined(separator: "\n")
        }

        out.append("Role: \(attr(element, kAXRoleAttribute as String) ?? "nil")")
        out.append("Subrole: \(attr(element, kAXSubroleAttribute as String) ?? "nil")")
        out.append("Description: \(attr(element, kAXRoleDescriptionAttribute as String) ?? "nil")")

        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable)
        out.append("Value settable: \(settable.boolValue) (status \(settableStatus.rawValue))")

        let value = attr(element, kAXValueAttribute as String)
        out.append("Value readable: \(value != nil) (\(value?.count ?? 0) chars)")
        out.append("NumberOfCharacters: \(TextReader.length(of: element).map(String.init) ?? "nil")")

        if let range = TextReader.selectedRange(element) {
            out.append("Selected range: loc \(range.location) len \(range.length)")
        } else {
            out.append("Selected range: UNAVAILABLE — snapshot() bails here")
        }

        let descriptor = TextReader.describe(element, bundleID: bundleID)
        out.append("Descriptor: editable=\(descriptor.roleIsEditable) "
            + "secure=\(descriptor.isSecureField)")

        if TextReader.snapshot(element) == nil {
            out.append("snapshot(): nil — read would fail")
        } else {
            out.append("snapshot(): OK")
        }

        return out.joined(separator: "\n")
    }

    /// When there's no focused element, the useful question is whether the app
    /// exposes any AX tree at all — an empty window list means priming failed
    /// outright, rather than focus simply being somewhere unexpected.
    private static func windowSurvey(pid: pid_t) -> String {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windows = value as? [AXUIElement] else {
            return "Windows: unavailable (status \(status.rawValue)) — no usable tree."
        }
        let roles = windows.prefix(3).map { attr($0, kAXRoleAttribute as String) ?? "?" }
        return "Windows: \(windows.count) [\(roles.joined(separator: ", "))]"
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
