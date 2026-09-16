import Foundation

enum ValuationError: LocalizedError {
    case notConfigured
    case insecureEndpoint
    case badResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No pricing endpoint set. Add one in Settings."
        case .insecureEndpoint:
            return "The pricing endpoint must use HTTPS."
        case .badResponse:
            return "The pricing service returned an unexpected response."
        case .http(let code):
            return "The pricing service returned an error (HTTP \(code))."
        }
    }
}

/// The JSON the app expects back from the endpoint. Provider-agnostic: your
/// proxy adapts Wine-Searcher / Apify / CellarTracker into this shape, so the
/// app never encodes any one provider's schema.
///
///     GET {baseURL}/valuation?lwin={lwin11}&q={producer name}&vintage={year}&currency=USD
///     → { "average": 189.00, "min": 165.00, "max": 220.00, "currency": "USD",
///         "offers": [ { "merchant": "…", "price": 175.00, "currency": "USD",
///                       "url": "https://…", "address": "…",
///                       "latitude": 41.0, "longitude": -73.7, "inStock": true } ] }
struct RemoteValuationDTO: Decodable {
    var average: Decimal?
    var min: Decimal?
    var max: Decimal?
    var currency: String?
    /// Critic/community score on the 100-point scale.
    var score: Int?
    /// Label image URL.
    var image: String?
    var offers: [OfferDTO]?
    /// Which provider actually priced the wine ("vivino", "wine-searcher", …).
    /// Older proxies omit it; `sourceName` is the fallback.
    var source: String?

    struct OfferDTO: Decodable {
        var merchant: String
        var price: Decimal?
        var currency: String?
        var url: String?
        var address: String?
        var latitude: Double?
        var longitude: Double?
        var inStock: Bool?
    }
}

/// Talks to the configured endpoint and maps its response into the app's
/// `ValuationService` and `PurchaseService` abstractions. One fetch backs both,
/// so a refresh makes a single network call.
struct RemoteValuationClient: ValuationService, PurchaseService {
    let config: ValuationConfig
    var session: URLSession = .shared
    /// Source tag written onto snapshots; overridable if you point at a
    /// non-Wine-Searcher backend.
    var sourceName: String = "wine-searcher"

    func estimate(for wine: Wine) async throws -> ValuationResult? {
        guard let dto = try await fetch(for: wine), let avg = dto.average else { return nil }
        return ValuationResult(averagePrice: avg,
                               minPrice: dto.min,
                               maxPrice: dto.max,
                               currency: dto.currency ?? "USD",
                               source: dto.source ?? sourceName,
                               score: dto.score,
                               imageURL: dto.image)
    }

    func offers(for wine: Wine) async throws -> [MerchantOffer] {
        guard let dto = try await fetch(for: wine) else { return [] }
        return (dto.offers ?? []).map { o in
            MerchantOffer(merchantName: o.merchant,
                          price: o.price,
                          currency: o.currency ?? "USD",
                          productURL: o.url.flatMap { URL(string: $0) },
                          address: o.address,
                          latitude: o.latitude,
                          longitude: o.longitude,
                          inStock: o.inStock ?? true)
        }
    }

    // MARK: - Networking

    private func fetch(for wine: Wine) async throws -> RemoteValuationDTO? {
        guard let request = try makeRequest(for: wine) else { return nil }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ValuationError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw ValuationError.http(http.statusCode) }
        return try JSONDecoder().decode(RemoteValuationDTO.self, from: data)
    }

    private func makeRequest(for wine: Wine) throws -> URLRequest? {
        guard let base = config.baseURL else { throw ValuationError.notConfigured }
        guard ValuationConfig.isAcceptableEndpoint(base) else { throw ValuationError.insecureEndpoint }

        guard var comps = URLComponents(
            url: base.appendingPathComponent("valuation"),
            resolvingAgainstBaseURL: false) else { return nil }

        var items = [URLQueryItem(name: "currency", value: "USD")]
        if let lwin = wine.lwin11 { items.append(URLQueryItem(name: "lwin", value: lwin)) }
        let q = [wine.producer, wine.name].filter { !$0.isEmpty }.joined(separator: " ")
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if let v = wine.vintage { items.append(URLQueryItem(name: "vintage", value: String(v))) }
        comps.queryItems = items
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        // A cold lookup scrapes live listings through the proxy (~30–60 s);
        // repeats are served from the proxy's 7-day cache.
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Credential travels in the header only, never the URL — so it can't
        // land in server logs or a shared link.
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
