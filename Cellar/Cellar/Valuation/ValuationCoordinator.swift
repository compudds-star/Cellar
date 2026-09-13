import Foundation
import SwiftData

/// Orchestrates pricing: picks the remote service when an endpoint is
/// configured (else nothing), enforces a cache TTL so a paid API is hit at most
/// once per wine per window, and persists results as `ValuationSnapshot` +
/// `PurchaseOption` rows the rest of the app already reads.
enum ValuationCoordinator {

    /// Whether online lookups are available right now.
    static var isConfigured: Bool { ValuationConfig.current.isConfigured }

    private static func remoteService() -> (ValuationService & PurchaseService)? {
        let cfg = ValuationConfig.current
        guard cfg.isConfigured else { return nil }
        return RemoteValuationClient(config: cfg)
    }

    /// True when the wine already has a remote snapshot newer than the TTL.
    static func isFresh(_ wine: Wine, ttlDays: Int = 7) -> Bool {
        guard let snap = wine.latestValuation, snap.source != "manual",
              let cutoff = Calendar.current.date(byAdding: .day, value: -ttlDays, to: .now)
        else { return false }
        return snap.asOf > cutoff
    }

    /// Refresh valuation + offers for a wine and persist them. No-ops (returns
    /// false) when data is still fresh and `force` is false. Throws
    /// `ValuationError.notConfigured` if there's no endpoint.
    @MainActor
    @discardableResult
    static func refresh(_ wine: Wine,
                        context: ModelContext,
                        force: Bool = false,
                        ttlDays: Int = 7) async throws -> Bool {
        guard let service = remoteService() else { throw ValuationError.notConfigured }
        if !force, isFresh(wine, ttlDays: ttlDays) { return false }

        // One network call backs both, via the shared DTO on the client.
        let result = try await service.estimate(for: wine)
        let offers = try await service.offers(for: wine)

        if let result {
            let snapshot = ValuationSnapshot(averagePrice: result.averagePrice,
                                             minPrice: result.minPrice,
                                             maxPrice: result.maxPrice,
                                             currency: result.currency,
                                             source: result.source)
            snapshot.wine = wine
            context.insert(snapshot)
            if let score = result.score { wine.communityScore = score }
            // Only fill a DB image when there's no scanned photo.
            if wine.labelImage == nil, let img = result.imageURL { wine.imageURL = img }
        }

        // Replace prior remotely-fetched offers; keep it simple and idempotent.
        for old in wine.purchaseOptions { context.delete(old) }
        for offer in offers {
            let option = PurchaseOption(merchantName: offer.merchantName,
                                        price: offer.price,
                                        currency: offer.currency,
                                        productURL: offer.productURL?.absoluteString,
                                        latitude: offer.latitude,
                                        longitude: offer.longitude,
                                        addressLine: offer.address,
                                        inStock: offer.inStock)
            option.wine = wine
            context.insert(option)
        }
        return result != nil || !offers.isEmpty
    }
}
