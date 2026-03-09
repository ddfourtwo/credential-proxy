import SwiftUI

struct PinEntryView: View {
    let seal = SealKeyManager.shared
    let onUnlocked: () -> Void

    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var errorMessage = ""
    @State private var attempts = 0
    @State private var isFirstRun: Bool
    @State private var isConfirming = false
    @State private var showResetConfirm = false

    init(onUnlocked: @escaping () -> Void) {
        self.onUnlocked = onUnlocked
        _isFirstRun = State(initialValue: SealKeyManager.shared.isFirstRun)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            SecureField(isConfirming ? "Confirm PIN" : "Enter PIN", text: isConfirming ? $confirmPin : $pin)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { submit() }

            HStack(spacing: 12) {
                if attempts > 0 && !isFirstRun {
                    Button("Reset") { showResetConfirm = true }
                        .foregroundStyle(.red)
                }

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.cancelAction)

                Button(isFirstRun ? (isConfirming ? "Confirm" : "Next") : "Unlock") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(currentPin.isEmpty)
            }

            if showResetConfirm {
                Divider()
                VStack(spacing: 8) {
                    Text("This will delete all encrypted secrets. You will need to re-add your credentials after setting a new PIN.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Cancel") { showResetConfirm = false }
                        Button("Reset Everything") { doReset() }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(32)
        .frame(width: 320)
    }

    private var currentPin: String { isConfirming ? confirmPin : pin }

    private var title: String {
        if isFirstRun {
            return isConfirming ? "Confirm PIN" : "Set Up Credential Proxy"
        }
        return "Unlock Credential Proxy"
    }

    private var subtitle: String {
        if isFirstRun {
            return isConfirming
                ? "Re-enter your PIN to confirm."
                : "Choose a PIN to protect your secrets.\nThis PIN will be required each time the app launches."
        }
        if attempts > 0 {
            return "Wrong PIN (attempt \(attempts)). Try again.\nIf you updated the app, click Reset."
        }
        return "Enter your PIN to unlock secrets."
    }

    private func submit() {
        errorMessage = ""
        if isFirstRun {
            if !isConfirming {
                guard !pin.isEmpty else { return }
                isConfirming = true
                return
            }
            // Confirming
            if pin != confirmPin {
                errorMessage = "PINs don't match. Try again."
                confirmPin = ""
                isConfirming = false
                pin = ""
                return
            }
            do {
                try seal.setup(pin: pin)
                onUnlocked()
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            do {
                // Try migration first (binary was updated)
                if seal.hasPendingMigration {
                    if try seal.completeMigration(pin: pin) {
                        onUnlocked()
                        return
                    }
                }
                if try seal.unlock(pin: pin) {
                    onUnlocked()
                } else {
                    attempts += 1
                    pin = ""
                    errorMessage = ""
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func doReset() {
        seal.reset()
        isFirstRun = true
        isConfirming = false
        pin = ""
        confirmPin = ""
        attempts = 0
        errorMessage = ""
    }
}
