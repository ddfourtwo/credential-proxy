import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Injecting reverse proxy — the substitution-free way to let a backend USE a
/// credential without ever holding it.
///
/// A backend is configured with `base_url = http://127.0.0.1:PORT/inject/<SECRET>/<host>`
/// and NO api key. It makes a plain local request here; this proxy validates the
/// upstream host against the secret's allowedDomains, injects the credential as an
/// Authorization header, forwards over real HTTPS, and returns the response. The
/// secret never enters the backend's memory or env, and — unlike /reveal — no raw
/// value is ever handed back to the caller, so there is nothing to leak and no human
/// step is required. Exfil is bounded exactly like proxy_request: the credential can
/// only ever travel to an allowlisted host.
public func handleInjectProxy(
    _ request: HTTPRequest,
    secretStore: SecretStore,
    auditLogger: AuditLogger
) async -> HTTPResponse {
    guard let secretName = request.params["secret"], !secretName.isEmpty,
          let host = request.params["host"], !host.isEmpty else {
        return .error(400, "inject path must be /inject/<SECRET>/<host>/<path...>")
    }
    let tail = request.params["*"] ?? ""

    let metadata: SecretMetadata?
    do {
        metadata = try await secretStore.getSecretMetadata(name: secretName)
    } catch {
        return .error(500, "Failed to read secret metadata: \(error.localizedDescription)")
    }
    guard let metadata else {
        return .error(404, "Secret '\(secretName)' is not configured")
    }

    // The credential may only travel to an allowlisted host.
    guard DomainMatcher.isDomainAllowed(host, allowedDomains: metadata.allowedDomains) else {
        auditLogger.log(AuditEvent(
            type: .SECRET_BLOCKED,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            secret: secretName,
            domain: host,
            reason: "DOMAIN_NOT_ALLOWED"
        ))
        return .error(403, "Secret '\(secretName)' cannot be used with host '\(host)'")
    }

    // We inject an Authorization header, so header placement must be permitted.
    guard metadata.allowedPlacements.contains(.header) else {
        auditLogger.log(AuditEvent(
            type: .SECRET_BLOCKED,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            secret: secretName,
            domain: host,
            reason: "PLACEMENT_NOT_ALLOWED"
        ))
        return .error(403, "Secret '\(secretName)' does not permit 'header' placement")
    }

    // Resolve the value in-process — no /reveal hop, so no device-auth prompt and no
    // plaintext crossing a caller-reachable boundary.
    let value: String
    do {
        guard let resolved = try await secretStore.getSecret(name: secretName) else {
            return .error(404, "Secret '\(secretName)' could not be retrieved")
        }
        value = resolved
    } catch {
        return .error(500, "Secret '\(secretName)' could not be retrieved: \(error.localizedDescription)")
    }

    // Build the upstream URL from the raw (still-encoded) tail to avoid double-encoding.
    var urlString = "https://\(host)/\(tail)"
    if !request.query.isEmpty {
        let q = request.query
            .map { "\(encodeQuery($0.key))=\(encodeQuery($0.value))" }
            .joined(separator: "&")
        urlString += "?\(q)"
    }
    guard let url = URL(string: urlString) else {
        return .error(400, "Invalid upstream URL: \(urlString)")
    }

    var upstream = URLRequest(url: url)
    upstream.httpMethod = request.method
    // Copy caller headers except hop-by-hop / routing / any caller-supplied auth.
    let stripped: Set<String> = ["host", "connection", "content-length", "authorization", "accept-encoding"]
    for (key, headerValue) in request.headers where !stripped.contains(key.lowercased()) {
        upstream.setValue(headerValue, forHTTPHeaderField: key)
    }
    upstream.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
    if request.method != "GET", let body = request.body {
        upstream.httpBody = body
    }

    do {
        let (data, response) = try await URLSession.shared.data(for: upstream)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 502

        try? await secretStore.recordUsage(name: secretName)
        auditLogger.log(AuditEvent(
            type: .SECRET_USED,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            secret: secretName,
            domain: host,
            reason: "inject-proxy"
        ))

        // Defense in depth: scrub any accidental raw echo of the value.
        var outBody = data
        if let text = String(data: data, encoding: .utf8) {
            let redaction = RedactionService.redactSecrets(in: text, secrets: [(name: secretName, value: value)])
            if redaction.redacted {
                outBody = Data(redaction.content.utf8)
            }
        }

        var outHeaders: [String: String] = [:]
        if let contentType = http?.value(forHTTPHeaderField: "Content-Type") {
            outHeaders["Content-Type"] = contentType
        }
        return HTTPResponse(status: status, headers: outHeaders, body: outBody)
    } catch {
        return .error(502, "Upstream request to \(host) failed: \(error.localizedDescription)")
    }
}

private func encodeQuery(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
}
