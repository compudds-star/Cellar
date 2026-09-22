import SwiftUI
import SwiftData

/// App settings: defaults for new bottles, and online pricing. The endpoint and
/// defaults are stored in UserDefaults; the API key goes to the Keychain and is
/// never shown back in full.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CellarCollection.name) private var collections: [CellarCollection]

    @State private var collectionDefault = CollectionMemory.defaultChoice
    @State private var wineSize = BottleDefaults.wine
    @State private var spiritSize = BottleDefaults.spirit

    @State private var baseURLText = ValuationSettings.baseURL?.absoluteString ?? ""
    @State private var apiKeyText = ""
    @State private var hasStoredKey = APIKeyStore.hasKey
    @State private var invalidURL = false
    @State private var copiedID = false
    private let deviceID = DeviceIdentity.current

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Collection", selection: $collectionDefault) {
                        Text("Last used").tag(CollectionDefault.lastUsed)
                        Text("None").tag(CollectionDefault.noCollection)
                        ForEach(collections) { Text($0.name).tag(CollectionDefault.collection($0.id)) }
                    }
                    BottleSizePicker(selection: $wineSize, title: "Wine bottle size")
                    BottleSizePicker(selection: $spiritSize, title: "Spirits bottle size")
                } header: {
                    Text("Defaults for new bottles")
                } footer: {
                    Text("Used when adding wine or bottles; you can still change them each time.")
                }

                Section("Pricing endpoint") {
                    TextField("https://your-host or http://192.168.1.20:8787", text: $baseURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if invalidURL {
                        Text("Use https://, or http:// only for a local proxy (localhost, *.local, or a 192.168/10/172.16 address). Leave blank to disable online pricing.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Text("HTTPS for real hosts. Plain http:// works only for a dev proxy on your Mac — on an iPhone use the Mac's LAN address, not 127.0.0.1.")
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
                    NavigationLink {
                        InviteFriendView()
                    } label: {
                        Label("Invite a friend", systemImage: "person.badge.plus")
                    }
                } footer: {
                    Text("Passes this pricing server on as a QR code or a link, so they don't have to type any of it.")
                }

                Section {
                    Text("Prices are cached per wine for 7 days, so a paid API is hit at most once per wine per week.")
                        .font(.caption).foregroundStyle(.secondary)
                } footer: {
                    // Deliberately quiet rather than hidden: when lookups stop working
                    // the first question is "what's your device id?", and neither side
                    // can answer that about an invisible field.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Device ID")
                            Text(deviceID).monospaced()
                            Button {
                                UIPasteboard.general.string = deviceID
                                copiedID = true
                            } label: {
                                Image(systemName: copiedID ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy device ID")
                        }
                        // Which build someone is on — the other half of any
                        // "it doesn't work on my phone" conversation.
                        Text(AppVersion.display)
                            .accessibilityIdentifier("app-version")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                // A deleted default collection falls back to "Last used".
                if case .collection(let id) = collectionDefault, !collections.contains(where: { $0.id == id }) {
                    collectionDefault = .lastUsed
                }
            }
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
            guard let url = URL(string: trimmed), ValuationConfig.isAcceptableEndpoint(url) else {
                invalidURL = true
                return
            }
            ValuationSettings.baseURL = url
        }
        let key = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { APIKeyStore.save(key) }
        CollectionMemory.defaultChoice = collectionDefault
        BottleDefaults.wine = wineSize
        BottleDefaults.spirit = spiritSize
        dismiss()
    }
}
