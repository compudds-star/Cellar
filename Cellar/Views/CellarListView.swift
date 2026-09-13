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

    private var filtered: [Wine] {
        wines.filter { wine in
            guard !wine.isWishlist else { return false }
            let matchesType = typeFilter == nil || wine.type == typeFilter
            let matchesSearch = searchText.isEmpty
                || wine.displayTitle.localizedCaseInsensitiveContains(searchText)
                || wine.varietal.localizedCaseInsensitiveContains(searchText)
                || wine.region.localizedCaseInsensitiveContains(searchText)
            return matchesType && matchesSearch
        }
    }

    private var cellarTotal: Decimal {
        CellarStats(wines: wines.filter { !$0.isWishlist }).totalValue
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
                    List {
                        Section {
                            ForEach(filtered) { wine in
                                NavigationLink(value: wine) {
                                    WineRow(wine: wine)
                                }
                            }
                            .onDelete(perform: delete)
                        } header: {
                            HStack {
                                Text("\(filtered.count) wines")
                                Spacer()
                                Text("Cellar value \(Money.string(cellarTotal))")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cellar")
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
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
                        Text("\(wine.inStockCount) in stock").font(.caption).foregroundStyle(.secondary)
                        if wine.hasValuation {
                            Text("· \(Money.string(wine.totalEstimatedValue))")
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
