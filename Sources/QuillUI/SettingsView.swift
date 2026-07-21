import AppKit
import QuillAI
import QuillAccessibility
import QuillCore
import QuillStorage
import SwiftUI

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            AccountSettingsView().tabItem { Label("API Key", systemImage: "key") }
            PermissionsSettingsView().tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 340)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @State private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("Tone", selection: $settings.tone) {
                    ForEach(ToneProfile.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Rewrite strength", selection: $settings.aggressiveness) {
                    ForEach(Aggressiveness.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            Section {
                Picker("Model", selection: $settings.model) {
                    ForEach(RewriteModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Rewrite strength also sets how much the model deliberates. Light and Balanced skip it entirely, which is what keeps a rewrite under a second.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pause Quill", isOn: $settings.isPaused)
                LabeledContent("Shortcut") {
                    Text("⌥⌘K").font(.system(.body, design: .rounded))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - API key

struct AccountSettingsView: View {
    @State private var keyInput = ""
    @State private var status: Status = .unknown
    @State private var isValidating = false

    private let keychain = KeychainStore()
    private let provider = OpenAIProvider()

    enum Status: Equatable {
        case unknown, stored, valid, invalid(String)
    }

    var body: some View {
        Form {
            Section {
                SecureField("sk-…", text: $keyInput)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save & Verify") { save() }
                        .disabled(keyInput.isEmpty || isValidating)
                    Button("Remove") {
                        try? keychain.deleteAPIKey()
                        keyInput = ""
                        status = .unknown
                    }
                    if isValidating { ProgressView().controlSize(.small) }
                    Spacer()
                }

                statusLine
            } header: {
                Text("OpenAI API key")
            } footer: {
                Text("Stored in the macOS Keychain, this device only, never synced to iCloud. Quill talks directly to api.openai.com — there is no Quill server, so your text is never seen by anyone but you and OpenAI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Link("Create a key in the OpenAI dashboard",
                     destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.callout)
            } footer: {
                Text("A ChatGPT Plus or Pro subscription does not provide API access — those are separate products with separate billing. Quill needs a platform API key with credits on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if (try? keychain.apiKey()) ?? nil != nil { status = .stored }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .unknown:
            Text("No key stored.").font(.caption).foregroundStyle(.secondary)
        case .stored:
            Label("Key stored.", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .valid:
            Label("Key verified.", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        case let .invalid(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isValidating = true
        Task {
            let result = await provider.validateKey(key, model: SettingsStore.shared.model)
            isValidating = false
            switch result {
            case .success:
                do {
                    try keychain.store(apiKey: key)
                    keyInput = ""
                    status = .valid
                } catch {
                    status = .invalid(error.localizedDescription)
                }
            case let .failure(error):
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                status = .invalid(message)
            }
        }
    }
}

// MARK: - Permissions

struct PermissionsSettingsView: View {
    @State private var isTrusted = AXPermissions.isTrusted
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility") {
                    Label(
                        isTrusted ? "Granted" : "Not granted",
                        systemImage: isTrusted ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(isTrusted ? .green : .red)
                }
                if !isTrusted {
                    Button("Grant Accessibility…") { AXPermissions.requestTrust() }
                    Button("Open System Settings…") { AXPermissions.openAccessibilitySettings() }
                }
            } footer: {
                Text("Quill reads the text in the focused field and writes the rewrite back. Both require Accessibility. Trust can be revoked while Quill is running, so this is re-checked every 2 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Quill is not sandboxed — the Accessibility API requires it. That means the Mac App Store is not a distribution option; see docs/09-risks.md §1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in isTrusted = AXPermissions.isTrusted }
    }
}
