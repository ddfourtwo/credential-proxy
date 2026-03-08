import Foundation

enum AuditEventType: String, Codable {
    case SECRET_USED
    case SECRET_USED_EXEC
    case SECRET_BLOCKED
    case SECRET_REDACTED
    case SECRET_ADDED
    case SECRET_REMOVED
    case SECRET_ROTATED
}

struct AuditEvent: Codable {
    let type: AuditEventType
    let timestamp: String
    let secret: String

    // SECRET_USED / SECRET_BLOCKED
    var domain: String?
    // SECRET_USED
    var method: String?
    var status: Int?
    // SECRET_USED / SECRET_USED_EXEC
    var durationMs: Int?
    // SECRET_USED_EXEC
    var command: String?
    var exitCode: Int?
    // SECRET_BLOCKED
    var reason: String?
    // SECRET_REDACTED
    var responseBytes: Int?
    var redactedCount: Int?
    // SECRET_ADDED
    var domains: [String]?
    var placements: [String]?
    // SECRET_ROTATED
    var previousUses: Int?
}

class AuditLogger {
    private static let maxLogSize = 10 * 1024 * 1024 // 10MB

    private(set) var logFilePath: String
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    init(logFilePath: String? = nil) {
        if let logFilePath {
            self.logFilePath = logFilePath
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.path
            self.logFilePath = "\(appSupport)/credential-proxy/audit.log"
        }
    }

    func log(_ event: AuditEvent) {
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
