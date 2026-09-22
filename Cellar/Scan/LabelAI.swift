import Foundation
import UIKit

/// Turns what the camera read into fields, by asking the pricing service's
/// `/parse-label` endpoint.
///
/// On-device OCR is good at pixels and bad at meaning: it returns the characters
/// but can't tell which line is the producer, and it has no way to know that
/// "CHATFAU MARGAIIX" is Château Margaux. `LabelParser`'s heuristics take it as
/// far as rules can; this takes it the rest of the way.
///
/// **Two modes, and the difference is the whole privacy story:**
///  * `refine(lines:)` sends only the text the phone already recognised — the
///    photo never leaves the device. Every scan does this.
///  * `read(photo:)` sends the picture, and only ever when the person taps the
///    button offering it, because the text came back unreadable.
enum LabelAI {
    /// Fields read from a label, plus how sure the reader was.
    struct Reading: Equatable {
        var label: ParsedLabel
        var confidence: Confidence
        /// True when the picture was sent rather than the text.
        var fromPhoto: Bool

        enum Confidence: String, Codable {
            case high, medium, low
        }
    }

    enum Failure: LocalizedError {
        case notConfigured
        case unavailable
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "No pricing endpoint set, so labels can't be read for you. Add one in Settings."
            case .unavailable:
                return "Label reading isn't switched on for this server."
            case .http(let code):
                return "Couldn't read the label (HTTP \(code))."
            }
        }
    }

    /// Whether the app can ask for a reading at all — used to hide the affordance
    /// rather than offer something that will fail.
    static var isAvailable: Bool { ValuationConfig.current.isConfigured }

    /// The text route: the photo stays on the phone.
    static func refine(lines: [String]) async throws -> Reading {
        guard !lines.isEmpty else { throw Failure.unavailable }
        return try await send(["lines": lines])
    }

    /// The photo route, offered only after a poor text reading and never automatic.
    /// The image is shrunk first — a label is legible well below camera resolution,
    /// and a smaller picture is both faster and cheaper to read.
    static func read(photo: UIImage) async throws -> Reading {
        guard let jpeg = ImageResizer.jpeg(from: photo, maxDimension: 1100, quality: 0.8) else {
            throw Failure.unavailable
        }
        return try await send([
            "image": ["media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
        ])
    }

    // MARK: - Transport

    private struct Response: Decodable {
        var producer: String?
        var name: String?
        var varietal: String?
        var region: String?
        var country: String?
        var vintage: Int?
        var type: String?
        var confidence: Reading.Confidence?
        var source: String?
    }

    private static func send(_ body: [String: Any]) async throws -> Reading {
        let config = ValuationConfig.current
        guard let base = config.baseURL, config.isConfigured else { throw Failure.notConfigured }

        var request = URLRequest(url: base.appendingPathComponent("parse-label"))
        request.httpMethod = "POST"
        // Reading a photo takes longer than reading a line of text, and both are
        // well inside the app's other network waits.
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Cellar-Device")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        switch http.statusCode {
        case 200..<300: break
        case 429: throw ValuationError.quotaExceeded
        case 403: throw ValuationError.accessRevoked
        case 503: throw Failure.unavailable
        default: throw Failure.http(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        var label = ParsedLabel()
        label.producer = decoded.producer?.trimmed ?? ""
        label.name = decoded.name?.trimmed ?? ""
        label.varietal = decoded.varietal?.trimmed ?? ""
        label.region = decoded.region?.trimmed ?? ""
        label.country = decoded.country?.trimmed ?? ""
        label.vintage = decoded.vintage
        label.type = decoded.type.flatMap(WineType.init(rawValue:)) ?? .red
        return Reading(label: label,
                       confidence: decoded.confidence ?? .medium,
                       fromPhoto: decoded.source == "photo")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
