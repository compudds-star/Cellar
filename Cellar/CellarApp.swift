import SwiftUI
import SwiftData
import os

@main
struct CellarApp: App {
    /// The store, or why it couldn't be opened. Never crashes on a store error:
    /// the user sees what happened and can retry (e.g. after unlocking).
    @State private var store = CellarApp.openStore()

    var body: some Scene {
        WindowGroup {
            switch store {
            case .success(let container):
                RootTabView()
                    .modelContainer(container)
            case .failure(let error):
                StoreErrorView(error: error) {
                    store = CellarApp.openStore()
                }
            }
        }
    }

    private static let log = Logger(subsystem: "com.doony.cellar", category: "store")

    static func openStore() -> Result<ModelContainer, Error> {
        let schema = Schema([
            Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self,
            TastingNote.self
        ])
        // On-device store in Application Support. No CloudKit for the baseline;
        // switch `cloudKitDatabase` to `.automatic` + add the iCloud entitlement
        // later for cross-device sync.
        let storeURL = URL.applicationSupportDirectory.appending(path: "Cellar.store")
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        do {
            return .success(try ModelContainer(for: schema, configurations: config))
        } catch {
            log.error("Could not create ModelContainer: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }
    }
}

/// Shown instead of the app when the cellar database can't be opened. The data
/// on disk is left untouched so nothing is lost; retrying may succeed once the
/// cause (locked device, low storage) clears.
private struct StoreErrorView: View {
    let error: Error
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't open your cellar", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Your wines are still on this iPhone. Try again, and if this keeps happening, restart the phone or free up storage.")
            Text(error.localizedDescription)
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}
