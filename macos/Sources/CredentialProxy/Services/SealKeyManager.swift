import Foundation
import CryptoKit
import CommonCrypto

/// Manages a "seal key" derived from a user PIN + persistent salt.
///
/// Secrets are encrypted with the seal key (AES-256-GCM). The seal key is
/// never stored — it's derived at each app launch from the user's PIN.
/// An agent cannot derive the key without knowing the PIN.
///
/// Files stored in data dir:
///   - seal.salt: random 32-byte salt (not secret — useless without PIN)
///   - seal.verify: encrypted known string to verify correct PIN
final class SealKeyManager {
    static let shared = SealKeyManager()

    private let dataDir: String = {
        let dir = NSHomeDirectory() + "/Library/Application Support/credential-proxy"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var saltPath: String { dataDir + "/seal.salt" }
    private var verifyPath: String { dataDir + "/seal.verify" }
    private var migrationPath: String { dataDir + "/seal.migration" }

    private let verificationPlaintext = "credential-proxy-seal-key-valid"
    private let pbkdf2Iterations: UInt32 = 200_000

    private(set) var cachedKey: SymmetricKey?
    private var cachedPin: String?

    var isUnlocked: Bool { cachedKey != nil }
    var isFirstRun: Bool { !FileManager.default.fileExists(atPath: saltPath) }

    private init() {}

    // MARK: - Setup (first run)

    /// Create a new seal key from a user-chosen PIN.
    /// Generates salt, derives key, stores salt + verification blob.
    /// Throws `saltAlreadyExists` if called when seal data already exists — prevents
    /// accidental overwrite of the salt which would make all stored secrets undecryptable.
    func setup(pin: String) throws {
        guard isFirstRun else {
            throw SealKeyError.saltAlreadyExists
        }
        let salt = generateSalt()
        let key = try deriveKey(pin: pin, salt: salt)

        // Encrypt verification string
        let verifyData = try encrypt(verificationPlaintext, key: key)

        // Write salt and verification to files
        try salt.write(to: URL(fileURLWithPath: saltPath))
        try verifyData.write(to: URL(fileURLWithPath: verifyPath))

        // Set restrictive permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saltPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: verifyPath)

        cachedKey = key
        cachedPin = pin
    }

    // MARK: - Unlock (subsequent launches)

    /// Unlock with a PIN. Returns true if PIN is correct.
    func unlock(pin: String) throws -> Bool {
        if cachedKey != nil { return true }

        guard let salt = try? Data(contentsOf: URL(fileURLWithPath: saltPath)),
              let verifyData = try? Data(contentsOf: URL(fileURLWithPath: verifyPath)) else {
            throw SealKeyError.noSealData
        }

        let key = try deriveKey(pin: pin, salt: salt)

        // Verify by decrypting the verification blob
        guard let decrypted = try? decrypt(verifyData, key: key),
              decrypted == verificationPlaintext else {
            return false // Wrong PIN
        }

        cachedKey = key
        cachedPin = pin
        return true
    }

    // MARK: - Reset

    /// Delete seal data and all stored secrets.
    func reset() {
        try? FileManager.default.removeItem(atPath: saltPath)
        try? FileManager.default.removeItem(atPath: verifyPath)
        try? FileManager.default.removeItem(atPath: migrationPath)
        cachedKey = nil
        cachedPin = nil
        // Delete all stored secrets (they can't be decrypted anymore)
        let secretsDir = dataDir + "/secrets"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: secretsDir) {
            for file in files where file.hasSuffix(".sealed") {
                try? FileManager.default.removeItem(atPath: secretsDir + "/" + file)
            }
        }
    }

    // MARK: - Update Migration

    var hasPendingMigration: Bool {
        FileManager.default.fileExists(atPath: migrationPath)
    }

    /// Prepare for binary update: re-encrypt all secrets with a migration key
    /// (PIN + salt, no binary hash) so the new binary can decrypt them.
    func prepareForUpdate() throws {
        guard let key = cachedKey else { throw SealKeyError.notUnlocked }
        guard let salt = try? Data(contentsOf: URL(fileURLWithPath: saltPath)) else {
            throw SealKeyError.noSealData
        }

        guard let pin = cachedPin else { throw SealKeyError.notUnlocked }
        let migrationKey = try deriveMigrationKey(pin: pin, salt: salt)

        // Read all secrets from files, decrypt with current key, re-encrypt with migration key
        let secretsDir = dataDir + "/secrets"
        var migrated: [MigrationSecret] = []

        if let files = try? FileManager.default.contentsOfDirectory(atPath: secretsDir) {
            for file in files where file.hasSuffix(".sealed") {
                let name = String(file.dropLast(7))
                let path = secretsDir + "/" + file
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let plaintext = try? decrypt(data, key: key) else { continue }

                let migrationData = try encrypt(plaintext, key: migrationKey)
                migrated.append(MigrationSecret(name: name, data: migrationData))
            }
        }

        // Also re-encrypt the verification string with migration key
        let verifyMigration = try encrypt(verificationPlaintext, key: migrationKey)

        // Write migration blob
        let blob = try JSONEncoder().encode(MigrationBlob(
            verify: verifyMigration,
            secrets: migrated
        ))
        try blob.write(to: URL(fileURLWithPath: migrationPath), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: migrationPath)
    }

    /// After binary update: unlock with PIN using migration key, re-encrypt secrets with new binary-bound key.
    func completeMigration(pin: String) throws -> Bool {
        guard let salt = try? Data(contentsOf: URL(fileURLWithPath: saltPath)),
              let blobData = try? Data(contentsOf: URL(fileURLWithPath: migrationPath)) else {
            return false
        }

        let migrationKey = try deriveMigrationKey(pin: pin, salt: salt)
        let blob = try JSONDecoder().decode(MigrationBlob.self, from: blobData)

        // Verify PIN with migration key
        guard let decrypted = try? decrypt(blob.verify, key: migrationKey),
              decrypted == verificationPlaintext else {
            return false // Wrong PIN
        }

        // Derive new binary-bound key
        let newKey = try deriveKey(pin: pin, salt: salt)

        // Re-encrypt each secret with the new key and write to files
        let secretsDir = dataDir + "/secrets"
        try? FileManager.default.createDirectory(atPath: secretsDir, withIntermediateDirectories: true)

        for secret in blob.secrets {
            guard let plaintext = try? decrypt(secret.data, key: migrationKey) else { continue }
            let newData = try encrypt(plaintext, key: newKey)
            let path = secretsDir + "/" + secret.name + ".sealed"
            try newData.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }

        // Update verification blob for new key
        let newVerify = try encrypt(verificationPlaintext, key: newKey)
        try newVerify.write(to: URL(fileURLWithPath: verifyPath))

        // Clean up migration file
        try? FileManager.default.removeItem(atPath: migrationPath)

        cachedKey = newKey
        cachedPin = pin
        return true
    }

    /// Derive a key from PIN + salt only (no binary hash) for migration.
    private func deriveMigrationKey(pin: String, salt: Data) throws -> SymmetricKey {
        let pinData = Data(pin.utf8)
        var derivedKey = Data(count: 32)

        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            pinData.withUnsafeBytes { pinBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pinData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw SealKeyError.keyDerivationFailed }
        return SymmetricKey(data: derivedKey)
    }

    // MARK: - Key Derivation

    private func generateSalt() -> Data {
        var salt = Data(count: 32)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return salt
    }

    /// Hash the running binary. A rebuilt binary produces a different hash,
    /// so even with the correct PIN, a tampered binary derives a different key.
    private func binaryHash() throws -> Data {
        guard let path = Bundle.main.executablePath else {
            throw SealKeyError.binaryHashFailed
        }
        let binaryData = try Data(contentsOf: URL(fileURLWithPath: path))
        let hash = SHA256.hash(data: binaryData)
        return Data(hash)
    }

    private func deriveKey(pin: String, salt: Data) throws -> SymmetricKey {
        let pinData = Data(pin.utf8)
        // Combine salt with binary hash — ties the key to this exact binary
        let binHash = try binaryHash()
        var combinedSalt = salt
        combinedSalt.append(binHash)
        var derivedKey = Data(count: 32)

        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            pinData.withUnsafeBytes { pinBytes in
                combinedSalt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pinData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        combinedSalt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw SealKeyError.keyDerivationFailed
        }

        return SymmetricKey(data: derivedKey)
    }

    // MARK: - Encrypt / Decrypt Secrets

    func encrypt(_ plaintext: String) throws -> Data {
        guard let key = cachedKey else {
            throw SealKeyError.notUnlocked
        }
        return try encrypt(plaintext, key: key)
    }

    func decrypt(_ ciphertext: Data) throws -> String {
        guard let key = cachedKey else {
            throw SealKeyError.notUnlocked
        }
        return try decrypt(ciphertext, key: key)
    }

    private func encrypt(_ plaintext: String, key: SymmetricKey) throws -> Data {
        let data = Data(plaintext.utf8)
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw SealKeyError.encryptionFailed
        }
        return combined
    }

    private func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> String {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        let data = try AES.GCM.open(sealedBox, using: key)
        guard let plaintext = String(data: data, encoding: .utf8) else {
            throw SealKeyError.decryptionFailed
        }
        return plaintext
    }
}

// MARK: - Migration Types

private struct MigrationBlob: Codable {
    let verify: Data
    let secrets: [MigrationSecret]
}

private struct MigrationSecret: Codable {
    let name: String
    let data: Data
}

enum SealKeyError: LocalizedError {
    case notUnlocked
    case encryptionFailed
    case decryptionFailed
    case keyDerivationFailed
    case noSealData
    case binaryHashFailed
    case saltAlreadyExists

    var errorDescription: String? {
        switch self {
        case .notUnlocked: return "Seal key not unlocked — PIN required"
        case .encryptionFailed: return "Failed to encrypt secret"
        case .decryptionFailed: return "Failed to decrypt secret"
        case .keyDerivationFailed: return "Key derivation failed"
        case .noSealData: return "No seal data found — reinstall required"
        case .binaryHashFailed: return "Could not hash binary — cannot derive seal key"
        case .saltAlreadyExists: return "Seal data already exists — use unlock() or reset() first"
        }
    }
}
