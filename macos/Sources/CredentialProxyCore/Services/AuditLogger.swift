import Foundation

public enum AuditEventType: String, Codable {
    case SECRET_USED
    case SECRET_USED_EXEC
    case SECRET_BLOCKED
    case SECRET_REDACTED
    case SECRET_ADDED
    case SECRET_REMOVED
    case SECRET_ROTATED
}

public struct AuditEvent: Codable {
    public let type: AuditEventType
    public let timestamp: String
    public let secret: String

    // SECRET_USED / SECRET_BLOCKED
    public var domain: String?
    // SECRET_USED
    public var method: String?
    public var status: Int?
    // SECRET_USED / SECRET_USED_EXEC
    public var durationMs: Int?
    // SECRET_USED_EXEC
    public var command: String?
    public var exitCode: Int?
    // SECRET_BLOCKED
    public var reason: String?
    // SECRET_REDACTED
    public var responseBytes: Int?
    public var redactedCount: Int?
    // SECRET_ADDED
    public var domains: [String]?
    public var placements: [String]?
    // SECRET_ROTATED
    public var previousUses: Int?

    public init(
        type: AuditEventType,
        timestamp: String,
        secret: String,
        domain: String? = nil,
        method: String? = nil,
        status: Int? = nil,
        durationMs: Int? = nil,
        command: String? = nil,
        exitCode: Int? = nil,
        reason: String? = nil,
        responseBytes: Int? = nil,
        redactedCount: Int? = nil,
        domains: [String]? = nil,
        placements: [String]? = nil,
        previousUses: Int? = nil
    ) {
        self.type = type
        self.timestamp = timestamp
        self.secret = secret
        self.domain = domain
        self.method = method
        self.status = status
        self.durationMs = durationMs
        self.command = command
        self.exitCode = exitCode
        self.reason = reason
        self.responseBytes = responseBytes
        self.redactedCount = redactedCount
        self.domains = domains
        self.placements = placements
        self.previousUses = previousUses
    }
}

public class AuditLogger {
    private static let maxLogSize = 10 * 1024 * 1024 // 10MB

    public private(set) var logFilePath: String
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    public init(logFilePath: String? = nil) {
        if let logFilePath {
            self.logFilePath = logFilePath
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.path
            self.logFilePath = "\(appSupport)/credential-proxy/audit.log"
        }
    }

    public func log(_ event: AuditEvent) {
        ensureLogDir()
        rotateIfNeeded()

        guard let data = try? encoder.encode(event),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        let line = json + "\n"
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: logFilePath) {
            guard let handle = FileHandle(forWritingAtPath: logFilePath) else { return }
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            fileManager.createFile(
                atPath: logFilePath,
                contents: Data(line.utf8),
                attributes: [.posixPermissions: 0o600]
            )
        }
    }

    private func ensureLogDir() {
        let dir = (logFilePath as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func rotateIfNeeded() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: logFilePath),
              let attrs = try? fileManager.attributesOfItem(atPath: logFilePath),
              let size = attrs[.size] as? Int,
              size >= Self.maxLogSize else {
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let rotatedPath = "\(logFilePath).\(timestamp).old"
        try? fileManager.moveItem(atPath: logFilePath, toPath: rotatedPath)
    }
}
