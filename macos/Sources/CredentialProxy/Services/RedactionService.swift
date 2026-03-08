import Foundation

struct RedactionResult {
    let content: String
    let redacted: Bool
    let redactedSecrets: [String]
}

enum RedactionService {
    /// Replace secret values in content with `[REDACTED:SECRET_NAME]`.
    /// Skips secrets shorter than 6 characters to avoid false positives.
    static func redactSecrets(
        in content: String,
        secrets: [(name: String, value: String)]
    ) -> RedactionResult {
        var result = content
        var redactedSecrets: [String] = []

        for secret in secrets {
            guard secret.value.count >= 6 else { continue }

            if result.contains(secret.value) {
                result = result.replacingOccurrences(
                    of: secret.value,
                    with: "[REDACTED:\(secret.name)]"
                )
                redactedSecrets.append(secret.name)
            }
        }

        return RedactionResult(
            content: result,
            redacted: !redactedSecrets.isEmpty,
            redactedSecrets: redactedSecrets
        )
    }
}
