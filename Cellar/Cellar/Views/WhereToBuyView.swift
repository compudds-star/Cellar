import SwiftUI
import MapKit

/// "Where can I buy this?" — two parts:
///  1. Online offers from a `PurchaseService` (stubbed empty in the baseline).
///  2. Wine stores physically near you (MapKit), with one-tap directions.
struct WhereToBuyView: View {
    let wine: Wine

    @State private var stores: [NearbyStore] = []
    @State private var offers: [MerchantOffer] = []
    @State private var loading = false
    @State private var locationDenied = false

    private let purchaseService: PurchaseService = NoRemotePurchaseService()

    var body: some View {
        List {
            Section("Online") {
                if offers.isEmpty {
                    Text("No online pricing configured yet. Add a PurchaseService to show merchant offers here.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(offers) { offer in
                        HStack {
                            Text(offer.merchantName)
                            Spacer()
                            if let p = offer.price { Text(Money.string(p, currency: offer.currency)) }
                        }
                    }
                }
            }

            Section("Nearby wine stores") {
                if loading {
                    HStack { ProgressView(); Text("Finding stores near you…") }
                } else if locationDenied {
                    Text("Location access is off. Enable it in Settings to find nearby stores.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if stores.isEmpty {
                    Text("No stores found nearby.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(stores) { store in
                        Button {
                            NearbyStores.openDirections(to: store)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(store.name).fontWeight(.medium)
                                    Spacer()
                                    if let d = store.distanceMeters {
                                        Text(distanceString(d)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if !store.address.isEmpty {
                                    Text(store.address).font(.caption).foregroundStyle(.secondary)
                                }
                                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
                                    .font(.caption).foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Where to buy")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        offers = (try? await purchaseService.offers(for: wine)) ?? []
        if let coord = await OneShotLocation().current() {
            stores = await NearbyStores.search(near: coord)
        } else {
            locationDenied = true
        }
    }

    private func distanceString(_ meters: CLLocationDistance) -> String {
        let miles = meters / 1609.34
        return miles < 10 ? String(format: "%.1f mi", miles) : String(format: "%.0f mi", miles)
    }
}
