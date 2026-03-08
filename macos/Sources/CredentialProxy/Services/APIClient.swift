import Foundation

@MainActor
final class APIClient: ObservableObject {
    private let baseURL: URL
    private var mgmtToken: String?

    init(port: Int = 8787) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func setToken(_ token: String) {
        self.mgmtToken = token
    }

    // MARK: - Health

    func healthCheck() async -> Bool {
        guard let url = URL(string: "/health", relativeTo: baseURL) else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["status"] as? String == "ok"
        } catch {
            return false
        }
    }

    // MARK: - Credentials

    func listCredentials() async throws -> [Credential] {
        let url = URL(string: "/credentials", relativeTo: baseURL)!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(CredentialListResponse.self, from: data)
        return response.credentials
    }

    func addCredential(
        name: String,
        value: String,
        allowedDomains: [String],
        allowedPlacements: [String],
        allowedCommands: [String]?
    ) async throws {
        let url = URL(string: "/credentials", relativeTo: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeader(&request)

        var body: [String: Any] = [
            "name": name,
            "value": value,
            "allowedDomains": allowedDomains,
            "allowedPlacements": allowedPlacements
        ]
        if let cmds = allowedCommands, !cmds.isEmpty {
            body["allowedCommands"] = cmds
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
    }

    func deleteCredential(name: String) async throws {
        let url = URL(string: "/credentials/\(name)", relativeTo: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        addAuthHeader(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
    }

    func rotateCredential(name: String, newValue: String) async throws {
        let url = URL(string: "/credentials/\(name)/rotate", relativeTo: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeader(&request)

        let body = ["value": newValue]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
    }

    // MARK: - Audit

    func getAuditLog(limit: Int = 50) async throws -> [String] {
        let url = URL(string: "/audit?limit=\(limit)", relativeTo: baseURL)!
        var request = URLRequest(url: url)
        addAuthHeader(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
        let audit = try JSONDecoder().decode(AuditResponse.self, from: data)
        return audit.events
    }

    // MARK: - Helpers

    private func addAuthHeader(_ request: inout URLRequest) {
        if let token = mgmtToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if http.statusCode >= 400 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                throw APIError.serverError(http.statusCode, error)
            }
            throw APIError.serverError(http.statusCode, "HTTP \(http.statusCode)")
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .serverError(_, let message): return message
        }
    }
}
