import AppKit
import QuillAccessibility
import QuillCore
import QuillInput
import QuillStorage
import QuillUI
import SwiftUI

@main
struct QuillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var settings = SettingsStore.shared
    @State private var trust = AXTrustMonitor.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(isTrusted: trust.isTrusted)
        } label: {
            Image(nsImage: menuBarImage)
        }
        .menuBarExtraStyle(.menu)

        Settings { SettingsView() }
    }

    private var menuBarSymbol: String {
        if !trust.isTrusted { return "exclamationmark.circle" }
        if settings.isPaused { return "pencil.tip.crop.circle" }
        return "pencil.tip.crop.circle.fill"
    }

    /// Resolve the symbol ourselves so a name that doesn't exist on this OS
    /// can't produce an *invisible* menu bar item. `Image(systemName:)` renders
    /// nothing in that case, and the failure is silent — which is worst in the
    /// untrusted state, the one where the user has to click the item to grant
    /// Accessibility. Degrade to a symbol that has shipped since Big Sur.
    private var menuBarImage: NSImage {
        let symbol = menuBarSymbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Quill")
            ?? NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: "Quill")!
        image.isTemplate = true
        return image
    }
}

private struct MenuContent: View {
    let isTrusted: Bool
    @State private var settings = SettingsStore.shared

    var body: some View {
        if !isTrusted {
            Button("Grant Accessibility permission…") {
                AXPermissions.requestTrust()
                AXPermissions.openAccessibilitySettings()
            }
            Divider()
        }

        Button("Rewrite selection  ⌥⌘K") {
            RewriteCoordinator.shared.triggerRewrite()
        }
        .disabled(!isTrusted || settings.isPaused)

        Divider()

        Toggle("Pause Quill", isOn: $settings.isPaused)

        Picker("Tone", selection: $settings.tone) {
            ForEach(ToneProfile.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        Picker("Strength", selection: $settings.aggressiveness) {
            ForEach(Aggressiveness.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }

        Divider()

        Button("Setup…") { OnboardingWindowController.shared.present() }

        Button("Copy diagnostics") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(Diagnostics.report(), forType: .string)
        }

        Divider()

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",", modifiers: .command)

        Button("Quit Quill") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement is set in Info.plist; this is belt-and-braces for the case
        // where the binary is launched outside the bundle.
        NSApp.setActivationPolicy(.accessory)

        // Register the global trigger. Deliberately NOT prompting for
        // Accessibility here — prompting at launch is how you get denied before
        // you've explained anything (docs/10 §1).
        HotkeyManager.shared.register(.rewrite) {
            RewriteCoordinator.shared.triggerRewrite()
        }

        // TCC never calls back when a grant changes, so poll for it.
        AXTrustMonitor.shared.start()

        // Must be running before the first rewrite: clicking the menu bar item
        // makes Quill frontmost, and this is what remembers where the user was.
        TargetAppTracker.shared.start()

        // Follows focus and shows the highlight + rewrite button.
        FieldOverlay.shared.start()

        // First run: explain, then ask. Note this shows a window rather than
        // firing the TCC prompt directly at launch — see docs/10 §1, a prompt
        // with no explanation in front of it is a prompt that gets denied.
        OnboardingWindowController.shared.presentIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        RewriteCoordinator.shared.dismiss()
    }
}
