import SwiftUI
import SwiftData

struct CellarListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Wine.createdAt, order: .reverse)])
    private var wines: [Wine]

    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var typeFilter: WineType?
    @State private var scope: CollectionScope = .all
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @Query(sort: \CellarCollection.name) private var collections: [CellarCollection]

    private var filtered: [Wine] {
        wines.filter { wine in
            guard !wine.isWishlist else { return false }
            let matchesType = typeFilter == nil || wine.type == typeFilter
            let matchesScope = scope == .all || !wine.inStockBottles(in: scope).isEmpty
            let matchesSearch = searchText.isEmpty
                || wine.displayTitle.localizedCaseInsensitiveContains(searchText)
                || wine.varietal.localizedCaseInsensitiveContains(searchText)
                || wine.region.localizedCaseInsensitiveContains(searchText)
            return matchesType && matchesScope && matchesSearch
        }
        .sorted(by: Wine.alphabeticalOrder)
    }

    private var selectedWines: [Wine] { filtered.filter { selection.contains($0.id) } }
    /// In-stock bottles of the selected wines that a move would take (within the collection filter).
    private var selectedBottleCount: Int {
        selectedWines.reduce(0) { $0 + $1.inStockBottles(in: scope).count }
    }

    private var cellarTotal: Decimal {
        CellarStats(wines: wines.filter { !$0.isWishlist }, scope: scope).totalValue
    }

    var body: some View {
        NavigationStack {
            Group {
                if !wines.contains(where: { !$0.isWishlist }) {
                    ContentUnavailableView {
                        Label("Your cellar is empty", systemImage: "wineglass")
                    } description: {
                        Text("Scan a label or add a wine by hand to get started.")
                    } actions: {
                        Button("Add wine") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(selection: $selection) {
                        Section {
                            ForEach(filtered) { wine in
                                NavigationLink(value: wine) {
                                    WineRow(wine: wine, scope: scope)
                                }
                            }
                            // No delete buttons while selecting, so a mis-tap can't delete a wine.
                            .onDelete(perform: editMode.isEditing ? nil : delete)
                        } header: {
                            HStack {
                                Text("\(filtered.count) wines")
                                Spacer()
                                Text("\(scope == .all ? "Cellar" : scope.title) value \(Money.string(cellarTotal))")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(scope == .all ? "Cellar" : scope.title)
            .onChange(of: collections) { _, current in
                // A deleted collection can't stay selected.
                if case .collection(let selected) = scope, !current.contains(selected) { scope = .all }
            }
            .searchable(text: $searchText, prompt: "Search wines")
            .navigationDestination(for: Wine.self) { WineDetailView(wine: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("All types") { typeFilter = nil }
                        Section("Wine") {
                            ForEach(WineType.wines) { t in
                                Button(t.label) { typeFilter = t }
                            }
                        }
                        Section("Spirits") {
                            ForEach(WineType.spirits) { t in
                                Button(t.label) { typeFilter = t }
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !collections.isEmpty {
                        Menu {
                            Picker("Collection", selection: $scope) {
                                Text("All collections").tag(CollectionScope.all)
                                ForEach(collections) { Text($0.name).tag(CollectionScope.collection($0)) }
                                Text("No collection").tag(CollectionScope.unassigned)
                            }
                        } label: {
                            Label("Collection", systemImage: scope == .all ? "archivebox" : "archivebox.fill")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if wines.contains(where: { !$0.isWishlist }) {
                        Button(editMode.isEditing ? "Done" : "Select") {
                            withAnimation {
                                editMode = editMode.isEditing ? .inactive : .active
                                selection.removeAll()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                if editMode.isEditing {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Text("\(selection.count) wine\(selection.count == 1 ? "" : "s") · \(selectedBottleCount) bottle\(selectedBottleCount == 1 ? "" : "s")")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        MoveToCollectionMenu(bottleCount: selectedBottleCount) { destination in
                            CollectionMover.move(bottlesOf: selectedWines, in: scope, to: destination)
                            withAnimation {
                                selection.removeAll()
                                editMode = .inactive
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddWineFlow()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            // Rebuild drink-window reminders when the cellar's composition changes.
            .task(id: wines.count) {
                await DrinkWindowNotifier.rescheduleAll(for: wines)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(filtered[index]) }
    }
}

struct WineRow: View {
    let wine: Wine
    /// Counts and values only the bottles in this collection.
    var scope: CollectionScope = .all

    var body: some View {
        HStack(spacing: 12) {
            WineThumbnail(imageData: wine.labelImage, imageURL: wine.imageURL, type: wine.type)
            VStack(alignment: .leading, spacing: 3) {
                Text(wine.displayTitle).font(.headline).lineLimit(2)
                let sub = [wine.varietal, wine.region].filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let rating = wine.rating, rating > 0 {
                        StarsInline(rating: rating)
                    }
                    if !wine.isWishlist {
                        Text("\(wine.inStockBottles(in: scope).count) in stock").font(.caption).foregroundStyle(.secondary)
                        if wine.hasValuation {
                            Text("· \(Money.string(wine.totalEstimatedValue(in: scope)))")
                                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                        }
                    } else if let best = wine.bestOfferPrice {
                        Text("from \(Money.string(best))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
