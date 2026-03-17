import Foundation

// MARK: - Proxy Request

public struct ProxyRequestInput: Codable {
    public let method: String
    public let url: String
    public var headers: [String: String]?
    public var body: ProxyBody?
    public var timeout: Int?
}

/// Handles JSON body as either a string or a dictionary.
public enum ProxyBody: Codable {
    case string(String)
    case dict([String: AnyCodableValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.typeMismatch(
                ProxyBody.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or object for body")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .dict(let dict):
            try container.encode(dict)
        }
    }
}

/// Type-erased JSON value for arbitrary dictionary bodies.
public enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case dict([String: AnyCodableValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.typeMismatch(
                AnyCodableValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let arr): try container.encode(arr)
        case .dict(let dict): try container.encode(dict)
        }
    }
}

public struct ProxyRequestOutput: Codable {
    public let status: Int
    public let statusText: String
    public let headers: [String: String]
    public let body: String
    public let redacted: Bool

    public init(status: Int, statusText: String, headers: [String: String], body: String, redacted: Bool) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.body = body
        self.redacted = redacted
    }
}

public enum ProxyRequestErrorType: String, Codable {
    case secretNotFound = "SECRET_NOT_FOUND"
    case secretDomainBlocked = "SECRET_DOMAIN_BLOCKED"
    case secretPlacementBlocked = "SECRET_PLACEMENT_BLOCKED"
    case requestFailed = "REQUEST_FAILED"
}

public struct ProxyRequestError: Codable, Error {
    public let error: ProxyRequestErrorType
    public let message: String
    public var hint: String?
    public var secret: String?
    public var requestedDomain: String?
    public var allowedDomains: [String]?
    public var requestedPlacement: String?
    public var allowedPlacements: [String]?
    public var cause: String?

    public init(error: ProxyRequestErrorType, message: String, hint: String? = nil, secret: String? = nil, requestedDomain: String? = nil, allowedDomains: [String]? = nil, requestedPlacement: String? = nil, allowedPlacements: [String]? = nil, cause: String? = nil) {
        self.error = error
        self.message = message
        self.hint = hint
        self.secret = secret
        self.requestedDomain = requestedDomain
        self.allowedDomains = allowedDomains
        self.requestedPlacement = requestedPlacement
        self.allowedPlacements = allowedPlacements
        self.cause = cause
    }
}

// MARK: - Proxy Exec

public struct ProxyExecInput: Codable {
    public let command: [String]
    public var env: [String: String]?
    public var cwd: String?
    public var timeout: Int?
    public var stdin: String?
}

public struct ProxyExecOutput: Codable {
    public let exitCode: Int
    public let stdout: String
    public let stderr: String
    public let redacted: Bool
    public let timedOut: Bool

    public init(exitCode: Int, stdout: String, stderr: String, redacted: Bool, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.redacted = redacted
        self.timedOut = timedOut
    }
}

public enum ProxyExecErrorType: String, Codable {
    case secretNotFound = "SECRET_NOT_FOUND"
    case secretCommandBlocked = "SECRET_COMMAND_BLOCKED"
    case secretPlacementBlocked = "SECRET_PLACEMENT_BLOCKED"
    case execFailed = "EXEC_FAILED"
}

public struct ProxyExecError: Codable, Error {
    public let error: ProxyExecErrorType
    public let message: String
    public var hint: String?
    public var secret: String?
    public var requestedCommand: String?
    public var allowedCommands: [String]?
    public var requestedPlacement: String?
    public var allowedPlacements: [String]?
    public var cause: String?

    public init(error: ProxyExecErrorType, message: String, hint: String? = nil, secret: String? = nil, requestedCommand: String? = nil, allowedCommands: [String]? = nil, requestedPlacement: String? = nil, allowedPlacements: [String]? = nil, cause: String? = nil) {
        self.error = error
        self.message = message
        self.hint = hint
        self.secret = secret
        self.requestedCommand = requestedCommand
        self.allowedCommands = allowedCommands
        self.requestedPlacement = requestedPlacement
        self.allowedPlacements = allowedPlacements
        self.cause = cause
    }
}
