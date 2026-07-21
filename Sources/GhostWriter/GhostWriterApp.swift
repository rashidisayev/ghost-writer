import AppKit
import GhostWriterAccessibility
import GhostWriterCore
import GhostWriterInput
import GhostWriterStorage
import GhostWriterUI
import SwiftUI

@main
struct GhostWriterApp: App {
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
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Ghost Writer")
            ?? NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: "Ghost Writer")!
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

        Toggle("Pause Ghost Writer", isOn: $settings.isPaused)

        Picker("Tone", selection: $settings.tone) {
            ForEach(ToneProfile.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        Picker("Strength", selection: $settings.aggressiveness) {
            ForEach(Aggressiveness.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }

        Divider()

        Button("Copy diagnostics") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(Diagnostics.report(), forType: .string)
        }

        Divider()

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",", modifiers: .command)

        Button("Quit Ghost Writer") { NSApplication.shared.terminate(nil) }
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
        // makes Ghost Writer frontmost, and this is what remembers where the user was.
        TargetAppTracker.shared.start()

        // Follows focus and shows the highlight + rewrite button.
        FieldOverlay.shared.start()

    }

    func applicationWillTerminate(_ notification: Notification) {
        RewriteCoordinator.shared.dismiss()
    }
}
