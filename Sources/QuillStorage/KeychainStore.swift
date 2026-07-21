import Foundation
import Security

public enum KeychainError: Error, LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .status(code):
            let message = SecCopyErrorMessageString(code, nil) as String? ?? "unknown"
            return "Keychain error \(code): \(message)"
        }
    }
}

public struct KeychainStore: Sendable {
    private let service = "com.quill.app.openai"
    private let account = "default"

    public init() {}

    /// The data protection keychain is the modern one and the one we want, but
    /// it requires a keychain-access-group entitlement, which is derived from a
    /// Team ID. An ad-hoc signature has no Team ID, so every call fails with
    /// errSecMissingEntitlement (-34018) — which is what a local build off
    /// Scripts/build-app.sh is. Fall back to the file-based keychain there.
    ///
    /// This does NOT weaken the iCloud promise in Settings: items sync only when
    /// kSecAttrSynchronizable is true, and it is never set here. What is lost is
    /// kSecAttrAccessible, which the file-based keychain ignores — the item is
    /// protected by the login keychain's own unlock state instead.
    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        return q
    }

    public func store(apiKey: String) throws {
        // Clear both keychains first. Reads check data protection before the
        // file-based one, so an item left behind there would shadow the new key.
        _ = SecItemDelete(baseQuery(dataProtection: true) as CFDictionary)
        _ = SecItemDelete(baseQuery(dataProtection: false) as CFDictionary)

        var query = baseQuery(dataProtection: true)
        query[kSecValueData as String] = Data(apiKey.utf8)
        // ThisDeviceOnly: an API key silently syncing via iCloud Keychain to the
        // user's other machines is a surprise they didn't ask for.
        // AfterFirstUnlock rather than WhenUnlocked so the agent works after a
        // reboot-and-login without a second prompt.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // kSecAttrAccessible is meaningless to the file-based keychain, so
            // it is dropped rather than passed and silently ignored.
            var legacy = baseQuery(dataProtection: false)
            legacy[kSecValueData as String] = Data(apiKey.utf8)
            status = SecItemAdd(legacy as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func apiKey() throws -> String? {
        // A miss on the data protection keychain comes back as errSecItemNotFound,
        // NOT errSecMissingEntitlement — so "not found" has to fall through to the
        // file-based keychain too, or an ad-hoc build never reads back what it
        // just wrote.
        for dataProtection in [true, false] {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            switch status {
            case errSecSuccess:
                guard let data = out as? Data else { throw KeychainError.status(status) }
                return String(data: data, encoding: .utf8)
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw KeychainError.status(status)
            }
        }
        return nil
    }

    public func deleteAPIKey() throws {
        // Remove from both, so "Remove" can't leave a copy behind in the one
        // this build happens not to be using.
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess
                || status == errSecItemNotFound
                || status == errSecMissingEntitlement else {
                throw KeychainError.status(status)
            }
        }
    }

    public var hasKey: Bool { (try? apiKey()) .flatMap { $0 } != nil }
}
