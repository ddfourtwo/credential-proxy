import Foundation

// MARK: - Placeholder Detection

private enum ExecPlacement: String {
    case arg
    case env
}

private struct PlaceholderInfo {
    let name: String
    let placement: ExecPlacement
    let fullMatch: String
}

private let placeholderRegex = try! NSRegularExpression(pattern: #"\{\{([A-Z][A-Z0-9_]*)\}\}"#)

private func findPlaceholders(in input: ProxyExecInput) -> [PlaceholderInfo] {
    var placeholders: [PlaceholderInfo] = []

    for arg in input.command {
        let range = NSRange(arg.startIndex..., in: arg)
        let matches = placeholderRegex.matches(in: arg, range: range)
        for match in matches {
            let fullRange = Range(match.range, in: arg)!
            let nameRange = Range(match.range(at: 1), in: arg)!
            placeholders.append(PlaceholderInfo(
                name: String(arg[nameRange]),
                placement: .arg,
                fullMatch: String(arg[fullRange])
            ))
        }
    }

    if let env = input.env {
        for value in env.values {
            let range = NSRange(value.startIndex..., in: value)
            let matches = placeholderRegex.matches(in: value, range: range)
            for match in matches {
                let fullRange = Range(match.range, in: value)!
                let nameRange = Range(match.range(at: 1), in: value)!
                placeholders.append(PlaceholderInfo(
                    name: String(value[nameRange]),
                    placement: .env,
                    fullMatch: String(value[fullRange])
                ))
            }
        }
    }

    return placeholders
}

// MARK: - Command Matching

private func commandMatchesPattern(_ command: [String], _ pattern: String) -> Bool {
    let commandStr = command.joined(separator: " ")
    return fnmatch(pattern, commandStr, FNM_NOESCAPE) == 0
}

// MARK: - Secret Substitution

private func substituteSecrets(in content: String, secrets: [String: String]) -> String {
    var result = content
    for (name, value) in secrets {
        result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
    }
    return result
}

// MARK: - Handler

func handleProxyExec(
    _ input: ProxyExecInput,
    secretStore: SecretStore,
    auditLogger: AuditLogger
) async -> Result<ProxyExecOutput, ProxyExecError> {
    let startTime = Date()

    guard !input.command.isEmpty else {
        return .failure(ProxyExecError(
            error: .execFailed,
            message: "Command array cannot be empty"
        ))
    }

    // Find all placeholders
    let placeholders = findPlaceholders(in: input)

    // Validate each placeholder
    for placeholder in placeholders {
        let metadata: SecretMetadata?
        do {
            metadata = try await secretStore.getSecretMetadata(name: placeholder.name)
        } catch {
            return .failure(ProxyExecError(
                error: .execFailed,
                message: "Failed to read secret metadata: \(error.localizedDescription)"
            ))
        }

        guard let metadata else {
            return .failure(ProxyExecError(
                error: .secretNotFound,
                message: "Secret '\(placeholder.name)' is not configured",
                hint: "Use 'credential-proxy add \(placeholder.name)' to configure"
            ))
        }

        // Check placement
        let requiredPlacement: SecretPlacement = placeholder.placement == .arg ? .arg : .env
        if !metadata.allowedPlacements.contains(requiredPlacement) {
            auditLogger.log(AuditEvent(
                type: .SECRET_BLOCKED,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                secret: placeholder.name,
                reason: "PLACEMENT_NOT_ALLOWED"
            ))
            return .failure(ProxyExecError(
                error: .secretPlacementBlocked,
                message: "Secret '\(placeholder.name)' cannot be used in '\(placeholder.placement.rawValue)'",
                secret: placeholder.name,
                requestedPlacement: placeholder.placement.rawValue,
                allowedPlacements: metadata.allowedPlacements.map(\.rawValue)
            ))
        }

        // Check command restrictions
        if let allowedCommands = metadata.allowedCommands, !allowedCommands.isEmpty {
            let allowed = allowedCommands.contains { pattern in
                commandMatchesPattern(input.command, pattern)
            }
            if !allowed {
                auditLogger.log(AuditEvent(
                    type: .SECRET_BLOCKED,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    secret: placeholder.name,
                    reason: "COMMAND_NOT_ALLOWED"
                ))
                return .failure(ProxyExecError(
                    error: .secretCommandBlocked,
                    message: "Secret '\(placeholder.name)' cannot be used with command '\(input.command[0])'",
                    secret: placeholder.name,
                    requestedCommand: input.command.joined(separator: " "),
                    allowedCommands: allowedCommands
                ))
            }
        }
    }

    // Load secret values
    let uniqueNames = Array(Set(placeholders.map(\.name)))
    var secretValues: [String: String] = [:]

    for name in uniqueNames {
        do {
            guard let value = try await secretStore.getSecret(name: name) else {
                return .failure(ProxyExecError(
                    error: .secretNotFound,
                    message: "Secret '\(name)' could not be retrieved",
                    hint: "The secret may be corrupted or 1Password may not be authenticated."
                ))
            }
            secretValues[name] = value
        } catch {
            return .failure(ProxyExecError(
                error: .secretNotFound,
                message: "Secret '\(name)' could not be retrieved",
                hint: "The secret may be corrupted or 1Password may not be authenticated."
            ))
        }
    }

    // Substitute secrets in command arguments
    let substitutedCommand = input.command.map { substituteSecrets(in: $0, secrets: secretValues) }

    // Substitute secrets in environment variables
    var substitutedEnv = ProcessInfo.processInfo.environment
    if let env = input.env {
        for (key, value) in env {
            substitutedEnv[key] = substituteSecrets(in: value, secrets: secretValues)
        }
    }

    // Execute command
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdinPipe = Pipe()

    let executable = substitutedCommand[0]
    if executable.hasPrefix("/") {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(substitutedCommand.dropFirst())
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = substitutedCommand
    }

    process.environment = substitutedEnv
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = stdinPipe

    if let cwd = input.cwd {
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    }

    do {
        try process.run()
    } catch {
        return .failure(ProxyExecError(
            error: .execFailed,
            message: "Failed to execute command: \(error.localizedDescription)",
            cause: error.localizedDescription
        ))
    }

    // Write stdin if provided
    if let stdinData = input.stdin?.data(using: .utf8) {
        stdinPipe.fileHandleForWriting.write(stdinData)
    }
    stdinPipe.fileHandleForWriting.closeFile()

    // Timeout handling
    let timeoutMs = input.timeout ?? 30_000
    var timedOut = false

    let processTask = Task {
        // Read stdout/stderr concurrently before waitUntilExit to avoid pipe deadlocks
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (stdoutData, stderrData)
    }

    let timeoutTask = Task {
        try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
        process.terminate()
        return true
    }

    let (stdoutData, stderrData): (Data, Data)

    // Race: process completion vs timeout
    let result = await processTask.value
    stdoutData = result.0
    stderrData = result.1
    timeoutTask.cancel()

    if !timeoutTask.isCancelled {
        // Check if timeout fired before we cancelled it
        timedOut = !process.isRunning && process.terminationStatus == 15 // SIGTERM
    }

    // Simpler timeout detection: if the timeout task completed before cancellation
    // we detect via termination reason
    if process.terminationReason == .uncaughtSignal {
        // Could be timeout-triggered SIGTERM
        timedOut = true
    }

    let duration = Int(Date().timeIntervalSince(startTime) * 1000)
    let exitCode = timedOut ? 124 : Int(process.terminationStatus)

    var stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    var stderr = String(data: stderrData, encoding: .utf8) ?? ""

    // Record usage and audit for each secret
    for name in uniqueNames {
        try? await secretStore.recordUsage(name: name)
        auditLogger.log(AuditEvent(
            type: .SECRET_USED_EXEC,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            secret: name,
            durationMs: duration,
            command: input.command[0],
            exitCode: exitCode
        ))
    }

    // Redact secret values from output
    let secrets = secretValues.map { (name: $0.key, value: $0.value) }
    let stdoutRedaction = RedactionService.redactSecrets(in: stdout, secrets: secrets)
    let stderrRedaction = RedactionService.redactSecrets(in: stderr, secrets: secrets)
    stdout = stdoutRedaction.content
    stderr = stderrRedaction.content
    let redacted = stdoutRedaction.redacted || stderrRedaction.redacted

    if redacted {
        let totalBytes = stdoutData.count + stderrData.count
        let allRedacted = Set(stdoutRedaction.redactedSecrets + stderrRedaction.redactedSecrets)
        for name in allRedacted {
            auditLogger.log(AuditEvent(
                type: .SECRET_REDACTED,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                secret: name,
                responseBytes: totalBytes,
                redactedCount: 1
            ))
        }
    }

    return .success(ProxyExecOutput(
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr,
        redacted: redacted,
        timedOut: timedOut
    ))
}
