import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Handles HTTP proxy requests with credential substitution.
public enum ProxyRequestHandler {

    // MARK: - Placeholder Detection

    private static let placeholderRegex = try! NSRegularExpression(
        pattern: #"\{\{([A-Z][A-Z0-9_]*)\}\}"#
    )

    private struct PlaceholderInfo {
        let name: String
        let placement: SecretPlacement
        let fullMatch: String
    }

    private static func findPlaceholders(in input: ProxyRequestInput) -> [PlaceholderInfo] {
        var placeholders: [PlaceholderInfo] = []

        // Check URL path
        placeholders += scanPlaceholders(in: input.url, placement: .url)

        // Check headers
        if let headers = input.headers {
            for (_, value) in headers {
                placeholders += scanPlaceholders(in: value, placement: .header)
            }
        }

        // Check body
        if let body = input.body {
            let bodyStr: String
            switch body {
            case .string(let s):
                bodyStr = s
            case .dict(let dict):
                if let data = try? JSONEncoder().encode(dict),
                   let str = String(data: data, encoding: .utf8) {
                    bodyStr = str
                } else {
                    bodyStr = ""
                }
            }
            placeholders += scanPlaceholders(in: bodyStr, placement: .body)
        }

        // Check URL query params
        if let urlComponents = URLComponents(string: input.url) {
            for item in urlComponents.queryItems ?? [] {
                if let value = item.value {
                    placeholders += scanPlaceholders(in: value, placement: .query)
                }
            }
        }

        return placeholders
    }

    private static func scanPlaceholders(in text: String, placement: SecretPlacement) -> [PlaceholderInfo] {
        let range = NSRange(text.startIndex..., in: text)
        return placeholderRegex.matches(in: text, range: range).compactMap { match in
            guard let fullRange = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return PlaceholderInfo(
                name: String(text[nameRange]),
                placement: placement,
                fullMatch: String(text[fullRange])
            )
        }
    }

    // MARK: - Validation

    private static func validatePlaceholder(
        _ placeholder: PlaceholderInfo,
        targetDomain: String,
        secretStore: SecretStore,
        auditLogger: AuditLogger
    ) async -> ProxyRequestError? {
        let metadata: SecretMetadata?
        do {
            metadata = try await secretStore.getSecretMetadata(name: placeholder.name)
        } catch {
            return ProxyRequestError(
                error: .requestFailed,
                message: "Failed to read secret metadata",
                cause: error.localizedDescription
            )
        }

        guard let metadata else {
            return ProxyRequestError(
                error: .secretNotFound,
                message: "Secret '\(placeholder.name)' is not configured",
                hint: "Use 'credential-proxy add \(placeholder.name)' to configure"
            )
        }

        if !DomainMatcher.isDomainAllowed(targetDomain, allowedDomains: metadata.allowedDomains) {
            auditLogger.log(AuditEvent(
                type: .SECRET_BLOCKED,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                secret: placeholder.name,
                domain: targetDomain,
                reason: "DOMAIN_NOT_ALLOWED"
            ))
            return ProxyRequestError(
                error: .secretDomainBlocked,
                message: "Secret '\(placeholder.name)' cannot be used with domain '\(targetDomain)'",
                secret: placeholder.name,
                requestedDomain: targetDomain,
                allowedDomains: metadata.allowedDomains
            )
        }

        if !metadata.allowedPlacements.contains(placeholder.placement) {
            auditLogger.log(AuditEvent(
                type: .SECRET_BLOCKED,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                secret: placeholder.name,
                domain: targetDomain,
                reason: "PLACEMENT_NOT_ALLOWED"
            ))
            return ProxyRequestError(
                error: .secretPlacementBlocked,
                message: "Secret '\(placeholder.name)' cannot be used in '\(placeholder.placement.rawValue)'",
                secret: placeholder.name,
                requestedPlacement: placeholder.placement.rawValue,
                allowedPlacements: metadata.allowedPlacements.map(\.rawValue)
            )
        }

        return nil
    }

    // MARK: - Substitution

    private static func substituteSecrets(in content: String, values: [String: String]) -> String {
        var result = content
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
    }

    // MARK: - Public API

    public static func handleProxyRequest(
        _ input: ProxyRequestInput,
        secretStore: SecretStore,
        auditLogger: AuditLogger
    ) async -> Result<ProxyRequestOutput, ProxyRequestError> {
        let startTime = Date()

        // Extract target domain
        guard let targetDomain = DomainMatcher.extractDomain(from: input.url) else {
            return .failure(ProxyRequestError(
                error: .requestFailed,
                message: "Invalid URL",
                cause: "Could not extract domain from URL"
            ))
        }

        // Find all placeholders
        let placeholders = findPlaceholders(in: input)

        // Validate each placeholder
        for placeholder in placeholders {
            if let error = await validatePlaceholder(
                placeholder,
                targetDomain: targetDomain,
                secretStore: secretStore,
                auditLogger: auditLogger
            ) {
                return .failure(error)
            }
        }

        // Load secret values
        let secretNames = Array(Set(placeholders.map(\.name)))
        var secretValues: [String: String] = [:]

        for name in secretNames {
            let value: String?
            do {
                value = try await secretStore.getSecret(name: name)
            } catch {
                return .failure(ProxyRequestError(
                    error: .requestFailed,
                    message: "Failed to retrieve secret '\(name)'",
                    cause: error.localizedDescription
                ))
            }
            guard let value else {
                return .failure(ProxyRequestError(
                    error: .secretNotFound,
                    message: "Secret '\(name)' could not be decrypted",
                    hint: "The secret may be corrupted. Try rotating it."
                ))
            }
            secretValues[name] = value
        }

        // Substitute secrets in URL, headers, body
        let url = substituteSecrets(in: input.url, values: secretValues)

        var headers: [String: String] = [:]
        if let inputHeaders = input.headers {
            for (key, value) in inputHeaders {
                headers[key] = substituteSecrets(in: value, values: secretValues)
            }
        }

        var bodyData: Data?
        if let body = input.body {
            let bodyStr: String
            switch body {
            case .string(let s):
                bodyStr = s
            case .dict(let dict):
                if let data = try? JSONEncoder().encode(dict),
                   let str = String(data: data, encoding: .utf8) {
                    bodyStr = str
                } else {
                    bodyStr = ""
                }
            }
            let substituted = substituteSecrets(in: bodyStr, values: secretValues)
            bodyData = Data(substituted.utf8)
        }

        // Build URLRequest
        guard let requestURL = URL(string: url) else {
            return .failure(ProxyRequestError(
                error: .requestFailed,
                message: "Invalid URL after substitution",
                cause: "Could not parse URL: \(url)"
            ))
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = input.method
        request.timeoutInterval = TimeInterval(input.timeout ?? 30000) / 1000.0

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if input.method != "GET" {
            request.httpBody = bodyData
        }

        // Execute request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(ProxyRequestError(
                error: .requestFailed,
                message: "Request to \(targetDomain) failed",
                cause: "timeout after \(input.timeout ?? 30000)ms"
            ))
        } catch {
            return .failure(ProxyRequestError(
                error: .requestFailed,
                message: "Request to \(targetDomain) failed",
                cause: error.localizedDescription
            ))
        }

        let httpResponse = response as! HTTPURLResponse
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // Record usage and audit for each secret
        for name in secretNames {
            try? await secretStore.recordUsage(name: name)
            auditLogger.log(AuditEvent(
                type: .SECRET_USED,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                secret: name,
                domain: targetDomain,
                method: input.method,
                status: httpResponse.statusCode,
                durationMs: durationMs
            ))
        }

        // Read response body and redact secrets
        var responseBody = String(data: data, encoding: .utf8) ?? ""

        let redactionResult = RedactionService.redactSecrets(
            in: responseBody,
            secrets: secretValues.map { (name: $0.key, value: $0.value) }
        )
        responseBody = redactionResult.content

        if redactionResult.redacted {
            for name in redactionResult.redactedSecrets {
                auditLogger.log(AuditEvent(
                    type: .SECRET_REDACTED,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    secret: name,
                    responseBytes: data.count,
                    redactedCount: 1
                ))
            }
        }

        // Convert response headers
        var responseHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                responseHeaders[key] = value
            }
        }

        let statusText = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)

        return .success(ProxyRequestOutput(
            status: httpResponse.statusCode,
            statusText: statusText,
            headers: responseHeaders,
            body: responseBody,
            redacted: redactionResult.redacted
        ))
    }
}
