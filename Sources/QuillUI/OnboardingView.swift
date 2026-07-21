import AppKit
import QuillAccessibility
import QuillAI
import QuillCore
import QuillStorage
import SwiftUI

/// First-run setup: Accessibility, then the API key. Both are required before
/// the app can do anything at all, and a menu bar agent has nowhere to explain
/// itself — without this the first experience is an icon that does nothing.
public struct OnboardingView: View {
    public enum Step { case permission, apiKey, done }

    @State private var step: Step = .permission
    @State private var trust = AXTrustMonitor.shared
    @State private var keyInput = ""
    @State private var isValidating = false
    @State private var keyError: String?

    private let keychain = KeychainStore()
    private let provider = OpenAIProvider()
    private let onFinish: () -> Void

    public init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .permission: permissionStep
                case .apiKey: apiKeyStep
                case .done: doneStep
                }
            }
            .padding(24)
        }
        .frame(width: 480)
        .onChange(of: trust.isTrusted) { _, isTrusted in
            // The monitor polls, so this advances on its own the moment the
            // switch is flipped in System Settings — no "click Continue" step
            // that the user can be staring at having already granted it.
            if isTrusted, step == .permission { step = nextAfterPermission() }
        }
        .onAppear {
            if trust.isTrusted { step = nextAfterPermission() }
        }
    }

    private func nextAfterPermission() -> Step {
        keychain.hasKey ? .done : .apiKey
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.tip.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Quill").font(.headline)
                Text("Rewrites your writing in any app.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Step 1

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Step 1 of 2 — Accessibility", systemImage: "1.circle.fill")
                .font(.subheadline.weight(.medium))

            Text("Quill reads the text field you're typing in, and writes the rewrite back. macOS calls this Accessibility permission, and it can't be granted on your behalf.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("Quill never reads password fields, and skips terminals and password managers entirely.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open System Settings") {
                    // Prompt first so Quill is listed, then open the pane —
                    // otherwise the user arrives at a list it isn't in yet.
                    AXPermissions.requestTrust()
                    AXPermissions.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)

                if trust.isTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Skip") { step = nextAfterPermission() }
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: - Step 2

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Step 2 of 2 — OpenAI API key", systemImage: "2.circle.fill")
                .font(.subheadline.weight(.medium))

            Text("Quill sends text straight to OpenAI using your own key. There is no Quill server, so nobody else can see what you write.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-…", text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            Text("A ChatGPT subscription doesn't include API access — the key needs its own credit balance.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link("Create a key at platform.openai.com",
                 destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.callout)

            if let keyError {
                Label(keyError, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Save & Verify", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(keyInput.isEmpty || isValidating)
                if isValidating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Skip for now") { step = .done }
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: - Step 3

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("You're set up", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)

            Text("Put the caret in any paragraph and press ⌥⌘K, or click the pencil button that appears beside the text field.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("Quill lives in the menu bar — there's no Dock icon. Everything is configurable from there.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Start writing") { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isValidating = true
        keyError = nil
        Task {
            let result = await provider.validateKey(key, model: SettingsStore.shared.model)
            isValidating = false
            switch result {
            case .success:
                do {
                    try keychain.store(apiKey: key)
                    keyInput = ""
                    step = .done
                } catch {
                    keyError = error.localizedDescription
                }
            case let .failure(error):
                keyError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

/// Hosts the onboarding flow in a real window.
///
/// An `LSUIElement` app has no Dock icon and cannot normally front a window, so
/// the activation policy is raised to `.regular` for the duration and dropped
/// back afterwards. Without that the window opens behind whatever the user is
/// looking at, which is indistinguishable from the app not launching.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    public static let shared = OnboardingWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    /// Shows setup when something is actually missing. A user who has already
    /// granted permission and stored a key never sees this again.
    public func presentIfNeeded() {
        let settings = SettingsStore.shared
        let needsSetup = !AXPermissions.isTrusted || !KeychainStore().hasKey
        guard needsSetup || !settings.hasCompletedOnboarding else { return }
        present()
    }

    public func present() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            center(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView { [weak self] in self?.finish() }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Quill Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        center(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// `NSWindow.center()` is unreliable here — for an accessory app being
    /// promoted to `.regular` it has placed this window past the right edge of
    /// a wide display, where it is technically "on screen" and completely
    /// invisible. Compute the origin from the visible frame instead, and clamp
    /// it so the window can never land off-screen.
    ///
    /// Sizing has to happen before positioning: a SwiftUI window reports a
    /// placeholder frame until its content is laid out, and centring against
    /// that puts the real window half a screen off.
    private func center(_ window: NSWindow) {
        if let content = window.contentViewController?.view {
            content.layoutSubtreeIfNeeded()
            let fitting = content.fittingSize
            if fitting.width > 1, fitting.height > 1 {
                window.setContentSize(fitting)
            }
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        let x = min(max(visible.midX - size.width / 2, visible.minX),
                    visible.maxX - size.width)
        let y = min(max(visible.midY - size.height / 2, visible.minY),
                    visible.maxY - size.height)
        window.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func finish() {
        SettingsStore.shared.hasCompletedOnboarding = true
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        // Closing by any route marks setup as seen, and drops the app back to
        // being an agent — a Dock icon left behind here would be a bug.
        SettingsStore.shared.hasCompletedOnboarding = true
        NSApp.setActivationPolicy(.accessory)
    }
}
