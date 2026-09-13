import Foundation
import CoreLocation

/// An online offer for a wine from a merchant. Value type — persisted as a
/// `PurchaseOption` only if the user pins it.
struct MerchantOffer: Identifiable {
    let id = UUID()
    var merchantName: String
    var price: Decimal?
    var currency: String = "USD"
    var productURL: URL?
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var inStock: Bool = true

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// "Where can I buy this online, and for how much?" Stubbed for the offline
/// baseline (returns none). Wire a real implementation later — e.g. a client
/// that calls a Wine-Searcher proxy on your own host — with no UI change.
protocol PurchaseService {
    func offers(for wine: Wine) async throws -> [MerchantOffer]
}

/// Offline baseline: no online pricing yet. The nearby-store path
/// (`NearbyStores`, MapKit-based) still works and needs no service.
struct NoRemotePurchaseService: PurchaseService {
    func offers(for wine: Wine) async throws -> [MerchantOffer] { [] }
}
