import Foundation
import SwiftUI
import CredentialProxyCore

/// Manages credential request windows triggered by AI agents.
/// The agent calls request_credential → HTTP endpoint → this manager opens a UI window
/// where the user can paste the secret value.
class CredentialRequestManager {
    static let shared = CredentialRequestManager()

    private init() {}

    /// Request a credential from the user via a macOS UI window.
    /// Returns true if the user saved the credential, false if cancelled or timed out.
    func requestCredential(
        name: String,
        domains: [String],
        placements: [String],
        commands: [String]?
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "Credential Request"
                window.center()
                window.isReleasedWhenClosed = false

                var hasResumed = false

                let view = RequestCredentialView(
                    name: name,
                    initialDomains: domains,
                    initialPlacements: placements,
                    initialCommands: commands
                ) { saved in
                    guard !hasResumed else { return }
                    hasResumed = true
                    window.close()
                    NSApplication.shared.setActivationPolicy(.accessory)
                    continuation.resume(returning: saved)
                }

                window.contentView = NSHostingView(rootView: view)

                // Close button = cancel
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    guard !hasResumed else { return }
                    hasResumed = true
                    NSApplication.shared.setActivationPolicy(.accessory)
                    continuation.resume(returning: false)
                }

                // Float above everything and activate app
                window.level = .floating
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()


                // 5-minute timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                    guard !hasResumed else { return }
                    hasResumed = true
                    window.close()
                    NSApplication.shared.setActivationPolicy(.accessory)
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
