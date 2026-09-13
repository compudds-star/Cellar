import SwiftUI
import SwiftData

@main
struct CellarApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema([
            Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self
        ])
        // On-device store in Application Support. No CloudKit for the baseline;
        // switch `cloudKitDatabase` to `.automatic` + add the iCloud entitlement
        // later for cross-device sync.
        let storeURL = URL.applicationSupportDirectory.appending(path: "Cellar.store")
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(container)
    }
}
