import SwiftUI
import SwiftData

private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct CellarDashboardView: View {
    @Query private var wines: [Wine]
    @Query(sort: \CellarCollection.name) private var collections: [CellarCollection]
    @State private var exportItem: ExportItem?
    @State private var exportError: String?

    private var owned: [Wine] { wines.filter { !$0.isWishlist } }
    private var stats: CellarStats { CellarStats(wines: owned) }

    var body: some View {
        NavigationStack {
            List {
                StatsSummarySections(stats: stats, caption: "Estimated cellar value")
                collectionsSection
            }
            .navigationTitle("Value")
            .navigationDestination(for: CollectionScope.self) { CollectionDetailView(scope: $0) }
            .navigationDestination(for: Wine.self) { WineDetailView(wine: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            export { try CellarCSVExporter.write(owned) }
                        } label: { Label("Export CSV", systemImage: "tablecells") }
                        Button {
                            export { try CellarPDFExporter.write(owned) }
                        } label: { Label("Export PDF summary", systemImage: "doc.richtext") }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(owned.isEmpty)
                }
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(items: [item.url])
            }
            .alert("Export failed", isPresented: .constant(exportError != nil)) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    /// A total per collection (plus unassigned bottles), each opening its breakdown.
    private var collectionsSection: some View {
        Section {
            ForEach(collections) { collection in
                collectionRow(.collection(collection))
            }
            if !collections.isEmpty, CellarStats(wines: owned, scope: .unassigned).bottleCount > 0 {
                collectionRow(.unassigned)
            }
            NavigationLink {
                CollectionsView()
            } label: {
                Label(collections.isEmpty ? "Create collections" : "Manage collections", systemImage: "archivebox")
            }
        } header: {
            Text("Collections")
        } footer: {
            if collections.isEmpty {
                Text("Name a collection for each place you keep bottles to see a total for each.")
            }
        }
    }

    private func collectionRow(_ scope: CollectionScope) -> some View {
        let s = CellarStats(wines: owned, scope: scope)
        return NavigationLink(value: scope) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scope.title)
                    Text("\(s.bottleCount) bottle\(s.bottleCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Money.string(s.totalValue)).fontWeight(.semibold)
            }
        }
    }

    private func export(_ make: () throws -> URL) {
        do { exportItem = ExportItem(url: try make()) }
        catch { exportError = error.localizedDescription }
    }
}

/// Total, counts, and value-by-type chart for a set of bottles.
struct StatsSummarySections: View {
    let stats: CellarStats
    let caption: String

    var body: some View {
        Section {
            VStack(spacing: 4) {
                Text(Money.string(stats.totalValue))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text(caption)
                    .font(.subheadline).foregroundStyle(.secondary)
                if stats.hasUnvaluedBottles {
                    Text("\(stats.bottleCount - stats.valuedBottleCount) of \(stats.bottleCount) bottles have no estimate — total is a floor.")
                        .font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }

        Section {
            HStack {
                stat("Bottles", "\(stats.bottleCount)")
                Divider()
                stat("Wines", "\(stats.wineCount)")
                Divider()
                stat("Valued", "\(stats.valuedBottleCount)")
            }
        }

        if stats.pricedBottleCount > 0 {
            Section {
                HStack {
                    Text("You paid")
                    Spacer()
                    Text(Money.string(stats.paidTotal)).fontWeight(.semibold)
                }
                if let gain = stats.gainDescription {
                    HStack {
                        Text("Gain")
                        Spacer()
                        Text(gain)
                            .fontWeight(.semibold)
                            .foregroundStyle(stats.gain < 0 ? Color.red : Color.green)
                    }
                }
            } header: {
                Text("Cost & gain")
            } footer: {
                if stats.comparableBottleCount < stats.bottleCount {
                    Text("Gain covers the \(stats.comparableBottleCount) of \(stats.bottleCount) bottles that have both a price paid and an estimate.")
                }
            }
        }

        if !stats.byType.isEmpty {
            Section("Value by type") {
                ValueByTypeBars(entries: stats.byType)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title2).fontWeight(.semibold)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Value per type as horizontal bars. Laid out by hand rather than with Swift Charts
/// so each type's name, bar, and amount always sit on the same line, at any width.
private struct ValueByTypeBars: View {
    let entries: [(type: WineType, value: Decimal, bottles: Int)]

    private func amount(_ value: Decimal) -> Double { (value as NSDecimalNumber).doubleValue }
    private var largest: Double { max(entries.map { amount($0.value) }.max() ?? 0, 0.01) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(entries, id: \.type) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.type.label).font(.subheadline)
                        Text("\(entry.bottles) bottle\(entry.bottles == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(Money.string(entry.value))
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            // A sliver keeps a small-but-real value visible.
                            Capsule().fill(entry.type.tint)
                                .frame(width: max(geo.size.width * amount(entry.value) / largest,
                                                  amount(entry.value) > 0 ? 3 : 0))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
