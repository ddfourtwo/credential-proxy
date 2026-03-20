import SwiftUI
import CredentialProxyCore

struct UpdateCredentialView: View {
    let name: String
    let currentDomains: [String]
    let currentPlacements: [String]
    let currentCommands: [String]?
    let proposedDomains: [String]?
    let proposedPlacements: [String]?
    let proposedCommands: [String]?
    let onComplete: (Bool) -> Void

    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)
                Text("Claude wants to update a credential")
                    .font(.headline)
            }

            Divider()

            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text("Credential").font(.caption).foregroundStyle(.secondary)
                Text(name)
                    .font(.system(.body, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
            }

            // Changes
            if let domains = proposedDomains {
                changeRow(label: "Allowed Domains",
                          current: currentDomains.joined(separator: ", "),
                          proposed: domains.joined(separator: ", "))
            }

            if let placements = proposedPlacements {
                changeRow(label: "Allowed Placements",
                          current: currentPlacements.joined(separator: ", "),
                          proposed: placements.joined(separator: ", "))
            }

            if let commands = proposedCommands {
                changeRow(label: "Allowed Commands",
                          current: currentCommands?.joined(separator: ", ") ?? "(none)",
                          proposed: commands.joined(separator: ", "))
            }

            Text("The secret value will not be changed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Deny") { onComplete(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding()
        .frame(width: 500)
    }

    @ViewBuilder
    private func changeRow(label: String, current: String, proposed: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(current)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .strikethrough()
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(proposed)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.blue)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        let placementValues = proposedPlacements?.compactMap { SecretPlacement(rawValue: $0) }

        Task {
            do {
                let updated = try await SecretStore.shared.updateSecretMetadata(
                    name: name,
                    allowedDomains: proposedDomains,
                    allowedPlacements: placementValues,
                    allowedCommands: proposedCommands
                )
                if !updated {
                    errorMessage = "Credential not found"
                    isSaving = false
                } else {
                    onComplete(true)
                }
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
