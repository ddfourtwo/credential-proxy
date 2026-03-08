import Foundation

struct Credential: Identifiable, Codable {
    let name: String
    let sourceType: String
    let allowedDomains: [String]
    let allowedPlacements: [String]
    let allowedCommands: [String]?
    let configured: Bool
    let createdAt: String
    let lastUsed: String?
    let usageCount: Int

    var id: String { name }

    var domainsDisplay: String {
        allowedDomains.joined(separator: ", ")
    }

    var placementsDisplay: String {
        allowedPlacements.joined(separator: ", ")
    }

    var lastUsedDisplay: String {
        guard let lastUsed else { return "Never" }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: lastUsed) else { return lastUsed }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

struct CredentialListResponse: Codable {
    let credentials: [Credential]
}

struct MutationResponse: Codable {
    let success: Bool?
    let error: String?
}

struct AuditResponse: Codable {
    let events: [String]
}
