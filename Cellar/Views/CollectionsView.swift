import SwiftUI
import SwiftData

/// Collection chooser for bottle forms, with an inline "New collection…" option.
struct CollectionPicker: View {
    @Binding var selection: CellarCollection?
    @Environment(\.modelContext) private var context
    @Query(sort: \CellarCollection.name) private var collections: [CellarCollection]
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        Picker("Collection", selection: $selection) {
            Text("None").tag(CellarCollection?.none)
            ForEach(collections) { Text($0.name).tag(Optional($0)) }
        }
        Button {
            newName = ""
            naming = true
        } label: {
            Label("New collection…", systemImage: "plus")
        }
        .alert("New collection", isPresented: $naming) {
            TextField("Name (e.g. Beach house)", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                if let created = CollectionStore.create(named: newName, in: context) { selection = created }
            }
        }
    }
}

/// Add, rename, and delete collections, with each one's total.
struct CollectionsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CellarCollection.name) private var collections: [CellarCollection]
    @Query private var wines: [Wine]
    @State private var naming = false
    @State private var nameText = ""
    @State private var renaming: CellarCollection?
    @State private var deleting: CellarCollection?

    private var owned: [Wine] { wines.filter { !$0.isWishlist } }

    var body: some View {
        List {
            if collections.isEmpty {
                ContentUnavailableView {
                    Label("No collections yet", systemImage: "archivebox")
                } description: {
                    Text("Name a collection for each place you keep bottles, like Home or Beach house.")
                }
            }
            ForEach(collections) { collection in
                let stats = CellarStats(wines: owned, scope: .collection(collection))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                        Text("\(stats.bottleCount) bottle\(stats.bottleCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Money.string(stats.totalValue)).foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleting = collection
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        nameText = collection.name
                        renaming = collection
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Collections")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    nameText = ""
                    naming = true
                } label: {
                    Label("New collection", systemImage: "plus")
                }
            }
        }
        .alert("New collection", isPresented: $naming) {
            TextField("Name (e.g. Beach house)", text: $nameText)
            Button("Cancel", role: .cancel) {}
            Button("Create") { CollectionStore.create(named: nameText, in: context) }
        }
        .alert("Rename collection", isPresented: Binding(get: { renaming != nil },
                                                          set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { renaming?.name = name }
                renaming = nil
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "collection")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let collection = deleting { context.delete(collection) }
                deleting = nil
            }
        } message: {
            Text("Its bottles stay in your cellar without a collection.")
        }
    }
}

/// One collection's (or the unassigned bottles') totals and wines.
struct CollectionDetailView: View {
    let scope: CollectionScope
    @Query(sort: [SortDescriptor(\Wine.createdAt, order: .reverse)]) private var wines: [Wine]

    private var owned: [Wine] { wines.filter { !$0.isWishlist } }
    private var winesInScope: [Wine] { owned.filter { !$0.inStockBottles(in: scope).isEmpty } }

    var body: some View {
        List {
            StatsSummarySections(stats: CellarStats(wines: owned, scope: scope), caption: "Estimated value")
            Section("Wines") {
                if winesInScope.isEmpty {
                    Text("No bottles here yet.").foregroundStyle(.secondary)
                }
                ForEach(winesInScope) { wine in
                    NavigationLink(value: wine) {
                        WineRow(wine: wine, scope: scope)
                    }
                }
            }
        }
        .navigationTitle(scope.title)
    }
}
