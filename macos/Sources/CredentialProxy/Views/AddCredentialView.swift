import SwiftUI

struct AddCredentialView: View {
    let onComplete: () async -> Void
    @EnvironmentObject var apiClient: APIClient
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var value = ""
    @State private var domainsText = ""
    @State private var placements: Set<String> = ["header"]
    @State private var commandsText = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private let allPlacements = ["header", "body", "query", "env", "arg"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Credential")
                .font(.headline)

            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("GITHUB_TOKEN", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("SCREAMING_SNAKE_CASE (e.g., API_KEY, GITHUB_TOKEN)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Value
            VStack(alignment: .leading, spacing: 4) {
                Text("Value").font(.caption).foregroundStyle(.secondary)
                SecureField("Secret value", text: $value)
                    .textFieldStyle(.roundedBorder)
            }

            // Domains
            VStack(alignment: .leading, spacing: 4) {
                Text("Allowed Domains").font(.caption).foregroundStyle(.secondary)
                TextField("api.github.com, *.example.com", text: $domainsText)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated. Use *.domain.com for wildcards.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Placements
            VStack(alignment: .leading, spacing: 4) {
                Text("Allowed Placements").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(allPlacements, id: \.self) { placement in
                        Toggle(placement, isOn: Binding(
                            get: { placements.contains(placement) },
                            set: { isOn in
                                if isOn { placements.insert(placement) }
                                else { placements.remove(placement) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
            }

            // Commands (optional)
            VStack(alignment: .leading, spacing: 4) {
                Text("Allowed Commands (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("git *, npm publish", text: $commandsText)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated glob patterns for exec proxy. Leave empty to skip.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isSaving)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private var isValid: Bool {
        !name.isEmpty && !value.isEmpty && !domainsText.isEmpty && !placements.isEmpty
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        let domains = domainsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let cmds = commandsText.isEmpty ? nil : commandsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        Task {
            do {
                try await apiClient.addCredential(
                    name: name.uppercased(),
                    value: value,
                    allowedDomains: domains,
                    allowedPlacements: Array(placements),
                    allowedCommands: cmds
                )
                await onComplete()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
