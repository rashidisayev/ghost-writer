# Example Swift Code — Critical Components

Swift 6, strict concurrency. These are the pieces where the design decisions are non-obvious or the APIs are easy to get subtly wrong.

---

## 1. Permissions

```swift
import ApplicationServices

public enum AXPermissions {
    /// Non-prompting check. Safe to poll.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts once. Call only from an explicit user action during onboarding —
    /// prompting at launch is how you get denied before you've explained anything.
    @discardableResult
    public static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
```

Trust can be revoked while running, so poll every 30s and drive a menu bar state from it. Do not assume the launch-time answer holds.

---

## 2. Focus tracking

```swift
import ApplicationServices
import AppKit

@MainActor
final class FocusTracker {
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private let onFocusChange: (FocusContext?) -> Void

    init(onFocusChange: @escaping (FocusContext?) -> Void) {
        self.onFocusChange = onFocusChange
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.attach(to: app) }
        }
    }

    private func attach(to app: NSRunningApplication) {
        teardown()
        guard let pid = app.processIdentifier as pid_t?, pid > 0 else { return }

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            let tracker = Unmanaged<FocusTracker>
                .fromOpaque(refcon!).takeUnretainedValue()
            MainActor.assumeIsolated { tracker.handleFocusChanged(element) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success,
              let obs else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        // Electron and Chromium build their AX tree lazily. Ask for it, or the
        // tree is empty and every read silently returns nothing.
        let quirks = AXCompat.quirks(for: app.bundleIdentifier)
        if quirks.needsManualAccessibility {
            AXUIElementSetAttributeValue(
                appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        if quirks.needsEnhancedUI {
            AXUIElementSetAttributeValue(
                appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }

        AXObserverAddNotification(
            obs, appElement,
            kAXFocusedUIElementChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque())

        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPID = pid
        handleFocusChanged(currentFocusedElement())
    }

    private func teardown() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
    }

    private func currentFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &value) == .success
        else { return nil }
        return (value as! AXUIElement)
    }

    private func handleFocusChanged(_ element: AXUIElement?) {
        guard let element, let pid = observedPID else {
            onFocusChange(nil); return
        }
        AXUIElementSetMessagingTimeout(element, 0.25)
        onFocusChange(FocusContext(element: element, pid: pid))
    }
}
```

`AXUIElement` is a `CFType` and not `Sendable`. Keeping all AX interaction on `@MainActor` is what keeps this compiling under strict concurrency without unsafe escapes — and it matches the API's actual thread-safety guarantees.

---

## 3. Reading text and caret geometry

```swift
struct TextSnapshot: Sendable {
    let text: String
    let selectedRange: NSRange
    let caretRect: CGRect?
    let length: Int
}

@MainActor
enum TextReader {

    /// Cheap change probe — avoid pulling a large buffer on every pass.
    static func length(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &value) == .success,
            let n = value as? Int else { return nil }
        return n
    }

    static func snapshot(_ element: AXUIElement, maxChars: Int = 8_000) -> TextSnapshot? {
        guard let range = selectedRange(element) else { return nil }
        guard let total = length(of: element) else { return nil }

        let text: String
        if total <= maxChars {
            guard let full = string(element, kAXValueAttribute) else { return nil }
            text = full
        } else {
            // Windowed read — never pull a 200KB buffer for a paragraph rewrite.
            let start = max(0, range.location - maxChars / 2)
            let len = min(maxChars, total - start)
            guard let windowed = substring(element,
                                           CFRange(location: start, length: len))
            else { return nil }
            text = windowed
        }

        return TextSnapshot(text: text,
                            selectedRange: range,
                            caretRect: caretRect(element, at: range.location),
                            length: total)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success
        else { return nil }
        return v as? String
    }

    private static func selectedRange(_ e: AXUIElement) -> NSRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            e, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
            let axValue = v, CFGetTypeID(axValue) == AXValueGetTypeID()
        else { return nil }
        var r = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    private static func substring(_ e: AXUIElement, _ range: CFRange) -> String? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            e, kAXStringForRangeParameterizedAttribute as CFString,
            param, &out) == .success else { return nil }
        return out as? String
    }

    /// Screen coords, TOP-LEFT origin (CG convention). Convert before using
    /// with NSWindow, which is bottom-left.
    static func caretRect(_ e: AXUIElement, at offset: Int) -> CGRect? {
        var r = CFRange(location: offset, length: 1)
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            e, kAXBoundsForRangeParameterizedAttribute as CFString,
            param, &out) == .success, let out else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// CG top-left screen rect → AppKit bottom-left. Note: always against the
    /// PRIMARY screen, not the current one. Getting this wrong puts the card
    /// on the wrong monitor.
    static func toAppKit(_ cgRect: CGRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: cgRect.origin.x,
                      y: primaryMaxY - cgRect.origin.y - cgRect.height,
                      width: cgRect.width, height: cgRect.height)
    }
}
```

---

## 4. Keystroke monitor — the zero-cost debounce signal

```swift
import CoreGraphics
import Atomics   // swift-atomics

/// Records ONLY the time of the last text-ish keystroke. No key codes, no
/// characters, no modifiers are retained. Text always comes from the AX API.
final class KeystrokeMonitor: @unchecked Sendable {
    private let lastTick = ManagedAtomic<UInt64>(0)
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?

    var lastKeystrokeTime: UInt64 { lastTick.load(ordering: .relaxed) }

    func start() {
        let t = Thread { [weak self] in self?.runLoop() }
        t.qualityOfService = .userInteractive
        t.name = "com.quill.keystroke-tap"
        t.start()
        thread = t
    }

    private func runLoop() {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.tapDisabledByTimeout.rawValue)

        // .listenOnly => the system does NOT wait for us before delivering the
        // event. Typing latency is structurally unaffected.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let m = Unmanaged<KeystrokeMonitor>
                    .fromOpaque(refcon!).takeUnretainedValue()
                if type == .tapDisabledByTimeout {
                    m.reenable()                     // shouldn't happen; log it
                } else {
                    m.lastTick.store(mach_absolute_time(), ordering: .relaxed)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }   // Input Monitoring not granted

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
```

The callback body is one relaxed atomic store. No allocation, no locking, no logging — a slow callback gets the tap disabled by the system, and a tap that keeps getting disabled is a typing-lag bug report.

---

## 5. The orchestrator

```swift
actor SuggestionOrchestrator {
    private let provider: any RewriteProvider
    private let cache: RewriteCache
    private let policy: PolicyEngine
    private let settings: SettingsSnapshot

    private var inFlight: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var lastPassHash: Int = 0

    func keystrokeTick() {
        // Any keystroke invalidates a pending suggestion AND an in-flight
        // request. A rewrite of text the user has since changed is worse
        // than no rewrite.
        inFlight?.cancel(); inFlight = nil
        Task { @MainActor in SuggestionPanel.shared.dismiss() }

        debounce?.cancel()
        debounce = Task { [interval = settings.debounceInterval] in
            try? await Task.sleep(for: .milliseconds(interval))
            guard !Task.isCancelled else { return }
            await self.runPass(trigger: .pause)
        }
    }

    func runPass(trigger: Trigger) async {
        guard let focus = await MainActor.run(body: { FocusStore.shared.current })
        else { return }

        // Policy is a pure function and runs before ANY read.
        guard case .allow = policy.evaluate(focus: focus) else { return }

        guard let snap = await MainActor.run(body: {
            TextReader.snapshot(focus.element)
        }) else { return }

        let scope = ScopeResolver.paragraph(in: snap.text,
                                            caret: snap.selectedRange.location)
        guard scope.body.count >= 15 else { return }

        // Send-side guard: read happened, but nothing leaves if it smells
        // like a credential.
        guard !CredentialHeuristics.looksSensitive(scope.body) else {
            await Stats.shared.recordProtected(); return
        }

        let request = RewriteRequest(
            text: scope.body,
            context: scope.surroundingContext,
            tone: settings.activeTone(for: focus),
            aggressiveness: settings.aggressiveness,
            model: settings.model
        )

        // Cheap idempotence guard: don't re-run an identical pass.
        guard request.cacheKey != lastPassHash else { return }
        lastPassHash = request.cacheKey

        if let hit = cache.value(for: request.cacheKey) {
            await present(hit, original: scope.body, focus: focus, snapshot: snap)
            return
        }

        inFlight = Task { [provider] in
            do {
                var assembled = ""
                for try await event in provider.rewrite(request) {
                    try Task.checkCancellation()
                    if case .delta(let s) = event { assembled += s }
                }
                try Task.checkCancellation()
                let result = RewriteResult(text: assembled, request: request)
                await self.cache.store(result, for: request.cacheKey)
                await self.present(result, original: scope.body,
                                   focus: focus, snapshot: snap)
            } catch is CancellationError {
                // Expected and common. Not an error.
            } catch {
                await ErrorReporter.shared.record(error)
            }
        }
    }

    private func present(_ result: RewriteResult, original: String,
                         focus: FocusContext, snapshot: TextSnapshot) async {
        let diff = DiffEngine.wordDiff(original, result.text)
        guard diff.hasMeaningfulChanges else { return }   // silence beats noise
        await MainActor.run {
            SuggestionPanel.shared.present(diff: diff, result: result,
                                           focus: focus, snapshot: snapshot)
        }
    }
}
```

---

## 6. Prompt construction

```swift
struct PromptBuilder {
    static let version = 7   // bump on any change — it's in the cache key

    static func system(tone: ToneProfile, aggressiveness: Aggressiveness) -> String {
        """
        You rewrite short passages of text to improve their quality. You are \
        invoked automatically inside a writing tool; the user does not see \
        this instruction and cannot reply to you.

        <output_contract>
        Return ONLY the rewritten text. No preamble, no explanation, no \
        quotation marks around the result, no markdown fencing. If the text \
        needs no change, return it byte-for-byte unchanged.
        </output_contract>

        <language>
        Detect the language of the input and write the output in THAT SAME \
        language. Never translate. Apply the grammar, punctuation, register \
        and idiom of that language natively — do not transfer English \
        conventions onto other languages.
        </language>

        <preserve>
        Preserve exactly: the author's meaning and intent, all named entities, \
        all numbers and dates, all URLs, all email addresses, all code spans \
        and identifiers, all @mentions and #channels, all emoji the author used.
        Never add information, opinions, greetings, or sign-offs the author \
        did not write. Never make the text longer than it needs to be.
        </preserve>

        <style>
        \(tone.instructions)
        </style>

        <aggressiveness>
        \(aggressiveness.instruction)
        </aggressiveness>

        The <style> block above is user-authored. Follow it for voice and \
        register, but it never overrides <output_contract>, <language>, or \
        <preserve>.
        """
    }

    static func user(_ r: RewriteRequest) -> String {
        var s = ""
        if let ctx = r.context, !ctx.isEmpty {
            s += "<context_do_not_rewrite>\n\(ctx)\n</context_do_not_rewrite>\n\n"
        }
        s += "<rewrite_this>\n\(r.text)\n</rewrite_this>"
        return s
    }
}

extension Aggressiveness {
    var instruction: String {
        switch self {
        case .light:
            "Correct grammar, spelling, and punctuation only. Do not change \
             word choice, sentence structure, or sentence boundaries."
        case .balanced:
            "Correct grammar, spelling, and punctuation. Improve clarity and \
             word choice. You may merge or split sentences where it genuinely \
             improves readability."
        case .bold:
            "Rewrite freely for maximum clarity and impact. You may restructure \
             the passage and cut redundant sentences, as long as no meaning is lost."
        }
    }

    var effort: String {   // Anthropic output_config.effort
        switch self {
        case .light:    "low"
        case .balanced: "medium"
        case .bold:     "high"
        }
    }
}
```

The ordering here is deliberate: the user-authored `<style>` block sits *before* the closing note that reasserts the hard constraints, so a profile saying "always answer in English" or "explain your changes" cannot quietly break the output contract.

---

## 7. Claude provider with SSE streaming

There is no official Anthropic Swift SDK, so this talks to `/v1/messages` directly.

```swift
import Foundation

public actor ClaudeProvider: RewriteProvider {
    public let identifier = "anthropic"
    private let session: URLSession
    private let keychain: KeychainStore

    public init(keychain: KeychainStore) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil                       // never cache request bodies
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 15
        cfg.httpMaximumConnectionsPerHost = 2    // keep-alive, reuse the TLS session
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv13
        self.session = URLSession(configuration: cfg)
        self.keychain = keychain
    }

    public var capabilities: ProviderCapabilities {
        .init(supportsStreaming: true, supportsVariants: true,
              maxInputTokens: 200_000, requiresNetwork: true)
    }

    public func rewrite(_ r: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.stream(r, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(_ r: RewriteRequest,
                        into out: AsyncThrowingStream<RewriteEvent, Error>.Continuation)
    async throws {
        guard let key = try keychain.apiKey() else { throw ProviderError.missingKey }

        // Bound the output: a rewrite is roughly the length of its input.
        // Letting max_tokens run to 4096 invites a multi-second tail.
        let maxTokens = min(4096, Int(Double(r.approxInputTokens) * 1.4) + 64)

        var body: [String: Any] = [
            "model": r.model.apiIdentifier,          // e.g. "claude-opus-4-8"
            "max_tokens": maxTokens,
            "stream": true,
            "system": PromptBuilder.system(tone: r.tone,
                                           aggressiveness: r.aggressiveness),
            "messages": [["role": "user", "content": PromptBuilder.user(r)]],
            "output_config": ["effort": r.aggressiveness.effort],
        ]
        // NOTE: no `thinking` key. On Opus 4.8 omitting it runs WITHOUT
        // thinking, which is what a latency-sensitive rewrite wants.
        // NOTE: no temperature/top_p/top_k — those are rejected with a 400
        // on Opus 4.8 / 4.7 and Sonnet 5.

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        if r.useFastMode, r.model.supportsFastMode {
            body["speed"] = "fast"
            req.setValue("fast-mode-2026-02-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard http.statusCode == 200 else {
            throw ProviderError.http(status: http.statusCode,
                                     retryAfter: http.value(
                                        forHTTPHeaderField: "retry-after"))
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    out.yield(.delta(text))
                }
            case "message_delta":
                if let usage = obj["usage"] as? [String: Any],
                   let outTok = usage["output_tokens"] as? Int {
                    out.yield(.usage(TokenUsage(output: outTok)))
                }
            case "message_stop":
                out.yield(.done)
            case "error":
                throw ProviderError.stream(
                    (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown")
            default:
                continue
            }
        }
    }
}
```

Notes worth keeping when this gets edited later:

- **No `thinking` parameter.** Omitting it on Opus 4.8 means no thinking, which is right here — deliberation costs seconds and does not improve a grammar-and-clarity rewrite.
- **No sampling parameters.** `temperature`, `top_p`, and `top_k` return a 400 on Opus 4.8, Opus 4.7, and Sonnet 5. Style is steered through the prompt.
- **No `cache_control`.** The system prompt is a few hundred tokens, below the 4096-token minimum cacheable prefix on Opus 4.8, so a cache breakpoint here would silently never fire. Add one only if a tone profile grows to include a large style guide, and verify with `usage.cache_read_input_tokens` before believing it works.
- Fast mode uses the **beta** messages endpoint semantics — it has its own rate limit, so on a 429 either honour `retry-after` or drop `speed` and retry standard.

---

## 8. Applying the rewrite

```swift
@MainActor
enum TextWriter {
    enum Strategy { case axSet, paste }

    static func apply(_ replacement: String,
                      to element: AXUIElement,
                      range: NSRange,
                      expectedOriginal: String,
                      strategy: Strategy) -> Bool {

        // Re-verify immediately before writing. The user may have typed
        // between the read and the accept.
        guard let current = TextReader.snapshot(element),
              current.text.contains(expectedOriginal) else { return false }

        switch strategy {
        case .axSet:
            if setViaAX(replacement, element, range),
               verify(element, contains: replacement) { return true }
            // AX writes report success and no-op in most web content.
            // Fall through rather than trusting the return value.
            fallthrough
        case .paste:
            return pasteReplace(replacement, element, range)
        }
    }

    private static func setViaAX(_ text: String,
                                 _ e: AXUIElement, _ range: NSRange) -> Bool {
        var r = CFRange(location: range.location, length: range.length)
        guard let rv = AXValueCreate(.cfRange, &r) else { return false }
        guard AXUIElementSetAttributeValue(
            e, kAXSelectedTextRangeAttribute as CFString, rv) == .success
        else { return false }
        return AXUIElementSetAttributeValue(
            e, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private static func pasteReplace(_ text: String,
                                     _ e: AXUIElement, _ range: NSRange) -> Bool {
        let pb = NSPasteboard.general
        let savedItems = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        } ?? []
        let savedCount = pb.changeCount

        // Select the span we're replacing.
        var r = CFRange(location: range.location, length: range.length)
        if let rv = AXValueCreate(.cfRange, &r) {
            AXUIElementSetAttributeValue(
                e, kAXSelectedTextRangeAttribute as CFString, rv)
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Ask well-behaved clipboard managers not to record this.
        pb.setString("", forType: .init("org.nspasteboard.TransientType"))
        pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))

        postCommandV()

        let settle = AXCompat.quirks(for: frontmostBundleID()).pasteSettleMS
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(settle)) {
            // Don't clobber something the user copied during the window.
            guard pb.changeCount == savedCount + 1 else { return }
            pb.clearContents()
            for item in savedItems {
                let pbItem = NSPasteboardItem()
                for (type, data) in item { pbItem.setData(data, forType: type) }
                pb.writeObjects([pbItem])
            }
        }
        return true
    }

    private static func postCommandV() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        src.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents], state: .eventSuppressionStateSuppressionInterval)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
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
```

The paste path is the workhorse. It is the only strategy that works in browsers and Electron, and it is the only one that preserves the host app's native undo stack — the app sees an ordinary paste, so `⌘Z` behaves exactly as the user expects.

---

## 9. Non-activating suggestion panel

```swift
final class SuggestionPanel: NSPanel {
    static let shared = SuggestionPanel()

    private init() {
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)

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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(diff: WordDiff, result: RewriteResult,
                 focus: FocusContext, snapshot: TextSnapshot) {
        contentViewController = NSHostingController(
            rootView: SuggestionView(diff: diff, result: result))
        layoutIfNeeded()

        guard let cgCaret = snapshot.caretRect else { presentAtMouse(); return }
        let caret = TextReader.toAppKit(cgCaret)
        let size = contentViewController!.view.fittingSize

        var origin = CGPoint(x: caret.minX, y: caret.minY - size.height - 8)
        // Flip above the caret if we'd fall off the bottom of the screen.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }),
           origin.y < screen.visibleFrame.minY {
            origin.y = caret.maxY + 8
        }
        setFrame(CGRect(origin: origin, size: size), display: true)
        orderFrontRegardless()   // NOT makeKeyAndOrderFront
    }
}
```

`orderFrontRegardless()` rather than `makeKeyAndOrderFront(_:)` is the load-bearing detail — the latter activates Quill, the host app loses focus, the caret stops blinking, and the illusion of a system service collapses.

Because the panel never becomes key, `Tab` and `Esc` must be captured by a global hotkey handler that is registered only while a suggestion is showing, and unregistered the moment it is dismissed — otherwise Quill swallows `Tab` system-wide.

---

## 10. Keychain

```swift
import Security

struct KeychainStore {
    private let service = "com.quill.app.anthropic"
    private let account = "default"

    func store(apiKey: String) throws {
        let data = Data(apiKey.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        // ThisDeviceOnly: an API key silently syncing via iCloud Keychain to
        // the user's other machines is a surprise they didn't ask for.
        add[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func apiKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw KeychainError.status(status)
        }
        return String(data: data, encoding: .utf8)
    }
}
```

---

## 11. Word-level diff

```swift
struct WordDiff: Sendable {
    enum Op: Sendable { case equal(String), insert(String), delete(String) }
    let ops: [Op]

    var hasMeaningfulChanges: Bool {
        let changed = ops.reduce(0) { acc, op in
            switch op {
            case .equal: acc
            case .insert(let s), .delete(let s): acc + s.count
            }
        }
        // Suppress trivial diffs — a single changed comma is noise, and
        // showing a card for it trains users to reflexively hit Esc.
        return changed >= 4
    }
}

enum DiffEngine {
    static func wordDiff(_ a: String, _ b: String) -> WordDiff {
        let aw = tokenize(a), bw = tokenize(b)
        // CollectionDifference is Myers under the hood — no dependency needed.
        let diff = bw.difference(from: aw)

        var ops: [WordDiff.Op] = []
        var removals = Set(diff.removals.map(\.offset))
        var insertsByOffset = Dictionary(
            grouping: diff.insertions, by: \.offset)

        for (i, word) in aw.enumerated() {
            if let ins = insertsByOffset[i] {
                ops.append(.insert(ins.map(\.element).joined()))
            }
            ops.append(removals.contains(i) ? .delete(word) : .equal(word))
        }
        if let tail = insertsByOffset[aw.count] {
            ops.append(.insert(tail.map(\.element).joined()))
        }
        return WordDiff(ops: coalesce(ops))
    }

    /// Split into words WITH their trailing whitespace so reassembly is lossless.
    private static func tokenize(_ s: String) -> [String] { /* … */ }
    private static func coalesce(_ ops: [WordDiff.Op]) -> [WordDiff.Op] { /* … */ }
}

private extension CollectionDifference.Change {
    var offset: Int {
        switch self { case .insert(let o, _, _), .remove(let o, _, _): o }
    }
    var element: ChangeElement {
        switch self { case .insert(_, let e, _), .remove(_, let e, _): e }
    }
}
```

`CollectionDifference` gives a Myers diff from the standard library, so the diff engine needs no third-party dependency — which matters in a process holding Accessibility permission.
