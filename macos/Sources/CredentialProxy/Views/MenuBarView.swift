import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var apiClient: APIClient
    @State private var credentials: [Credential] = []
    @State private var updateStatus: String?
    @State private var showPinPrompt = false
    @State private var pinInput = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status
            HStack {
                Circle()
                    .fill(serverManager.isRunning ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(serverManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Divider()

            // Credential summary
            if credentials.isEmpty {
                Text("No credentials configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            } else {
                ForEach(credentials.prefix(5)) { cred in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cred.name)
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                            Text(cred.domainsDisplay)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(cred.usageCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
                if credentials.count > 5 {
                    Text("+\(credentials.count - 5) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
            }

            Divider()

            // Actions
            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Manage Credentials...", systemImage: "list.bullet")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            Button {
                if serverManager.isRunning {
                    serverManager.stop()
                } else {
                    serverManager.start()
                    apiClient.setToken(serverManager.getToken())
                }
            } label: {
                Label(
                    serverManager.isRunning ? "Stop Server" : "Start Server",
                    systemImage: serverManager.isRunning ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            Button {
                if SealKeyManager.shared.isUnlocked {
                    doPrepareForUpdate()
                } else {
                    showPinPrompt = true
                    pinInput = ""
                    updateStatus = nil
                }
            } label: {
                Label("Prepare for Update", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            if showPinPrompt {
                HStack(spacing: 6) {
                    SecureField("Enter PIN", text: $pinInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onSubmit { unlockAndPrepare() }
                    Button("Go") { unlockAndPrepare() }
                        .disabled(pinInput.isEmpty)
                }
                .padding(.horizontal, 12)
            }

            if let status = updateStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(status.hasPrefix("Failed") || status.hasPrefix("Wrong") ? .red : .green)
                    .padding(.horizontal, 12)
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Credential Proxy", systemImage: "xmark.circle")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 280)
        .task {
            apiClient.setToken(serverManager.getToken())
            serverManager.start()
        }
        .task(id: serverManager.isRunning) {
            if serverManager.isRunning {
                credentials = (try? await apiClient.listCredentials()) ?? []
            }
        }
    }

    private func doPrepareForUpdate() {
        do {
            try SealKeyManager.shared.prepareForUpdate()
            updateStatus = "Ready for update"
            showPinPrompt = false
        } catch {
            updateStatus = "Failed: \(error.localizedDescription)"
        }
    }

    private func unlockAndPrepare() {
        do {
            if try SealKeyManager.shared.unlock(pin: pinInput) {
                doPrepareForUpdate()
            } else {
                updateStatus = "Wrong PIN"
            }
        } catch {
            updateStatus = "Failed: \(error.localizedDescription)"
        }
        pinInput = ""
    }
}
