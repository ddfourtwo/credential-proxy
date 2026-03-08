import Foundation

let CURRENT_VERSION = 2

// MARK: - Secret Placement

enum SecretPlacement: String, Codable, CaseIterable {
    case header
    case body
    case query
    case env
    case arg
}

// MARK: - Secret Source

enum SecretSource: Codable {
    case encrypted(encryptedValue: String)
    case onePassword(ref: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case encryptedValue
        case ref
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "encrypted":
            let value = try container.decode(String.self, forKey: .encryptedValue)
            self = .encrypted(encryptedValue: value)
        case "1password":
            let ref = try container.decode(String.self, forKey: .ref)
            self = .onePassword(ref: ref)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown secret source type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .encrypted(let encryptedValue):
            try container.encode("encrypted", forKey: .type)
            try container.encode(encryptedValue, forKey: .encryptedValue)
        case .onePassword(let ref):
            try container.encode("1password", forKey: .type)
            try container.encode(ref, forKey: .ref)
        }
    }
}

// MARK: - Secret Metadata

struct SecretMetadata: Codable {
    let source: SecretSource
    let allowedDomains: [String]
    let allowedPlacements: [SecretPlacement]
    var allowedCommands: [String]?
    let createdAt: String
    var lastUsed: String?
    var usageCount: Int
}

// MARK: - Secrets Store

struct SecretsStore: Codable {
    let version: Int
    var secrets: [String: SecretMetadata]
}

// MARK: - Secret Info

struct SecretInfo: Codable {
    let name: String
    let sourceType: String
    let allowedDomains: [String]
    let allowedPlacements: [SecretPlacement]
    var allowedCommands: [String]?
    let configured: Bool
    let createdAt: String
    var lastUsed: String?
    var usageCount: Int
}

// MARK: - Legacy Format (v1)

struct LegacySecretMetadata: Codable {
    let encryptedValue: String
    let allowedDomains: [String]
    let allowedPlacements: [SecretPlacement]
    let createdAt: String
    var lastUsed: String?
    var usageCount: Int
}
