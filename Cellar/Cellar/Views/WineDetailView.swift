import SwiftUI
import SwiftData

struct WineDetailView: View {
    @Bindable var wine: Wine
    @Environment(\.modelContext) private var context
    @State private var estimateText = ""
    @State private var editingEstimate = false

    var body: some View {
        List {
            if let data = wine.labelImage, let ui = UIImage(data: data) {
                Section {
                    Image(uiImage: ui).resizable().scaledToFit()
                        .frame(maxWidth: .infinity).frame(maxHeight: 220)
                }
                .listRowInsets(EdgeInsets())
            }

            Section("Details") {
                detailRow("Varietal", wine.varietal)
                detailRow("Region", [wine.region, wine.country].filter { !$0.isEmpty }.joined(separator: ", "))
                detailRow("Type", wine.type.label)
                detailRow("Vintage", wine.vintage.map(String.init) ?? "NV")
            }

            Section("Value") {
                HStack {
                    Text("Per 750 mL estimate")
                    Spacer()
                    if editingEstimate {
                        TextField("0.00", text: $estimateText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        Button("Set") {
                            wine.manualEstimatedValue = Decimal(string: estimateText)
                            editingEstimate = false
                        }
                    } else {
                        Text(wine.hasValuation ? Money.string(wine.estimatedUnitValue) : "—")
                            .foregroundStyle(.secondary)
                        Button("Edit") {
                            estimateText = wine.manualEstimatedValue.map { "\($0)" } ?? ""
                            editingEstimate = true
                        }
                    }
                }
                HStack {
                    Text("In-stock total")
                    Spacer()
                    Text(Money.string(wine.totalEstimatedValue)).fontWeight(.semibold)
                }
                if let snap = wine.latestValuation {
                    Text("From \(snap.source), \(snap.asOf.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Bottles (\(wine.inStockCount) in stock)") {
                ForEach(wine.bottles.sorted { $0.addedAt < $1.addedAt }) { bottle in
                    BottleRow(bottle: bottle)
                }
                Button {
                    let b = Bottle(size: .standard)
                    b.wine = wine
                    context.insert(b)
                } label: {
                    Label("Add a bottle", systemImage: "plus")
                }
            }

            Section {
                NavigationLink {
                    WhereToBuyView(wine: wine)
                } label: {
                    Label("Where to buy", systemImage: "map")
                }
            }

            if !wine.notes.isEmpty {
                Section("Notes") { Text(wine.notes) }
            }
        }
        .navigationTitle(wine.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value)
            }
        }
    }
}

struct BottleRow: View {
    @Bindable var bottle: Bottle

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.size.label).font(.subheadline)
                if !bottle.storageLocation.isEmpty {
                    Text(bottle.storageLocation).font(.caption).foregroundStyle(.secondary)
                }
                if let price = bottle.purchasePrice {
                    Text("Paid \(Money.string(price))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                ForEach(BottleStatus.allCases) { s in
                    Button(s.label) {
                        bottle.status = s
                        bottle.consumedDate = (s == .consumed) ? .now : nil
                    }
                }
            } label: {
                Text(bottle.status.label)
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(bottle.status.isInCellar ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }
}
