import Foundation

public let CURRENT_VERSION = 2

// MARK: - Secret Placement

public enum SecretPlacement: String, Codable, CaseIterable {
    case header
    case body
    case query
    case url
    case env
    case arg
}

// MARK: - Secret Source

public enum SecretSource: Codable {
    case encrypted(encryptedValue: String)
    case onePassword(ref: String)
    case keychain

    private enum CodingKeys: String, CodingKey {
        case type
        case encryptedValue
        case ref
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "encrypted":
            let value = try container.decode(String.self, forKey: .encryptedValue)
            self = .encrypted(encryptedValue: value)
        case "1password":
            let ref = try container.decode(String.self, forKey: .ref)
            self = .onePassword(ref: ref)
        case "keychain":
            self = .keychain
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown secret source type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .encrypted(let encryptedValue):
            try container.encode("encrypted", forKey: .type)
            try container.encode(encryptedValue, forKey: .encryptedValue)
        case .onePassword(let ref):
            try container.encode("1password", forKey: .type)
            try container.encode(ref, forKey: .ref)
        case .keychain:
            try container.encode("keychain", forKey: .type)
        }
    }
}

// MARK: - Secret Metadata

public struct SecretMetadata: Codable {
    public let source: SecretSource
    public let allowedDomains: [String]
    public let allowedPlacements: [SecretPlacement]
    public var allowedCommands: [String]?
    public let createdAt: String
    public var lastUsed: String?
    public var usageCount: Int

    public init(
        source: SecretSource,
        allowedDomains: [String],
        allowedPlacements: [SecretPlacement],
        allowedCommands: [String]? = nil,
        createdAt: String,
        lastUsed: String? = nil,
        usageCount: Int
    ) {
        self.source = source
        self.allowedDomains = allowedDomains
        self.allowedPlacements = allowedPlacements
        self.allowedCommands = allowedCommands
        self.createdAt = createdAt
        self.lastUsed = lastUsed
        self.usageCount = usageCount
    }
}

// MARK: - Secrets Store

public struct SecretsStore: Codable {
    public let version: Int
    public var secrets: [String: SecretMetadata]

    public init(version: Int, secrets: [String: SecretMetadata]) {
        self.version = version
        self.secrets = secrets
    }
}

// MARK: - Secret Info

public struct SecretInfo: Codable {
    public let name: String
    public let sourceType: String
    public let allowedDomains: [String]
    public let allowedPlacements: [SecretPlacement]
    public var allowedCommands: [String]?
    public let configured: Bool
    public let createdAt: String
    public var lastUsed: String?
    public var usageCount: Int

    public init(
        name: String,
        sourceType: String,
        allowedDomains: [String],
        allowedPlacements: [SecretPlacement],
        allowedCommands: [String]? = nil,
        configured: Bool,
        createdAt: String,
        lastUsed: String? = nil,
        usageCount: Int
    ) {
        self.name = name
        self.sourceType = sourceType
        self.allowedDomains = allowedDomains
        self.allowedPlacements = allowedPlacements
        self.allowedCommands = allowedCommands
        self.configured = configured
        self.createdAt = createdAt
        self.lastUsed = lastUsed
        self.usageCount = usageCount
    }
}

// MARK: - Legacy Format (v1)

public struct LegacySecretMetadata: Codable {
    public let encryptedValue: String
    public let allowedDomains: [String]
    public let allowedPlacements: [SecretPlacement]
    public let createdAt: String
    public var lastUsed: String?
    public var usageCount: Int
}
