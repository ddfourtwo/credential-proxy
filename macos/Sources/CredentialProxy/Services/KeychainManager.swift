import Foundation
import Security

/// Manages credential storage in macOS Keychain.
/// Each secret is stored as a generic password with:
///   - service: "com.credential-proxy.secrets"
///   - account: the secret name (e.g., "GITHUB_TOKEN")
///   - value: encrypted with the seal key (AES-256-GCM via SealKeyManager)
///
/// Uses a permissive SecAccess so that rebuilds of the binary don't trigger
/// per-credential Keychain password prompts. Security is provided by the
/// seal key encryption, not Keychain ACLs.
final class KeychainManager {
    static let shared = KeychainManager()
    private let service = "com.credential-proxy.secrets"

    private init() {}

    /// Create a SecAccess that allows any application to access the item.
    /// This prevents macOS from prompting for each credential after a binary rebuild.
    private func createPermissiveAccess(label: String) -> SecAccess? {
        var access: SecAccess?
        let status = SecAccessCreate(label as CFString, nil, &access)
        guard status == errSecSuccess, let access = access else { return nil }

        // Get all ACLs and remove the trusted app restriction from each
        guard let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationAny) as? [SecACL] else {
            return access
        }
        for acl in acls {
            var apps: CFArray?
            var desc: CFString?
            var prompt: SecKeychainPromptSelector = []
            SecACLCopyContents(acl, &apps, &desc, &prompt)
            // nil apps = any application can access (no per-app restriction)
            SecACLSetContents(acl, nil, desc ?? "" as CFString, prompt)
        }
        return access
    }

    func store(name: String, value: String) throws {
        // Encrypt the value with the seal key
        let encrypted = try SealKeyManager.shared.encrypt(value)

        // Delete existing item first (update = delete + add)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: encrypted,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Credential Proxy: \(name)"
        ]
        if let access = createPermissiveAccess(label: "Credential Proxy: \(name)") {
            addQuery[kSecAttrAccess as String] = access
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    func retrieve(name: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.retrieveFailed(status)
        }

        // Try to decrypt with seal key (normal path)
        if let decrypted = try? SealKeyManager.shared.decrypt(data) {
            return decrypted
        }

        // Legacy fallback: unencrypted value from before seal key was introduced.
        // Transparently re-encrypt it for next time.
        if let plaintext = String(data: data, encoding: .utf8) {
            try? store(name: name, value: plaintext)
            return plaintext
        }

        return nil
    }

    func delete(name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func list() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError.listFailed(status)
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

enum KeychainError: LocalizedError {
    case encodingFailed
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case listFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode secret value"
        case .storeFailed(let s): return "Keychain store failed: \(s)"
        case .retrieveFailed(let s): return "Keychain retrieve failed: \(s)"
        case .deleteFailed(let s): return "Keychain delete failed: \(s)"
        case .listFailed(let s): return "Keychain list failed: \(s)"
        }
    }
}
