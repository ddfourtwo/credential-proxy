import Foundation

public struct Credential: Identifiable, Codable {
    public let name: String
    public let sourceType: String
    public let allowedDomains: [String]
    public let allowedPlacements: [String]
    public let allowedCommands: [String]?
    public let configured: Bool
    public let createdAt: String
    public let lastUsed: String?
    public let usageCount: Int

    public var id: String { name }

    public var domainsDisplay: String {
        allowedDomains.joined(separator: ", ")
    }

    public var placementsDisplay: String {
        allowedPlacements.joined(separator: ", ")
    }

    public var lastUsedDisplay: String {
        guard let lastUsed else { return "Never" }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: lastUsed) else { return lastUsed }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

public struct CredentialListResponse: Codable {
    public let credentials: [Credential]
}

public struct MutationResponse: Codable {
    public let success: Bool?
    public let error: String?
}

public struct AuditResponse: Codable {
    public let events: [String]
}
