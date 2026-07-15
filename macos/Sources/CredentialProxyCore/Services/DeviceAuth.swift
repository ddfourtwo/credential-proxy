import Foundation
import LocalAuthentication

/// Server-side human-presence gate for operations that hand a plaintext secret
/// back to the caller (i.e. /reveal). Enforcing this in the server — not just the
/// GUI client — means any caller (agent CLI, raw HTTP with a stolen mgmt token,
/// the GUI) must pass the local user's Touch ID / password before a secret value
/// leaves the process. Fails closed: if device auth is unavailable, access is denied.
public enum DeviceAuth {
    /// Prompt for device-owner authentication (Touch ID, falling back to password).
    /// Returns true only on an explicit successful authentication.
    public static func require(reason: String) async -> Bool {
        let context = LAContext()

        var canEvalError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &canEvalError) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
