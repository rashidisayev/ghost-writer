import AppKit
import ApplicationServices
import QuillAI
import QuillAccessibility
import QuillCore
import QuillInput
import QuillStorage
import SwiftUI

/// Drives one pass: read focused text → scope to the paragraph → policy → OpenAI
/// → present diff → write back on accept.
///
/// v1 is hotkey-triggered (⌥⌘K). The continuous keystroke-debounce path from
/// docs/02-architecture.md needs Input Monitoring on top of Accessibility and is
/// deliberately deferred — see README "Status" for the phase gate.
@MainActor
@Observable
public final class RewriteCoordinator {
    public static let shared = RewriteCoordinator()

    private let provider = OpenAIProvider()
    private let settings = SettingsStore.shared

    private var inFlight: Task<Void, Never>?
    private var acceptToken: UInt32?
    private var dismissToken: UInt32?

    /// Captured at read time so accept writes to exactly what we rewrote.
    private var pendingElement: AXUIElement?
    private var pendingRange: NSRange?
    private var pendingOriginal: String?
    private var pendingBundleID: String?

    public private(set) var lastError: String?
    public private(set) var isWorking = false

    private init() {}

    // MARK: - Trigger

    public func triggerRewrite() {
        guard AXPermissions.isTrusted else {
            presentFailure("Quill needs Accessibility permission. Open Settings to grant it.")
            return
        }
        guard !settings.isPaused else { return }

        cancelInFlight()

        guard let app = TargetAppTracker.shared.target else {
            presentFailure("No text field focused.")
            return
        }

        // Priming MUST precede the focus query. Electron and Chromium build no
        // accessibility tree until asked, so asking for focus first returns
        // nothing and this bails out before the priming it needed ever runs.
        TextReader.primeLazyAccessibility(
            for: app.processIdentifier, bundleID: app.bundleIdentifier)

        guard let element = TextReader.focusedElement(in: app.processIdentifier)
            ?? TextReader.focusedElement() else {
            presentFailure("No text field focused in \(app.localizedName ?? "that app").")
            return
        }

        // Policy is a pure function and runs before ANY read.
        let descriptor = TextReader.describe(element, bundleID: app.bundleIdentifier)
        switch settings.policy.evaluate(descriptor) {
        case .allow:
            break
        case .denySecureField:
            presentFailure("Quill never reads secure fields.")
            return
        case .denyNotEditable:
            presentFailure("That isn't an editable text field.")
            return
        case let .denyExcludedApp(bundle):
            presentFailure("Quill is disabled in \(bundle).")
            return
        case .denyPaused:
            return
        }

        guard let snapshot = TextReader.snapshot(element) else {
            presentFailure("Couldn't read text from this app. Its accessibility tree may be unavailable.")
            return
        }

        // Selection wins over paragraph scope when the user made one.
        let scope: TextScope
        if snapshot.selectedRange.length >= ScopeResolver.minimumBodyLength,
           let selected = Self.substring(snapshot.text, snapshot.selectedRange, offset: snapshot.windowOffset) {
            scope = TextScope(body: selected, range: snapshot.selectedRange, surroundingContext: nil)
        } else {
            let caretInWindow = snapshot.selectedRange.location - snapshot.windowOffset
            guard let resolved = ScopeResolver.paragraph(in: snapshot.text, caret: caretInWindow) else {
                presentFailure("Not enough text to rewrite — write at least \(ScopeResolver.minimumBodyLength) characters.")
                return
            }
            scope = TextScope(
                body: resolved.body,
                range: NSRange(
                    location: resolved.range.location + snapshot.windowOffset,
                    length: resolved.range.length
                ),
                surroundingContext: resolved.surroundingContext
            )
        }

        // Send-side guard: the read happened, but nothing leaves if it smells
        // like a credential.
        guard !CredentialHeuristics.looksSensitive(scope.body) else {
            presentFailure("That text looks like it contains a credential. Nothing was sent.")
            return
        }

        pendingElement = element
        pendingRange = scope.range
        pendingOriginal = scope.body
        pendingBundleID = descriptor.bundleIdentifier

        let request = RewriteRequest(
            text: scope.body,
            context: scope.surroundingContext,
            tone: settings.tone,
            aggressiveness: settings.aggressiveness,
            model: settings.model
        )

        isWorking = true
        lastError = nil
        present(state: .working, anchor: snapshot.caretRect)

        inFlight = Task { [provider] in
            var assembled = ""
            do {
                for try await event in provider.rewrite(request) {
                    try Task.checkCancellation()
                    if case let .delta(chunk) = event { assembled += chunk }
                }
                try Task.checkCancellation()
                self.finish(rewritten: assembled, original: scope.body, anchor: snapshot.caretRect)
            } catch is CancellationError {
                // Expected and common. Not an error.
            } catch {
                self.isWorking = false
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.presentFailure(message)
            }
        }
    }

    // MARK: - Completion

    private func finish(rewritten raw: String, original: String, anchor: CGRect?) {
        isWorking = false
        let rewritten = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rewritten.isEmpty else {
            dismiss()
            return
        }

        let diff = DiffEngine.wordDiff(original, rewritten)
        // Silence beats noise: no card at all when nothing meaningful changed.
        guard diff.hasMeaningfulChanges else {
            dismiss()
            return
        }

        present(
            state: .ready(.init(ops: diff.ops, replacement: rewritten)),
            anchor: anchor
        )
    }

    private func accept(_ replacement: String) {
        defer { dismiss() }
        guard let element = pendingElement,
              let range = pendingRange,
              let original = pendingOriginal else { return }

        let applied = TextWriter.apply(
            replacement,
            to: element,
            range: range,
            expectedOriginal: original,
            bundleID: pendingBundleID
        )
        if !applied {
            NSSound.beep()
        }
    }

    // MARK: - Panel plumbing

    private func present(state: SuggestionView.State, anchor: CGRect?) {
        SuggestionPanel.shared.present(
            state: state,
            anchor: anchor,
            onAccept: { [weak self] in
                if case let .ready(box) = state { self?.accept(box.replacement) }
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        bindTransientHotkeys(acceptEnabled: {
            if case .ready = state { return true } else { return false }
        }(), state: state)
    }

    private func presentFailure(_ message: String) {
        lastError = message
        isWorking = false
        present(state: .failed(message), anchor: nil)
        // Failure cards self-dismiss; they're informational, not actionable.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, case .some = self.lastError else { return }
            self.dismiss()
        }
    }

    /// Tab and Esc are registered ONLY while a suggestion is showing, and
    /// unregistered the moment it's dismissed — otherwise Quill swallows Tab
    /// system-wide.
    private func bindTransientHotkeys(acceptEnabled: Bool, state: SuggestionView.State) {
        releaseTransientHotkeys()
        dismissToken = HotkeyManager.shared.register(.dismiss) { [weak self] in
            self?.dismiss()
        }
        guard acceptEnabled, case let .ready(box) = state else { return }
        acceptToken = HotkeyManager.shared.register(.accept) { [weak self] in
            self?.accept(box.replacement)
        }
    }

    private func releaseTransientHotkeys() {
        if let acceptToken { HotkeyManager.shared.unregister(acceptToken) }
        if let dismissToken { HotkeyManager.shared.unregister(dismissToken) }
        acceptToken = nil
        dismissToken = nil
    }

    public func dismiss() {
        cancelInFlight()
        releaseTransientHotkeys()
        SuggestionPanel.shared.dismiss()
        lastError = nil
        pendingElement = nil
        pendingRange = nil
        pendingOriginal = nil
        pendingBundleID = nil
    }

    private func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
        isWorking = false
    }

    // MARK: - Helpers

    /// `range` came from AX and is therefore UTF-16. NSString indexes in the
    /// same units, so it slices correctly where `Array(text)` — which indexes
    /// by Character — silently returns the wrong substring for any text with
    /// emoji or combining marks.
    private static func substring(_ text: String, _ range: NSRange, offset: Int) -> String? {
        let ns = text as NSString
        let start = range.location - offset
        guard start >= 0, range.length > 0, start + range.length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: start, length: range.length))
    }
}
