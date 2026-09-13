import SwiftUI
import SwiftData

struct CellarListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Wine.createdAt, order: .reverse)])
    private var wines: [Wine]

    @State private var showingAdd = false
    @State private var searchText = ""
    @State private var typeFilter: WineType?

    private var filtered: [Wine] {
        wines.filter { wine in
            let matchesType = typeFilter == nil || wine.type == typeFilter
            let matchesSearch = searchText.isEmpty
                || wine.displayTitle.localizedCaseInsensitiveContains(searchText)
                || wine.varietal.localizedCaseInsensitiveContains(searchText)
                || wine.region.localizedCaseInsensitiveContains(searchText)
            return matchesType && matchesSearch
        }
    }

    private var cellarTotal: Decimal {
        CellarStats(wines: wines).totalValue
    }

    var body: some View {
        NavigationStack {
            Group {
                if wines.isEmpty {
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
                        Divider()
                        ForEach(WineType.allCases) { t in
                            Button(t.label) { typeFilter = t }
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
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
            LabelThumbnail(data: wine.labelImage, type: wine.type)
            VStack(alignment: .leading, spacing: 2) {
                Text(wine.displayTitle).font(.headline).lineLimit(2)
                Text([wine.varietal, wine.region].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("\(wine.inStockCount) in stock").font(.caption)
                    if wine.hasValuation {
                        Text(Money.string(wine.totalEstimatedValue))
                            .font(.caption).fontWeight(.semibold)
                    } else {
                        Text("no estimate").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LabelThumbnail: View {
    let data: Data?
    let type: WineType

    var body: some View {
        Group {
            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "wineglass").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
