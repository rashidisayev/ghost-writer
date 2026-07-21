import AppKit
import ApplicationServices

@MainActor
public enum TextWriter {

    public enum Strategy: Sendable { case axSet, paste }

    /// Writes `replacement` over `range`. Re-verifies immediately before writing:
    /// the user may have typed between the read and the accept, and a rewrite of
    /// text they've since changed is worse than no rewrite at all.
    @discardableResult
    public static func apply(
        _ replacement: String,
        to element: AXUIElement,
        range: NSRange,
        expectedOriginal: String,
        bundleID: String?
    ) -> Bool {
        guard let current = TextReader.snapshot(element),
              current.text.contains(expectedOriginal) else { return false }

        let quirks = AXCompat.quirks(for: bundleID)
        if !quirks.preferPasteStrategy {
            if setViaAX(replacement, element, range),
               verify(element, contains: replacement) {
                return true
            }
            // AX writes report SUCCESS and silently no-op in most web content.
            // Fall through rather than trusting the return value.
        }
        return pasteReplace(replacement, element, range, settleMS: quirks.pasteSettleMS)
    }

    private static func setViaAX(
        _ text: String, _ e: AXUIElement, _ range: NSRange
    ) -> Bool {
        var r = CFRange(location: range.location, length: range.length)
        guard let rv = AXValueCreate(.cfRange, &r) else { return false }
        guard AXUIElementSetAttributeValue(
            e, kAXSelectedTextRangeAttribute as CFString, rv) == .success else { return false }
        return AXUIElementSetAttributeValue(
            e, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// The workhorse. The only strategy that works in browsers and Electron, and
    /// the only one that preserves the host app's native undo stack — the app
    /// sees an ordinary paste, so ⌘Z behaves exactly as the user expects.
    private static func pasteReplace(
        _ text: String, _ e: AXUIElement, _ range: NSRange, settleMS: Int
    ) -> Bool {
        let pb = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] =
            pb.pasteboardItems?.map { item in
                var d: [NSPasteboard.PasteboardType: Data] = [:]
                for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
                return d
            } ?? []
        let savedCount = pb.changeCount

        // Select the span we're replacing.
        var r = CFRange(location: range.location, length: range.length)
        if let rv = AXValueCreate(.cfRange, &r) {
            AXUIElementSetAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, rv)
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Ask well-behaved clipboard managers not to record this.
        pb.setString("", forType: .init("org.nspasteboard.TransientType"))
        pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(settleMS)) {
            // Don't clobber something the user copied during the window.
            guard pb.changeCount == savedCount + 1 else { return }
            pb.clearContents()
            let items = savedItems.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        return true
    }

    private static func postCommandV() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        src.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents],
            state: .eventSuppressionStateSuppressionInterval)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func verify(_ e: AXUIElement, contains s: String) -> Bool {
        guard let snap = TextReader.snapshot(e) else { return false }
        return snap.text.contains(s)
    }
}
