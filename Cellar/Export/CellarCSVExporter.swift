import Foundation

/// Builds a CSV of the cellar — one row per bottle so quantities, sizes, prices,
/// and storage locations are all preserved. Pure string builder (testable);
/// `write` drops it in a temp file for the share sheet.
enum CellarCSVExporter {
    static let columns = [
        "Producer", "Name", "Vintage", "Varietal", "Region", "Country", "Type",
        "LWIN", "Size", "Status", "Storage", "PurchasePrice", "PurchaseDate",
        "DrinkFrom", "DrinkTo", "YourRating", "CommunityScore",
        "EstUnitValue", "BestOnlinePrice"
    ]

    static func csv(for wines: [Wine]) -> String {
        var lines = [columns.joined(separator: ",")]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")

        for wine in wines.sorted(by: { $0.displayTitle < $1.displayTitle }) {
            let bottles = wine.bottles.sorted { $0.addedAt < $1.addedAt }
            // A wine with no bottles still exports one informational row.
            let rows: [Bottle?] = bottles.isEmpty ? [nil] : bottles.map { Optional($0) }
            for bottle in rows {
                let fields: [String] = [
                    esc(wine.producer),
                    esc(wine.name),
                    wine.vintage.map { String($0) } ?? "NV",
                    esc(wine.varietal),
                    esc(wine.region),
                    esc(wine.country),
                    esc(wine.type.label),
                    wine.lwin11 ?? wine.lwin7 ?? "",
                    esc(bottle?.size.label ?? ""),
                    esc(bottle?.status.label ?? ""),
                    esc(bottle?.storageLocation ?? ""),
                    bottle?.purchasePrice.map { "\($0)" } ?? "",
                    bottle?.purchaseDate.map { df.string(from: $0) } ?? "",
                    bottle?.drinkFrom.map { "\($0)" } ?? "",
                    bottle?.drinkTo.map { "\($0)" } ?? "",
                    wine.rating.map { "\($0)" } ?? "",
                    wine.communityScore.map { "\($0)" } ?? "",
                    wine.hasValuation ? "\(wine.estimatedUnitValue)" : "",
                    wine.bestOfferPrice.map { "\($0)" } ?? ""
                ]
                lines.append(fields.joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func write(_ wines: [Wine]) throws -> URL {
        let stamp = fileStamp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cellar-\(stamp).csv")
        try csv(for: wines).data(using: .utf8)?.write(to: url)
        return url
    }

    // Quote a field if it contains comma, quote, or newline; double interior quotes.
    private static func esc(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: .now)
    }
}
