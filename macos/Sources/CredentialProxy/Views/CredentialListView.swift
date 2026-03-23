import SwiftUI
import LocalAuthentication
import CredentialProxyCore

struct CredentialListView: View {
    @EnvironmentObject var apiClient: APIClient
    @EnvironmentObject var serverManager: ServerManager
    @State private var credentials: [Credential] = []
    @State private var showingAdd = false
    @State private var showingRotate: Credential?
    @State private var deleteTarget: Credential?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var revealedSecret: RevealedSecret?

    private struct RevealedSecret: Identifiable {
        let id = UUID()
        let name: String
        let value: String
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Credentials")
                    .font(.headline)
                Spacer()

                if !serverManager.isRunning {
                    Label("Server offline", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button {
                    Task { await loadCredentials() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!serverManager.isRunning)

                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!serverManager.isRunning)
            }
            .padding()

            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { errorMessage = nil }
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            // Table
            if credentials.isEmpty && !isLoading {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "key.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No credentials configured")
                        .foregroundStyle(.secondary)
                    Button("Add Credential") { showingAdd = true }
                        .disabled(!serverManager.isRunning)
                }
                Spacer()
            } else {
                Table(credentials) {
                    TableColumn("Name") { cred in
                        Text(cred.name)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn("Source") { cred in
                        Label(
                            cred.sourceType == "1password" ? "1Password" : "Encrypted",
                            systemImage: cred.sourceType == "1password" ? "lock.shield" : "lock.fill"
                        )
                        .font(.caption)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Domains") { cred in
                        Text(cred.domainsDisplay)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .width(min: 120, ideal: 200)

                    TableColumn("Placements") { cred in
                        Text(cred.placementsDisplay)
                            .font(.caption)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Uses") { cred in
                        Text("\(cred.usageCount)")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .width(40)

                    TableColumn("Last Used") { cred in
                        Text(cred.lastUsedDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("") { cred in
                        HStack(spacing: 4) {
                            Button {
                                revealSecret(cred)
                            } label: {
                                Image(systemName: "eye")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal")

                            if cred.sourceType != "1password" {
                                Button {
                                    showingRotate = cred
                                } label: {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                .buttonStyle(.borderless)
                                .help("Rotate")
                            }
                            Button {
                                deleteTarget = cred
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                        }
                    }
                    .width(80)
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCredentialView { await loadCredentials() }
                .environmentObject(apiClient)
        }
        .sheet(item: $showingRotate) { cred in
            RotateCredentialView(credential: cred) { await loadCredentials() }
                .environmentObject(apiClient)
        }
        .alert("Delete Credential", isPresented: .init(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    Task {
                        do {
                            try await apiClient.deleteCredential(name: target.name)
                            await loadCredentials()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        deleteTarget = nil
                    }
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(deleteTarget?.name ?? "")\"? This cannot be undone.")
        }
        .sheet(item: $revealedSecret) { secret in
            RevealSecretView(name: secret.name, value: secret.value)
        }
        .task(id: serverManager.isRunning) {
            if serverManager.isRunning {
                await loadCredentials()
            }
        }
    }

    private func revealSecret(_ credential: Credential) {
        let context = LAContext()
        context.localizedReason = "reveal credential"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = "Authentication not available: \(error?.localizedDescription ?? "unknown")"
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Reveal \"\(credential.name)\"") { success, authError in
            DispatchQueue.main.async {
                if success {
                    Task {
                        do {
                            let value = try await apiClient.revealCredential(name: credential.name)
                            revealedSecret = RevealedSecret(name: credential.name, value: value)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                } else if let authError {
                    if (authError as NSError).code != LAError.userCancel.rawValue {
                        errorMessage = authError.localizedDescription
                    }
                }
            }
        }
    }

    private func loadCredentials() async {
        isLoading = true
        defer { isLoading = false }
        do {
            credentials = try await apiClient.listCredentials()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct RotateCredentialView: View {
    let credential: Credential
    let onComplete: () async -> Void
    @EnvironmentObject var apiClient: APIClient
    @Environment(\.dismiss) private var dismiss
    @State private var newValue = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rotate \(credential.name)")
                .font(.headline)

            SecureField("New value", text: $newValue)
                .textFieldStyle(.roundedBorder)

            if let error = errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rotate") {
                    Task {
                        isSaving = true
                        do {
                            try await apiClient.rotateCredential(name: credential.name, newValue: newValue)
                            await onComplete()
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newValue.isEmpty || isSaving)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

struct RevealSecretView: View {
    let name: String
    let value: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(name)
                .font(.headline)

            GroupBox {
                ScrollView {
                    Text(value)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 450)
    }
}
