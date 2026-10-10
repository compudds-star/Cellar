import Foundation
import PDFKit
import UIKit

/// Reads a merchant's order email into purchases, by asking the pricing service's
/// `/parse-order` endpoint — the same server, key and per-device allowance as
/// label reading. Only the email the person chose to import is sent; nothing is
/// read from a mailbox.
enum OrderReader {
    struct Reading: Equatable {
        var merchant: String
        var orderDate: Date?
        var currency: String
        var items: [Item]
    }

    struct Item: Equatable {
        var producer = ""
        var name = ""
        var varietal = ""
        var region = ""
        var country = ""
        var vintage: Int?
        var type: WineType = .red
        var quantity = 1
        var unitPrice: Decimal?
        var bottleML: Int?
        var criticScore: Int?
        var productURL: String?
        var imageURL: String?
    }

    enum Failure: LocalizedError {
        case notConfigured
        case unavailable
        case notAnOrder
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Reading order emails needs the pricing server. Add one in Settings."
            case .unavailable:
                return "Reading order emails isn't switched on for this server."
            case .notAnOrder:
                return "That doesn't look like an order for wine or spirits."
            case .http(let code):
                return "Couldn't read the order (HTTP \(code))."
            }
        }
    }

    static var isAvailable: Bool { ValuationConfig.current.isConfigured }

    static func read(_ email: OrderEmail) async throws -> Reading {
        var body: [String: Any] = ["text": email.text]
        if !email.subject.isEmpty { body["subject"] = email.subject }
        if !email.from.isEmpty { body["from"] = email.from }
        if !email.date.isEmpty { body["date"] = email.date }
        if !email.images.isEmpty {
            body["images"] = email.images.map { ["url": $0.url, "alt": $0.alt] }
        }
        var request = try makeRequest(path: "parse-order")
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        let decoded = try JSONDecoder().decode(OrderDTO.self, from: data)
        guard decoded.is_order, !decoded.items.isEmpty else { throw Failure.notAnOrder }
        return Reading(
            merchant: decoded.merchant.trimmed,
            orderDate: Self.day(decoded.order_date) ?? email.sentDate,
            currency: decoded.currency.trimmed.uppercased().isEmpty ? "USD" : decoded.currency.trimmed.uppercased(),
            items: decoded.items.map { dto in
                Item(producer: dto.producer.trimmed,
                     name: dto.name.trimmed,
                     varietal: dto.varietal.trimmed,
                     region: dto.region.trimmed,
                     country: dto.country.trimmed,
                     vintage: dto.vintage,
                     type: WineType(rawValue: dto.type) ?? .other,
                     quantity: max(1, dto.quantity),
                     unitPrice: dto.unit_price.flatMap { $0 > 0 ? Decimal(string: String(format: "%.2f", $0)) : nil },
                     bottleML: dto.bottle_ml,
                     criticScore: dto.critic_score,
                     productURL: dto.product_url.trimmed.hasPrefix("https://") ? dto.product_url.trimmed : nil,
                     imageURL: dto.image_url.trimmed.hasPrefix("https://") ? dto.image_url.trimmed : nil)
            })
    }

    // MARK: - Pictures

    /// A bottle photo for a line: the picture from the email when it had one,
    /// otherwise one found on the web for the same wine and vintage. Nil when
    /// neither turns up — the wine is saved without one.
    static func picture(for item: Item) async -> Data? {
        if let url = item.imageURL.flatMap(URL.init(string:)), let data = await download(url) {
            return data
        }
        let query = [item.producer, item.name].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return nil }
        for url in (try? await searchImages(query: query, vintage: item.vintage)) ?? [] {
            if let data = await download(url) { return data }
        }
        return nil
    }

    static func searchImages(query: String, vintage: Int?) async throws -> [URL] {
        var request = try makeRequest(path: "find-image", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "vintage", value: vintage.map(String.init) ?? ""),
        ])
        request.timeoutInterval = 120
        let data = try await send(request)
        struct Found: Decodable { var image_urls: [String] }
        return try JSONDecoder().decode(Found.self, from: data).image_urls
            .compactMap(URL.init(string:)).filter { $0.scheme == "https" }
    }

    /// Fetches a picture and keeps it only if it really is one, resized like a
    /// label photo so it doesn't bloat the store.
    static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 15_000_000,
              let image = UIImage(data: data),
              min(image.size.width, image.size.height) >= 80 else { return nil }
        return ImageResizer.jpeg(from: image, maxDimension: 1200, quality: 0.8)
    }

    // MARK: - Files

    /// An email from a file: a saved message (.eml), a web page, a PDF (Mail's
    /// Print → Share), or plain text.
    static func email(fromFile data: Data, fileExtension: String) -> OrderEmail? {
        let email: OrderEmail
        if fileExtension.lowercased() == "pdf" {
            guard let text = PDFDocument(data: data)?.string else { return nil }
            email = OrderEmail(text: OrderEmail.tidy(text))
        } else {
            let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            email = OrderEmail.from(raw: raw)
        }
        return email.isEmpty ? nil : email
    }

    // MARK: - Transport

    private struct OrderDTO: Decodable {
        var is_order: Bool
        var merchant: String
        var order_date: String
        var currency: String
        var items: [ItemDTO]
    }

    private struct ItemDTO: Decodable {
        var producer: String
        var name: String
        var varietal: String
        var region: String
        var country: String
        var vintage: Int?
        var type: String
        var quantity: Int
        var unit_price: Double?
        var bottle_ml: Int?
        var critic_score: Int?
        var product_url: String
        var image_url: String
    }

    private static func makeRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        let config = ValuationConfig.current
        guard let base = config.baseURL, config.isConfigured else { throw Failure.notConfigured }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw Failure.notConfigured }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Cellar-Device")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        switch http.statusCode {
        case 200..<300: return data
        case 429: throw ValuationError.quotaExceeded
        case 403: throw ValuationError.accessRevoked
        case 404, 503: throw Failure.unavailable
        default: throw Failure.http(http.statusCode)
        }
    }

    /// "2026-09-14" → that day, at noon local so it never slips a day in display.
    static func day(_ text: String) -> Date? {
        let parts = text.trimmed.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
