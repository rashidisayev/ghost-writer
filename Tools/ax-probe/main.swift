// ax-probe — the Phase 0 go/no-go tool.
//
// Answers one question per app: can we read the text the user is typing,
// and can we write it back?
//
// Build:  swiftc -O main.swift -o ax-probe
// Run:    ./ax-probe --delay 5
//         (then click into a text field in the app you want to test)

import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Output helpers

let bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m"
let green = "\u{1B}[32m", red = "\u{1B}[31m", yellow = "\u{1B}[33m"

func ok(_ s: String)   { print("  \(green)✓\(reset) \(s)") }
func bad(_ s: String)  { print("  \(red)✗\(reset) \(s)") }
func warn(_ s: String) { print("  \(yellow)!\(reset) \(s)") }
func info(_ s: String) { print("  \(dim)·\(reset) \(s)") }
func header(_ s: String) { print("\n\(bold)\(s)\(reset)") }

// MARK: - AX helpers

func copyAttr(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success
    else { return nil }
    return value
}

func stringAttr(_ element: AXUIElement, _ attr: String) -> String? {
    copyAttr(element, attr) as? String
}

func intAttr(_ element: AXUIElement, _ attr: String) -> Int? {
    copyAttr(element, attr) as? Int
}

func rangeAttr(_ element: AXUIElement, _ attr: String) -> CFRange? {
    guard let v = copyAttr(element, attr), CFGetTypeID(v) == AXValueGetTypeID()
    else { return nil }
    var r = CFRange()
    guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
    return r
}

func attributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success,
          let list = names as? [String] else { return [] }
    return list
}

func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
    var r = CFRange(location: location, length: length)
    guard let param = AXValueCreate(.cfRange, &r) else { return nil }
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXBoundsForRangeParameterizedAttribute as CFString,
        param, &out) == .success, let out,
        CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
    return rect
}

func focusedElement() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.5)
    guard let v = copyAttr(system, kAXFocusedUIElementAttribute as String) else { return nil }
    guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

/// Truncate + escape newlines so a long buffer doesn't flood the terminal.
func preview(_ s: String, _ limit: Int = 160) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: "⏎")
    if flat.count <= limit { return flat }
    return String(flat.prefix(limit)) + "…"
}

// MARK: - Arguments

var delaySeconds: UInt32 = 3
var attemptWrite = false
var dumpAllAttributes = false

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--delay":
        if let v = argIterator.next(), let n = UInt32(v) { delaySeconds = n }
    case "--write":
        attemptWrite = true
    case "--all":
        dumpAllAttributes = true
    case "--help", "-h":
        print("""
        ax-probe — inspect the focused text field of the frontmost app

          --delay N   seconds to wait before probing (default 3)
          --write     also attempt a non-destructive write test
          --all       dump every AX attribute on the focused element
        """)
        exit(0)
    default:
        break
    }
}

// MARK: - 1. Permission

header("1. Accessibility permission")

if AXIsProcessTrusted() {
    ok("Process is AX-trusted")
} else {
    bad("Process is NOT AX-trusted")
    print("""

      A command-line tool inherits the TCC grant of its PARENT app.
      Grant Accessibility to the terminal you're running this from:

        System Settings → Privacy & Security → Accessibility
        → enable Terminal (or iTerm / Ghostty / VS Code)

      Then fully quit and reopen that terminal — the grant is only
      picked up on process launch.

    """)
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    exit(1)
}

// MARK: - 2. Target

print("\nSwitch to the app you want to test and click into a text field…")
for remaining in stride(from: Int(delaySeconds), to: 0, by: -1) {
    print("  \(remaining)…", terminator: "\r")
    fflush(stdout)
    sleep(1)
}
print("  probing now  ")

header("2. Frontmost application")

guard let app = NSWorkspace.shared.frontmostApplication else {
    bad("No frontmost application")
    exit(1)
}
let bundleID = app.bundleIdentifier ?? "(unknown)"
info("Name:      \(app.localizedName ?? "?")")
info("Bundle ID: \(bundleID)")
info("PID:       \(app.processIdentifier)")

// MARK: - 3. Secure input

header("3. Secure input state")

if IsSecureEventInputEnabled() {
    warn("Secure input is ENABLED — a password field is focused somewhere,")
    warn("or an app has left it stuck on. Quill would go dormant here.")
} else {
    ok("Secure input is off — safe to read")
}

// MARK: - 4. Lazy accessibility tree opt-in

header("4. Accessibility tree activation")

let appElement = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(appElement, 0.5)

func probeFocused() -> AXUIElement? { focusedElement() }

var element = probeFocused()
var neededActivation = false

if element == nil || stringAttr(element!, kAXValueAttribute as String) == nil {
    info("No readable focused element yet — trying the lazy-tree attributes")

    let manual = AXUIElementSetAttributeValue(
        appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    let enhanced = AXUIElementSetAttributeValue(
        appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

    info("AXManualAccessibility  → \(manual == .success ? "accepted" : "rejected (\(manual.rawValue))")")
    info("AXEnhancedUserInterface → \(enhanced == .success ? "accepted" : "rejected (\(enhanced.rawValue))")")

    usleep(400_000) // give the app a beat to build the tree
    element = probeFocused()
    neededActivation = true
}

guard let element else {
    bad("Could not resolve a focused UI element")
    print("\n  \(bold)VERDICT: UNSUPPORTED\(reset) — no focused element exposed.\n")
    exit(2)
}

if neededActivation {
    warn("This app needs lazy-tree activation (Electron/Chromium/Firefox class)")
} else {
    ok("Accessibility tree was already available")
}

// MARK: - 5. Element identity

header("5. Focused element")

let role = stringAttr(element, kAXRoleAttribute as String) ?? "(none)"
let subrole = stringAttr(element, kAXSubroleAttribute as String) ?? "(none)"
info("Role:    \(role)")
info("Subrole: \(subrole)")

if subrole == (kAXSecureTextFieldSubrole as String) {
    bad("This is a SECURE TEXT FIELD — Quill must never read it")
    print("\n  \(bold)VERDICT: BLOCKED (correctly)\(reset)\n")
    exit(0)
}

let attrs = attributeNames(element)
info("Exposes \(attrs.count) attributes")
if dumpAllAttributes {
    for name in attrs.sorted() {
        let v = copyAttr(element, name)
        let desc = v.map { String(describing: $0).prefix(80) } ?? "nil"
        print("      \(dim)\(name)\(reset) = \(desc)")
    }
}

// MARK: - 6. Reading text

header("6. Reading text")

var canRead = false
var currentText = ""

if let text = stringAttr(element, kAXValueAttribute as String) {
    canRead = true
    currentText = text
    ok("kAXValue readable — \(text.count) chars")
    info("Content: \"\(preview(text))\"")
} else {
    bad("kAXValue not readable")
}

if let n = intAttr(element, kAXNumberOfCharactersAttribute as String) {
    ok("kAXNumberOfCharacters = \(n)  (cheap change-detection probe available)")
} else {
    warn("kAXNumberOfCharacters unavailable — every pass must pull the full buffer")
}

var caretLocation = 0
if let r = rangeAttr(element, kAXSelectedTextRangeAttribute as String) {
    caretLocation = r.location
    ok("kAXSelectedTextRange = {location: \(r.location), length: \(r.length)}")
} else {
    bad("kAXSelectedTextRange unavailable — cannot locate the caret")
}

if let sel = stringAttr(element, kAXSelectedTextAttribute as String), !sel.isEmpty {
    info("Current selection: \"\(preview(sel, 60))\"")
}

// Windowed read — the API that keeps large buffers cheap.
if attrs.contains(kAXStringForRangeParameterizedAttribute as String)
    || currentText.count > 0 {
    var r = CFRange(location: 0, length: min(20, currentText.count))
    if r.length > 0, let param = AXValueCreate(.cfRange, &r) {
        var out: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            param, &out)
        if status == .success, let s = out as? String {
            ok("kAXStringForRange works — windowed reads available: \"\(preview(s, 40))\"")
        } else {
            warn("kAXStringForRange unsupported — large buffers will be expensive")
        }
    }
}

// MARK: - 7. Caret geometry

header("7. Caret geometry (for the suggestion overlay)")

if let rect = boundsForRange(element, location: max(0, caretLocation - 1), length: 1) {
    ok("kAXBoundsForRange works → \(rect)")
    info("Full underline overlay is possible in this app")
} else {
    warn("kAXBoundsForRange unavailable")
    if let posV = copyAttr(element, kAXPositionAttribute as String),
       let sizeV = copyAttr(element, kAXSizeAttribute as String),
       CFGetTypeID(posV) == AXValueGetTypeID(),
       CFGetTypeID(sizeV) == AXValueGetTypeID() {
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
        info("Fallback: element frame = \(CGRect(origin: p, size: s))")
        info("Degrade to a caret-anchored card, no per-word underlines")
    } else {
        bad("No element frame either — card must be positioned at the mouse")
    }
}

// MARK: - 8. Write capability

header("8. Write capability")

var settable = DarwinBoolean(false)
AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
let valueSettable = settable.boolValue

var selSettable = DarwinBoolean(false)
AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selSettable)

var rangeSettable = DarwinBoolean(false)
AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &rangeSettable)

info("kAXValue settable:             \(valueSettable)")
info("kAXSelectedText settable:      \(selSettable.boolValue)")
info("kAXSelectedTextRange settable: \(rangeSettable.boolValue)")

if attemptWrite && canRead && !currentText.isEmpty {
    print("\n  Attempting non-destructive round-trip write…")
    let marker = currentText + " ✎"
    let status = AXUIElementSetAttributeValue(
        element, kAXValueAttribute as CFString, marker as CFString)
    usleep(200_000)
    let after = stringAttr(element, kAXValueAttribute as String) ?? ""

    if status == .success && after == marker {
        ok("AX write APPLIED and verified → strategy .axSet is viable")
        // Restore.
        _ = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, currentText as CFString)
        info("Original text restored")
    } else if status == .success {
        bad("AX write reported SUCCESS but the text did not change")
        warn("This is the classic silent no-op — paste strategy is required")
    } else {
        bad("AX write failed (\(status.rawValue)) — paste strategy is required")
    }
} else if attemptWrite {
    warn("Skipping write test — nothing readable to restore afterwards")
} else {
    info("Re-run with --write to test whether AX writes actually apply")
}

// MARK: - 9. Verdict

header("9. Verdict for \(bundleID)")

let hasCaret = rangeAttr(element, kAXSelectedTextRangeAttribute as String) != nil
let hasBounds = boundsForRange(element, location: max(0, caretLocation - 1), length: 1) != nil

if canRead && hasCaret {
    print("  \(green)\(bold)SUPPORTED\(reset)")
    print("""

      readStrategy:      \(currentText.count > 8000 ? ".rangedSubstring" : ".fullValue")
      writeStrategy:     \(valueSettable ? ".axSet (verify with --write)" : ".paste")
      rangeBounds:       \(hasBounds ? "yes — full underline overlay" : "no — caret indicator only")
      needsActivation:   \(neededActivation)
    """)
    print("""

      Suggested AXCompat entry:

        "\(bundleID)": AppQuirks(
            needsManualAccessibility: \(neededActivation),
            needsEnhancedUI: \(neededActivation),
            writeStrategy: .\(valueSettable ? "axSet" : "paste"),
            supportsRangeBounds: \(hasBounds),
            readStrategy: .\(currentText.count > 8000 ? "rangedSubstring" : "fullValue"),
            excludedByDefault: false,
            pasteSettleMS: 250
        )

    """)
} else if canRead {
    print("  \(yellow)\(bold)PARTIAL\(reset) — text readable but no caret position")
    print("  Manual-selection rewriting only; no automatic paragraph scoping.\n")
} else {
    print("  \(red)\(bold)UNSUPPORTED\(reset) — no readable text")
    print("  Quill must detect this app and go dormant.\n")
}
