import Foundation

/// A price estimate for a wine, currency-agnostic at the value layer.
struct ValuationResult {
    var averagePrice: Decimal
    var minPrice: Decimal?
    var maxPrice: Decimal?
    var currency: String
    var source: String
    /// Critic/community score on the 100-point scale, when the provider returns one.
    var score: Int?
    /// Label image URL from the provider database, when available.
    var imageURL: String?
}

/// Abstraction over "what is this wine worth?" so the UI never knows whether
/// the number came from the user, a cached snapshot, or a paid API.
///
/// Ship day one with `ManualValuationService` (offline, zero cost). Later, add
/// e.g. `WineSearcherValuationService: ValuationService` that hits a proxy on
/// your own host and returns a `ValuationResult` — no UI change required.
protocol ValuationService {
    /// Look up an estimate. Return nil when the service can't price this wine.
    func estimate(for wine: Wine) async throws -> ValuationResult?
}

/// Offline baseline. There is no remote pricing yet: the "estimate" is whatever
/// the user typed as the manual per-750mL value, echoed back as a snapshot so
/// the rest of the app treats manual and enriched values identically.
struct ManualValuationService: ValuationService {
    func estimate(for wine: Wine) async throws -> ValuationResult? {
        guard let manual = wine.manualEstimatedValue else { return nil }
        return ValuationResult(averagePrice: manual,
                               minPrice: nil,
                               maxPrice: nil,
                               currency: "USD",
                               source: "manual",
                               score: nil,
                               imageURL: nil)
    }
}

// MARK: - Currency formatting

enum Money {
    static func string(_ amount: Decimal, currency: String = "USD") -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        return f.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}
