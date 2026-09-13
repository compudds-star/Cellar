import SwiftUI
import SwiftData
import MapKit

/// "Where can I buy this?" — two parts:
///  1. Online offers fetched by the `ValuationCoordinator` (merchant, price,
///     link), persisted as `PurchaseOption` rows and shown here.
///  2. Wine stores physically near you (MapKit), with one-tap directions.
struct WhereToBuyView: View {
    @Bindable var wine: Wine
    @Environment(\.modelContext) private var context

    @State private var stores: [NearbyStore] = []
    @State private var loadingStores = false
    @State private var refreshingOffers = false
    @State private var locationDenied = false
    @State private var errorMessage: String?

    private var offers: [PurchaseOption] {
        wine.purchaseOptions.sorted { ($0.price ?? .greatestFiniteMagnitude) < ($1.price ?? .greatestFiniteMagnitude) }
    }

    var body: some View {
        List {
            Section {
                if offers.isEmpty {
                    Text(ValuationCoordinator.isConfigured
                         ? "No online offers yet. Tap Refresh to look them up."
                         : "Set a pricing endpoint in Settings to show online offers.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(offers.enumerated()), id: \.element.id) { index, offer in
                        // offers is sorted cheapest-first; badge the lowest price.
                        OfferRow(offer: offer, isCheapest: index == 0 && offer.price != nil)
                    }
                }
                if ValuationCoordinator.isConfigured {
                    Button {
                        Task { await refreshOffers() }
                    } label: {
                        HStack {
                            Label("Refresh offers", systemImage: "arrow.clockwise")
                            if refreshingOffers { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(refreshingOffers)
                }
            } header: {
                Text("Online")
            }

            Section("Nearby wine stores") {
                if loadingStores {
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
        .alert("Couldn't fetch offers", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await loadStores() }
    }

    private func refreshOffers() async {
        guard !refreshingOffers else { return }
        refreshingOffers = true
        defer { refreshingOffers = false }
        do {
            _ = try await ValuationCoordinator.refresh(wine, context: context, force: true)
        } catch let error as ValuationError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadStores() async {
        loadingStores = true
        defer { loadingStores = false }
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

struct OfferRow: View {
    let offer: PurchaseOption
    var isCheapest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(offer.merchantName).fontWeight(.medium)
                if isCheapest {
                    Text("Best price")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Capsule())
                }
                Spacer()
                if let price = offer.price {
                    Text(Money.string(price, currency: offer.currency))
                        .fontWeight(isCheapest ? .semibold : .regular)
                        .foregroundStyle(isCheapest ? .green : .primary)
                }
            }
            if let address = offer.addressLine, !address.isEmpty {
                Text(address).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if let urlString = offer.productURL, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Label("Open", systemImage: "safari").font(.caption)
                    }
                }
                if offer.hasCoordinate,
                   let lat = offer.latitude, let lon = offer.longitude {
                    Button {
                        let store = NearbyStore(name: offer.merchantName,
                                                address: offer.addressLine ?? "",
                                                coordinate: .init(latitude: lat, longitude: lon),
                                                phone: nil, distanceMeters: nil)
                        NearbyStores.openDirections(to: store)
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
    }
}
