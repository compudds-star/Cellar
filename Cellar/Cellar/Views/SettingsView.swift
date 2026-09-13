import SwiftUI

/// Configure online pricing. The endpoint is stored in UserDefaults; the API
/// key goes to the Keychain and is never shown back in full.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var baseURLText = ValuationSettings.baseURL?.absoluteString ?? ""
    @State private var apiKeyText = ""
    @State private var hasStoredKey = APIKeyStore.hasKey
    @State private var invalidURL = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Pricing endpoint") {
                    TextField("https://your-host/api", text: $baseURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if invalidURL {
                        Text("Enter a valid https:// URL, or leave blank to disable online pricing.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Text("Must be HTTPS. Recommended: a small proxy on your own host that holds the provider key and caches results.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("API key") {
                    SecureField(hasStoredKey ? "•••••••• (stored)" : "Paste key (optional)",
                                text: $apiKeyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if hasStoredKey {
                        Button("Remove stored key", role: .destructive) {
                            APIKeyStore.delete()
                            hasStoredKey = false
                            apiKeyText = ""
                        }
                    }
                    Text("Stored in the Keychain on this device only, never in the app bundle. Leave blank if your proxy holds the key.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Text("Prices are cached per wine for 7 days, so a paid API is hit at most once per wine per week.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pricing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ValuationSettings.baseURL = nil
        } else {
            guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
                invalidURL = true
                return
            }
            ValuationSettings.baseURL = url
        }
        let key = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { APIKeyStore.save(key) }
        dismiss()
    }
}
