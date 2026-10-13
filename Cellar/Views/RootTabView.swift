import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var importMessage: String?
    @State private var invite: ValuationConfig.Invite?
    @State private var inviteApplied: String?
    /// An order email shared from Mail, waiting to be reviewed.
    @State private var sharedOrder: OrderEmail?

    var body: some View {
        TabView {
            CellarListView()
                .tabItem { Label("Cellar", systemImage: "square.grid.2x2") }
            WishlistView()
                .tabItem { Label("Wishlist", systemImage: "star") }
            DrankView()
                .tabItem { Label("Drank", systemImage: "wineglass") }
            CellarDashboardView()
                .tabItem { Label("Value", systemImage: "chart.pie") }
        }
        .task {
            // Warm the LWIN index off the main thread so the first match is instant.
            DispatchQueue.global(qos: .utility).async { LWINDatabase.shared.loadIfNeeded() }
            // Ask once for permission to send drink-window reminders.
            await DrinkWindowNotifier.requestAuthorization()
            DataCleanup.titleCaseAllCapsNames(in: context)
            await importSharedWines()
            AutomaticBackup.runIfDue(context.container)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await importSharedWines() }
                AutomaticBackup.runIfDue(context.container)
            }
        }
        // Setup in one tap: cellar://configure?endpoint=…&token=… fills in the
        // pricing server so nobody has to type a URL into Settings. Always asks
        // first — a link can come from anywhere, and it decides where this phone
        // sends its wine lookups.
        .onOpenURL { url in
            if let parsed = ValuationConfig.invite(from: url) { invite = parsed }
        }
        .alert("Use this pricing server?",
               isPresented: Binding(get: { invite != nil }, set: { if !$0 { invite = nil } }),
               presenting: invite) { pending in
            Button("Use \(pending.host)") {
                ValuationConfig.apply(pending)
                inviteApplied = pending.host
                invite = nil
            }
            Button("Not now", role: .cancel) { invite = nil }
        } message: { pending in
            Text("Vino Cellar will look up prices at \(pending.host)\(pending.token == nil ? "" : ", using the access token in this link"). Your wines, bottles and notes stay on this phone either way. You can change or clear this in Settings.")
        }
        .alert("Pricing is set up",
               isPresented: Binding(get: { inviteApplied != nil }, set: { if !$0 { inviteApplied = nil } })) {
            Button("OK") { inviteApplied = nil }
        } message: {
            Text("Prices will be looked up at \(inviteApplied ?? "") from now on.")
        }
        .sheet(item: $sharedOrder) { email in
            OrderImportView(email: email)
        }
        .alert("Added from another app",
               isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    /// Wines shared from Vivino, Safari, etc. wait in the App Group folder until now.
    private func importSharedWines() async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        // An order shared in from Mail opens for review; it can't be imported
        // blind because the bottles need checking and placing in collections.
        if sharedOrder == nil, let order = SharedOrderStore.load().first {
            SharedOrderStore.remove(order)
            sharedOrder = order
        }
        let wines = await PendingImporter.importAll(into: context)
        guard !wines.isEmpty else { return }
        if wines.count == 1, let wine = wines.first {
            importMessage = "\(wine.displayTitle) was added to your \(wine.isWishlist ? "Wishlist" : "Cellar")."
        } else {
            let toWishlist = wines.filter(\.isWishlist).count
            importMessage = "\(wines.count) wines were added: \(toWishlist) to your Wishlist, \(wines.count - toWishlist) to your Cellar."
        }
    }
}

#Preview {
    RootTabView()
        // cloudKitDatabase: .none — with the iCloud entitlement, the default would try CloudKit.
        .modelContainer(try! ModelContainer(
            for: Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self,
            TastingNote.self, CellarCollection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
}
