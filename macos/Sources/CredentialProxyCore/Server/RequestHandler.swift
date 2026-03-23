import CryptoKit
import Foundation

// MARK: - Request Body Types

private struct RequestCredentialBody: Codable {
    let name: String?
    let domains: [String]?
    let placements: [String]?
    let commands: [String]?
    // Also accept allowedDomains/allowedPlacements/allowedCommands for direct API calls
    let allowedDomains: [String]?
    let allowedPlacements: [String]?
    let allowedCommands: [String]?

    var resolvedDomains: [String]? { domains ?? allowedDomains }
    var resolvedPlacements: [String]? { placements ?? allowedPlacements }
    var resolvedCommands: [String]? { commands ?? allowedCommands }
}

private struct AddCredentialBody: Codable {
    let name: String?
    let value: String?
    let allowedDomains: [String]?
    let allowedPlacements: [String]?
    let allowedCommands: [String]?
}

private struct UpdateCredentialBody: Codable {
    let allowedDomains: [String]?
    let allowedPlacements: [String]?
    let allowedCommands: [String]?
    // Also accept short forms from MCP tool
    let domains: [String]?
    let placements: [String]?
    let commands: [String]?

    var resolvedDomains: [String]? { allowedDomains ?? domains }
    var resolvedPlacements: [String]? { allowedPlacements ?? placements }
    var resolvedCommands: [String]? { allowedCommands ?? commands }
}

private struct RotateCredentialBody: Codable {
    let value: String?
}

// MARK: - Request Handler

public enum RequestHandler {

    public static func configureRoutes(
        router: Router,
        secretStore: SecretStore,
        auditLogger: AuditLogger,
        mgmtToken: String?,
        requestCredentialHandler: (@Sendable (HTTPRequest) async -> HTTPResponse)? = nil,
        updateCredentialHandler: (@Sendable (HTTPRequest) async -> HTTPResponse)? = nil
    ) {
        // MARK: Public Endpoints

        router.route("GET", "/health") { _ in
            .ok(["status": "ok", "service": "credential-proxy"])
        }

        router.route("GET", "/credentials") { request in
            do {
                let credentials = try await secretStore.listSecrets()
                return .json(200, ["credentials": credentials])
            } catch {
                return .error(500, error.localizedDescription)
            }
        }

        router.route("POST", "/proxy") { request in
            guard let body = request.body, !body.isEmpty else {
                return .error(400, "Request body is required")
            }

            let input: ProxyRequestInput
            do {
                input = try JSONDecoder().decode(ProxyRequestInput.self, from: body)
            } catch {
                return .error(400, "Invalid JSON body")
            }

            guard !input.method.isEmpty, !input.url.isEmpty else {
                return .error(400, "method and url are required")
            }

            let result = await ProxyRequestHandler.handleProxyRequest(
                input,
                secretStore: secretStore,
                auditLogger: auditLogger
            )

            switch result {
            case .success(let output):
                return .json(200, output)
            case .failure(let error):
                let status: Int
                switch error.error {
                case .secretNotFound: status = 404
                case .secretDomainBlocked, .secretPlacementBlocked: status = 403
                case .requestFailed: status = 500
                }
                return .json(status, error)
            }
        }

        router.route("POST", "/exec") { request in
            guard let body = request.body, !body.isEmpty else {
                return .error(400, "Request body is required")
            }

            let input: ProxyExecInput
            do {
                input = try JSONDecoder().decode(ProxyExecInput.self, from: body)
            } catch {
                return .error(400, "Invalid JSON body")
            }

            guard !input.command.isEmpty else {
                return .error(400, "command array is required")
            }

            let result = await handleProxyExec(
                input,
                secretStore: secretStore,
                auditLogger: auditLogger
            )

            switch result {
            case .success(let output):
                return .json(200, output)
            case .failure(let error):
                let status: Int
                switch error.error {
                case .secretNotFound: status = 404
                case .secretCommandBlocked, .secretPlacementBlocked: status = 403
                case .execFailed: status = 500
                }
                return .json(status, error)
            }
        }

        router.route("POST", "/request-credential") { request in
            guard let handler = requestCredentialHandler else {
                return .error(501, "Not available in headless mode")
            }
            return await handler(request)
        }

        router.route("POST", "/update-credential") { request in
            guard let handler = updateCredentialHandler else {
                return .error(501, "Not available in headless mode")
            }
            return await handler(request)
        }

        // MARK: Management Endpoints

        router.route("POST", "/credentials") { request in
            if let response = requireMgmtAuth(request, mgmtToken: mgmtToken) {
                return response
            }

            guard let body = request.body, !body.isEmpty else {
                return .error(400, "Request body is required")
            }

            let parsed: AddCredentialBody
            do {
                parsed = try JSONDecoder().decode(AddCredentialBody.self, from: body)
            } catch {
                return .error(400, "Invalid JSON")
            }

            guard let name = parsed.name, !name.isEmpty,
                  let value = parsed.value, !value.isEmpty,
                  let domains = parsed.allowedDomains, !domains.isEmpty else {
                return .error(400, "name, value, and allowedDomains are required")
            }

            let placements = (parsed.allowedPlacements ?? ["header"]).compactMap {
                SecretPlacement(rawValue: $0)
            }

            do {
                let result = try await secretStore.addSecret(
                    name: name,
                    value: value,
                    allowedDomains: domains,
                    allowedPlacements: placements,
                    allowedCommands: parsed.allowedCommands
                )
                let status = result.overwritten ? 200 : 201
                return .json(status, [
                    "success": AnyCodableValue.bool(true),
                    "created": AnyCodableValue.bool(result.created),
                    "overwritten": AnyCodableValue.bool(result.overwritten),
                ])
            } catch {
                return .error(400, error.localizedDescription)
            }
        }

        router.route("DELETE", "/credentials/:name") { request in
            if let response = requireMgmtAuth(request, mgmtToken: mgmtToken) {
                return response
            }

            guard let name = request.params["name"] else {
                return .error(400, "Missing credential name")
            }

            do {
                let removed = try await secretStore.removeSecret(name: name)
                if !removed {
                    return .error(404, "Secret \"\(name)\" not found")
                }
                return .json(200, ["success": AnyCodableValue.bool(true), "name": AnyCodableValue.string(name)])
            } catch {
                return .error(500, error.localizedDescription)
            }
        }

        router.route("GET", "/credentials/:name/reveal") { request in
            if let response = requireMgmtAuth(request, mgmtToken: mgmtToken) {
                return response
            }

            guard let name = request.params["name"] else {
                return .error(400, "Missing credential name")
            }

            do {
                guard let value = try await secretStore.getSecret(name: name) else {
                    return .error(404, "Secret \"\(name)\" not found")
                }
                auditLogger.log(AuditEvent(
                    type: .SECRET_USED,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    secret: name,
                    reason: "revealed via GUI"
                ))
                return .json(200, ["name": AnyCodableValue.string(name), "value": AnyCodableValue.string(value)])
            } catch {
                return .error(500, error.localizedDescription)
            }
        }

        router.route("POST", "/credentials/:name/rotate") { request in
            if let response = requireMgmtAuth(request, mgmtToken: mgmtToken) {
                return response
            }

            guard let name = request.params["name"] else {
                return .error(400, "Missing credential name")
            }

            guard let body = request.body, !body.isEmpty else {
                return .error(400, "Request body is required")
            }

            let parsed: RotateCredentialBody
            do {
                parsed = try JSONDecoder().decode(RotateCredentialBody.self, from: body)
            } catch {
                return .error(400, "Invalid JSON")
            }

            guard let value = parsed.value, !value.isEmpty else {
                return .error(400, "value is required")
            }

            do {
                guard let previousUsageCount = try await secretStore.rotateSecret(name: name, newValue: value) else {
                    return .error(404, "Secret \"\(name)\" not found")
                }
                return .json(200, [
                    "success": AnyCodableValue.bool(true),
                    "name": AnyCodableValue.string(name),
                    "previousUsageCount": AnyCodableValue.int(previousUsageCount),
                ])
            } catch {
                return .error(500, error.localizedDescription)
            }
        }

        router.route("POST", "/validate-hmac") { request in
            guard let body = request.body, !body.isEmpty else {
                return .error(400, "Request body is required")
            }

            struct ValidateHMACInput: Decodable {
                let secretName: String
                let algorithm: String
                let payload: String  // base64-encoded
                let signature: String
                let encoding: String
                let prefix: String?
            }

            guard let input = try? JSONDecoder().decode(ValidateHMACInput.self, from: body) else {
                return .error(400, "Invalid JSON: requires secretName, algorithm, payload, signature, encoding")
            }

            guard input.algorithm == "sha256" else {
                return .error(400, "Unsupported algorithm: \(input.algorithm). Only sha256 is supported.")
            }

            do {
                guard let secret = try await secretStore.getSecret(name: input.secretName) else {
                    return .error(404, "Secret not found: \(input.secretName)")
                }

                guard let payloadData = Data(base64Encoded: input.payload) else {
                    return .error(400, "Invalid base64 payload")
                }

                let key = SymmetricKey(data: Data(secret.utf8))
                let computed = HMAC<SHA256>.authenticationCode(for: payloadData, using: key)
                let computedHex = computed.map { String(format: "%02x", $0) }.joined()

                var providedSig = input.signature
                if let prefix = input.prefix, !prefix.isEmpty, providedSig.hasPrefix(prefix) {
                    providedSig = String(providedSig.dropFirst(prefix.count))
                }

                // Constant-time comparison
                let computedBytes = Array(computedHex.utf8)
                let providedBytes = Array(providedSig.utf8)
                var match = computedBytes.count == providedBytes.count
                for i in 0..<min(computedBytes.count, providedBytes.count) {
                    match = match && (computedBytes[i] == providedBytes[i])
                }
                if computedBytes.count != providedBytes.count { match = false }

                return .json(200, ["valid": AnyCodableValue.bool(match)])
            } catch {
                return .error(500, error.localizedDescription)
            }
        }

        router.route("GET", "/audit") { request in
            if let response = requireMgmtAuth(request, mgmtToken: mgmtToken) {
                return response
            }

            let limit = Int(request.query["lines"] ?? request.query["limit"] ?? "100") ?? 100

            let logPath = auditLogger.logFilePath
            let fileManager = FileManager.default

            guard fileManager.fileExists(atPath: logPath) else {
                return .json(200, ["entries": [String]()])
            }

            do {
                let content = try String(contentsOfFile: logPath, encoding: .utf8)
                let lines = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n")
                    .filter { !$0.isEmpty }
                let entries = Array(lines.suffix(limit).reversed())
                return .json(200, ["entries": entries])
            } catch {
                return .error(500, "Failed to read audit log: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Auth

    private static func checkMgmtAuth(_ request: HTTPRequest, mgmtToken: String?) -> Bool {
        guard let token = mgmtToken, !token.isEmpty else {
            return true // No token configured = no auth required
        }
        return request.headers["authorization"] == "Bearer \(token)"
    }

    private static func requireMgmtAuth(_ request: HTTPRequest, mgmtToken: String?) -> HTTPResponse? {
        if checkMgmtAuth(request, mgmtToken: mgmtToken) {
            return nil // Auth passed
        }
        return .error(401, "Management token required")
    }
}
