import SwiftUI
import SwiftData
import Charts

private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct CellarDashboardView: View {
    @Query private var wines: [Wine]
    @State private var exportItem: ExportItem?
    @State private var exportError: String?

    private var owned: [Wine] { wines.filter { !$0.isWishlist } }
    private var stats: CellarStats { CellarStats(wines: owned) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 4) {
                        Text(Money.string(stats.totalValue))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                        Text("Estimated cellar value")
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

                if !stats.byType.isEmpty {
                    Section("Value by type") {
                        Chart(stats.byType, id: \.type) { entry in
                            BarMark(
                                x: .value("Value", (entry.value as NSDecimalNumber).doubleValue),
                                y: .value("Type", entry.type.label))
                            .annotation(position: .trailing) {
                                Text(Money.string(entry.value)).font(.caption2)
                            }
                        }
                        .frame(height: CGFloat(stats.byType.count) * 44 + 20)
                    }
                }
            }
            .navigationTitle("Value")
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

    private func export(_ make: () throws -> URL) {
        do { exportItem = ExportItem(url: try make()) }
        catch { exportError = error.localizedDescription }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title2).fontWeight(.semibold)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
