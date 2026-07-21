import AppKit
import ApplicationServices
import GhostWriterCore

public struct TextSnapshot: Sendable {
    public let text: String
    public let selectedRange: NSRange
    public let caretRect: CGRect?
    public let length: Int
    /// Offset of `text` within the full buffer — nonzero when the read was windowed.
    public let windowOffset: Int
}

/// `AXUIElement` is a CFType and not Sendable. Keeping all AX interaction on
/// @MainActor is what keeps this compiling under strict concurrency without
/// unsafe escapes — and it matches the API's actual thread-safety guarantees.
@MainActor
public enum TextReader {

    /// Focus within a specific process. Preferred over the system-wide element,
    /// which resolves against the frontmost app — and that is Ghost Writer itself
    /// whenever the rewrite was triggered from the menu bar item.
    public static func focusedElement(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return focused(of: app)
    }

    public static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        return focused(of: system)
    }

    private static func focused(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Describes the focused field without reading a single character of it.
    /// Policy runs on this, before any text read.
    /// `bundleID` is passed in rather than read from `frontmostApplication`:
    /// when the trigger came from Ghost Writer's own menu, the frontmost app is Ghost Writer,
    /// and policy would evaluate the user's app exclusions against the wrong
    /// bundle identifier — quietly never matching.
    public static func describe(_ element: AXUIElement, bundleID: String?) -> FocusDescriptor {
        let role = string(element, kAXRoleAttribute as String)
        let subrole = string(element, kAXSubroleAttribute as String)

        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        var isEditable = editableRoles.contains(role ?? "")
        // Web content often reports AXGroup/AXStaticText with an editable
        // ancestor; the presence of a settable value attribute is the reliable
        // signal there.
        if !isEditable {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(
                element, kAXValueAttribute as CFString, &settable) == .success {
                isEditable = settable.boolValue
            }
        }

        return FocusDescriptor(
            bundleIdentifier: bundleID,
            isSecureField: subrole == (kAXSecureTextFieldSubrole as String),
            roleIsEditable: isEditable
        )
    }

    /// The focused field's on-screen rect, in CG (top-left origin) coordinates.
    /// Built from position + size rather than a single frame attribute, which
    /// plenty of apps don't implement.
    public static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero

        var posValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &posValue) == .success,
            let posValue, CFGetTypeID(posValue) == AXValueGetTypeID(),
            AXValueGetValue(posValue as! AXValue, .cgPoint, &origin) else { return nil }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }

        guard size.width > 1, size.height > 1 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Cheap change probe — avoid pulling a large buffer on every pass.
    public static func length(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &value) == .success,
            let n = value as? Int else { return nil }
        return n
    }

    public static func snapshot(_ element: AXUIElement, maxChars: Int = 8_000) -> TextSnapshot? {
        guard let range = selectedRange(element) else { return nil }
        // `.utf16.count`, not `.count`: this total is compared against and mixed
        // with AX offsets, which are UTF-16. kAXNumberOfCharacters is already in
        // those units, so the fallback has to match it.
        let total = length(of: element) ?? string(element, kAXValueAttribute as String)?.utf16.count
        guard let total else { return nil }

        let text: String
        let offset: Int
        if total <= maxChars {
            guard let full = string(element, kAXValueAttribute as String) else { return nil }
            text = full
            offset = 0
        } else {
            // Windowed read — never pull a 200KB buffer for a paragraph rewrite.
            let start = max(0, range.location - maxChars / 2)
            let len = min(maxChars, total - start)
            guard let windowed = substring(element, CFRange(location: start, length: len))
            else { return nil }
            text = windowed
            offset = start
        }

        return TextSnapshot(
            text: text,
            selectedRange: range,
            caretRect: caretRect(element, at: range.location),
            length: total,
            windowOffset: offset
        )
    }

    // MARK: - Primitives

    static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    public static func selectedRange(_ e: AXUIElement) -> NSRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            e, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
            let axValue = v, CFGetTypeID(axValue) == AXValueGetTypeID()
        else { return nil }
        var r = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    static func substring(_ e: AXUIElement, _ range: CFRange) -> String? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            e, kAXStringForRangeParameterizedAttribute as CFString, param, &out) == .success
        else { return nil }
        return out as? String
    }

    /// Screen coords, TOP-LEFT origin (CG convention). Convert before using with
    /// NSWindow, which is bottom-left.
    public static func caretRect(_ e: AXUIElement, at offset: Int) -> CGRect? {
        var r = CFRange(location: offset, length: 1)
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            e, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
            let out, CFGetTypeID(out) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// CG top-left screen rect → AppKit bottom-left. Always measured against the
    /// PRIMARY screen, not the current one. Getting this wrong puts the card on
    /// the wrong monitor.
    public static func toAppKit(_ cgRect: CGRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: cgRect.origin.x,
            y: primaryMaxY - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    /// Electron and Chromium need to be asked to build their AX tree.
    public static func primeLazyAccessibility(for pid: pid_t, bundleID: String?) {
        let quirks = AXCompat.quirks(for: bundleID)
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        if quirks.needsManualAccessibility {
            AXUIElementSetAttributeValue(
                appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        if quirks.needsEnhancedUI {
            AXUIElementSetAttributeValue(
                appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}
