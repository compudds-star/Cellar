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
    @State private var lastRefresh: PriceLookup.BulkResult?
    @State private var refreshError: String?
    @Query(sort: \CellarCollection.name) private var collections: [CellarCollection]

    private var filtered: [Wine] {
        wines.filter { wine in
            // Wishlist wines and finished ones (no stock left) have their own tabs.
            guard !wine.isWishlist, !wine.isDrank else { return false }
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

    /// One section of the list. The list reads Collection → Wine or Spirits →
    /// style, but a SwiftUI section has only one header, so each shelf carries the
    /// headings it is the first to need: `collectionTitle` on the first shelf of a
    /// collection, `groupTitle` on the first of that collection's wines or spirits.
    private struct Shelf: Identifiable {
        let scope: CollectionScope
        let type: WineType
        let wines: [Wine]
        let collectionTitle: String?
        let groupTitle: String?
        /// Every wine in this collection's Wine (or Spirits) half — what the group
        /// heading counts.
        let groupWines: [Wine]
        let id: String
        var isWineStyle: Bool { !type.isSpirit }
    }

    /// Collections are only a heading when there is a choice to make: filter to one
    /// and the name is already in the title, and with no collections at all there is
    /// nothing to head.
    private var showsCollectionHeadings: Bool { scope == .all && !collections.isEmpty }

    /// Which collections the list is divided into, in name order, with unassigned
    /// bottles last. A wine kept in two places appears under both, counted in each.
    private var listScopes: [CollectionScope] {
        guard showsCollectionHeadings else { return [scope] }
        let candidates = collections.map { CollectionScope.collection($0) } + [.unassigned]
        return candidates.filter { s in filtered.contains { !$0.inStockBottles(in: s).isEmpty } }
    }

    /// Collection, then wine styles in their usual order (Red, White, Rosé…), then
    /// the spirits alphabetically. Producers are already alphabetical inside each.
    private var shelves: [Shelf] {
        var result: [Shelf] = []
        for listScope in listScopes {
            let here = filtered.filter { !$0.inStockBottles(in: listScope).isEmpty }
            guard !here.isEmpty else { continue }
            let byType = Dictionary(grouping: here, by: \.type)
            let styles = WineType.wines.filter { byType[$0] != nil }
            let spirits = byType.keys.filter(\.isSpirit)
                .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            let wineHalf = here.filter { !$0.type.isSpirit }
            let spiritHalf = here.filter { $0.type.isSpirit }
            var firstOfCollection = true

            for (index, type) in (styles + spirits).enumerated() {
                let isSpirit = type.isSpirit
                let startsGroup = isSpirit ? (index == styles.count) : (index == 0)
                result.append(Shelf(
                    scope: listScope,
                    type: type,
                    wines: byType[type] ?? [],
                    collectionTitle: firstOfCollection && showsCollectionHeadings ? listScope.title : nil,
                    groupTitle: startsGroup ? (isSpirit ? "Spirits" : "Wine") : nil,
                    groupWines: isSpirit ? spiritHalf : wineHalf,
                    id: "\(listScope.title)|\(type.rawValue)"))
                firstOfCollection = false
            }
        }
        return result
    }

    private var selectedWines: [Wine] { filtered.filter { selection.contains($0.id) } }
    /// In-stock bottles of the selected wines that a move would take (within the collection filter).
    private var selectedBottleCount: Int {
        selectedWines.reduce(0) { $0 + $1.inStockBottles(in: scope).count }
    }

    /// Wines whose bottles make up the cellar value shown (respects the collection filter).
    private var pricedWines: [Wine] {
        wines.filter { !$0.isWishlist && !$0.inStockBottles(in: scope).isEmpty }
    }

    /// In-stock bottles of the wines listed (within the collection filter).
    private var bottleCount: Int {
        filtered.reduce(0) { $0 + $1.inStockBottles(in: scope).count }
    }

    private var cellarTotal: Decimal {
        CellarStats(wines: wines.filter { !$0.isWishlist }, scope: scope).totalValue
    }

    var body: some View {
        NavigationStack {
            Group {
                if !wines.contains(where: { !$0.isWishlist && !$0.isDrank }) {
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
                        ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
                            Section {
                                ForEach(shelf.wines) { wine in
                                    NavigationLink(value: wine) {
                                        WineRow(wine: wine, scope: shelf.scope)
                                    }
                                }
                                // No delete buttons while selecting, so a mis-tap can't delete a wine.
                                .onDelete(perform: editMode.isEditing ? nil : { delete(shelf.wines, at: $0) })
                            } header: {
                                VStack(alignment: .leading, spacing: 8) {
                                    // The cellar summary rides on the first section's header.
                                    if index == 0 { summaryHeader }
                                    shelfHeader(shelf)
                                }
                                .textCase(nil)
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
                    if wines.contains(where: { !$0.isWishlist && !$0.isDrank }) {
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
            .alert("Couldn't refresh prices",
                   isPresented: Binding(get: { refreshError != nil }, set: { if !$0 { refreshError = nil } })) {
                Button("OK") { refreshError = nil }
            } message: {
                Text(refreshError ?? "")
            }
            // Rebuild drink-window reminders when the cellar's composition changes.
            .task(id: wines.count) {
                await DrinkWindowNotifier.rescheduleAll(for: wines)
            }
        }
    }

    /// Wine and bottle counts on the left, cellar value and the refresh control on the right.
    private var summaryHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(filtered.count) wine\(filtered.count == 1 ? "" : "s")")
                Text("\(bottleCount) bottle\(bottleCount == 1 ? "" : "s")")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(scope == .all ? "Cellar" : scope.title) value \(Money.string(cellarTotal))")
                    .fontWeight(.semibold)
                refreshControl
            }
        }
    }

    /// The bold category heading (only on the section that carries it) and, for wine,
    /// the style underneath it.
    @ViewBuilder
    private func shelfHeader(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let collection = shelf.collectionTitle {
                HStack(spacing: 6) {
                    Image(systemName: "archivebox.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(collection).font(.title3.weight(.bold)).foregroundStyle(.primary)
                    bottlesCaption(filtered.filter { !$0.inStockBottles(in: shelf.scope).isEmpty },
                                   in: shelf.scope)
                }
            }
            if let group = shelf.groupTitle {
                HStack(spacing: 6) {
                    Text(group).font(.headline.weight(.bold)).foregroundStyle(.primary)
                    bottlesCaption(shelf.groupWines, in: shelf.scope)
                }
                .padding(.leading, shelf.collectionTitle == nil && !showsCollectionHeadings ? 0 : 10)
            }
            HStack(spacing: 6) {
                Circle().fill(shelf.type.tint).frame(width: 8, height: 8)
                Text(shelf.type.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                bottlesCaption(shelf.wines, in: shelf.scope)
            }
            .padding(.leading, showsCollectionHeadings ? 20 : 10)
        }
    }

    /// "12 bottles" for a set of wines, counting only the collection in view.
    private func bottlesCaption(_ wines: [Wine], in scope: CollectionScope) -> some View {
        let bottles = wines.reduce(0) { $0 + $1.inStockBottles(in: scope).count }
        return Text("\(bottles) bottle\(bottles == 1 ? "" : "s")")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Refresh arrow and its status on one line, under the cellar value.
    private var refreshControl: some View {
        HStack(spacing: 8) {
            Button {
                Task { await refreshAllPrices() }
            } label: {
                Label("Refresh Prices", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
            }
            .disabled(PriceLookup.shared.bulkProgress != nil || pricedWines.isEmpty)
            refreshStatus
        }
        .textCase(nil)
    }

    /// Status line under the button: live progress, the last run's outcome, or how old the prices are.
    @ViewBuilder
    private var refreshStatus: some View {
        Group {
            if let progress = PriceLookup.shared.bulkProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                }
            } else if let result = lastRefresh {
                Text("Updated \(result.updated) of \(result.total) wine\(result.total == 1 ? "" : "s")"
                     + (result.failed > 0 ? " · \(result.failed) failed" : ""))
            } else if let oldest = pricedWines.compactMap({ $0.latestValuation }).filter({ $0.source != "manual" }).map(\.asOf).min() {
                Text("Prices from \(oldest.formatted(.relative(presentation: .named)))")
            } else {
                Text("No online prices yet")
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// Re-prices every wine counted in the cellar value; the total updates as results arrive.
    private func refreshAllPrices() async {
        guard ValuationCoordinator.isConfigured else {
            refreshError = ValuationError.notConfigured.errorDescription
            return
        }
        lastRefresh = nil
        do {
            let result = try await PriceLookup.shared.refreshAll(pricedWines, context: context)
            lastRefresh = result
            if result.total > 0, result.failed == result.total {
                refreshError = result.firstError
            }
        } catch {
            refreshError = (error as? ValuationError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete(_ wines: [Wine], at offsets: IndexSet) {
        for index in offsets { context.delete(wines[index]) }
    }
}

struct WineRow: View {
    let wine: Wine
    /// Counts and values only the bottles in this collection.
    var scope: CollectionScope = .all

    var body: some View {
        // Top-aligned so the name stays level with the top of the label, whatever
        // the rating column adds below it.
        HStack(alignment: .top, spacing: 12) {
            // A larger label than a thumbnail, with the critic score under it.
            VStack(spacing: 5) {
                WineThumbnail(imageData: wine.labelImage, type: wine.type,
                              width: 72, height: 116)
                if let score = wine.communityScore {
                    ScoreBadge(score: score, large: true)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(wine.nameLine).font(.headline).lineLimit(2)
                Text(wine.vintageLabel).font(.footnote.weight(.semibold))
                let sub = [wine.varietal, wine.region].filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let window = DrinkWindowEstimate.window(for: wine) {
                    Text("Peak \(window.label)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let rating = wine.rating, rating > 0 {
                        StarsInline(rating: rating)
                    }
                    if wine.isDrank {
                        Text("Drank").font(.caption).foregroundStyle(.secondary)
                        if let date = wine.lastConsumedDate {
                            Text("· \(date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if !wine.isWishlist {
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
