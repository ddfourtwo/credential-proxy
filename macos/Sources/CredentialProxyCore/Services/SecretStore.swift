import Foundation

/// Manages secret metadata (JSON file) and secret values (Keychain).
///
/// The metadata file (secrets.json) is HMAC-signed with the seal key.
/// On every save, the HMAC is written to secrets.json.sig.
/// On every load, the HMAC is verified — if tampered, the store refuses to load.
/// This prevents agents from widening allowedDomains by editing the file directly.
public actor SecretStore {
    public static let shared = SecretStore()

    private let keychain = KeychainManager.shared
    private let secretsFilePath: URL
    private var signaturePath: URL { secretsFilePath.appendingPathExtension("sig") }

    private static let namePattern = try! NSRegularExpression(pattern: "^[A-Z][A-Z0-9_]*$")
    private static let domainPattern = try! NSRegularExpression(
        pattern: #"^(\*\.)?[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$"#
    )

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("credential-proxy")
        secretsFilePath = dir.appendingPathComponent("secrets.json")
    }

    // MARK: - Store Operations

    public func loadStore() throws -> SecretsStore {
        guard FileManager.default.fileExists(atPath: secretsFilePath.path) else {
            return SecretsStore(version: CURRENT_VERSION, secrets: [:])
        }

        let data = try Data(contentsOf: secretsFilePath)

        // Verify HMAC if seal key is available
        if SealKeyManager.shared.isUnlocked {
            guard FileManager.default.fileExists(atPath: signaturePath.path) else {
                throw SecretStoreError.signatureMissing
            }
            let signature = try Data(contentsOf: signaturePath)
            guard try SealKeyManager.shared.verifyHMAC(data, signature: signature) else {
                throw SecretStoreError.metadataTampered
            }
        }

        let store = try JSONDecoder().decode(SecretsStore.self, from: data)

        if store.version == 1 {
            return try migrateV1ToV2(store)
        }

        return store
    }

    public func saveStore(_ store: SecretsStore) throws {
        let dir = secretsFilePath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        try data.write(to: secretsFilePath, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsFilePath.path)

        // Sign the metadata file
        if SealKeyManager.shared.isUnlocked {
            try signData(data)
        }
    }

    /// Whether the metadata file exists but has no HMAC signature.
    public var needsSignature: Bool {
        FileManager.default.fileExists(atPath: secretsFilePath.path)
            && !FileManager.default.fileExists(atPath: signaturePath.path)
    }

    /// Read the current secrets.json, re-write it through saveStore() to generate a valid signature.
    /// Call this only after explicit user authentication (Touch ID / system password).
    public func resignMetadata() throws {
        // Bypass HMAC check — read raw data and decode
        let data = try Data(contentsOf: secretsFilePath)
        let store = try JSONDecoder().decode(SecretsStore.self, from: data)
        // saveStore() writes the file and signs it
        try saveStore(store)
    }

    private func signData(_ data: Data) throws {
        let signature = try SealKeyManager.shared.hmac(data)
        try signature.write(to: signaturePath, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: signaturePath.path)
    }

    public func migrateV1ToV2(_ store: SecretsStore) throws -> SecretsStore {
        // Re-decode secrets as legacy format
        let data = try JSONEncoder().encode(store)
        let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rawSecrets = raw["secrets"] as? [String: Any] ?? [:]

        var migrated = SecretsStore(version: CURRENT_VERSION, secrets: [:])

        for (name, value) in rawSecrets {
            guard let secretDict = value as? [String: Any],
                  let encryptedValue = secretDict["encryptedValue"] as? String else {
                continue
            }

            let allowedDomains = secretDict["allowedDomains"] as? [String] ?? []
            let placementStrings = secretDict["allowedPlacements"] as? [String] ?? []
            let placements = placementStrings.compactMap { SecretPlacement(rawValue: $0) }

            migrated.secrets[name] = SecretMetadata(
                source: .encrypted(encryptedValue: encryptedValue),
                allowedDomains: allowedDomains,
                allowedPlacements: placements,
                allowedCommands: nil,
                createdAt: secretDict["createdAt"] as? String ?? ISO8601DateFormatter().string(from: Date()),
                lastUsed: secretDict["lastUsed"] as? String,
                usageCount: secretDict["usageCount"] as? Int ?? 0
            )
        }

        try saveStore(migrated)
        return migrated
    }

    // MARK: - CRUD Operations

    public func addSecret(
        name: String,
        value: String,
        allowedDomains: [String],
        allowedPlacements: [SecretPlacement] = [.header],
        allowedCommands: [String]? = nil
    ) throws -> (created: Bool, overwritten: Bool) {
        try validateSecretName(name)
        try validateDomains(allowedDomains)

        var store = try loadStore()
        let overwritten = store.secrets[name] != nil

        try keychain.store(name: name, value: value)

        store.secrets[name] = SecretMetadata(
            source: .encrypted(encryptedValue: "__keychain__"),
            allowedDomains: allowedDomains,
            allowedPlacements: allowedPlacements,
            allowedCommands: allowedCommands,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            lastUsed: nil,
            usageCount: 0
        )

        try saveStore(store)
        return (created: true, overwritten: overwritten)
    }

    public func getSecret(name: String) throws -> String? {
        let store = try loadStore()
        guard store.secrets[name] != nil else {
            return nil
        }
        return try keychain.retrieve(name: name)
    }

    public func getSecretMetadata(name: String) throws -> SecretMetadata? {
        let store = try loadStore()
        return store.secrets[name]
    }

    public func listSecrets() throws -> [SecretInfo] {
        let store = try loadStore()
        let existingFiles = Set(try keychain.list())

        return store.secrets.compactMap { name, meta in
            // Skip orphaned entries (metadata exists but .sealed file is missing)
            if case .encrypted = meta.source, !existingFiles.contains(name) {
                return nil
            }

            let sourceType: String
            switch meta.source {
            case .encrypted:
                sourceType = "encrypted"
            case .keychain:
                sourceType = "keychain"
            case .onePassword:
                sourceType = "1password"
            }

            return SecretInfo(
                name: name,
                sourceType: sourceType,
                allowedDomains: meta.allowedDomains,
                allowedPlacements: meta.allowedPlacements,
                allowedCommands: meta.allowedCommands,
                configured: true,
                createdAt: meta.createdAt,
                lastUsed: meta.lastUsed,
                usageCount: meta.usageCount
            )
        }
    }

    public func updateSecretMetadata(
        name: String,
        allowedDomains: [String]?,
        allowedPlacements: [SecretPlacement]?,
        allowedCommands: [String]??
    ) throws -> Bool {
        var store = try loadStore()
        guard let secret = store.secrets[name] else {
            return false
        }

        if let domains = allowedDomains {
            try validateDomains(domains)
        }

        store.secrets[name] = SecretMetadata(
            source: secret.source,
            allowedDomains: allowedDomains ?? secret.allowedDomains,
            allowedPlacements: allowedPlacements ?? secret.allowedPlacements,
            allowedCommands: allowedCommands ?? secret.allowedCommands,
            createdAt: secret.createdAt,
            lastUsed: secret.lastUsed,
            usageCount: secret.usageCount
        )

        try saveStore(store)
        return true
    }

    public func removeSecret(name: String) throws -> Bool {
        var store = try loadStore()

        guard store.secrets[name] != nil else {
            return false
        }

        try keychain.delete(name: name)
        store.secrets.removeValue(forKey: name)
        try saveStore(store)
        return true
    }

    public func rotateSecret(name: String, newValue: String) throws -> Int? {
        var store = try loadStore()
        guard let secret = store.secrets[name] else {
            return nil
        }

        if case .onePassword = secret.source {
            throw SecretStoreError.cannotRotate1Password
        }

        let previousUsageCount = secret.usageCount

        try keychain.store(name: name, value: newValue)

        store.secrets[name] = SecretMetadata(
            source: secret.source,
            allowedDomains: secret.allowedDomains,
            allowedPlacements: secret.allowedPlacements,
            allowedCommands: secret.allowedCommands,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            lastUsed: nil,
            usageCount: 0
        )

        try saveStore(store)
        return previousUsageCount
    }

    public func recordUsage(name: String) throws {
        var store = try loadStore()
        guard let secret = store.secrets[name] else {
            return
        }

        store.secrets[name] = SecretMetadata(
            source: secret.source,
            allowedDomains: secret.allowedDomains,
            allowedPlacements: secret.allowedPlacements,
            allowedCommands: secret.allowedCommands,
            createdAt: secret.createdAt,
            lastUsed: ISO8601DateFormatter().string(from: Date()),
            usageCount: secret.usageCount + 1
        )

        try saveStore(store)
    }

    public func secretExists(name: String) throws -> Bool {
        let store = try loadStore()
        return store.secrets[name] != nil
    }

    // MARK: - Validation

    private func validateSecretName(_ name: String) throws {
        let range = NSRange(name.startIndex..., in: name)
        guard Self.namePattern.firstMatch(in: name, range: range) != nil else {
            throw SecretStoreError.invalidName(name)
        }
    }

    private func validateDomains(_ domains: [String]) throws {
        if domains.isEmpty {
            throw SecretStoreError.noDomainsProvided
        }

        for domain in domains {
            let range = NSRange(domain.startIndex..., in: domain)
            guard Self.domainPattern.firstMatch(in: domain, range: range) != nil else {
                throw SecretStoreError.invalidDomain(domain)
            }
        }
    }
}

// MARK: - Errors

public enum SecretStoreError: LocalizedError {
    case invalidName(String)
    case noDomainsProvided
    case invalidDomain(String)
    case cannotRotate1Password
    case metadataTampered
    case signatureMissing

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "Invalid secret name \"\(name)\". Must be SCREAMING_SNAKE_CASE (e.g., API_KEY, GITHUB_TOKEN)"
        case .noDomainsProvided:
            return "At least one allowed domain is required"
        case .invalidDomain(let domain):
            return "Invalid domain pattern \"\(domain)\""
        case .cannotRotate1Password:
            return "Cannot rotate 1Password secrets. Update the value in 1Password instead."
        case .metadataTampered:
            return "secrets.json has been modified outside the app — refusing to load. Use the app UI to manage credentials."
        case .signatureMissing:
            return "secrets.json.sig is missing — refusing to load. Restart the app to re-sign, or use the app UI to manage credentials."
        }
    }
}
